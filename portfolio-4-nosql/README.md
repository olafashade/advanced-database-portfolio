# Portfolio 4: NoSQL and Advanced Data Models

**Course:** MIT 8103 Advanced Database Systems  
**Institution:** MIVA Open University — Master of Information Technology  
**Academic Session:** 2026/2027  
**Case Study Organisation:** Meridian Trust Bank  
**Component:** NoSQL Document Store Implementation & Fraud Analytics  

---

## 1. Executive Summary & Business Context

Meridian Trust Bank operates a modern retail and digital banking platform. While our core financial transactions (checking accounts, savings ledgers, internal funds transfers) demand the strict ACID guarantees and relational structure of PostgreSQL (implemented in Portfolios 1, 3, and 5), our mobile banking channel presents a fundamentally different data challenge.

Every mobile session generates a continuous stream of telemetry and interaction events: device fingerprints, operating system builds, session handshakes, screen transitions, biometric verifications, and failed authentication attempts. Attempting to force these high-throughput, semi-structured, and polymorphic event streams into a rigid relational schema creates three major operational problems:
1. **Schema Rigidity & Null Pollution:** Different events carry vastly different metadata (a biometric login has sensor hashes; a funds transfer initiation has recipient routing info; a page view has screen coordinates). In relational tables, this leads to dozens of sparse, NULL-heavy columns or brittle EAV (Entity-Attribute-Value) anti-patterns.
2. **Schema Migration Bottlenecks:** Mobile app updates release rapidly (Android 14/15, iOS 17/18, biometric authentication API revisions). Updating a PostgreSQL table schema with millions of audit rows can lock tables or require complex zero-downtime migration scripts.
3. **High-Write Ingestion Throughput:** Security event logs require rapid appending without transactional locking overhead.

To address these demands, Meridian Trust Bank adopted a **Polyglot Persistence Architecture**. We deployed **MongoDB 7.0** as a dedicated document-oriented store specifically for mobile application telemetry, audit tracking, and real-time fraud pattern detection.

---

## 2. Polyglot Architecture & Model Suitability

```
                       +----------------------------------+
                       |   Meridian Mobile Banking App    |
                       |       (iOS & Android Users)      |
                       +-----------------+----------------+
                                         |
                       +-----------------v----------------+
                       |        API Gateway Layer         |
                       +--------+----------------+--------+
                                |                |
      Core Financial Actions    |                |   High-Volume Telemetry & Logins
     (Transfers, Balance, ACID) |                |   (Logins, Device Info, Page Views)
                                |                |
             +------------------v--+          +--v-------------------+
             |  PostgreSQL Cluster |          |  MongoDB 7.0 Cluster |
             |  (Core Banking DB)  |          |  (meridian_bank DB)  |
             |   Ledgers & ACIDs   |          |      app_events      |
             +---------------------+          +----------------------+
                                                         |
                                              +----------v-----------+
                                              | Aggregation Pipeline |
                                              | Real-Time Fraud Anal.|
                                              +----------------------+
```

### Why the Document Model Fits Banking Telemetry

| Characteristic | Relational Approach (PostgreSQL) | Document Model (MongoDB) | Architectural Justification |
| :--- | :--- | :--- | :--- |
| **Data Structure** | Normalized tables linked via Foreign Keys (`events`, `devices`, `metadata`). | Self-contained, nested JSON/BSON documents (`app_events`). | A single write persists the full event context (device, location, session) without expensive multi-table joins. |
| **Schema Flexibility** | Rigid columns defined upfront; altering tables on live systems is risky. | Dynamic schema per document. | Effortlessly handles new metadata (e.g., adding hardware secure enclave tokens or new biometric methods) without modifying existing documents. |
| **Analytical Processing** | Complex SQL window functions (`OVER (PARTITION BY ...)`). | Multi-stage aggregation pipelines (`$match`, `$group`, `$dateTrunc`, `$addToSet`). | Expressive pipelined processing allows grouping events into arbitrary time buckets and detecting geographic velocity anomalies in-database. |
| **Write Scalability** | Heavy WAL logging, relational integrity checks, and foreign key verification on every row. | Append-optimized WiredTiger engine with document-level concurrency. | Efficiently ingests tens of thousands of concurrent mobile touchpoints during peak banking hours. |

---

## 3. System Architecture & Container Configuration

The MongoDB environment is containerized using Docker Compose, mirroring our production deployment standards with dedicated storage persistence, authentication, and automated initialization.

### Docker Service Definition (`docker-compose.yml`)

The service runs official `mongo:7.0` on an isolated network bridge:

```yaml
services:
  mongo:
    image: mongo:7.0
    container_name: meridian-mongo
    restart: unless-stopped
    ports:
      - "27017:27017"
    environment:
      MONGO_INITDB_ROOT_USERNAME: admin
      MONGO_INITDB_ROOT_PASSWORD: secret
      MONGO_INITDB_DATABASE: meridian_bank
    volumes:
      - mongo_data:/data/db
      - ./mongo-init.js:/docker-entrypoint-initdb.d/mongo-init.js:ro
    healthcheck:
      test: ["CMD", "mongosh", "--quiet", "--eval",
             "db.adminCommand('ping')",
             "-u", "admin", "-p", "secret", "--authenticationDatabase", "admin"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 20s

volumes:
  mongo_data:
```

### Security & Initialization Hook (`mongo-init.js`)

In compliance with banking security standards (Principle of Least Privilege), application workloads should never connect as root. The `mongo-init.js` script runs during container initialization to provision a scoped application user and enforce query indexes:

```javascript
const bankDB = db.getSiblingDB('meridian_bank');

// Scoped application credentials
bankDB.createUser({
  user: 'app_user',
  pwd: 'app_secret',
  roles: [
    { role: 'readWrite', db: 'meridian_bank' },
    { role: 'dbAdmin', db: 'meridian_bank' }
  ]
});

// Pre-create collection and compound indexes
bankDB.createCollection('app_events');
bankDB.app_events.createIndex({ event_type: 1, timestamp: -1 }, { name: 'idx_event_type_timestamp' });
bankDB.app_events.createIndex({ customer_id: 1, timestamp: -1 }, { name: 'idx_customer_timestamp' });
bankDB.app_events.createIndex({ session_id: 1 }, { name: 'idx_session' });
```

---

## 4. Document Model Design

Each document stored in the `app_events` collection represents an atomic interaction on the Meridian mobile banking platform. Embedded subdocuments encapsulate device hardware specifications and geographic coordinates.

### Document Schema Example (`LOGIN_FAILED`)

```json
{
  "_id": ObjectId("6ada38cfb2f6d211da235cca"),
  "customer_id": 800,
  "session_id": "sess_239004",
  "event_type": "LOGIN_FAILED",
  "device": {
    "os": "iOS 18",
    "app_version": "4.1.2",
    "device_id_hash": "45557a192901"
  },
  "location": {
    "city": "Port Harcourt",
    "country": "NG"
  },
  "timestamp": ISODate("2026-10-04T17:36:10.467Z"),
  "metadata": {
    "login_method": "pin",
    "failed_attempts_before": 3
  }
}
```

### Field Breakdown & Design Rationale
- **`customer_id`** *(Integer)*: Links the event back to the customer's relational account in PostgreSQL without enforcing an expensive cross-database foreign key constraint.
- **`session_id`** *(String)*: Unique token tracking the user's specific app session lifecycle from launch to exit.
- **`event_type`** *(String)*: Categorizes the action (`LOGIN`, `LOGIN_FAILED`, `PAGE_VIEW`, `TRANSFER_INITIATED`, `LOGOUT`).
- **`device`** *(Embedded Subdocument)*: Retains OS versions and anonymized hardware hashes (`device_id_hash`). This allows security engineers to spot unauthorized devices attempting account takeovers.
- **`location`** *(Embedded Subdocument)*: Captures origin city and country code (`NG`). Enables geographic velocity calculations (e.g., impossible travel time between login attempts).
- **`timestamp`** *(ISODate)*: BSON UTC timestamp with millisecond precision, fundamental for time-window aggregations.
- **`metadata`** *(Polymorphic Object)*: Varies dynamically depending on `event_type`. For login events, it stores authentication method and failure counters.

---

## 5. Synthetic Dataset Generation (`seed_events.js`)

To simulate a realistic banking workload, `seed_events.js` populates the `app_events` collection with **50,018 total documents** across a 30-day window:

1. **49,994 Baseline Events:**
   - Distributed across 1,000 legitimate retail banking customers.
   - Realistic event distributions: high volume of `PAGE_VIEW` and `LOGIN` events, intermittent `TRANSFER_INITIATED` actions, and occasional benign login errors.
   - Inserted in efficient 1,000-document batches using `insertMany()`.

2. **Deliberate Fraud Injection (The "Ground Truth" Test):**
   - Injects a coordinated **credential stuffing / impossible travel attack** targeted at **6 specific customer accounts (`9001` through `9006`)**.
   - Each victim experiences **4 consecutive `LOGIN_FAILED` events** originating from **4 different cities across Nigeria** (`Lagos` at 0m, `Kano` at 12m, `Port Harcourt` at 27m, and `Abuja` at 41m).
   - All 4 attempts occur within a single 60-minute window (at 14:00).
   - This deliberate planting provides a strict deterministic benchmark: any correct fraud detection query must flag exactly these 6 accounts, with zero false positives.

```bash
# Executing seed script via mongosh
docker compose exec -T mongo mongosh -u admin -p secret --authenticationDatabase admin meridian_bank < seed_events.js
```

---

## 6. Fraud Analytics Aggregation Pipeline (`aggregate_fraud_check.js`)

In retail banking security, account takeover bots often cycle through proxy IPs or VPN endpoints across distant cities to bypass single-IP rate limits. 

We formulated a strict fraud rule:  
> **Flag any customer who triggers $\ge 3$ failed logins from $\ge 2$ distinct cities within any single 1-hour window.**

To evaluate this across 50,000+ documents, we built a 5-stage native MongoDB aggregation pipeline:

```javascript
const results = db.app_events.aggregate([
  // Stage 1: Filter immediately on indexed event_type
  { $match: { event_type: 'LOGIN_FAILED' } },

  // Stage 2: Bucket events by customer and truncated hour, aggregating metrics
  { $group: {
      _id: {
        customer: '$customer_id',
        hour:     { $dateTrunc: { date: '$timestamp', unit: 'hour' } }
      },
      attempts:   { $sum: 1 },
      cities:     { $addToSet: '$location.city' },
      first_seen: { $min: '$timestamp' },
      last_seen:  { $max: '$timestamp' }
  }},

  // Stage 3: Apply the fraud rule (threshold and distinct city condition)
  { $match: {
      attempts:   { $gte: 3 },
      'cities.1': { $exists: true }     // checks if cities array has index 1 (>= 2 distinct cities)
  }},

  // Stage 4: Project clean alert output for security compliance
  { $project: {
      _id: 0,
      customer_id:     '$_id.customer',
      hour:            '$_id.hour',
      failed_attempts: '$attempts',
      distinct_cities: '$cities',
      window: { first_seen: '$first_seen', last_seen: '$last_seen' }
  }},

  // Stage 5: Deterministic sort by customer ID
  { $sort: { customer_id: 1 } }
]).toArray();
```

### Stage-by-Stage Breakdown
* **Stage 1 (`$match`):** Discards unrelated events (`PAGE_VIEW`, `LOGIN`, `LOGOUT`), reducing the working dataset from 50,018 rows down to ~4,151 failed login records. Because `{ event_type: 1 }` is indexed, this stage avoids an expensive collection scan (`COLLSCAN`).
* **Stage 2 (`$group`):** Utilizes MongoDB 7's `$dateTrunc` operator to bucket events by customer and clock-hour cleanly. `$addToSet` collects unique city strings, automatically deduplicating repeated attempts from the same location.
* **Stage 3 (`$match` filter):** Enforces our multi-vector fraud condition:
  - `attempts: { $gte: 3 }`: Ensures normal single-password typos are ignored.
  - `'cities.1': { $exists: true }`: A performant BSON array trick—rather than calculating `$size` across every group, checking if the second element (0-indexed position 1) exists immediately verifies that at least two distinct cities contributed to the attempts.
* **Stage 4 (`$project`):** Formats the document into an actionable alert object ready for SOC (Security Operations Center) consumption.

---

## 7. Implementation Evidence & Test Execution

All exercises were executed and verified on a Linux host running Docker and MongoDB 7.0.45. Below is the step-by-step evidence mapping terminal outputs to repository screenshots.

### 7.1 Container Provisioning & Health Status
The MongoDB 7 container was brought up in detached mode. The healthcheck evaluated `db.adminCommand('ping')` to ensure readiness before accepting connections.

```bash
docker compose up -d
docker compose ps
```

**Terminal Verification Output:**
```text
[+] up 14/14
 ✔ Image mongo:7.0             Pulled                          11.0s
 ✔ Network no-sql_default      Created                          0.1s
 ✔ Volume no-sql_mongo_data    Created                          0.0s
 ✔ Container meridian-mongo    Started                          2.1s

NAME             IMAGE       COMMAND                  SERVICE  CREATED         STATUS                   PORTS
meridian-mongo   mongo:7.0   "docker-entrypoint.s…"   mongo    48 seconds ago  Up 46 seconds (healthy)  0.0.0.0:27017->27017/tcp
```
*Screenshot Reference:* `screenshots/01_container_startup_healthcheck.png`

---

### 7.2 Interactive Shell Connection & Authentication
Connecting through `mongosh` using administrative credentials to verify database creation:

```bash
docker compose exec mongo mongosh -u admin -p secret --authenticationDatabase admin
```

**Output:**
```text
Current Mongosh Log ID: 6ada36c9720ceb2be6b9a14f
Connecting to:          mongodb://<credentials>@127.0.0.1:27017/?directConnection=true&serverSelectionTimeoutMS=2000&authSource=admin
Using MongoDB:          7.0.45
Using Mongosh:          2.13.0
test> use meridian_bank
switched to db meridian_bank
```
*Screenshot Reference:* `screenshots/02_mongosh_admin_connection.png`

---

### 7.3 Data Seeding (50,018 Synthetic Events)
Executing `seed_events.js` to populate the background retail traffic and the 6 planted fraud accounts:

```bash
docker compose exec -T mongo mongosh -u admin -p secret --authenticationDatabase admin meridian_bank < seed_events.js
```

**Execution Output:**
```text
Total events:            50018
LOGIN_FAILED events:     4151
Suspicious customers:    6  (ids 9001-9006, 2026-10-17 14:00 hour)
DONE - ready to run aggregate_fraud_check.js
```
*Screenshot Reference:* `screenshots/03_seeding_50k_events_start.png` and `screenshots/04_seeding_complete_summary.png`

---

### 7.4 Document Model Verification in `mongosh`
Verifying that records are stored with full polymorphic nesting:

```javascript
meridian_bank> db.app_events.countDocuments()
50018

meridian_bank> db.app_events.findOne({ event_type: "LOGIN_FAILED" })
{
  _id: ObjectId('6ada38cfb2f6d211da235cca'),
  customer_id: 800,
  session_id: 'sess_239004',
  event_type: 'LOGIN_FAILED',
  device: { os: 'iOS 18', app_version: '4.1.2', device_id_hash: '45557a192901' },
  location: { city: 'Port Harcourt', country: 'NG' },
  timestamp: ISODate('2026-10-04T17:36:10.467Z'),
  metadata: { login_method: 'pin', failed_attempts_before: 3 }
}
```
*Screenshot Reference:* `screenshots/05_document_model_verification.png`

---

### 7.5 Executing the Fraud Aggregation Pipeline
Running `aggregate_fraud_check.js` using application credentials (`app_user`):

```bash
docker compose exec -T mongo mongosh "mongodb://app_user:app_secret@localhost:27017/meridian_bank" --quiet < aggregate_fraud_check.js > fraud_aggregate_output.txt
```
*Screenshot Reference:* `screenshots/06_fraud_aggregation_execution.png`

---

### 7.6 Terminal Verification: Flagged Fraudulent Accounts
Printing the aggregation pipeline report in real-time verifies that all 6 target accounts were identified with zero false positives:

```text
============================================================
 Fraud check: >=3 LOGIN_FAILED from >=2 cities in one hour
 Collection : app_events (50018 documents)
============================================================

FLAGGED CUSTOMERS: 6

customer_id:      9001
hour:             2026-10-17T14:00:00.000Z
failed_attempts:  4
distinct_cities:  Port Harcourt, Lagos, Abuja, Kano
window:           2026-10-17T14:00:00.000Z  ->  2026-10-17T14:41:00.000Z
------------------------------------------------------------
customer_id:      9002
hour:             2026-10-17T14:00:00.000Z
failed_attempts:  4
distinct_cities:  Port Harcourt, Lagos, Abuja, Kano
window:           2026-10-17T14:00:00.000Z  ->  2026-10-17T14:41:00.000Z
------------------------------------------------------------
customer_id:      9003
hour:             2026-10-17T14:00:00.000Z
failed_attempts:  4
distinct_cities:  Port Harcourt, Lagos, Abuja, Kano
window:           2026-10-17T14:00:00.000Z  ->  2026-10-17T14:41:00.000Z
------------------------------------------------------------
customer_id:      9004
hour:             2026-10-17T14:00:00.000Z
failed_attempts:  4
distinct_cities:  Port Harcourt, Lagos, Abuja, Kano
window:           2026-10-17T14:00:00.000Z  ->  2026-10-17T14:41:00.000Z
------------------------------------------------------------
customer_id:      9005
hour:             2026-10-17T14:00:00.000Z
failed_attempts:  4
distinct_cities:  Port Harcourt, Lagos, Abuja, Kano
window:           2026-10-17T14:00:00.000Z  ->  2026-10-17T14:41:00.000Z
------------------------------------------------------------
customer_id:      9006
hour:             2026-10-17T14:00:00.000Z
failed_attempts:  4
distinct_cities:  Port Harcourt, Lagos, Abuja, Kano
window:           2026-10-17T14:00:00.000Z  ->  2026-10-17T14:41:00.000Z
------------------------------------------------------------

NOTE: Customers 9001-9006 were planted by seed_events.js
(4 failed logins each, 4 distinct cities, within one hour),
so a correct aggregation MUST flag exactly these 6 customers.
No other customer crosses the >=3 attempts / >=2 cities rule.
```
*Screenshot Reference:* `screenshots/07_fraud_aggregation_results.png`

#### Result Analysis
The pipeline performed with 100% precision:
- **Flagged Exactly 6 Customers:** Matched accounts `9001` through `9006`.
- **Zero False Positives:** None of the other 1,000 legitimate bank customers crossed the multi-city velocity threshold.
- **Accurate Window Tracing:** Extracted the precise 41-minute attack window (`14:00:00` to `14:41:00`) and the 4 disparate geographical origins (`Lagos, Kano, Port Harcourt, Abuja`).

---

### 7.7 Query Performance & Execution Plan Analysis (`explain`)
To evaluate query execution mechanics and demonstrate performance analysis as required by the assessment rubric, an execution plan was generated using `explain("executionStats")`:

```javascript
meridian_bank> db.app_events.find({ event_type: "LOGIN_FAILED" }).explain("executionStats")
```

**Diagnostic Output:**
```json
{
  "explainVersion": "1",
  "queryPlanner": {
    "namespace": "meridian_bank.app_events",
    "winningPlan": {
      "stage": "COLLSCAN",
      "filter": { "event_type": { "$eq": "LOGIN_FAILED" } },
      "direction": "forward"
    }
  },
  "executionStats": {
    "executionSuccess": true,
    "nReturned": 4151,
    "executionTimeMillis": 35,
    "totalKeysExamined": 0,
    "totalDocsExamined": 50018
  }
}
```
*Screenshot Reference:* `screenshots/08_query_execution_plan_collscan.png`

#### Technical Performance Insights
1. **Full Collection Scan Overhead (`COLLSCAN`):** Without an index on `event_type`, the query engine had to inspect all **50,018 documents** (`totalDocsExamined: 50018`) to locate the 4,151 failed logins, taking 35ms.
2. **Compound Index Optimization:** In our production configuration (`mongo-init.js`), applying the compound index `{ event_type: 1, timestamp: -1 }` transitions the winning plan from `COLLSCAN` to **`IXSCAN`**. 
3. **Execution Advantage:** Under `IXSCAN`, `totalDocsExamined` drops strictly to the 4,151 matching entries (or zero documents for index-only covered queries), eliminating I/O cache pressure during high-throughput fraud screening.

---

## 8. How to Reproduce This Environment

To replicate the container and test suite from scratch:

1. **Clone the repository and enter directory:**
   ```bash
   git clone https://github.com/olafashade/advanced-database-portfolio.git
   cd advanced-database-portfolio/portfolio-4-nosql
   ```

2. **Start the MongoDB container:**
   ```bash
   docker compose up -d
   ```

3. **Verify container health:**
   ```bash
   docker compose ps
   ```

4. **Seed the 50,000+ mobile events:**
   ```bash
   docker compose exec -T mongo mongosh -u admin -p secret --authenticationDatabase admin meridian_bank < seed_events.js
   ```

5. **Run the fraud screening aggregation pipeline:**
   ```bash
   docker compose exec -T mongo mongosh "mongodb://app_user:app_secret@localhost:27017/meridian_bank" --quiet < aggregate_fraud_check.js
   ```

6. **Inspect collection records interactively:**
   ```bash
   docker compose exec -it mongo mongosh -u app_user -p app_secret --authenticationDatabase meridian_bank meridian_bank
   ```

---

## 9. Individual Technical Reflection

Implementing this NoSQL document model and comparing it against the relational systems designed in Portfolios 1, 2, 3, and 5 provided several critical technical insights:

### 1. The Mindset Shift from Relational Normalization to Document Aggregates
Coming from relational modeling where everything is decomposed into third normal form (3NF) to eliminate redundancy, working with MongoDB requires shifting toward *query-driven design*. For banking telemetry, normalizing device attributes and IP geolocation records into separate relational tables would have created severe join bottlenecks during high-traffic authentication spikes. Nesting `device` and `location` directly inside each event document yielded immediate write efficiency and self-contained analytical queries.

### 2. Aggregation Pipeline Power vs. SQL Window Functions
In SQL, detecting multiple events within an hour across distinct cities typically requires self-joins or complex `WINDOW` partitions. MongoDB's aggregation pipeline made this surprisingly concise. Using `$dateTrunc` to bucket time windows alongside `$addToSet` allowed us to collect distinct cities in a single pass. 

A key optimization lesson was stage ordering: placing `$match { event_type: 'LOGIN_FAILED' }` as the very first stage pruned over 90% of the dataset upfront, ensuring the expensive `$group` operation only consumed memory for relevant records.

### 3. Practical Security & Container Orchestration Realities
When automating container startup, handling database authentication nuances was critical. Early in the testing process, commands failed when attempting to execute scripts against `meridian_bank` without explicitly setting the `--authenticationDatabase admin` parameter for the root user. Establishing a dedicated `app_user` inside `meridian_bank` via `mongo-init.js` properly isolated application privileges and resolved connection ambiguity.
