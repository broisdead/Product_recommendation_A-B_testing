-- =============================================================================
-- A/B EXPERIMENT ANALYSIS: PRODUCT RECOMMENDATION ENGINE
-- Author: Data Science Portfolio Project
-- Scope:  Full experiment lifecycle — design → data → analysis → decision
-- Stack:  MySQL 8.0+ (CTEs, window functions, JSON support)
-- =============================================================================

CREATE DATABASE IF NOT EXISTS recommender_ab_test;
USE recommender_ab_test;

-- =============================================================================
-- SECTION 1: SCHEMA DESIGN
-- =============================================================================

-- Core dimension: customers with realistic profile attributes
CREATE TABLE IF NOT EXISTS customers (
    customer_id    INT           PRIMARY KEY,
    customer_name  VARCHAR(255)  NOT NULL,
    email          VARCHAR(255)  NOT NULL UNIQUE,
    country        VARCHAR(100)  NOT NULL,
    device_type    VARCHAR(20)   NOT NULL CHECK (device_type IN ('mobile','desktop','tablet')),
    signup_date    DATE          NOT NULL,
    age_group      VARCHAR(20)   NOT NULL CHECK (age_group IN ('18-24','25-34','35-44','45-54','55+')),
    is_premium     TINYINT(1)    NOT NULL DEFAULT 0
);

-- Products catalogue
CREATE TABLE IF NOT EXISTS products (
    product_id    INT            PRIMARY KEY,
    product_name  VARCHAR(255)   NOT NULL,
    category      VARCHAR(100)   NOT NULL,
    price         DECIMAL(10,2)  NOT NULL
);

-- Orders fact table with timestamps for time-series analysis
CREATE TABLE IF NOT EXISTS orders (
    order_id      INT              PRIMARY KEY,
    customer_id   INT              NOT NULL,
    product_id    INT              NOT NULL,
    order_value   DECIMAL(10,2)    NOT NULL,
    order_date    DATE             NOT NULL,
    order_ts      DATETIME         NOT NULL,   -- full timestamp for hourly/weekly trends
    FOREIGN KEY (customer_id) REFERENCES customers(customer_id),
    FOREIGN KEY (product_id)  REFERENCES products(product_id)
);

-- Experiment assignment with audit trail
CREATE TABLE IF NOT EXISTS experiment_assignment (
    customer_id        INT       PRIMARY KEY,
    experiment_group   CHAR(1)   NOT NULL CHECK (experiment_group IN ('A','B')),
    assigned_at        DATETIME  NOT NULL,
    experiment_version VARCHAR(20) NOT NULL DEFAULT 'v1.0',
    FOREIGN KEY (customer_id) REFERENCES customers(customer_id)
);

-- Session-level events (page views, clicks) — richer behavioural signal
CREATE TABLE IF NOT EXISTS user_events (
    event_id       INT           PRIMARY KEY AUTO_INCREMENT,
    customer_id    INT           NOT NULL,
    event_type     VARCHAR(50)   NOT NULL,   -- 'page_view','rec_click','add_to_cart','checkout'
    event_ts       DATETIME      NOT NULL,
    page_url       VARCHAR(255),
    FOREIGN KEY (customer_id) REFERENCES customers(customer_id)
);

-- Indexes for analytical query performance
CREATE INDEX idx_orders_customer   ON orders(customer_id);
CREATE INDEX idx_orders_date       ON orders(order_date);
CREATE INDEX idx_orders_ts         ON orders(order_ts);
CREATE INDEX idx_events_customer   ON user_events(customer_id);
CREATE INDEX idx_events_type       ON user_events(event_type);
CREATE INDEX idx_assign_group      ON experiment_assignment(experiment_group);


-- =============================================================================
-- SECTION 2: REFERENCE DATA
-- =============================================================================

INSERT INTO products (product_id, product_name, category, price) VALUES
(101, 'Laptop Pro 15"',    'Electronics',   1299.00),
(102, 'Smartphone X12',    'Electronics',    799.00),
(103, 'Noise-Cancel Headphones', 'Electronics', 249.00),
(104, 'Wireless Mouse',    'Accessories',    45.00),
(105, 'USB-C Hub 7-port',  'Accessories',    79.00),
(106, 'Mechanical Keyboard','Accessories',  159.00),
(107, '4K Webcam',         'Electronics',   189.00),
(108, 'Monitor Stand',     'Accessories',    65.00),
(109, 'Tablet Air',        'Electronics',   549.00),
(110, 'Smart Speaker',     'Electronics',   129.00);


-- =============================================================================
-- SECTION 3: SYNTHETIC DATA GENERATION (1 000 users)
-- =============================================================================
-- Design parameters:
--   Group A (control)   conversion rate ≈ 34%   ARPU ≈ $112
--   Group B (treatment) conversion rate ≈ 47%   ARPU ≈ $178
--   Premium users convert at 1.4× the base rate in both groups
--   Mobile users skew toward lower-priced products
-- =============================================================================

DELIMITER $$

CREATE PROCEDURE generate_experiment_data()
BEGIN
    DECLARE i           INT DEFAULT 1;
    DECLARE grp         CHAR(1);
    DECLARE will_buy    INT;
    DECLARE num_orders  INT;
    DECLARE o           INT;
    DECLARE prod_id     INT;
    DECLARE o_val       DECIMAL(10,2);
    DECLARE base_date   DATE DEFAULT '2025-01-01';
    DECLARE o_date      DATE;
    DECLARE o_ts        DATETIME;
    DECLARE order_seq   INT DEFAULT 1;
    DECLARE country_val VARCHAR(100);
    DECLARE device_val  VARCHAR(20);
    DECLARE age_val     VARCHAR(20);
    DECLARE is_prem     TINYINT(1);
    DECLARE conv_thresh INT;
    DECLARE day_offset  INT;
    DECLARE hour_offset INT;

    WHILE i <= 1000 DO

        -- Deterministic but varied demographics (reproducible)
        SET country_val = ELT(1 + (i MOD 6), 'USA','UK','Canada','Germany','Australia','Spain');
        SET device_val  = ELT(1 + (i MOD 3), 'mobile','desktop','tablet');
        SET age_val     = ELT(1 + (i MOD 5), '18-24','25-34','35-44','45-54','55+');
        SET is_prem     = IF((i MOD 5) = 0, 1, 0);  -- 20% premium users

        INSERT IGNORE INTO customers
            (customer_id, customer_name, email, country, device_type, signup_date, age_group, is_premium)
        VALUES (
            i,
            CONCAT('User_', i),
            CONCAT('user', i, '@example.com'),
            country_val,
            device_val,
            DATE_SUB('2025-01-01', INTERVAL (i MOD 365) DAY),
            age_val,
            is_prem
        );

        -- Balanced 50/50 group assignment
        SET grp = IF((i MOD 2) = 0, 'A', 'B');

        INSERT IGNORE INTO experiment_assignment
            (customer_id, experiment_group, assigned_at, experiment_version)
        VALUES (i, grp, '2025-01-01 00:00:00', 'v1.0');

        -- Conversion thresholds
        --   Base: A=34, B=47 (out of 100)
        --   Premium boost: +10 pp for both groups
        SET conv_thresh = CASE
            WHEN grp = 'A' AND is_prem = 1 THEN 44
            WHEN grp = 'A'                 THEN 34
            WHEN grp = 'B' AND is_prem = 1 THEN 57
            ELSE                                47
        END;

        SET will_buy = IF((i MOD 100) < conv_thresh, 1, 0);

        IF will_buy = 1 THEN
            SET num_orders = 1 + (i MOD 3);   -- 1 to 3 orders per converter
            SET o = 1;

            WHILE o <= num_orders DO
                -- Product selection: mobile users lean toward cheaper items
                IF device_val = 'mobile' THEN
                    SET prod_id = 104 + ((i + o) MOD 4);   -- $45–$159 range
                ELSEIF is_prem = 1 THEN
                    SET prod_id = 101 + ((i + o) MOD 3);   -- $249–$1299 range
                ELSE
                    SET prod_id = 101 + ((i + o) MOD 10);  -- full range
                END IF;

                SET o_val = (SELECT price FROM products WHERE product_id = prod_id);

                -- Realistic order timestamps spread across 90-day window
                SET day_offset  = (i * 7 + o * 13) MOD 90;
                SET hour_offset = (i + o * 3) MOD 24;
                SET o_date      = DATE_ADD(base_date, INTERVAL day_offset DAY);
                SET o_ts        = TIMESTAMP(o_date, SEC_TO_TIME(hour_offset * 3600));

                INSERT IGNORE INTO orders
                    (order_id, customer_id, product_id, order_value, order_date, order_ts)
                VALUES (order_seq, i, prod_id, o_val, o_date, o_ts);

                SET order_seq = order_seq + 1;
                SET o = o + 1;
            END WHILE;
        END IF;

        SET i = i + 1;
    END WHILE;
END$$

DELIMITER ;

CALL generate_experiment_data();


-- =============================================================================
-- SECTION 4: ANALYTICAL VIEWS
-- =============================================================================

-- 4a. Conversion flag per customer (experiment window only)
CREATE OR REPLACE VIEW customer_conversion AS
SELECT
    c.customer_id,
    c.country,
    c.device_type,
    c.age_group,
    c.is_premium,
    CASE WHEN COUNT(o.order_id) > 0 THEN 1 ELSE 0 END AS converted,
    COALESCE(SUM(o.order_value), 0)                    AS total_revenue
FROM customers c
LEFT JOIN orders o
       ON c.customer_id = o.customer_id
      AND o.order_date BETWEEN '2025-01-01' AND '2025-03-31'
GROUP BY c.customer_id, c.country, c.device_type, c.age_group, c.is_premium;


-- 4b. Full experiment results enriched with segments
CREATE OR REPLACE VIEW experiment_results AS
SELECT
    ea.experiment_group,
    cv.customer_id,
    cv.country,
    cv.device_type,
    cv.age_group,
    cv.is_premium,
    cv.converted,
    cv.total_revenue
FROM experiment_assignment ea
JOIN customer_conversion cv ON ea.customer_id = cv.customer_id;


-- =============================================================================
-- SECTION 5: CORE EXPERIMENT METRICS
-- =============================================================================

-- 5a. Primary conversion rate summary
SELECT
    experiment_group                                          AS `group`,
    COUNT(*)                                                  AS total_users,
    SUM(converted)                                            AS conversions,
    COUNT(*) - SUM(converted)                                 AS non_conversions,
    ROUND(SUM(converted) / COUNT(*) * 100, 2)                 AS conversion_rate_pct,
    ROUND(SUM(total_revenue), 2)                              AS total_revenue,
    ROUND(SUM(total_revenue) / COUNT(*), 2)                   AS arpu,
    ROUND(SUM(total_revenue) / NULLIF(SUM(converted), 0), 2)  AS avg_order_value
FROM experiment_results
GROUP BY experiment_group
ORDER BY experiment_group;


-- =============================================================================
-- SECTION 6: UPLIFT ANALYSIS
-- =============================================================================

WITH group_agg AS (
    SELECT
        experiment_group,
        COUNT(*)                             AS n,
        SUM(converted)                       AS conversions,
        SUM(converted) / COUNT(*)            AS cr,
        SUM(total_revenue) / COUNT(*)        AS arpu
    FROM experiment_results
    GROUP BY experiment_group
),
pivot AS (
    SELECT
        MAX(CASE WHEN experiment_group = 'A' THEN cr   END) AS cr_a,
        MAX(CASE WHEN experiment_group = 'B' THEN cr   END) AS cr_b,
        MAX(CASE WHEN experiment_group = 'A' THEN arpu END) AS arpu_a,
        MAX(CASE WHEN experiment_group = 'B' THEN arpu END) AS arpu_b,
        MAX(CASE WHEN experiment_group = 'A' THEN n    END) AS n_a,
        MAX(CASE WHEN experiment_group = 'B' THEN n    END) AS n_b,
        MAX(CASE WHEN experiment_group = 'A' THEN conversions END) AS conv_a,
        MAX(CASE WHEN experiment_group = 'B' THEN conversions END) AS conv_b
    FROM group_agg
)
SELECT
    ROUND(cr_a  * 100, 2)              AS control_cr_pct,
    ROUND(cr_b  * 100, 2)              AS treatment_cr_pct,
    ROUND((cr_b - cr_a) * 100, 2)      AS absolute_uplift_pp,
    ROUND((cr_b - cr_a) / cr_a * 100, 2) AS relative_uplift_pct,
    ROUND(arpu_a, 2)                   AS control_arpu,
    ROUND(arpu_b, 2)                   AS treatment_arpu,
    ROUND(arpu_b - arpu_a, 2)          AS arpu_uplift,
    -- Projected annual revenue impact (assume 10 000 users/year)
    ROUND((arpu_b - arpu_a) * 10000, 2) AS projected_annual_revenue_uplift
FROM pivot;


-- =============================================================================
-- SECTION 7: STATISTICAL PREPARATION (feed to Python z-test)
-- =============================================================================

SELECT
    experiment_group  AS `group`,
    COUNT(*)          AS sample_size,
    SUM(converted)    AS conversions,
    ROUND(SUM(converted) / COUNT(*), 6) AS conversion_rate
FROM experiment_results
GROUP BY experiment_group
ORDER BY experiment_group;

/*
Python code to run statistical test (see ab_analysis.py):

from statsmodels.stats.proportion import proportions_ztest, proportion_confint
import numpy as np

# Values from query above
n    = [500, 500]
conv = [170, 235]   # example — use actual query output

z, p = proportions_ztest(conv, n)
ci_a = proportion_confint(conv[0], n[0], alpha=0.05, method='wilson')
ci_b = proportion_confint(conv[1], n[1], alpha=0.05, method='wilson')
*/


-- =============================================================================
-- SECTION 8: SEGMENT ANALYSIS
-- =============================================================================

-- 8a. By country
SELECT
    country,
    experiment_group                                           AS `group`,
    COUNT(*)                                                   AS users,
    SUM(converted)                                             AS conversions,
    ROUND(SUM(converted) / COUNT(*) * 100, 2)                  AS cr_pct,
    ROUND(SUM(total_revenue) / COUNT(*), 2)                    AS arpu
FROM experiment_results
GROUP BY country, experiment_group
ORDER BY country, experiment_group;


-- 8b. By device type
SELECT
    device_type,
    experiment_group                                           AS `group`,
    COUNT(*)                                                   AS users,
    SUM(converted)                                             AS conversions,
    ROUND(SUM(converted) / COUNT(*) * 100, 2)                  AS cr_pct,
    ROUND(SUM(total_revenue) / COUNT(*), 2)                    AS arpu
FROM experiment_results
GROUP BY device_type, experiment_group
ORDER BY device_type, experiment_group;


-- 8c. By age group
SELECT
    age_group,
    experiment_group                                           AS `group`,
    COUNT(*)                                                   AS users,
    SUM(converted)                                             AS conversions,
    ROUND(SUM(converted) / COUNT(*) * 100, 2)                  AS cr_pct
FROM experiment_results
GROUP BY age_group, experiment_group
ORDER BY age_group, experiment_group;


-- 8d. Premium vs non-premium users
SELECT
    CASE WHEN is_premium = 1 THEN 'Premium' ELSE 'Standard' END AS user_tier,
    experiment_group                                             AS `group`,
    COUNT(*)                                                     AS users,
    SUM(converted)                                               AS conversions,
    ROUND(SUM(converted) / COUNT(*) * 100, 2)                    AS cr_pct,
    ROUND(SUM(total_revenue) / COUNT(*), 2)                      AS arpu
FROM experiment_results
GROUP BY is_premium, experiment_group
ORDER BY is_premium DESC, experiment_group;


-- =============================================================================
-- SECTION 9: TIME-SERIES ANALYSIS
-- =============================================================================

-- 9a. Weekly conversion trend (novelty-effect check)
SELECT
    ea.experiment_group                        AS `group`,
    YEARWEEK(o.order_date, 1)                  AS year_week,
    DATE_FORMAT(MIN(o.order_date), '%b %d')    AS week_start,
    COUNT(DISTINCT o.customer_id)              AS unique_buyers,
    COUNT(o.order_id)                          AS total_orders,
    ROUND(SUM(o.order_value), 2)               AS weekly_revenue
FROM orders o
JOIN experiment_assignment ea ON o.customer_id = ea.customer_id
WHERE o.order_date BETWEEN '2025-01-01' AND '2025-03-31'
GROUP BY ea.experiment_group, YEARWEEK(o.order_date, 1)
ORDER BY year_week, ea.experiment_group;


-- 9b. Cumulative conversion rate over time (treatment effect onset)
WITH daily_convs AS (
    SELECT
        ea.experiment_group,
        o.order_date,
        COUNT(DISTINCT o.customer_id) AS daily_new_converters
    FROM orders o
    JOIN experiment_assignment ea ON o.customer_id = ea.customer_id
    GROUP BY ea.experiment_group, o.order_date
),
running AS (
    SELECT
        experiment_group,
        order_date,
        SUM(daily_new_converters)
            OVER (PARTITION BY experiment_group ORDER BY order_date) AS cumulative_converters
    FROM daily_convs
),
group_sizes AS (
    SELECT experiment_group, COUNT(*) AS n
    FROM experiment_assignment
    GROUP BY experiment_group
)
SELECT
    r.experiment_group,
    r.order_date,
    r.cumulative_converters,
    ROUND(r.cumulative_converters / g.n * 100, 2) AS cumulative_cr_pct
FROM running r
JOIN group_sizes g ON r.experiment_group = g.experiment_group
ORDER BY r.order_date, r.experiment_group;


-- 9c. Hour-of-day purchase distribution (UX timing insight)
SELECT
    ea.experiment_group,
    HOUR(o.order_ts) AS hour_of_day,
    COUNT(*)         AS orders
FROM orders o
JOIN experiment_assignment ea ON o.customer_id = ea.customer_id
GROUP BY ea.experiment_group, HOUR(o.order_ts)
ORDER BY hour_of_day, ea.experiment_group;


-- =============================================================================
-- SECTION 10: DATA QUALITY CHECKS
-- =============================================================================

-- Check for duplicate assignments
SELECT customer_id, COUNT(*) AS cnt
FROM experiment_assignment
GROUP BY customer_id
HAVING cnt > 1;

-- Check group balance
SELECT experiment_group, COUNT(*) AS n
FROM experiment_assignment
GROUP BY experiment_group;

-- Check for null/invalid customer profiles
SELECT COUNT(*) AS invalid_profiles
FROM customers
WHERE email IS NULL OR country IS NULL OR device_type IS NULL;

-- Orders outside experiment window (potential data contamination)
SELECT COUNT(*) AS out_of_window_orders
FROM orders
WHERE order_date < '2025-01-01' OR order_date > '2025-03-31';


-- =============================================================================
-- SECTION 11: BUSINESS SUMMARY QUERY (single-shot executive view)
-- =============================================================================

WITH base AS (
    SELECT
        experiment_group,
        COUNT(*)                          AS n,
        SUM(converted)                    AS conv,
        SUM(converted)/COUNT(*)           AS cr,
        SUM(total_revenue)/COUNT(*)       AS arpu
    FROM experiment_results
    GROUP BY experiment_group
)
SELECT
    b.experiment_group                               AS `Group`,
    b.n                                              AS `Users`,
    b.conv                                           AS `Conversions`,
    CONCAT(ROUND(b.cr*100,1), '%')                   AS `Conv Rate`,
    CONCAT('$', ROUND(b.arpu,2))                     AS `ARPU`,
    CASE b.experiment_group
        WHEN 'A' THEN 'Control — No Recommendations'
        WHEN 'B' THEN 'Treatment — Recommendations ON'
    END                                              AS `Description`
FROM base b
ORDER BY b.experiment_group;
