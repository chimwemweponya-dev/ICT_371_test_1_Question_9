-- Q9(a) Tables
CREATE TABLE farmers (
    farmer_id     SERIAL PRIMARY KEY,
    farmer_number VARCHAR(30) NOT NULL UNIQUE,
    full_name     VARCHAR(120) NOT NULL
);

CREATE TABLE deliveries (
    delivery_id  SERIAL PRIMARY KEY,
    farmer_id    INTEGER NOT NULL REFERENCES farmers(farmer_id),
    grade        CHAR(1) NOT NULL CHECK (grade IN ('A', 'B', 'C')),
    weight_kg    NUMERIC(12, 2) NOT NULL CHECK (weight_kg > 0),
    unit_rate    NUMERIC(10, 2) NOT NULL CHECK (unit_rate > 0),
    total_value  NUMERIC(12, 2) NOT NULL CHECK (total_value >= 0),
    delivered_on DATE NOT NULL,
    is_paid      BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE daily_purchases (
    purchase_date DATE PRIMARY KEY,
    total_weight  NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (total_weight >= 0),
    total_value   NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (total_value >= 0)
);

-- Q9(b) Function: fn_maize_rate (A=5, B=4, C=3)
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade TEXT)
RETURNS NUMERIC(10, 2)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Grade cannot be NULL';
    END IF;

    CASE p_grade
        WHEN 'A' THEN RETURN 5.00;
        WHEN 'B' THEN RETURN 4.00;
        WHEN 'C' THEN RETURN 3.00;
        ELSE RAISE EXCEPTION 'Unsupported maize grade: %', p_grade;
    END CASE;
END;
$$;

-- Q9(d) Trigger: BEFORE INSERT OR UPDATE sets unit_rate & total_value consistently
CREATE OR REPLACE FUNCTION fn_trg_deliveries_pricing()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'weight_kg must be positive, got %', NEW.weight_kg;
    END IF;

    NEW.unit_rate   := fn_maize_rate(NEW.grade);
    NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_deliveries_pricing
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW
EXECUTE FUNCTION fn_trg_deliveries_pricing();

-- Q9(c) Procedure: pr_receive_delivery
CREATE OR REPLACE PROCEDURE pr_receive_delivery(
    p_farmer_id INT,
    p_grade     TEXT,
    p_weight    NUMERIC(12, 2),
    p_date      DATE
)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM 1 FROM farmers WHERE farmer_id = p_farmer_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown farmer_id: %', p_farmer_id;
    END IF;

    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive, got %', p_weight;
    END IF;

    IF p_date IS NULL THEN
        RAISE EXCEPTION 'Delivery date cannot be NULL';
    END IF;

    PERFORM fn_maize_rate(p_grade);

    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
    VALUES (p_farmer_id, p_grade, p_weight, p_date, FALSE);
END;
$$;

-- Q9(a cont.) Seed 3 farmers & 6 deliveries (grades A, B, C & paid/unpaid) after trigger
INSERT INTO farmers (farmer_number, full_name) VALUES
    ('FRM-001', 'Benson Mwanza'),
    ('FRM-002', 'Agness Chirwa'),
    ('FRM-003', 'Patrick Ngoma');

CALL pr_receive_delivery(1, 'A', 100.00, CURRENT_DATE - 2);
CALL pr_receive_delivery(1, 'B', 50.00,  CURRENT_DATE - 1);
CALL pr_receive_delivery(2, 'B', 120.00, CURRENT_DATE - 1);
CALL pr_receive_delivery(2, 'C', 80.00,  CURRENT_DATE);
CALL pr_receive_delivery(3, 'C', 200.00, CURRENT_DATE - 1);
CALL pr_receive_delivery(3, 'A', 60.00,  CURRENT_DATE);

UPDATE deliveries SET is_paid = TRUE WHERE delivery_id IN (1, 3, 5);

-- Q9(e) View: v_farmer_amount_due (0 when no unpaid deliveries)
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT
    f.farmer_number,
    f.full_name,
    COALESCE(SUM(d.total_value) FILTER (WHERE NOT d.is_paid), 0.00) AS unpaid_amount
FROM farmers f
LEFT JOIN deliveries d ON d.farmer_id = f.farmer_id
GROUP BY f.farmer_id, f.farmer_number, f.full_name
ORDER BY f.farmer_number;

-- Q9(f) Composite Index & EXPLAIN
-- Optimizes filtering by farmer_id and date range on delivered_on
CREATE INDEX idx_deliveries_farmer_delivered_on ON deliveries (farmer_id, delivered_on);

EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM deliveries
WHERE farmer_id = 1
  AND delivered_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
-- Expected plan node: Index Scan using idx_deliveries_farmer_delivered_on on deliveries

-- Q9(g) Procedure & Scheduled Job (01:30 daily for previous day)
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_weight NUMERIC(12, 2);
    v_value  NUMERIC(12, 2);
BEGIN
    SELECT
        COALESCE(SUM(weight_kg), 0.00),
        COALESCE(SUM(total_value), 0.00)
    INTO v_weight, v_value
    FROM deliveries
    WHERE delivered_on = p_day;

    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    VALUES (p_day, v_weight, v_value)
    ON CONFLICT (purchase_date) DO UPDATE
    SET total_weight = EXCLUDED.total_weight,
        total_value  = EXCLUDED.total_value;
END;
$$;

SELECT cron.schedule(
    'refresh_daily_purchases',
    '30 1 * * *',
    $$CALL pr_refresh_purchases((CURRENT_TIMESTAMP AT TIME ZONE 'Africa/Lusaka')::date - 1);$$
);