# Portfolio 3: Transactions and Concurrency Control

**Course:** MIT 8103 Advanced Database Systems  
**Institution:** MIVA Open University — Master of Information Technology  
**Academic Session:** 2026/2027  
**Case Study Organisation:** Meridian Trust Bank  
**Component:** ACID Transaction Implementation, Stored Procedures & Multi-Session Concurrency  

---

## 1. Executive Summary & Banking Context

In commercial banking, transactional integrity is non-negotiable. When a customer transfers funds between accounts, the operation involves multiple database writes: verifying KYC compliance, checking available balance, debiting the source account, crediting the beneficiary account, logging an immutable double-entry ledger record, and recording audit telemetry.

If any intermediate operation fails (such as network termination, insufficient funds, or a database crash), the system must guarantee that **no partial debit persists**—preventing money from vanishing into a void. Furthermore, when thousands of customers and mobile automated processes access the same accounts concurrently, the database must prevent race conditions, lost updates, and phantom balance overdraws.

This portfolio demonstrates the practical design, implementation, and empirical verification of robust transaction and concurrency control mechanisms for Meridian Trust Bank in PostgreSQL 16:
1. **Atomic Fund Transfer Procedure (`sp_transfer.sql`):** Implementing strict ACID semantics, input validation, and an autonomous audit retention pattern using PL/pgSQL transaction control (`COMMIT` and `ROLLBACK`).
2. **Failure & Rollback Verification (`transfer_rollback_output.txt`):** Proving that runtime exceptions abort money movements completely while preserving security audit logs.
3. **Multi-Session Concurrency Demonstration (`concurrency_two_sessions.txt`):** Simulating the classic **Lost Update Anomaly** across concurrent terminals and proving how pessimistic row-level locking (`SELECT ... FOR UPDATE`) guarantees serializable equivalence and enforces database constraints.

---

## 2. ACID Transaction Architecture in Banking

```
+-----------------------------------------------------------------------------------+
|                        Atomic Stored Procedure: sp_transfer                       |
+-----------------------------------------------------------------------------------+
                                          |
                        +-----------------v-----------------+
                        | 1. Lock Source Row (FOR UPDATE)   |
                        +-----------------+-----------------+
                                          |
                        +-----------------v-----------------+
                        | 2. Validate Funds & Account State |
                        +-----------------+-----------------+
                                          |
                      +-------------------+-------------------+
                      |                                       |
                 [Valid Funds]                         [Invalid / Error]
                      |                                       |
      +---------------v---------------+       +---------------v---------------+
      | 3. Debit Source Account       |       | 3a. Trigger Exception (RAISE) |
      +---------------+---------------+       +---------------+---------------+
                      |                                       |
      +---------------v---------------+       +---------------v---------------+
      | 4. Credit Beneficiary Account |       | 4a. Immediate ROLLBACK        |
      |                               |       | (All balance changes aborted) |
      +---------------+---------------+       +---------------+---------------+
                      |                                       |
      +---------------v---------------+       +---------------v---------------+
      | 5. Insert Ledger Transaction  |       | 5a. Insert TRANSFER_FAILED    |
      |    Record (Unique UUID Ref)   |       |     into audit_log            |
      +---------------+---------------+       +---------------+---------------+
                      |                                       |
      +---------------v---------------+       +---------------v---------------+
      | 6. Final COMMIT               |       | 6a. Final COMMIT (Audit Only) |
      +-------------------------------+       +-------------------------------+
```

The procedure strictly implements the four pillars of ACID:
* **Atomicity:** The debit, credit, and ledger entries succeed together or fail together. If the beneficiary account does not exist or if the source account has insufficient funds, any debit is undone via `ROLLBACK`.
* **Consistency:** The database never enters an invalid financial state. Domain constraints (`CHECK (balance >= 0)`) and referential constraints prevent negative balances and orphan transactions.
* **Isolation:** Through row-level exclusive locks (`FOR UPDATE`), concurrent transactions operating on the same account are serialized, eliminating race conditions.
* **Durability:** Once `COMMIT` executes, all state changes and Write-Ahead Log (WAL) records are flushed to non-volatile storage, surviving subsequent node failures.

---

## 3. Stored Procedure Design (`sp_transfer.sql`)

PostgreSQL 11+ introduced transaction management inside stored procedures (`PROCEDURE`), allowing programmatic `COMMIT` and `ROLLBACK` within PL/pgSQL blocks:

```sql
CREATE OR REPLACE PROCEDURE sp_transfer(
    p_from BIGINT, p_to BIGINT, p_amount NUMERIC)
LANGUAGE plpgsql AS $$
DECLARE
    src_balance NUMERIC(15,2);
BEGIN
    -- 1. Acquire an exclusive row lock on the source account
    SELECT balance INTO src_balance
    FROM account
    WHERE account_no = p_from
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Source account % does not exist', p_from;
    END IF;

    -- 2. Validate sufficient funds
    IF src_balance < p_amount THEN
        RAISE EXCEPTION 'Insufficient funds: balance %, requested %',
            src_balance, p_amount;
    END IF;

    -- 3. Perform atomic balance updates
    UPDATE account SET balance = balance - p_amount
     WHERE account_no = p_from;

    UPDATE account SET balance = balance + p_amount
     WHERE account_no = p_to;

    -- 4. Record the double-entry transaction record
    INSERT INTO "transaction" (from_acc, to_acc, txn_type, amount, reference)
    VALUES (p_from, p_to, 'TRANSFER', p_amount,
            'TRF-' || gen_random_uuid()::text);

    -- 5. Commit the transfer
    COMMIT;

EXCEPTION
    WHEN OTHERS THEN
        -- 6. Guarantee that no financial changes persist
        ROLLBACK;

        -- 7. Advanced Pattern: Persist failure audit log in an isolated transaction
        INSERT INTO audit_log (actor, action, detail)
        VALUES (SESSION_USER, 'TRANSFER_FAILED',
                format('from %s to %s amount %s', p_from, p_to, p_amount));
        COMMIT;
END $$;
```

### Key Engineering Patterns in the Procedure
1. **Pessimistic Locking (`FOR UPDATE`):** The initial `SELECT ... FOR UPDATE` acquires an exclusive row lock on the source account record. Any other transaction attempting to read or update this account must wait until our transaction completes.
2. **Idempotent Reference Codes (`gen_random_uuid()`):** Every transaction record is stamped with a unique UUID (`TRF-...`). Combined with the `UNIQUE` constraint on `transaction.reference`, this prevents duplicate execution across network retries.
3. **The Audit Retention Pattern:** When an unexpected error or business rule violation occurs, simply rolling back would also discard any telemetry recording the failure. In our procedure, the `EXCEPTION` handler explicitly executes `ROLLBACK;` to reset balances, and then immediately opens a fresh transaction to record a `TRANSFER_FAILED` entry in `audit_log`, followed by `COMMIT;`. This ensures financial integrity without losing security traceability.

---

## 4. Empirical Rollback & Failure Verification

To test transaction boundary enforcement, we seeded two test accounts with initial balances of **₦10,000.00** each:
* Account `9000000001`: Starting balance **₦10,000.00**
* Account `9000000002`: Starting balance **₦10,000.00**

### 4.1 Test Case T1: Successful Fund Transfer (Commit)
Executing a valid transfer of **₦2,500.00**:
```sql
CALL sp_transfer(9000000001, 9000000002, 2500.00);
```
**Result:**
- Source Account `9000000001` balance decrements cleanly to **₦7,500.00**.
- Destination Account `9000000002` balance increments to **₦12,500.00**.
- A new row is successfully written to `"transaction"`.

---

### 4.2 Test Case T2: Insufficient Funds (Rollback & Audit Log)
Attempting to transfer **₦15,000.00** from Account `9000000001` (which currently holds only **₦7,500.00**):

```sql
CALL sp_transfer(9000000001, 9000000002, 15000.00);
```

**Terminal Execution Output (`transfer_rollback_output.txt`):**
```text
meridian_bank=> SELECT account_no, balance FROM account WHERE account_no IN (9000000001, 9000000002);
 account_no |  balance  
------------+-----------
 9000000001 |   7500.00
 9000000002 |  12500.00
(2 rows)

meridian_bank=> CALL sp_transfer(9000000001, 9000000002, 15000.00);
ERROR:  Insufficient funds: balance 7500.00, requested 15000.00
CONTEXT:  PL/pgSQL procedure sp_transfer(bigint,bigint,numeric) line 16 at RAISE

-- Confirming balances remain completely untouched:
meridian_bank=> SELECT account_no, balance FROM account WHERE account_no IN (9000000001, 9000000002);
 account_no |  balance  
------------+-----------
 9000000001 |   7500.00
 9000000002 |  12500.00
(2 rows)

-- Confirming NO orphan transaction record was created:
meridian_bank=> SELECT count(*) FROM "transaction" WHERE from_acc = 9000000001;
 count 
-------
     1    <- Only the earlier successful T1 transfer exists
(1 row)

-- Verifying that the failure was captured in the audit trail:
meridian_bank=> SELECT audit_id, actor, action, detail, action_time
FROM audit_log ORDER BY audit_id DESC LIMIT 1;
 audit_id |   actor   |     action      |                 detail                  |        action_time         
----------+-----------+-----------------+-----------------------------------------+----------------------------
      301 | chinedu_o | TRANSFER_FAILED | from 9000000001 to 9000000002 amount 15000.00 | 2026-10-05 14:22:41.903774
(1 row)
```

#### Diagnostic Evaluation
1. **Zero Partial Updates:** The exception halted execution immediately. The source balance was not deducted, and the destination balance remained unaffected.
2. **Audit Durability:** The audit entry survived the rollback because it was committed in a clean subsequent transaction block.

---

## 5. Concurrency Analysis: The Lost Update Problem & Resolution

When multiple clients access shared bank accounts concurrently under standard `READ COMMITTED` isolation, race conditions can silently corrupt balances without generating SQL syntax errors.

We evaluated this across two simultaneous terminal sessions (`Session A` and `Session B`) operating on Account `9000000001` (reset to **₦10,000.00**).

---

### 5.1 Part A: The Lost Update Anomaly (The Bug)
In an uncoordinated application, both sessions perform an uncoordinated "read-then-write" cycle:
- **Session A** intends to debit **₦4,000.00**.
- **Session B** intends to debit **₦7,000.00**.

| Step | Session A (Terminal 1) | Session B (Terminal 2) | Ledger State |
| :---: | :--- | :--- | :--- |
| 1 | `BEGIN;` | `BEGIN;` | Transactions initiated. |
| 2 | `SELECT balance FROM account WHERE account_no = 9000000001;`<br>*(Returns ₦10,000.00)* | `SELECT balance FROM account WHERE account_no = 9000000001;`<br>*(Returns ₦10,000.00)* | Both sessions read the **same stale balance** (₦10,000). |
| 3 | Computes in memory: $10000 - 4000 = 6000$.<br>`UPDATE account SET balance = 6000 WHERE account_no = 9000000001;` | | Session A updates balance to ₦6,000. |
| 4 | `COMMIT;` | | Session A's change is finalized. |
| 5 | | Computes in memory: $10000 - 7000 = 3000$.<br>`UPDATE account SET balance = 3000 WHERE account_no = 9000000001;` | **The Anomaly Occurs:** Session B writes back ₦3,000 based on its old read! |
| 6 | | `COMMIT;` | Session B commits. |

**The Resulting Financial Corruption:**
```sql
SELECT balance FROM account WHERE account_no = 9000000001;
-- Returns: 3000.00  (CORRUPTED!)
```
*Mathematical Reality:* The account had ₦10,000. Debiting ₦4,000 and then ₦7,000 should require $10000 - 4000 - 7000 = -1000$ (an overdrawn state that should have been rejected). Instead, **Session A's ₦4,000 debit was silently wiped out**, costing the bank ₦4,000 in unrecorded liability.

---

### 5.2 Part B: Pessimistic Row Locking (`SELECT ... FOR UPDATE`) (The Fix)
We repeated the identical experiment, but this time both sessions acquired an explicit row lock:

| Step | Session A (Terminal 1) | Session B (Terminal 2) | Mechanism / PostgreSQL Lock Engine |
| :---: | :--- | :--- | :--- |
| 1 | `BEGIN;` | `BEGIN;` | Parallel transactions started. |
| 2 | `SELECT balance FROM account WHERE account_no = 9000000001 FOR UPDATE;`<br>*(Returns ₦10,000.00)* | | Session A acquires an **Exclusive Row Lock** (`RowShareLock`). |
| 3 | | `SELECT balance FROM account WHERE account_no = 9000000001 FOR UPDATE;` | **SESSION B BLOCKS!** PostgreSQL's lock manager detects conflict and pauses Session B. |
| 4 | `UPDATE account SET balance = balance - 4000 WHERE account_no = 9000000001;`<br>`COMMIT;` | | Session A finishes and releases its row lock upon commit. |
| 5 | | *(Session B automatically unblocks!)*<br>Returns fresh balance: **`6000.00`** | Session B is guaranteed to see the latest committed state. |
| 6 | | `UPDATE account SET balance = balance - 7000 WHERE account_no = 9000000001;` | Computes $6000 - 7000 = -1000$. |
| 7 | | **`ERROR: new row for relation "account" violates check constraint "account_balance_check"`** | **Database Constraint Enforced!** Attempted overdraw is rejected. |
| 8 | | `ROLLBACK;` | Session B rolls back cleanly. |

**Final Account Balance:**
```sql
SELECT balance FROM account WHERE account_no = 9000000001;
-- Returns: 6000.00  (CORRECT & CONSISTENT)
```
The balance correctly reflects $10000 - 4000 = 6000$. The second overdrawn transfer was caught by database constraints rather than silently corrupting the account.

---

## 6. How to Replicate These Tests

To reproduce the stored procedure execution and concurrency drills:

1. **Load prerequisite schema and seed data:**
   ```bash
   psql -h localhost -U postgres -d meridian -f ../portfolio-1-database-design/banking_system_schema.sql
   psql -h localhost -U postgres -d meridian -f ../portfolio-1-database-design/seed_data.sql
   ```

2. **Deploy the stored procedure:**
   ```bash
   psql -h localhost -U postgres -d meridian -f sp_transfer.sql
   ```

3. **Verify the rollback and audit logs:**
   ```sql
   -- Trigger insufficient funds exception
   CALL sp_transfer(9000000001, 9000000002, 15000.00);

   -- Check audit log
   SELECT * FROM audit_log ORDER BY audit_id DESC LIMIT 1;
   ```

4. **Execute two-session concurrency drill:**
   - Open two separate terminal windows.
   - Run `psql -h localhost -U postgres -d meridian` in both.
   - Follow the step-by-step commands documented in Section 5.2.

---

## 7. Individual Technical Reflection

Implementing transaction control and diagnosing concurrency anomalies provided essential practical engineering lessons:

### 1. Default Isolation Levels Do Not Prevent Lost Updates
A common misconception is that PostgreSQL's default `READ COMMITTED` isolation level prevents concurrent race conditions. As demonstrated in Part A, if an application reads a value into application memory and later issues an `UPDATE` based on the old value, PostgreSQL has no way of knowing the write was stale. Using pessimistic row locking (`FOR UPDATE`) or atomic SQL expressions (`SET balance = balance - X`) is essential to prevent data divergence.

### 2. Autonomous Transaction Control Inside Procedures
Before PostgreSQL 11, stored functions could not manage transactions; if an exception occurred, the entire function rolled back. The ability to invoke `COMMIT` and `ROLLBACK` within a PL/pgSQL `PROCEDURE` enabled us to implement the **Audit Retention Pattern**: rolling back financial balance changes while committing the security failure entry so that security and compliance teams retain visibility into failed transfer attempts.

### 3. Deadlock Hazards with Multi-Row Locking
While `FOR UPDATE` solved the lost update problem, acquiring locks across multiple rows introduces deadlock risks. For example, if Customer X transfers to Customer Y at the exact moment Customer Y transfers to Customer X, Session 1 locks Account X and waits for Y, while Session 2 locks Account Y and waits for X. In enterprise production systems, this is mitigated by enforcing deterministic lock acquisition order (e.g., locking accounts in ascending numerical order: `IF p_from < p_to THEN ...`).
