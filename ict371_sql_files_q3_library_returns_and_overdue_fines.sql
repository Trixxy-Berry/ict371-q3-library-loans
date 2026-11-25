-- ============================================================================
-- ICT371 Advanced Database
-- Question 3: Library Returns and Overdue Fines (PostgreSQL / PL/pgSQL)
-- ============================================================================

-- (a) Database and seed data
CREATE TABLE books (
    book_id SERIAL PRIMARY KEY,
    title   VARCHAR(150) NOT NULL
);

CREATE TABLE loans (
    loan_id       SERIAL PRIMARY KEY,
    book_id       INT NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(120) NOT NULL,
    borrowed_on   DATE NOT NULL,
    due_on        DATE NOT NULL,
    returned_on   DATE NULL,
    fine_amount   NUMERIC(10, 2) NOT NULL DEFAULT 0.00 CHECK (fine_amount >= 0),
    CONSTRAINT chk_due_after_borrow CHECK (due_on >= borrowed_on)
);

CREATE TABLE loan_audit (
    audit_id        SERIAL PRIMARY KEY,
    loan_id         INT NOT NULL REFERENCES loans(loan_id),
    old_returned_on DATE NULL,
    new_returned_on DATE NULL,
    changed_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INT NOT NULL DEFAULT 0 CHECK (overdue_count >= 0),
    total_fine    NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (total_fine >= 0)
);

INSERT INTO books (title) VALUES
    ('Database System Concepts'),
    ('Clean Code'),
    ('Operating System Principles');

INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on, returned_on, fine_amount) VALUES
    (1, 'Tandiwe Lungu',  CURRENT_DATE - 15, CURRENT_DATE - 5, NULL, 0.00),
    (2, 'Mwamba Tembo',   CURRENT_DATE - 10, CURRENT_DATE - 2, CURRENT_DATE - 2, 0.00),
    (3, 'Kabwe Zulu',     CURRENT_DATE - 12, CURRENT_DATE - 6, CURRENT_DATE - 3, 6.00),
    (1, 'Thabo Mulenga',  CURRENT_DATE - 5,  CURRENT_DATE + 5, NULL, 0.00),
    (2, 'Chipo Phiri',    CURRENT_DATE - 20, CURRENT_DATE - 8, NULL, 0.00),
    (3, 'Luyando Banda',  CURRENT_DATE - 7,  CURRENT_DATE,     NULL, 0.00);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INT, p_as_of DATE)
RETURNS NUMERIC(10, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_due_on      DATE;
    v_returned_on DATE;
    v_effective   DATE;
    v_days_late   INT;
BEGIN
    SELECT due_on, returned_on
    INTO v_due_on, v_returned_on
    FROM loans
    WHERE loan_id = p_loan_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;

    IF v_returned_on IS NOT NULL THEN
        v_effective := LEAST(p_as_of, v_returned_on);
    ELSE
        v_effective := p_as_of;
    END IF;

    v_days_late := GREATEST(0, (v_effective - v_due_on));
    RETURN ROUND((v_days_late * 2)::numeric, 2);
END;
$$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_return_loan(
    p_loan_id     INT,
    p_returned_on DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_borrowed_on DATE;
    v_returned_on DATE;
    v_due_on      DATE;
    v_days_late   INT;
    v_fine        NUMERIC(10, 2);
BEGIN
    SELECT borrowed_on, returned_on, due_on
    INTO v_borrowed_on, v_returned_on, v_due_on
    FROM loans
    WHERE loan_id = p_loan_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;

    IF v_returned_on IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % has already been returned on %', p_loan_id, v_returned_on;
    END IF;

    IF p_returned_on IS NULL OR p_returned_on < v_borrowed_on THEN
        RAISE EXCEPTION 'Return date % cannot be before borrowed_on %', p_returned_on, v_borrowed_on;
    END IF;

    v_days_late := GREATEST(0, (p_returned_on - v_due_on));
    v_fine := ROUND((v_days_late * 2)::numeric, 2);

    UPDATE loans
    SET returned_on = p_returned_on,
        fine_amount = v_fine
    WHERE loan_id = p_loan_id;
END;
$$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION fn_log_loan_return()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.returned_on IS DISTINCT FROM OLD.returned_on THEN
        INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on, changed_at)
        VALUES (NEW.loan_id, OLD.returned_on, NEW.returned_on, CURRENT_TIMESTAMP);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_loans_returned_on_audit
AFTER UPDATE OF returned_on ON loans
FOR EACH ROW
EXECUTE FUNCTION fn_log_loan_return();

-- (e) View
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT
    b.title,
    l.borrower_name,
    l.due_on,
    fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL
  AND l.due_on < CURRENT_DATE;

-- (f) Index, Query, and EXPLAIN
-- Justification: Partial index on book_id for unreturned loans (returned_on IS NULL) avoids indexing historical returned loans.
CREATE INDEX idx_loans_book_unreturned
ON loans (book_id)
WHERE returned_on IS NULL;

EXPLAIN
SELECT loan_id, borrower_name, borrowed_on, due_on
FROM loans
WHERE book_id = 1
  AND returned_on IS NULL;

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    SELECT
        p_as_of,
        COUNT(*) FILTER (WHERE fn_loan_fine(loan_id, p_as_of) > 0),
        COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0.00)
    FROM loans
    WHERE returned_on IS NULL
      AND due_on < p_as_of
    ON CONFLICT (snapshot_date) DO UPDATE
    SET overdue_count = EXCLUDED.overdue_count,
        total_fine    = EXCLUDED.total_fine;
END;
$$;

-- Daily at 00:10 for CURRENT_DATE (pg_cron)
SELECT cron.schedule(
    'refresh_overdue_summary',
    '10 0 * * *',
    $$CALL pr_refresh_overdue(CURRENT_DATE);$$
);
