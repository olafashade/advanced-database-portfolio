-- =============================================================
-- sp_transfer.sql - Meridian Trust Bank
-- Portfolio 3: atomic fund transfer with commit / rollback
-- Target: PostgreSQL 16 (transaction control in a PROCEDURE)
-- Prerequisite: schema.sql and seed_data.sql already loaded.
-- =============================================================

-- -------------------------------------------------------------
-- 0. Demo setup: two test accounts with known balances,
--    so every example below is reproducible.
--    (Requires one verified customer - reuse customer_id 1.)
-- -------------------------------------------------------------
INSERT INTO branch (branch_name, location)
VALUES ('Test Branch', 'Test Location')
ON CONFLICT DO NOTHING;

INSERT INTO account (account_no, customer_id, branch_id, account_type, balance, status, opened_on)
VALUES
    (9000000001, 1, (SELECT max(branch_id) FROM branch), 'CURRENT', 10000.00, 'ACTIVE', CURRENT_DATE),
    (9000000002, 1, (SELECT max(branch_id) FROM branch), 'SAVINGS', 10000.00, 'ACTIVE', CURRENT_DATE)
ON CONFLICT (account_no) DO NOTHING;

SELECT account_no, balance FROM account WHERE account_no IN (9000000001, 9000000002);

-- -------------------------------------------------------------
-- 1. The stored procedure
-- -------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_transfer(
    p_from BIGINT, p_to BIGINT, p_amount NUMERIC)
LANGUAGE plpgsql AS $$
DECLARE
    src_balance NUMERIC(15,2);
BEGIN
    -- Lock the source row so no other session moves the same money
    SELECT balance INTO src_balance
    FROM account
    WHERE account_no = p_from
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Source account % does not exist', p_from;
    END IF;

    IF src_balance < p_amount THEN
        RAISE EXCEPTION 'Insufficient funds: balance %, requested %',
            src_balance, p_amount;
    END IF;

    UPDATE account SET balance = balance - p_amount
     WHERE account_no = p_from;
    UPDATE account SET balance = balance + p_amount
     WHERE account_no = p_to;

    INSERT INTO transaction (from_acc, to_acc, txn_type, amount, reference)
    VALUES (p_from, p_to, 'TRANSFER', p_amount,
            'TRF-' || gen_random_uuid()::text);

    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;   -- no partial debit ever persists
        INSERT INTO audit_log (actor, action, detail)
        VALUES (SESSION_USER, 'TRANSFER_FAILED',
                format('from %s to %s amount %s', p_from, p_to, p_amount));
        COMMIT;
END $$;

-- -------------------------------------------------------------
-- 2. Test cases (run these one at a time and capture the output)
-- -------------------------------------------------------------

-- T1: successful transfer of 2,500
CALL sp_transfer(9000000001, 9000000002, 2500.00);

-- expected balances afterwards:
--   9000000001 -> 7500.00
--   9000000002 -> 12500.00

-- T2: insufficient funds - should raise an exception and roll back
CALL sp_transfer(9000000001, 9000000002, 15000.00);

-- expected: error raised; 9000000001 balance still 7500.00;
-- a TRANSFER_FAILED row appears in audit_log.

-- T3: target account does not exist - full rollback
CALL sp_transfer(9000000001, 9999999999, 1000.00);

-- expected: error raised; both balances unchanged;
-- audit_log records the failure.
