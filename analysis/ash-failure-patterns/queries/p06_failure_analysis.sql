-- name: status_frequency
SELECT
    status,
    COUNT(*) AS attempt_count,
    ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM attempts), 3) AS attempt_percent
FROM attempts
GROUP BY status
ORDER BY attempt_count DESC, status ASC;

-- name: headline_summary
SELECT
    COUNT(*) AS attempt_count,
    SUM(CASE WHEN status IN ('feasible', 'infeasible') THEN 1 ELSE 0 END)
        AS evaluated_attempt_count,
    SUM(CASE WHEN status = 'feasible' THEN 1 ELSE 0 END)
        AS feasible_attempt_count,
    SUM(CASE WHEN core_nine = 1 THEN 1 ELSE 0 END) AS core_nine_attempt_count,
    1.0 * SUM(CASE WHEN core_nine = 1 THEN 1 ELSE 0 END)
        / SUM(CASE WHEN status IN ('feasible', 'infeasible') THEN 1 ELSE 0 END)
        AS core_nine_evaluated_fraction,
    SUM(CASE WHEN status IN ('constraint_failure', 'evaluation_failure') THEN 1 ELSE 0 END)
        AS pre_evaluation_stop_count
FROM attempts;

-- name: failure_frequency
SELECT
    f.reason,
    COUNT(*) AS failed_attempt_count,
    (SELECT COUNT(*) FROM attempts WHERE status IN ('feasible', 'infeasible'))
        AS evaluated_attempt_count,
    ROUND(
        100.0 * COUNT(*)
        / (SELECT COUNT(*) FROM attempts WHERE status IN ('feasible', 'infeasible')),
        3
    ) AS evaluated_attempt_percent
FROM failures AS f
JOIN attempts AS a ON a.sequence = f.sequence
WHERE a.status IN ('feasible', 'infeasible')
GROUP BY f.reason
ORDER BY failed_attempt_count DESC, f.reason ASC;

-- name: failure_set_frequency
SELECT
    failure_signature,
    canonical_failure_count,
    COUNT(*) AS attempt_count,
    ROUND(
        100.0 * COUNT(*)
        / (SELECT COUNT(*) FROM attempts WHERE status IN ('feasible', 'infeasible')),
        3
    ) AS evaluated_attempt_percent,
    MAX(core_nine) AS is_core_nine
FROM attempts
WHERE status = 'infeasible'
GROUP BY failure_signature, canonical_failure_count
ORDER BY attempt_count DESC, failure_signature ASC;

-- name: attempt_timeline
SELECT
    sequence,
    sweep,
    coordinate,
    value_text,
    canonical_failure_count,
    core_nine,
    cache_hit
FROM attempts
WHERE status IN ('feasible', 'infeasible')
ORDER BY sequence ASC;

-- name: bootstrap_best_margin
SELECT
    domain,
    metric,
    MAX(value) AS best_ci_low_db,
    MAX(threshold) AS threshold_db,
    MAX(value) - MAX(threshold) AS best_margin_db,
    COUNT(*) AS evaluated_attempt_count
FROM metrics
WHERE metric LIKE 'bootstrap_ci_low:%'
GROUP BY domain, metric
ORDER BY domain ASC, metric ASC;

-- name: chroma_best_margin
SELECT
    domain,
    metric,
    MIN(value) AS best_observed_pixels,
    MAX(threshold) AS threshold_pixels,
    MAX(threshold) - MIN(value) AS best_pass_margin_pixels,
    COUNT(*) AS evaluated_attempt_count
FROM metrics
WHERE metric IN (
    'maximum_chroma_displacement_pixels',
    'maximum_chroma_displacement_increase_pixels'
)
GROUP BY domain, metric
ORDER BY domain ASC, metric ASC;

-- name: route_predicate_failure_frequency
SELECT
    route,
    predicate,
    SUM(CASE WHEN passed = 0 THEN 1 ELSE 0 END) AS failed_attempt_count,
    COUNT(*) AS evaluated_attempt_count,
    ROUND(
        100.0 * SUM(CASE WHEN passed = 0 THEN 1 ELSE 0 END) / COUNT(*),
        3
    ) AS failed_attempt_percent,
    MIN(value) AS minimum_observed,
    MAX(value) AS maximum_observed,
    MAX(threshold) AS threshold,
    MAX(direction) AS direction,
    MAX(unit) AS unit
FROM route_predicates
GROUP BY route, predicate
ORDER BY failed_attempt_count DESC, route ASC, predicate ASC;

-- name: coordinate_response
WITH evaluated AS (
    SELECT
        coordinate,
        COUNT(*) AS evaluated_attempt_count,
        MIN(canonical_failure_count) AS minimum_failure_count,
        MAX(canonical_failure_count) AS maximum_failure_count,
        AVG(core_nine) AS core_nine_share
    FROM attempts
    WHERE status IN ('feasible', 'infeasible') AND coordinate IS NOT NULL
    GROUP BY coordinate
),
all_attempts AS (
    SELECT
        coordinate,
        COUNT(*) AS total_attempt_count,
        SUM(CASE WHEN status = 'constraint_failure' THEN 1 ELSE 0 END)
            AS constraint_failure_count,
        SUM(CASE WHEN status = 'evaluation_failure' THEN 1 ELSE 0 END)
            AS evaluation_failure_count
    FROM attempts
    WHERE coordinate IS NOT NULL
    GROUP BY coordinate
),
qualified_sweeps AS (
    SELECT
        sweep,
        coordinate,
        COUNT(DISTINCT value_text) AS distinct_value_count
    FROM attempts
    WHERE status IN ('feasible', 'infeasible') AND coordinate IS NOT NULL
    GROUP BY sweep, coordinate
    HAVING COUNT(DISTINCT value_text) >= 2
),
qualified_sweep_count AS (
    SELECT coordinate, COUNT(*) AS qualified_sweep_count
    FROM qualified_sweeps
    GROUP BY coordinate
),
per_sweep_metric_span AS (
    SELECT
        a.sweep,
        a.coordinate,
        m.domain,
        m.metric,
        MAX(m.value) - MIN(m.value) AS response_span
    FROM attempts AS a
    JOIN qualified_sweeps AS q
      ON q.sweep = a.sweep AND q.coordinate = a.coordinate
    JOIN metrics AS m ON m.sequence = a.sequence
    WHERE a.status IN ('feasible', 'infeasible') AND a.coordinate IS NOT NULL
    GROUP BY a.sweep, a.coordinate, m.domain, m.metric
),
metric_span AS (
    SELECT
        coordinate,
        MAX(CASE
            WHEN domain = 'engine_raw'
             AND metric = 'bootstrap_ci_low:y_vs_conventional'
            THEN response_span
            ELSE NULL
        END) AS engine_raw_conventional_ci_span_db,
        MAX(CASE
            WHEN domain = 'container_decoded'
             AND metric = 'bootstrap_ci_low:y_vs_conventional'
            THEN response_span
            ELSE NULL
        END) AS container_conventional_ci_span_db,
        MAX(CASE
            WHEN domain = 'engine_raw'
             AND metric = 'maximum_chroma_displacement_pixels'
            THEN response_span
            ELSE NULL
        END) AS engine_raw_chroma_span_pixels,
        MAX(CASE
            WHEN domain = 'container_decoded'
             AND metric = 'maximum_chroma_displacement_pixels'
            THEN response_span
            ELSE NULL
        END) AS container_chroma_span_pixels
    FROM per_sweep_metric_span
    GROUP BY coordinate
)
SELECT
    a.coordinate,
    a.total_attempt_count,
    e.evaluated_attempt_count,
    a.constraint_failure_count,
    a.evaluation_failure_count,
    e.minimum_failure_count,
    e.maximum_failure_count,
    ROUND(100.0 * e.core_nine_share, 3) AS core_nine_percent,
    COALESCE(q.qualified_sweep_count, 0) AS qualified_sweep_count,
    m.engine_raw_conventional_ci_span_db,
    m.container_conventional_ci_span_db,
    m.engine_raw_chroma_span_pixels,
    m.container_chroma_span_pixels
FROM all_attempts AS a
JOIN evaluated AS e ON e.coordinate = a.coordinate
LEFT JOIN metric_span AS m ON m.coordinate = a.coordinate
LEFT JOIN qualified_sweep_count AS q ON q.coordinate = a.coordinate
ORDER BY e.minimum_failure_count ASC, e.core_nine_share DESC, a.coordinate ASC;

-- name: candidate_metric_matrix
SELECT
    a.sequence,
    a.sweep,
    a.coordinate,
    a.value_text,
    a.canonical_failure_count,
    a.core_nine,
    MAX(CASE
        WHEN m.domain = 'engine_raw'
         AND m.metric = 'bootstrap_ci_low:y_vs_conventional'
        THEN m.value ELSE NULL
    END) AS engine_raw_conventional_ci_low_db,
    MAX(CASE
        WHEN m.domain = 'container_decoded'
         AND m.metric = 'bootstrap_ci_low:y_vs_conventional'
        THEN m.value ELSE NULL
    END) AS container_conventional_ci_low_db,
    MAX(CASE
        WHEN m.domain = 'engine_raw'
         AND m.metric = 'bootstrap_ci_low:y_vs_fixed'
        THEN m.value ELSE NULL
    END) AS engine_raw_fixed_ci_low_db,
    MAX(CASE
        WHEN m.domain = 'engine_raw'
         AND m.metric = 'bootstrap_ci_low:y_vs_non_ash'
        THEN m.value ELSE NULL
    END) AS engine_raw_non_ash_ci_low_db,
    MAX(CASE
        WHEN m.domain = 'engine_raw'
         AND m.metric = 'maximum_chroma_displacement_pixels'
        THEN m.value ELSE NULL
    END) AS engine_raw_chroma_pixels,
    MAX(CASE
        WHEN m.domain = 'container_decoded'
         AND m.metric = 'maximum_chroma_displacement_pixels'
        THEN m.value ELSE NULL
    END) AS container_chroma_pixels
FROM attempts AS a
JOIN metrics AS m ON m.sequence = a.sequence
WHERE a.status IN ('feasible', 'infeasible')
GROUP BY
    a.sequence,
    a.sweep,
    a.coordinate,
    a.value_text,
    a.canonical_failure_count,
    a.core_nine
ORDER BY a.sequence ASC;

-- name: unique_evaluation_metric_matrix
WITH first_attempt AS (
    SELECT evaluation_sha256, MIN(sequence) AS sequence
    FROM attempts
    WHERE status IN ('feasible', 'infeasible')
    GROUP BY evaluation_sha256
)
SELECT
    a.evaluation_sha256,
    a.sequence,
    a.sweep,
    a.coordinate,
    a.value_text,
    a.canonical_failure_count,
    a.core_nine,
    MAX(CASE
        WHEN m.domain = 'engine_raw'
         AND m.metric = 'bootstrap_ci_low:y_vs_conventional'
        THEN m.value ELSE NULL
    END) AS engine_raw_conventional_ci_low_db,
    MAX(CASE
        WHEN m.domain = 'container_decoded'
         AND m.metric = 'bootstrap_ci_low:y_vs_conventional'
        THEN m.value ELSE NULL
    END) AS container_conventional_ci_low_db,
    MAX(CASE
        WHEN m.domain = 'engine_raw'
         AND m.metric = 'bootstrap_ci_low:y_vs_fixed'
        THEN m.value ELSE NULL
    END) AS engine_raw_fixed_ci_low_db,
    MAX(CASE
        WHEN m.domain = 'engine_raw'
         AND m.metric = 'bootstrap_ci_low:y_vs_non_ash'
        THEN m.value ELSE NULL
    END) AS engine_raw_non_ash_ci_low_db,
    MAX(CASE
        WHEN m.domain = 'engine_raw'
         AND m.metric = 'maximum_chroma_displacement_pixels'
        THEN m.value ELSE NULL
    END) AS engine_raw_chroma_pixels,
    MAX(CASE
        WHEN m.domain = 'container_decoded'
         AND m.metric = 'maximum_chroma_displacement_pixels'
        THEN m.value ELSE NULL
    END) AS container_chroma_pixels
FROM first_attempt AS f
JOIN attempts AS a ON a.sequence = f.sequence
JOIN metrics AS m ON m.sequence = a.sequence
GROUP BY
    a.evaluation_sha256,
    a.sequence,
    a.sweep,
    a.coordinate,
    a.value_text,
    a.canonical_failure_count,
    a.core_nine
ORDER BY a.sequence ASC;

-- name: chroma_passing_tradeoff
WITH candidate_metrics AS (
    SELECT
        a.sequence,
        a.sweep,
        a.coordinate,
        a.value_text,
        a.canonical_failure_count,
        MAX(CASE
            WHEN m.domain = 'engine_raw'
             AND m.metric = 'bootstrap_ci_low:y_vs_conventional'
            THEN m.value ELSE NULL
        END) AS engine_raw_conventional_ci_low_db,
        MAX(CASE
            WHEN m.domain = 'container_decoded'
             AND m.metric = 'bootstrap_ci_low:y_vs_conventional'
            THEN m.value ELSE NULL
        END) AS container_conventional_ci_low_db,
        MAX(CASE
            WHEN m.domain = 'engine_raw'
             AND m.metric = 'maximum_chroma_displacement_pixels'
            THEN m.value ELSE NULL
        END) AS engine_raw_chroma_pixels,
        MAX(CASE
            WHEN m.domain = 'container_decoded'
             AND m.metric = 'maximum_chroma_displacement_pixels'
            THEN m.value ELSE NULL
        END) AS container_chroma_pixels
    FROM attempts AS a
    JOIN metrics AS m ON m.sequence = a.sequence
    WHERE a.status IN ('feasible', 'infeasible')
    GROUP BY
        a.sequence,
        a.sweep,
        a.coordinate,
        a.value_text,
        a.canonical_failure_count
)
SELECT *
FROM candidate_metrics
WHERE engine_raw_chroma_pixels <= 0.25
  AND container_chroma_pixels <= 0.25
ORDER BY canonical_failure_count ASC, sequence ASC;

-- name: state_coordinate6_risk_response
SELECT
    a.sequence,
    a.sweep,
    a.value_text,
    s.route,
    s.one_count,
    s.zero_count,
    a.canonical_failure_count,
    a.core_nine,
    (
        SELECT m.value
        FROM metrics AS m
        WHERE m.sequence = a.sequence
          AND m.domain = 'engine_raw'
          AND m.metric = 'bootstrap_ci_low:y_vs_conventional'
    ) AS engine_raw_conventional_ci_low_db,
    (
        SELECT MAX(m.value)
        FROM metrics AS m
        WHERE m.domain = 'engine_raw'
          AND m.metric = 'bootstrap_ci_low:y_vs_conventional'
    ) AS global_best_engine_raw_conventional_ci_low_db,
    EXISTS (
        SELECT 1
        FROM failures AS f
        WHERE f.sequence = a.sequence
          AND f.reason = 'check:state_causality'
    ) AS state_causality_failed
FROM attempts AS a
JOIN state_observations AS s ON s.sequence = a.sequence
WHERE a.status IN ('feasible', 'infeasible')
  AND a.coordinate = 'alias_or_ringing_risk_high_unorm15'
  AND s.coordinate = 6
ORDER BY a.sweep ASC, CAST(a.value_text AS INTEGER) ASC, s.route ASC;

-- name: pre_evaluation_error_frequency
SELECT
    a.status,
    e.error,
    COUNT(*) AS attempt_count
FROM attempts AS a
JOIN attempt_errors AS e ON e.sequence = a.sequence
WHERE a.status IN ('constraint_failure', 'evaluation_failure')
GROUP BY a.status, e.error
ORDER BY attempt_count DESC, a.status ASC, e.error ASC;
