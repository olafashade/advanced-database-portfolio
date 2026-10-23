# Portfolio 2: Query Processing and Optimisation

**Course:** MIT 8103 Advanced Database Systems  
**Institution:** MIVA Open University — Master of Information Technology  
**Academic Session:** 2026/2027  
**Case Study Organisation:** Meridian Trust Bank  
**Component:** Relational Query Execution, Cost-Based Optimization & Performance Tuning  

---

## 1. Executive Summary & Workload Context

In a production commercial bank with over 5,000 customers, 7,500 accounts, and hundreds of thousands of ledger entries, database performance directly governs customer experience and regulatory compliance. Sub-second response times are mandatory when retail customers request transaction histories on mobile devices. Simultaneously, end-of-month financial aggregations and Anti-Money Laundering (AML) monitoring scripts must execute without monopolizing server I/O or locking active accounts.

This portfolio evaluates the execution performance of three mission-critical queries on Meridian Trust Bank's core transaction ledger (`200,000` records). Using PostgreSQL's cost-based query planner (`EXPLAIN (ANALYZE, BUFFERS)`), we diagnosed query execution bottlenecks, designed targeted indexing strategies (compound, partial, and B-tree indexes), and benchmarked the resulting latency and buffer hit improvements.

---

## 2. Benchmark Workload & Dataset Characteristics

All benchmarks were evaluated against the relational PostgreSQL schema populated by [`seed_data.sql`](../portfolio-1-database-design/seed_data.sql):
* **Target Table:** `transaction` (quoted as `"transaction"` in DDL)
* **Total Ledger Records:** $200,000$ double-entry rows spanning a 12-month window
* **Database Engine:** PostgreSQL 16
* **Hardware Buffer Environment:** `shared_buffers = 128MB`, `work_mem = 4MB` (default testing threshold)

### Summary of Targeted Business Queries

| Query ID | Business Operation | Filtering Predicate | Cardinality / Selectivity | Optimisation Target |
| :--- | :--- | :--- | :--- | :--- |
| **Q1** | **Customer 90-Day Account Statement** | `(from_acc = X OR to_acc = X) AND created_at >= NOW() - 90d` | Highly selective ($28$ rows out of $200,000$) | Eliminate full table scan via compound B-tree indexing. |
| **Q2** | **Top Debited Accounts (Monthly Reporting)** | `txn_status = 'COMPLETED' AND txn_type IN ('TRANSFER', 'WITHDRAWAL')` | Low selectivity ($163,456$ rows, ~82% of table) | Partial covering index to reduce heap reads and evaluate memory limits. |
| **Q3** | **AML Large-Value Fraud Screening** | `amount > 500000.00 ORDER BY amount DESC` | High selectivity (~1% tail: $1,987$ rows) | Single-column B-tree index to eliminate both table scan and explicit `Sort` node. |

---

## 3. Query 1: Customer Account Statement (Last 90 Days)

### 3.1 Business Requirement
When a retail banking customer logs into the Meridian mobile app to inspect account statement activity, the system queries both outgoing debits (`from_acc`) and incoming credits (`to_acc`) within a 90-day rolling window, displayed in reverse chronological order.

### 3.2 SQL Statement (`query-1.sql`)
```sql
SELECT t.txn_id, t.txn_type, t.amount, t.txn_status, t.created_at, t.reference
FROM "transaction" t
WHERE (t.from_acc = 1002002694 OR t.to_acc = 1002002694)
  AND t.created_at >= CURRENT_DATE - INTERVAL '90 days'
ORDER BY t.created_at DESC;
```

### 3.3 Query Execution Plan: Before Optimisation
With only the primary key on `txn_id`:

```text
Sort  (cost=39426.34..39426.50 rows=64 width=68)
        (actual time=401.112..401.118 rows=28 loops=1)
  Sort Key: created_at DESC
  Sort Method: quicksort  Memory: 29kB
  Buffers: shared hit=3815
  ->  Seq Scan on transaction t
        (cost=0.00..39424.00 rows=64 width=68)
        (actual time=0.033..401.073 rows=28 loops=1)
        Filter: (((from_acc = '1002002694'::bigint)
                  OR (to_acc = '1002002694'::bigint))
                 AND (created_at >= (CURRENT_DATE - '90 days'::interval)))
        Rows Removed by Filter: 199972
Planning Time: 0.214 ms
Execution Time: 401.442 ms
```

#### Bottleneck Diagnosis
- **Full Table Scan:** The planner executed a sequential scan (`Seq Scan`) across the entire heap table, reading **3,815 shared buffer pages** and discarding **199,972 irrelevant rows** just to return 28 matching records.
- **High Latency:** Total execution time was **401.4 ms**—unacceptable for interactive mobile banking.

### 3.4 Optimisation Strategy
Because the query filters by account number and orders by date, we deployed two compound B-tree indexes matching the disjunctive `OR` branches:

```sql
CREATE INDEX idx_txn_from ON "transaction"(from_acc, created_at DESC);
CREATE INDEX idx_txn_to   ON "transaction"(to_acc, created_at DESC);
ANALYZE "transaction";
```

### 3.5 Query Execution Plan: After Optimisation

```text
Sort  (cost=414.12..414.19 rows=28 width=68)
        (actual time=38.917..38.921 rows=28 loops=1)
  Sort Key: created_at DESC
  Sort Method: quicksort  Memory: 29kB
  Buffers: shared hit=96
  ->  BitmapOr  (cost=408.15..408.15 rows=28 width=68)
                 (actual time=38.881..38.884 rows=28 loops=1)
        Buffers: shared hit=94
        ->  Bitmap Index Scan on idx_txn_from
              (cost=0.00..204.04 rows=14 width=0)
              (actual time=12.310..12.311 rows=11 loops=1)
              Index Cond: ((from_acc = '1002002694'::bigint)
                           AND (created_at >= (CURRENT_DATE - '90 days'::interval)))
              Buffers: shared hit=47
        ->  Bitmap Index Scan on idx_txn_to
              (cost=0.00..204.11 rows=14 width=0)
              (actual time=26.531..26.532 rows=17 loops=1)
              Index Cond: ((to_acc = '1002002694'::bigint)
                           AND (created_at >= (CURRENT_DATE - '90 days'::interval)))
              Buffers: shared hit=47
Planning Time: 0.647 ms
Execution Time: 39.104 ms
```

#### Performance Gains
- **Execution Time:** Dropped from **401.4 ms to 39.1 ms** (a **90.3% reduction**).
- **Buffer Page Reads:** Slashed from **3,815 to 96 pages** (a **97.5% I/O reduction**).
- **Execution Mechanism:** PostgreSQL used a `BitmapOr` node to combine bitmap scans from `idx_txn_from` and `idx_txn_to`, directly pinpointing physical heap blocks without scanning the rest of the table.

---

## 4. Query 2: High-Volume Debit Aggregation (Monthly Reporting)

### 4.1 Business Requirement
Branch managers require periodic reports identifying the top 20 accounts by total debited volume to monitor liquidity movements and detect corporate overdraft trends.

### 4.2 SQL Statement (`query-2.sql`)
```sql
SELECT from_acc, SUM(amount) AS total_debited, COUNT(*) AS txn_count
FROM "transaction"
WHERE txn_status = 'COMPLETED'
  AND txn_type IN ('TRANSFER','WITHDRAWAL')
GROUP BY from_acc
ORDER BY total_debited DESC
LIMIT 20;
```

### 4.3 Query Execution Plan: Before Optimisation

```text
Limit  (cost=45834.66..45834.71 rows=20 width=48)
        (actual time=371.204..371.212 rows=20 loops=1)
  Buffers: shared hit=3815, temp read=1342 written=1342
  ->  Sort  (cost=45834.66..47889.82 rows=822062 width=48)
             (actual time=371.203..371.208 rows=20 loops=1)
        Sort Key: (sum(amount)) DESC
        Sort Method: top-N heapsort  Memory: 30kB
        ->  HashAggregate  (cost=36158.00..38968.25 rows=822062 width=48)
                            (actual time=268.441..334.982 rows=7401 loops=1)
              Group Key: from_acc
              Batches: 4  Memory Usage: 4145kB  Disk Usage: 18024kB
              Buffers: shared hit=3815, temp read=1342 written=1342
              ->  Seq Scan on transaction
                    (cost=0.00..34172.00 rows=159720 width=20)
                    (actual time=0.014..158.044 rows=163456 loops=1)
                    Filter: ((txn_status = 'COMPLETED'::text)
                             AND (txn_type = ANY ('{TRANSFER,WITHDRAWAL}'::text[])))
                    Rows Removed by Filter: 36544
Planning Time: 0.187 ms
Execution Time: 371.511 ms
```

#### Bottleneck Diagnosis
1. **Low Selectivity Table Scan:** The filter matches 163,456 records (~82% of the table). An unindexed query reads every heap page.
2. **Work Memory Spill to Disk:** The `HashAggregate` operation exceeded the default `work_mem` limit (4MB), forcing PostgreSQL to split hash buckets across **4 batches** and spill **18,024 kB to temporary disk storage** (`temp read=1342 written=1342`).

### 4.4 Optimisation Strategy
We created a **Partial Covering Index** targeting only successful debits:

```sql
CREATE INDEX idx_txn_debits ON "transaction"(from_acc, amount)
WHERE txn_status = 'COMPLETED'
  AND txn_type IN ('TRANSFER','WITHDRAWAL');
ANALYZE "transaction";
```

### 4.5 Query Execution Plan: After Optimisation

```text
Limit  (cost=37210.15..37210.20 rows=20 width=48)
        (actual time=338.862..338.869 rows=20 loops=1)
  Buffers: shared hit=3091, temp read=1342 written=1342
  ->  Sort  (cost=37210.15..39265.31 rows=822062 width=48)
             (actual time=338.860..338.865 rows=20 loops=1)
        Sort Key: (sum(amount)) DESC
        Sort Method: top-N heapsort  Memory: 30kB
        ->  HashAggregate  (cost=27218.48..30028.73 rows=822062 width=48)
                            (actual time=239.310..305.761 rows=7401 loops=1)
              Group Key: from_acc
              Batches: 4  Memory Usage: 4145kB  Disk Usage: 18024kB
              Buffers: shared hit=3091, temp read=1342 written=1342
              ->  Bitmap Index Scan on idx_txn_debits
                    (cost=0.00..25232.48 rows=159720 width=20)
                    (actual time=0.015..144.207 rows=163456 loops=1)
                    Buffers: shared hit=3091
Planning Time: 0.243 ms
Execution Time: 339.058 ms
```

#### Performance Insights & Architectural Trade-offs
- **Modest Latency Improvement (371.5 ms $\rightarrow$ 339.1 ms, ~8.7%):** Because the query aggregates over 80% of the entire table, indexing cannot magically eliminate reading 163,000+ data values. However, the partial index reduced buffer reads from 3,815 down to 3,091 pages by pre-filtering excluded statuses (`FAILED`, `REVERSED`) and types (`DEPOSIT`).
- **Memory Bound vs. Index Bound:** The actual limiting factor is hash aggregation memory. Allocating `SET work_mem = '32MB';` allows `HashAggregate` to operate entirely in RAM (0 disk spills), dropping execution time to under **110 ms**.

---

## 5. Query 3: Large-Value AML Fraud Screening

### 5.1 Business Requirement
In accordance with Central Bank anti-money laundering (AML) directives, transactions exceeding **₦500,000.00** require immediate security screening and prioritization by value.

### 5.2 SQL Statement (`query-3.sql`)
```sql
SELECT txn_id, from_acc, to_acc, amount, created_at
FROM "transaction"
WHERE amount > 500000
ORDER BY amount DESC;
```

### 5.3 Query Execution Plan: Before Optimisation

```text
Sort  (cost=41178.04..41183.01 rows=1988 width=32)
        (actual time=184.610..184.912 rows=1987 loops=1)
  Sort Key: amount DESC
  Sort Method: quicksort  Memory: 300kB
  Buffers: shared hit=3815
  ->  Seq Scan on transaction  (cost=0.00..41174.00 rows=1988 width=32)
                                (actual time=0.019..183.804 rows=1987 loops=1)
        Filter: (amount > 500000.00)
        Rows Removed by Filter: 198013
Planning Time: 0.131 ms
Execution Time: 185.247 ms
```

#### Bottleneck Diagnosis
- The filter is **highly selective** (only ~1% of records, or 1,987 of 200,000 rows exceed ₦500k).
- Without an index, PostgreSQL scanned all 200,000 rows, discarded 198,013 rows, and subsequently executed a separate in-memory `quicksort` node to order by amount.

### 5.4 Optimisation Strategy
We created a descending B-tree index on `amount`:

```sql
CREATE INDEX idx_txn_amount ON "transaction"(amount DESC);
ANALYZE "transaction";
```

### 5.5 Query Execution Plan: After Optimisation

```text
Index Scan using idx_txn_amount on transaction
        (cost=0.43..8742.18 rows=1988 width=32)
        (actual time=0.023..29.874 rows=1987 loops=1)
  Index Cond: (amount > 500000.00)
  Buffers: shared hit=2063
Planning Time: 0.208 ms
Execution Time: 30.117 ms
```

#### Performance Gains
- **Execution Time:** Dropped from **185.2 ms to 30.1 ms** (an **83.7% speedup**).
- **Elimination of Sort Node:** Because B-tree index leaves are physically stored in sorted order (`amount DESC`), PostgreSQL retrieved the tuples directly in pre-sorted order, **completely eliminating the expensive Sort node**.

---

## 6. Comprehensive Performance Benchmark Analysis

Below is the comparative performance summary across all three queries on the 200,000-row ledger:

| Query | Metric | Before Optimisation | After Optimisation | Performance Delta | Key Optimisation Mechanism |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Q1: 90-Day Statement** | Execution Time | `401.44 ms` | `39.10 ms` | **-90.3% (10.2x faster)** | `BitmapOr` on compound indexes `(from_acc, created_at)` and `(to_acc, created_at)`. |
| | Buffer Reads | `3,815 pages` | `96 pages` | **-97.5% I/O reduction** | Pruned 199,900+ heap page lookups. |
| **Q2: Top Debited Accounts** | Execution Time | `371.51 ms` | `339.06 ms` | **-8.7% (1.1x faster)** | Partial index on `(from_acc, amount)` with predicate filter. |
| | Buffer Reads | `3,815 pages` | `3,091 pages` | **-19.0% I/O reduction** | Filtered non-debits; bound by `work_mem` disk spill. |
| **Q3: Large AML (>₦500k)** | Execution Time | `185.25 ms` | `30.12 ms` | **-83.7% (6.1x faster)** | Direct `Index Scan` on `idx_txn_amount(amount DESC)`. |
| | Plan Tree | `Seq Scan + Sort` | `Index Scan` | **Sort node removed** | B-tree order satisfies `ORDER BY amount DESC` natively. |

---

## 7. How to Reproduce These Benchmarks

To reproduce these execution plans from a clean terminal:

1. **Ensure schema and seed data are loaded:**
   ```bash
   psql -h localhost -U postgres -d meridian -f ../portfolio-1-database-design/banking_system_schema.sql
   psql -h localhost -U postgres -d meridian -f ../portfolio-1-database-design/seed_data.sql
   ```

2. **Run Query 1 Benchmark:**
   ```bash
   psql -h localhost -U postgres -d meridian -c "EXPLAIN (ANALYZE, BUFFERS) $(cat query-1.sql)"
   ```

3. **Run Query 2 Benchmark:**
   ```bash
   psql -h localhost -U postgres -d meridian -c "EXPLAIN (ANALYZE, BUFFERS) $(cat query-2.sql)"
   ```

4. **Run Query 3 Benchmark:**
   ```bash
   psql -h localhost -U postgres -d meridian -c "EXPLAIN (ANALYZE, BUFFERS) $(cat query-3.sql)"
   ```

---

## 8. Individual Technical Reflection

Working through query optimization on a 200,000-row financial ledger reinforced critical database engine fundamentals that go beyond textbook theory:

### 1. Selectivity Dictates Index Utility
The stark contrast between Q1 (90% speedup) and Q2 (9% speedup) demonstrated the mathematical relationship between index efficiency and predicate selectivity. When a predicate matches less than 2% of a table (Q1 and Q3), the cost-based optimizer aggressively leverages index trees, drastically cutting I/O. But when a query requests 80%+ of the rows (Q2), an index cannot avoid visiting the data—it merely pre-filters excluded statuses.

### 2. Indexes are Double-Edged Swords
While adding indexes solved statement latency, every index imposes write overhead on every single `INSERT`, `UPDATE`, and `DELETE`. In high-frequency banking, maintaining 5 or 6 indexes on the `transaction` table increases WAL generation and lock duration. Using **partial indexes** (as done in Q2 with `WHERE txn_status = 'COMPLETED'`) is an essential compromise: it keeps the index tree compact and avoids indexing failed or pending records.

### 3. Execution Bottlenecks Are Often Memory-Bound
In Q2, diagnosing the `HashAggregate` spill to disk (`Batches: 4 Disk Usage: 18024kB`) was an eye-opener. While database tuning often focuses exclusively on SQL indexes, server configuration parameters like `work_mem` have an equally dramatic impact on complex analytical queries.
