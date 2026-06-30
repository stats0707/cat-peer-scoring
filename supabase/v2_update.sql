-- ============================================================
-- 猫咪互评系统 v2：5 大模块 100 分制 数据库更新
-- 在 Supabase SQL Editor 中执行此脚本
-- ============================================================

-- 1. 删除旧的 CHECK 约束
ALTER TABLE public.scores DROP CONSTRAINT IF EXISTS scores_total_check;
-- 添加新的 CHECK 约束（0-100）
ALTER TABLE public.scores ADD CONSTRAINT scores_total_check CHECK (total BETWEEN 0 AND 100);

-- 2. 重建 upsert_score RPC 函数（5 维度，0-满分验证）
DROP FUNCTION IF EXISTS public.upsert_score(INT, INT, JSONB);
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
    v_dims CONSTANT TEXT[] := ARRAY['背景介绍','数据获取','数据说明','数据分析','商业应用'];
    v_maxes CONSTANT INT[]  := ARRAY[20, 15, 20, 30, 15];
    v_existing_id BIGINT;
    v_max INT;
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

    FOR i IN 1..array_length(v_dims,1) LOOP
        v_dim := v_dims[i];
        v_max := v_maxes[i];
        IF p_scores->>v_dim IS NULL THEN
            RETURN jsonb_build_object('success', false, 'error', '缺少评分维度: ' || v_dim);
        END IF;
        v_val := (p_scores->>v_dim)::INT;
        IF v_val < 0 OR v_val > v_max THEN
            RETURN jsonb_build_object('success', false, 'error', v_dim || ' 评分需为 0-' || v_max || ' 之间的数字');
        END IF;
    END LOOP;

    v_total := 0;
    FOR i IN 1..array_length(v_dims,1) LOOP
        v_total := v_total + (p_scores->>v_dims[i])::INT;
    END LOOP;

    SELECT id INTO v_existing_id FROM public.scores
    WHERE rater_group = p_rater_group AND rated_group = p_rated_group;

    INSERT INTO public.scores (rater_group, rated_group, scores, total)
    VALUES (p_rater_group, p_rated_group, p_scores, v_total)
    ON CONFLICT (rater_group, rated_group)
    DO UPDATE SET scores = p_scores, total = v_total, updated_at = NOW();

    RETURN jsonb_build_object(
        'success', true, 'message', '喵~ 评分已保存！🐾',
        'total', v_total,
        'action', CASE WHEN v_existing_id IS NULL THEN 'created' ELSE 'updated' END
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.upsert_score TO anon, authenticated;
