-- =============================================================
-- seed_data.sql  –  Meridian Trust Bank sample data
-- target: PostgreSQL 16
-- prerequisite: run schema.sql (Portfolio 1) first.
-- produces roughly: 10 branches, 5,000 customers, ~7,500 accounts,
-- 200,000 transactions (last 12 months), 400 loans + repayments,
-- and a small audit trail.
-- =============================================================

SET client_min_messages = warning;
BEGIN;

-- 1. Branches
INSERT INTO branch (branch_name, location) VALUES
 ('Head Office',        'Lagos Island'),
 ('Ikeja Branch',       'Ikeja, Lagos'),
 ('Victoria Island',    'Victoria Island, Lagos'),
 ('Abuja Central',      'Wuse, Abuja'),
 ('Port Harcourt',      'GRA, Port Harcourt'),
 ('Ibadan Ring Road',   'Ring Road, Ibadan'),
 ('Enugu Independence', 'Independence Layout, Enugu'),
 ('Kano Murtala',       'Murtala Mohammed Way, Kano'),
 ('Benin Airport Road', 'Airport Road, Benin City'),
 ('Abeokuta Oke-Ilewo', 'Oke-Ilewo, Abeokuta');

-- 2. customers (5,000)

INSERT INTO customer (first_name, last_name, date_of_birth, email, phone, address, kyc_status)
SELECT
    (ARRAY['Adaeze','Chinedu','Ngozi','Emeka','Funke','Tunde','Aisha','Ibrahim',
           'Nnamdi','Halima','Kelechi','Bola','Yusuf','Amara','Segun','Fatima',
           'Obinna','Zainab','Damilola','Chiamaka'])[ceil(random()*20)::int]              AS first_name,
    (ARRAY['Okafor','Adebayo','Eze','Bello','Ogunleye','Nwosu','Abubakar','Adeyemi',
           'Okonkwo','Sani','Obi','Balogun','Adamu','Iwu','Olawale','Musa',
           'Umeh','Danjuma','Fashola','Anyanwu'])[ceil(random()*20)::int]                  AS last_name,
    (DATE '1965-01-01' + (random() * (DATE '2005-01-01' - DATE '1965-01-01'))::int)      AS date_of_birth,
    'cust' || g || '@example.com'                                                         AS email,
    '+234' || lpad((7000000000 + floor(random()*999999999))::bigint::text, 10, '0')       AS phone,
    'Plot ' || (1 + floor(random()*400))::int || ', Street ' || (1 + floor(random()*60))::int || ', Lagos' AS address,
    (ARRAY['VERIFIED','VERIFIED','VERIFIED','PENDING','REJECTED'])[ceil(random()*5)::int] AS kyc_status
FROM generate_series(1, 5000) AS g;


-- 3. accounts (~7,500: most customers hold 1-2 accounts)

CREATE TEMP TABLE acct_pool AS
SELECT (1002000000 + row_number() OVER ())::bigint AS account_no,
       customer_id, branch_id, account_type, opened_on
FROM (
    SELECT customer_id,
           1 + floor(random()*10)::int  AS branch_id,
           CASE WHEN random() < 0.6 THEN 'SAVINGS' ELSE 'CURRENT' END AS account_type,
           (DATE '2018-01-01' + (random() * (CURRENT_DATE - DATE '2018-01-01'))::int) AS opened_on
    FROM customer
    UNION ALL
    -- second account for 40% of customers
    SELECT customer_id,
           1 + floor(random()*10)::int,
           CASE WHEN random() < 0.5 THEN 'SAVINGS' ELSE 'CURRENT' END,
           (DATE '2019-01-01' + (random() * (CURRENT_DATE - DATE '2019-01-01'))::int)
    FROM customer
    WHERE random() < 0.4
) s;

INSERT INTO account (account_no, customer_id, branch_id, account_type, balance, status, opened_on)
SELECT account_no, customer_id, branch_id, account_type,
       round((random() * 2000000 + 5000)::numeric, 2) AS balance,   -- NGN 5,000 – 2,005,000
       CASE WHEN random() < 0.03 THEN 'FROZEN' ELSE 'ACTIVE' END,
       opened_on
FROM acct_pool;

CREATE INDEX tmp_pool_idx ON acct_pool(account_no);
ANALYZE acct_pool;

-- 4. transactions (200,000 over the past 12 months)
--    - ~1% of rows are large (NGN 500k+) so the fraud query
--      (Q3) returns a realistic result set.
--    - ~4% are FAILED/REVERSED for status filtering tests.
INSERT INTO transaction (from_acc, to_acc, txn_type, amount, txn_status, created_at, reference)
SELECT
    f.account_no                                                          AS from_acc,
    t.account_no                                                          AS to_acc,
    (ARRAY['TRANSFER','TRANSFER','TRANSFER','TRANSFER','TRANSFER',
           'DEPOSIT','DEPOSIT','WITHDRAWAL','WITHDRAWAL'])[ceil(random()*9)::int] AS txn_type,
    round((
        CASE WHEN random() < 0.01
             THEN 500000 + random() * 2000000        -- the "large" tail for Q3
             ELSE 1000 + random() * 200000          -- everyday payments
        END)::numeric, 2)                                                  AS amount,
    CASE WHEN random() < 0.04
         THEN (ARRAY['FAILED','REVERSED'])[ceil(random()*2)::int]
         ELSE 'COMPLETED' END                                                AS txn_status,
    now() - (random() * interval '365 days')                                 AS created_at,
    'TRF-' || upper(substr(gen_random_uuid()::text, 1, 18))                  AS reference
FROM generate_series(1, 200000) AS g
CROSS JOIN LATERAL (SELECT account_no FROM acct_pool ORDER BY random() LIMIT 1) f
CROSS JOIN LATERAL (
    SELECT account_no FROM acct_pool
    WHERE account_no <> f.account_no
    ORDER BY random() LIMIT 1
) t;

-- 5. loans and scheduled repayments
INSERT INTO loan (customer_id, amount, interest_rate, term_months, loan_status, applied_on)
SELECT
    (1 + floor(random()*5000))::int                              AS customer_id,
    round((50000 + random() * 4500000)::numeric, 2)              AS amount,   -- 50k – 4.55M
    round((12 + random() * 18)::numeric, 2)                      AS interest_rate,
    (ARRAY[6,12,12,24,24,36])[(1 + floor(random()*6))::int]      AS term_months,
    (ARRAY['APPROVED','APPROVED','APPROVED','APPLIED','REJECTED','REPAID'])
        [(1 + floor(random()*6))::int]                           AS loan_status,
    (DATE '2024-01-01' + (random() * (CURRENT_DATE - DATE '2024-01-01'))::int)
FROM generate_series(1, 400) AS g;

INSERT INTO loan_repayment (loan_id, due_date, amount_due, amount_paid, paid_on)
SELECT
    l.loan_id,
    (l.applied_on + (m || ' months')::interval)::date            AS due_date,
    round((l.amount * (1 + l.interest_rate/100) / l.term_months)::numeric, 2) AS amount_due,
    CASE WHEN random() < 0.85
         THEN round((l.amount * (1 + l.interest_rate/100) / l.term_months)::numeric, 2)
         ELSE 0 END                                              AS amount_paid,
    CASE WHEN random() < 0.85
         THEN (l.applied_on + (m || ' months')::interval)::date - floor(random()*10)::int
         ELSE NULL END                                           AS paid_on
FROM loan l
CROSS JOIN generate_series(1, l.term_months) AS m;


-- 6. a small audit trail
INSERT INTO audit_log (actor, action, detail, action_time)
SELECT
    'teller' || (1 + floor(random()*40))::int,
    (ARRAY['LOGIN','PASSWORD_RESET','ACCOUNT_FROZEN','ACCOUNT_UNFROZEN','TXN_REVERSED'])
        [(1 + floor(random()*5))::int],
    'auto-generated seed audit entry #' || g,
    now() - (random() * interval '180 days')
FROM generate_series(1, 300) AS g;

COMMIT;


ANALYZE customer;
ANALYZE account;
ANALYZE transaction;
ANALYZE loan;
ANALYZE loan_repayment;

