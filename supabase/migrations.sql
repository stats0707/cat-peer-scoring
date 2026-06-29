-- ============================================================
-- 猫咪互评评分系统 - Supabase 数据库迁移脚本
-- 项目ID: chemkvrwogihnfnmvwzh
-- 请在 Supabase Dashboard > SQL Editor 中打开 New Query，
-- 复制全部内容，点击 Run 执行
-- ============================================================

-- ============================================================
-- 第一部分：创建 groups 表 + 种子数据
-- ============================================================
CREATE TABLE public.groups (
    id          INT PRIMARY KEY,
    members     TEXT[] NOT NULL,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

INSERT INTO public.groups (id, members) VALUES
  (1,  ARRAY['宋泽','魏海洋','孔文兴','李祥斌']),
  (2,  ARRAY['刘能浩','李向川','曹迎春']),
  (3,  ARRAY['彭翔栩','李文武','施润','王嵘俊']),
  (4,  ARRAY['邵明雨','朱俊莹','苏国']),
  (5,  ARRAY['朱楠','龙文静','朱明芬']),
  (6,  ARRAY['罗雯霄','李娜','张鑫雨','胡俊仪']),
  (7,  ARRAY['蔡奇仙','李美婷','胡兴蕊']),
  (8,  ARRAY['马跃芸','王永利','钱思怡']),
  (9,  ARRAY['代长美','罗微','赵国慧']),
  (10, ARRAY['曹希萌','马富容','崔冬月']),
  (11, ARRAY['陈玉曼','金淑靖']),
  (12, ARRAY['李韩']);

-- ============================================================
-- 第二部分：创建 scores 表 + 索引 + 触发器
-- ============================================================
CREATE TABLE public.scores (
    id          BIGSERIAL PRIMARY KEY,
    rater_group INT NOT NULL REFERENCES public.groups(id),
    rated_group INT NOT NULL REFERENCES public.groups(id),
    scores      JSONB NOT NULL,
    total       SMALLINT NOT NULL CHECK (total BETWEEN 6 AND 60),
    created_at  TIMESTAMPTZ DEFAULT NOW(),
    updated_at  TIMESTAMPTZ DEFAULT NOW(),
    
    CONSTRAINT unique_rater_rated UNIQUE (rater_group, rated_group),
    CONSTRAINT no_self_score CHECK (rater_group != rated_group)
);

CREATE INDEX idx_scores_rater ON public.scores(rater_group);
CREATE INDEX idx_scores_rated ON public.scores(rated_group);

CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_scores_updated_at
    BEFORE UPDATE ON public.scores
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- ============================================================
-- 第三部分：创建 group_results 视图（排名计算）
-- ============================================================
CREATE VIEW public.group_results AS
WITH score_aggs AS (
    SELECT
        rated_group,
        COUNT(*) AS score_count,
        ROUND(AVG(total), 2) AS avg_total,
        ROUND(AVG((scores->>'背景介绍')::NUMERIC), 2)   AS "avg_背景介绍",
        ROUND(AVG((scores->>'数据说明')::NUMERIC), 2)   AS "avg_数据说明",
        ROUND(AVG((scores->>'数据描述性分析')::NUMERIC), 2) AS "avg_数据描述性分析",
        ROUND(AVG((scores->>'数据建模分析')::NUMERIC), 2) AS "avg_数据建模分析",
        ROUND(AVG((scores->>'商业化应用')::NUMERIC), 2) AS "avg_商业化应用",
        ROUND(AVG((scores->>'报告格式与展示')::NUMERIC), 2) AS "avg_报告格式与展示"
    FROM public.scores
    GROUP BY rated_group
)
SELECT
    g.id AS group_id,
    g.members,
    COALESCE(s.avg_total, 0) AS avg_total,
    COALESCE(s.score_count, 0) AS score_count,
    COALESCE(s."avg_背景介绍", 0) AS "avg_背景介绍",
    COALESCE(s."avg_数据说明", 0) AS "avg_数据说明",
    COALESCE(s."avg_数据描述性分析", 0) AS "avg_数据描述性分析",
    COALESCE(s."avg_数据建模分析", 0) AS "avg_数据建模分析",
    COALESCE(s."avg_商业化应用", 0) AS "avg_商业化应用",
    COALESCE(s."avg_报告格式与展示", 0) AS "avg_报告格式与展示",
    RANK() OVER (ORDER BY COALESCE(s.avg_total, 0) DESC) AS rank
FROM public.groups g
LEFT JOIN score_aggs s ON g.id = s.rated_group
ORDER BY avg_total DESC NULLS LAST;

-- ============================================================
-- 第四部分：创建 upsert_score RPC 函数（评分提交+验证）
-- ============================================================
CREATE OR REPLACE FUNCTION public.upsert_score(
    p_rater_group INT,
    p_rated_group INT,
    p_scores JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_total INT;
    v_dim TEXT;
    v_val INT;
    v_dims CONSTANT TEXT[] := ARRAY[
        '背景介绍', '数据说明', '数据描述性分析',
        '数据建模分析', '商业化应用', '报告格式与展示'
    ];
    v_existing_id BIGINT;
BEGIN
    IF p_rater_group = p_rated_group THEN
        RETURN jsonb_build_object('success', false, 'error', '不能给自己的小组评分哦~ 🐱');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.groups WHERE id = p_rater_group) THEN
        RETURN jsonb_build_object('success', false, 'error', '无效的评分者组号');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.groups WHERE id = p_rated_group) THEN
        RETURN jsonb_build_object('success', false, 'error', '无效的被评组号');
    END IF;

    FOREACH v_dim IN ARRAY v_dims LOOP
        IF p_scores->>v_dim IS NULL THEN
            RETURN jsonb_build_object('success', false, 'error', '缺少评分维度: ' || v_dim);
        END IF;
    END LOOP;

    FOREACH v_dim IN ARRAY v_dims LOOP
        v_val := (p_scores->>v_dim)::INT;
        IF v_val < 1 OR v_val > 10 THEN
            RETURN jsonb_build_object('success', false, 'error', v_dim || ' 评分需为1-10之间的数字');
        END IF;
    END LOOP;

    v_total := (p_scores->>'背景介绍')::INT
             + (p_scores->>'数据说明')::INT
             + (p_scores->>'数据描述性分析')::INT
             + (p_scores->>'数据建模分析')::INT
             + (p_scores->>'商业化应用')::INT
             + (p_scores->>'报告格式与展示')::INT;

    SELECT id INTO v_existing_id
    FROM public.scores
    WHERE rater_group = p_rater_group AND rated_group = p_rated_group;

    INSERT INTO public.scores (rater_group, rated_group, scores, total)
    VALUES (p_rater_group, p_rated_group, p_scores, v_total)
    ON CONFLICT (rater_group, rated_group)
    DO UPDATE SET scores = p_scores, total = v_total, updated_at = NOW();

    RETURN jsonb_build_object(
        'success', true,
        'message', '喵~ 评分已保存！🐾',
        'total', v_total,
        'action', CASE WHEN v_existing_id IS NULL THEN 'created' ELSE 'updated' END
    );
END;
$$;

-- ============================================================
-- 第五部分：创建 get_groups_with_progress RPC 函数
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_groups_with_progress()
RETURNS TABLE(
    group_id       INT,
    members        TEXT[],
    member_count   INT,
    scored_count   BIGINT,
    total_to_score INT
)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT
        g.id,
        g.members,
        array_length(g.members, 1)::INT,
        COUNT(s.id),
        11
    FROM public.groups g
    LEFT JOIN public.scores s ON s.rater_group = g.id
    GROUP BY g.id, g.members
    ORDER BY g.id;
$$;

-- ============================================================
-- 第六部分：创建教师专用 RPC 函数
-- ============================================================
CREATE OR REPLACE FUNCTION public.reset_all_scores()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', '需要教师登录');
    END IF;
    DELETE FROM public.scores;
    RETURN jsonb_build_object('success', true, 'message', '所有评分已重置');
END;
$$;

CREATE OR REPLACE FUNCTION public.export_all_scores()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_scores JSONB;
    v_results JSONB;
BEGIN
    IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', '需要教师登录');
    END IF;
    SELECT jsonb_agg(row_to_json(s)) INTO v_scores FROM public.scores s;
    SELECT jsonb_agg(row_to_json(r)) INTO v_results FROM public.group_results r;
    RETURN jsonb_build_object(
        'scores', COALESCE(v_scores, '[]'::JSONB),
        'results', COALESCE(v_results, '[]'::JSONB),
        'exported_at', NOW()
    );
END;
$$;

-- ============================================================
-- 第七部分：RLS 策略
-- ============================================================
ALTER TABLE public.groups ENABLE ROW LEVEL SECURITY;
CREATE POLICY "groups_public_select" ON public.groups FOR SELECT USING (true);

ALTER TABLE public.scores ENABLE ROW LEVEL SECURITY;
CREATE POLICY "scores_public_select" ON public.scores FOR SELECT USING (true);
CREATE POLICY "scores_public_insert" ON public.scores FOR INSERT WITH CHECK (true);
CREATE POLICY "scores_public_update" ON public.scores FOR UPDATE USING (true);
CREATE POLICY "scores_admin_delete" ON public.scores FOR DELETE USING (auth.uid() IS NOT NULL);

-- ============================================================
-- 第八部分：启用 Realtime
-- ============================================================
ALTER PUBLICATION supabase_realtime ADD TABLE public.scores;

-- ============================================================
-- 第九部分：函数权限授予
-- ============================================================
GRANT EXECUTE ON FUNCTION public.upsert_score TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_groups_with_progress TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reset_all_scores TO authenticated;
GRANT EXECUTE ON FUNCTION public.export_all_scores TO authenticated;

-- ============================================================
-- 迁移完成！
-- ============================================================
-- 接下来请在 Supabase Dashboard 中：
-- 1. Authentication > Users > Add user 创建教师账号
--    (Email + Password, 勾选 Auto Confirm User)
-- 2. 或运行下面的 SQL 创建第一个教师账号：
--    (需要通过 Supabase Auth API 或 Dashboard 创建，无法纯 SQL)
-- ============================================================
