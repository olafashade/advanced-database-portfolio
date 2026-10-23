-- Banking System Database Schema
-- Database: PostgreSQL
-- Based on the schema supplied for MIT 8103 Advanced Database Systems.
-- Creates tables, primary/foreign keys, constraints, defaults, and indexes.
-- The table name "transaction" is quoted because TRANSACTION is a SQL keyword.

BEGIN;

CREATE TABLE customer (
    customer_id   SERIAL PRIMARY KEY,
    first_name    VARCHAR(50)  NOT NULL,
    last_name     VARCHAR(50)  NOT NULL,
    date_of_birth DATE         NOT NULL,
    email         VARCHAR(120) UNIQUE NOT NULL,
    phone         VARCHAR(20)  NOT NULL,
    address       VARCHAR(200),
    kyc_status    VARCHAR(15)  DEFAULT 'PENDING'
                  CHECK (kyc_status IN ('PENDING', 'VERIFIED', 'REJECTED')),
    created_at    TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE branch (
    branch_id   SERIAL PRIMARY KEY,
    branch_name VARCHAR(80)  NOT NULL,
    location    VARCHAR(100) NOT NULL
);

CREATE TABLE account (
    account_no   BIGINT PRIMARY KEY,
    customer_id  INT NOT NULL REFERENCES customer(customer_id),
    branch_id    INT NOT NULL REFERENCES branch(branch_id),
    account_type VARCHAR(15) NOT NULL
                 CHECK (account_type IN ('CURRENT', 'SAVINGS')),
    balance      NUMERIC(15,2) NOT NULL DEFAULT 0.00
                 CHECK (balance >= 0),
    status       VARCHAR(15) NOT NULL DEFAULT 'ACTIVE'
                 CHECK (status IN ('ACTIVE', 'FROZEN', 'CLOSED')),
    opened_on    DATE NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE "transaction" (
    txn_id      BIGSERIAL PRIMARY KEY,
    from_acc    BIGINT NOT NULL REFERENCES account(account_no),
    to_acc      BIGINT NOT NULL REFERENCES account(account_no),
    txn_type    VARCHAR(15) NOT NULL
                CHECK (txn_type IN ('TRANSFER', 'DEPOSIT', 'WITHDRAWAL')),
    amount      NUMERIC(15,2) NOT NULL CHECK (amount > 0),
    txn_status  VARCHAR(15) NOT NULL DEFAULT 'COMPLETED'
                CHECK (txn_status IN ('PENDING', 'COMPLETED', 'FAILED', 'REVERSED')),
    created_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    reference   VARCHAR(40) UNIQUE NOT NULL
);

CREATE INDEX idx_txn_from
    ON "transaction" (from_acc, created_at DESC);

CREATE INDEX idx_txn_to
    ON "transaction" (to_acc, created_at DESC);

CREATE TABLE audit_log (
    audit_id    BIGSERIAL PRIMARY KEY,
    actor       VARCHAR(60)  NOT NULL,
    action      VARCHAR(100) NOT NULL,
    detail      TEXT,
    action_time TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE loan (
    loan_id       SERIAL PRIMARY KEY,
    customer_id   INT NOT NULL REFERENCES customer(customer_id),
    amount        NUMERIC(15,2) NOT NULL CHECK (amount > 0),
    interest_rate NUMERIC(5,2) NOT NULL,
    term_months   INT NOT NULL CHECK (term_months > 0),
    loan_status   VARCHAR(15) DEFAULT 'APPLIED'
                  CHECK (loan_status IN ('APPLIED', 'APPROVED', 'REJECTED', 'REPAID')),
    applied_on    DATE DEFAULT CURRENT_DATE
);

CREATE TABLE loan_repayment (
    repayment_id SERIAL PRIMARY KEY,
    loan_id      INT NOT NULL REFERENCES loan(loan_id),
    due_date     DATE NOT NULL,
    amount_due   NUMERIC(15,2) NOT NULL,
    amount_paid  NUMERIC(15,2) NOT NULL DEFAULT 0.00,
    paid_on      DATE
);

COMMIT;

-- Normalisation summary for accompanying documentation:
-- 1NF: Each column stores a single value; repeating groups are not stored
--      as multiple values in a single column.
-- 2NF: Each table uses a single-column primary key, so there are no partial
--      dependencies on part of a composite primary key.
-- 3NF: Customer, branch, account, loan, and repayment facts are separated
--      into their respective tables to reduce duplication and update anomalies.
--
-- This script preserves the supplied design. Additional business rules
-- (such as repayment amount validation or transaction-type-specific account
-- requirements) would need separate constraints or application logic.
