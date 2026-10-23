# Advanced Database Systems Portfolio

**Course:** MIT 8103 Advanced Database Systems  
**Institution:** MIVA Open University — School of Postgraduate Studies  
**Programme:** Master of Information Technology  
**Academic Session:** 2026/2027  
**Student Assessment Type:** Individual Practical Database Portfolio (40 Marks)  
**Case Study Organisation:** Meridian Trust Bank  

---

## 1. Selected Case Study: Meridian Trust Bank

### 1.1 Organisation Profile & Scenario
**Meridian Trust Bank** is a licensed commercial and retail banking institution operating across major commercial centers in Nigeria (Lagos, Abuja, Port Harcourt, Ibadan, and Kano). The bank provides consumer banking, commercial treasury operations, and digital mobile services. Its offerings encompass checking and savings accounts, instantaneous domestic fund transfers, cash deposits and withdrawals, structured personal/business loans, and mobile banking applications.

### 1.2 Nature of the System & Polyglot Database Strategy
Modern financial platforms cannot rely on a one-size-fits-all database engine. Meridian Trust Bank implements a **Polyglot Persistence Architecture**:
1. **Relational Core (PostgreSQL 16):** Houses the core banking system of record—accounts, double-entry ledgers, loan schedules, and customer identities—where strict ACID guarantees, foreign keys, and zero balance discrepancies are legally mandated.
2. **Distributed Cloud HA (Patroni + etcd):** Protects the relational core against single-point-of-failure (SPOF) outages, enforcing zero data loss ($RPO = 0$) and automated failover via Raft consensus.
3. **NoSQL Document Store (MongoDB 7.0):** Ingests high-velocity, semi-structured mobile banking telemetry, audit trails, device fingerprints, and geolocation coordinates, powering real-time fraud pattern detection without burdening relational ledgers.

### 1.3 Database User Personas
* **Retail & Corporate Customers:** Check account balances, execute mobile fund transfers, view 90-day statements, and apply for loans.
* **Branch Tellers & Front-Desk Staff:** Perform customer onboarding, BVN/NIN identity verification (KYC), cash deposits, and counter withdrawals.
* **Credit & Loan Officers:** Review loan applications, configure interest rates and amortization tenures, approve facilities, and monitor repayment performance.
* **Security & Compliance Auditors:** Investigate suspicious multi-city login attempts, track failed transfers, and generate AML compliance reports.
* **Automated System Daemons:** Execute end-of-day ledger reconciliations, standing order transfers, and monthly interest calculations.

---

## 2. Portfolio Repository Structure

The repository is structured strictly according to the course specifications, with each activity operating as a self-contained module containing its scripts, datasets, execution evidence, and technical documentation:

```
advanced-database-portfolio/
├── portfolio-1-database-design/
│   ├── banking_system_er.drawio          # Raw diagram source (draw.io)
│   ├── banking_system_er.png             # Conceptual ER Diagram (Crow's Foot notation)
│   ├── banking_system_schema.sql         # Physical DDL schema & table constraints
│   ├── seed_data.sql                     # 200,000-row synthetic banking dataset
│   ├── screenshots/                      # pgAdmin 4 table catalog & query evidence
│   └── README.md                         # Normalisation (1NF-3NF) & design rationale
├── portfolio-2-query-optimisation/
│   ├── query-1.sql                       # Q1: 90-day account statement retrieval
│   ├── query-2.sql                       # Q2: Monthly top debited accounts aggregation
│   ├── query-3.sql                       # Q3: AML high-value fraud screening (>₦500k)
│   ├── q1_plan.txt                       # Detailed EXPLAIN (ANALYZE, BUFFERS) before/after
│   ├── q2_plan.txt                       # Detailed EXPLAIN (ANALYZE, BUFFERS) before/after
│   ├── q3_plan.txt                       # Detailed EXPLAIN (ANALYZE, BUFFERS) before/after
│   └── README.md                         # Performance benchmarks & indexing analysis
├── portfolio-3-transactions-concurrency/
│   ├── sp_transfer.sql                   # PL/pgSQL atomic fund transfer stored procedure
│   ├── transfer_rollback_output.txt      # Execution trace of failed transfer & audit retention
│   ├── concurrency_two_sessions.txt      # Two-session trace: Lost Update vs. FOR UPDATE
│   └── README.md                         # ACID breakdown & concurrency locking analysis
├── portfolio-4-nosql/
│   ├── docker-compose.yml                # MongoDB 7.0 container with persistent volumes
│   ├── mongo-init.js                     # RBAC application user & index initialization
│   ├── seed_events.js                    # 50,018 mobile telemetry events + planted fraud
│   ├── aggregate_fraud_check.js          # 5-stage native MongoDB aggregation pipeline
│   ├── fraud_aggregate_output.txt        # Output verifying exactly 6 flagged accounts
│   ├── screenshots/                      # 8 sequentially numbered execution screenshots
│   └── README.md                         # Polyglot architecture & pipeline breakdown
├── portfolio-5-distributed-cloud/
│   ├── docker-compose.yml                # 3-Node Spilo PostgreSQL + etcd 3.5.18 DCS cluster
│   ├── 01_schema_and_seed.sql            # Core banking seed script for replication testing
│   ├── test-replication.sh               # Cross-node data consistency verification script
│   ├── test-failover.sh                  # Automated primary failure & election drill script
│   ├── screenshots/                      # 5 terminal screenshots proving HA failover
│   └── portfolio_5_readme.md             # CAP theorem, DCS leases & failover analysis
└── README.md                             # Master repository index & executive documentation
```

---

## 3. Executive Summary of Portfolio Components

### [Portfolio 1: Database Design and Modelling](portfolio-1-database-design/README.md)
* **Objective:** Design and implement a robust relational foundation for Meridian Trust Bank adhering to strict normalisation standards.
* **Key Deliverables:**
  - **Conceptual ER Model:** Designed an entity-relationship diagram with Crow's Foot notation mapping 7 core entities (`customer`, `branch`, `account`, `"transaction"`, `loan`, `loan_repayment`, `audit_log`) and their cardinalities.
  - **Relational Schema:** Implemented PostgreSQL DDL enforcing surrogate primary keys, 64-bit NUBAN account numbers (`BIGINT`), and non-negative domain rules (`CHECK (balance >= 0)`, `CHECK (amount > 0)`).
  - **Formal Normalisation (3NF):** Formulated functional dependencies and documented the mathematical elimination of partial and transitive dependencies, preventing insertion, update, and deletion anomalies.
  - **Scale Seeding:** Created a scalable data generator ([`seed_data.sql`](portfolio-1-database-design/seed_data.sql)) seeding 10 branches, 5,000 customers, 7,500 accounts, and 200,000 transactions.
  - **Evidence:** Documented with pgAdmin 4 catalog inspection screenshots (`01_database_tables_schema.png`, `02_customer_table_data.png`, `03_account_table_data.png`).

---

### [Portfolio 2: Query Processing and Optimisation](portfolio-2-query-optimisation/README.md)
* **Objective:** Diagnose query bottlenecks on a 200,000-row ledger and design targeted indexing strategies using PostgreSQL's cost-based optimizer (`EXPLAIN (ANALYZE, BUFFERS)`).
* **Key Deliverables:**
  - **Q1 (Customer 90-Day Statement):** Evaluated disjunctive `OR` conditions. Deployed compound B-tree indexes (`idx_txn_from` and `idx_txn_to`), reducing latency from **`401.4 ms` down to `39.1 ms`** (**90.3% faster**) and slashing buffer page reads from 3,815 to 96.
  - **Q2 (Top Debited Accounts Aggregation):** Evaluated low-selectivity analytical grouping. Implemented a partial index (`idx_txn_debits`) filtered by `WHERE txn_status = 'COMPLETED'`, reducing execution time to `339.1 ms` and diagnosing `work_mem` hash aggregation disk spills.
  - **Q3 (AML Large-Value Fraud Screening >₦500k):** Evaluated high-selectivity predicate (~1% tail). Deployed `idx_txn_amount(amount DESC)`, dropping latency from **`185.2 ms` to `30.1 ms`** (**83.7% faster**) and completely eliminating the explicit `Sort` node from the plan tree.

---

### [Portfolio 3: Transactions and Concurrency](portfolio-3-transactions-concurrency/README.md)
* **Objective:** Guarantee ACID transactional durability and evaluate multi-user lock contention in high-volume fund transfers.
* **Key Deliverables:**
  - **Atomic Stored Procedure ([`sp_transfer.sql`](portfolio-3-transactions-concurrency/sp_transfer.sql)):** Implemented PL/pgSQL procedural transaction control (`COMMIT`, `ROLLBACK`) with pessimistic row locking (`SELECT ... FOR UPDATE`) and idempotency UUIDs.
  - **Audit Retention Pattern:** Verified that runtime exceptions (e.g. attempting to transfer ₦15,000 on a ₦7,500 balance) abort all balance modifications while persisting a `TRANSFER_FAILED` record into `audit_log` in an isolated transaction block.
  - **Multi-Session Concurrency Drill:** Simulated parallel execution across two terminal sessions, proving:
    - How naive `READ COMMITTED` allows the **Lost Update Anomaly** (silently wiping out ₦4,000).
    - How pessimistic locking (`FOR UPDATE`) forces Session B to block, read the fresh committed balance, and fail safely against the `account_balance_check` constraint.

---

### [Portfolio 4: NoSQL and Advanced Data Models](portfolio-4-nosql/README.md)
* **Objective:** Implement a document-oriented database for semi-structured mobile telemetry and execute real-time fraud pattern detection.
* **Key Deliverables:**
  - **MongoDB 7.0 Containerization:** Configured Docker Compose with persistent data volumes, healthchecks, and least-privilege RBAC authentication (`app_user`).
  - **Polymorphic Document Model:** Designed nested JSON schemas (`app_events`) storing device hashes, OS builds, and geographic locations in atomic documents without schema migration locks.
  - **Synthetic Dataset & Fraud Injection:** Loaded 50,018 events, planting an impossible-travel credential stuffing attack on 6 target customer accounts (`9001`–`9006`) with 4 failed logins across 4 distant cities within one hour.
  - **Native Aggregation Pipeline:** Executed a 5-stage pipeline (`$match`, `$group` with `$dateTrunc` and `$addToSet`, array existence filtering `'cities.1'`, and projection), flagging all 6 malicious accounts with 100% precision and zero false positives.
  - **Evidence:** Supported by 8 sequentially numbered terminal screenshots (`01_` through `08_`).

---

### [Portfolio 5: Distributed and Cloud Database Architecture](portfolio-5-distributed-cloud/portfolio_5_readme.md)
* **Objective:** Design, deploy, and verify an enterprise fault-tolerant distributed PostgreSQL cluster with automated self-healing.
* **Key Deliverables:**
  - **Cluster Topology:** Deployed 3 containerized PostgreSQL 16 nodes managed by **Zalando Spilo (Patroni DCS)** backed by an **etcd 3.5.18** Raft consensus cluster.
  - **Durability Guarantees:** Enforced synchronous streaming replication (`synchronous_commit = "on"`, `synchronous_standby_names = "FIRST 1 (*)"`), mathematically guaranteeing zero data loss ($RPO = 0$).
  - **CAP Theorem & Split-Brain Mitigation:** Configured time-limited etcd leader leases to immediately self-fence isolated primaries during network partitions, prioritizing Consistency and Partition Tolerance (CP).
  - **Crash-Failover Drill:** Simulated sudden primary leader crash (`docker stop node3`). Patroni promoted synchronous standby `node1` to cluster leader on Timeline 2 within 6 seconds ($RTO \approx 6\text{s}$), reconfigured `node2`, and re-synchronized the recovered primary using `pg_rewind`.

---

## 4. Technology Stack Matrix

| Layer / Component | Technology | Primary Architectural Role |
| :--- | :--- | :--- |
| **Relational Core** | PostgreSQL 16 | ACID transactions, double-entry bookkeeping, 3NF schema, PL/pgSQL procedures. |
| **NoSQL Store** | MongoDB 7.0 | High-velocity mobile telemetry, polymorphic BSON documents, aggregation pipelines. |
| **DCS Orchestration** | Patroni 3.3.0 | Distributed consensus-driven leader election, automated failover, node fencing. |
| **Consensus Store** | etcd 3.5.18 | Raft consensus engine, dynamic leader election leases, cluster configuration. |
| **Containerization** | Docker & Docker Compose | Isolated multi-node networking (`dbnet`), automated entrypoint provisioning. |
| **Administration** | pgAdmin 4 & `mongosh` | Schema catalog exploration, query plan visualization, interactive diagnostics. |

---

## 5. Quickstart: Replicating All Portfolios

To clone the repository and execute any of the portfolio exercises locally or on a cloud virtual server:

```bash
# 1. Clone the repository
git clone https://github.com/olafashade/advanced-database-portfolio.git
cd advanced-database-portfolio
```

### Running Portfolio 1 (Schema & Seed)
```bash
# Execute DDL and seed 200,000 transactions
psql -h localhost -U postgres -d meridian -f portfolio-1-database-design/banking_system_schema.sql
psql -h localhost -U postgres -d meridian -f portfolio-1-database-design/seed_data.sql
```

### Running Portfolio 2 (Query Optimization)
```bash
# Benchmark statement query with execution buffers
psql -h localhost -U postgres -d meridian -c "EXPLAIN (ANALYZE, BUFFERS) $(cat portfolio-2-query-optimisation/query-1.sql)"
```

### Running Portfolio 3 (Transactions & Concurrency)
```bash
# Deploy procedure and test rollback
psql -h localhost -U postgres -d meridian -f portfolio-3-transactions-concurrency/sp_transfer.sql
psql -h localhost -U postgres -d meridian -c "CALL sp_transfer(9000000001, 9000000002, 15000.00);"
```

### Running Portfolio 4 (NoSQL MongoDB Fraud Screening)
```bash
cd portfolio-4-nosql
docker compose up -d

# Seed 50,018 mobile events
docker compose exec -T mongo mongosh -u admin -p secret --authenticationDatabase admin meridian_bank < seed_events.js

# Execute fraud detection aggregation
docker compose exec -T mongo mongosh "mongodb://app_user:app_secret@localhost:27017/meridian_bank" --quiet < aggregate_fraud_check.js
cd ..
```

### Running Portfolio 5 (Distributed HA Failover Drill)
```bash
cd portfolio-5-distributed-cloud
docker compose up -d
./test-replication.sh
./test-failover.sh
cd ..
```

---

## 6. Academic Integrity & AI Use Declaration

In compliance with MIVA Open University’s School of Postgraduate Studies academic integrity guidelines (Section 11 of Assessment Brief):

1. **AI Tool Used:** Claude / Google Gemini (via Antigravity IDE).
2. **Purpose of Use:** AI was utilized as an interactive engineering pair-programmer and learning aid to assist in structuring documentation, verifying Markdown and LaTeX formatting, generating boilerplate synthetic event seed scripts, and evaluating PostgreSQL execution plan syntax.
3. **Review, Verification & Testing:** Every SQL query, stored procedure, Docker Compose manifest, and MongoDB aggregation pipeline was executed, tested, and validated on live PostgreSQL 16 and MongoDB 7.0 environments by the student. Terminal outputs, execution plans, and screenshots were captured directly from real test runs. All conclusions and technical reflections represent individual understanding.

---

## 7. Master Technical Reflection

Completing this practical portfolio across five interconnected domains provided critical takeaways that bridge database theory with enterprise engineering reality:

1. **The Polyglot Reality:** No single database engine solves all enterprise requirements. Using relational PostgreSQL for double-entry financial accounting provides mathematical correctness and regulatory peace of mind. Conversely, attempting to store thousands of high-frequency, polymorphically varying mobile events in PostgreSQL causes schema migration paralysis and table bloat—a workload where MongoDB's document model shines.
2. **Optimization Requires Holistic Understanding:** Writing an index is not a silver bullet. As demonstrated in Portfolio 2, an index on a low-selectivity column yields minimal improvement because the engine must still visit the heap; true speedups require understanding selectivity, buffer caches, and server memory allocations (`work_mem`).
3. **Distributed High Availability is About Fencing, Not Just Promotion:** Portfolio 5 proved that automatic failover is easy to promise but difficult to guarantee safely. The critical value of systems like Patroni and etcd lies in leader fencing—ensuring that an isolated node is immediately stripped of its write privileges before a new leader is crowned, preventing disastrous split-brain ledger divergence.
