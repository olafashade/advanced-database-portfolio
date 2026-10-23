-- Connect to the meridian database
\c meridian;

-- Drop existing tables to ensure a clean slate if re-running
DROP TABLE IF EXISTS audit_transactions CASCADE;
DROP TABLE IF EXISTS accounts CASCADE;

CREATE TABLE accounts (
    account_id SERIAL PRIMARY KEY,
    account_number VARCHAR(10) UNIQUE NOT NULL,
    customer_name VARCHAR(100) NOT NULL,
    account_type VARCHAR(20) NOT NULL CHECK (account_type IN ('Savings', 'Current', 'Fixed Deposit', 'Treasury', 'Loan Escrow')),
    currency VARCHAR(3) DEFAULT 'NGN',
    balance NUMERIC(15, 2) NOT NULL CHECK (balance >= 0),
    status VARCHAR(15) DEFAULT 'Active' CHECK (status IN ('Active', 'Dormant', 'Frozen', 'Closed')),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE audit_transactions (
    audit_id SERIAL PRIMARY KEY,
    account_id INT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
    change_type VARCHAR(20) NOT NULL CHECK (change_type IN ('Deposit', 'Withdrawal', 'Transfer_In', 'Transfer_Out', 'Interest_Credit', 'Fee_Debit')),
    amount NUMERIC(15, 2) NOT NULL CHECK (amount > 0),
    balance_after NUMERIC(15, 2) NOT NULL,
    reference_code VARCHAR(32) UNIQUE NOT NULL,
    recorded_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- =============================================================
-- 1. Core Banking Seed Accounts (Retail, Corporate, and Vault)
-- =============================================================
INSERT INTO accounts (account_number, customer_name, account_type, balance, status, created_at) VALUES
('0100000001', 'Meridian Reserve Vault',       'Treasury',      500000000.00, 'Active',  NOW() - INTERVAL '365 days'),
('0100000002', 'Interbank Settlement Escrow',  'Loan Escrow',    50000000.00, 'Active',  NOW() - INTERVAL '300 days'),
('0200001001', 'Dangote Logistics Hub',        'Current',        85400000.75, 'Active',  NOW() - INTERVAL '180 days'),
('0200001002', 'Flutterwave Settlement Acct',  'Current',       120000000.00, 'Active',  NOW() - INTERVAL '150 days'),
('0200001003', 'Ikeja Electricity Dist. Plc',  'Current',        42350800.20, 'Active',  NOW() - INTERVAL '120 days'),
('0300002001', 'Amina Bello',                  'Savings',          750000.00, 'Active',  NOW() - INTERVAL '90 days'),
('0300002002', 'Chidi Okafor',                 'Current',         1250000.50, 'Active',  NOW() - INTERVAL '80 days'),
('0300002003', 'Zainab Abubakar',              'Savings',          340000.00, 'Active',  NOW() - INTERVAL '60 days'),
('0300002004', 'Olumide Bakare',               'Savings',         2890500.00, 'Active',  NOW() - INTERVAL '45 days'),
('0300002005', 'Ngozi Eze',                    'Fixed Deposit',   15000000.00, 'Active',  NOW() - INTERVAL '40 days'),
('0300002006', 'Tunde Fashola',                'Current',          450000.25, 'Active',  NOW() - INTERVAL '30 days'),
('0300002007', 'Fatima Danjuma',               'Savings',           85200.00, 'Active',  NOW() - INTERVAL '25 days'),
('0300002008', 'Emeka Nwosu',                  'Savings',         1620000.00, 'Active',  NOW() - INTERVAL '20 days'),
('0300002009', 'Blessing Bassey',              'Current',          980400.00, 'Active',  NOW() - INTERVAL '15 days'),
('0300002010', 'Ibrahim Garba',                'Savings',           15400.50, 'Dormant', NOW() - INTERVAL '200 days');

-- =============================================================
-- 2. Audit Trail for Initial Account Openings & Transfers
-- =============================================================
INSERT INTO audit_transactions (account_id, change_type, amount, balance_after, reference_code, recorded_at) VALUES
(1,  'Deposit',        500000000.00, 500000000.00, 'TXN-INIT-0001', NOW() - INTERVAL '365 days'),
(2,  'Deposit',         50000000.00,  50000000.00, 'TXN-INIT-0002', NOW() - INTERVAL '300 days'),
(3,  'Deposit',         85400000.75,  85400000.75, 'TXN-INIT-0003', NOW() - INTERVAL '180 days'),
(4,  'Deposit',        120000000.00, 120000000.00, 'TXN-INIT-0004', NOW() - INTERVAL '150 days'),
(5,  'Deposit',         42350800.20,  42350800.20, 'TXN-INIT-0005', NOW() - INTERVAL '120 days'),
(6,  'Deposit',           750000.00,    750000.00, 'TXN-INIT-0006', NOW() - INTERVAL '90 days'),
(7,  'Deposit',          1250000.50,   1250000.50, 'TXN-INIT-0007', NOW() - INTERVAL '80 days'),
(8,  'Deposit',           340000.00,    340000.00, 'TXN-INIT-0008', NOW() - INTERVAL '60 days'),
(9,  'Deposit',          2890500.00,   2890500.00, 'TXN-INIT-0009', NOW() - INTERVAL '45 days'),
(10, 'Deposit',         15000000.00,  15000000.00, 'TXN-INIT-0010', NOW() - INTERVAL '40 days'),
(6,  'Transfer_Out',       25000.00,    725000.00, 'TXN-TRF-0011',  NOW() - INTERVAL '10 days'),
(8,  'Transfer_In',        25000.00,    365000.00, 'TXN-TRF-0012',  NOW() - INTERVAL '10 days'),
(7,  'Fee_Debit',            537.50,   1249463.00, 'TXN-FEE-0013',  NOW() - INTERVAL '5 days'),
(9,  'Interest_Credit',    14250.00,   2904750.00, 'TXN-INT-0014',  NOW() - INTERVAL '1 days');

-- =============================================================
-- 3. Synthetic Scale Data: Generate 1,000 Audit Log Entries
-- (Ideal for proving continuous WAL replication across nodes)
-- =============================================================
INSERT INTO audit_transactions (account_id, change_type, amount, balance_after, reference_code, recorded_at)
SELECT
    (floor(random() * 14) + 1)::int AS account_id,
    (ARRAY['Deposit', 'Withdrawal', 'Transfer_In', 'Transfer_Out', 'Fee_Debit'])[floor(random() * 5 + 1)] AS change_type,
    round((random() * 49900 + 100)::numeric, 2) AS amount,
    round((random() * 1000000 + 50000)::numeric, 2) AS balance_after,
    'SYNTH-' || to_char(NOW(), 'YYYYMMDD') || '-' || lpad(s.id::text, 6, '0') AS reference_code,
    NOW() - (s.id || ' minutes')::interval AS recorded_at
FROM generate_series(1, 1000) AS s(id);