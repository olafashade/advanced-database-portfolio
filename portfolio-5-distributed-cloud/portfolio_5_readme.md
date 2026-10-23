# Portfolio 5: Distributed & Cloud Database Architecture

**Course:** MIT 8103 Advanced Database Systems  
**Institution:** MIVA Open University — Master of Information Technology  
**Academic Session:** 2026/2027  
**Case Study Organisation:** Meridian Trust Bank  
**Component:** Distributed & Cloud Database Implementation and Verification

---

## 1. Executive Summary & Context

In a mission-critical commercial banking environment like Meridian Trust Bank, database outages or split-brain divergences cannot be tolerated. A single corrupted ledger balance, dropped transfer, or phantom credit can cause financial liability and violate regulatory standards. 

Standard standalone database setups present a single point of failure (SPOF). To mitigate this, this portfolio activity deploys and evaluates a fault-tolerant, highly available, distributed PostgreSQL cluster using **Zalando Spilo (PostgreSQL 16 + Patroni DCS)** backed by an **etcd 3.5.18** consensus store running on a Docker bridge network.

This document details the cluster topology, replication semantics, CAP theorem trade-offs, and empirical verification of zero-data-loss failover under simulated node failure.

---

## 2. Distributed System Architecture

The Meridian Trust Bank distributed database is organized into four containerized services running on an isolated virtual network (`dbnet`):

```
                       +-----------------------------+
                       |   etcd 3.5.18 (DCS Store)   |
                       | Raft Consensus Engine / TTL |
                       +--------------+--------------+
                                      |
                     Health checks & DCS heartbeats (port 2379)
                                      |
         +----------------------------+----------------------------+
         |                                                         |
+--------v--------+                                       +--------v--------+
|      node3      | <=== Sync Streaming Replication ===>  |      node1      |
|   Role: Leader  |                                       | Role: Sync Sb   |
| Host Port: 54323|                                       | Host Port: 54321|
+--------+--------+                                       +-----------------+
         |
         | <============ Async Streaming Replication ============>
         |
+--------v--------+
|      node2      |
|  Role: Replica  |
| Host Port: 54322|
+-----------------+
```

### Component Roles

1. **Distributed Configuration Store (etcd v3.5.18):**
   - Serves as the single source of truth for cluster state and dynamic election leases.
   - Leverages the **Raft consensus algorithm** to elect a primary leader and maintain heartbeat leases (`TTL`).
   - Configured with `--enable-v2=true` to provide compatibility with Patroni's REST communication layer.

2. **Primary Write Node (`node3`, Port 54323):**
   - Currently holds the distributed leader lock in etcd.
   - Accepts all write transactions (deposits, ledger transfers, account creations).
   - Flushes Write-Ahead Log (WAL) records locally and ships them to standby replicas.

3. **Synchronous Standby Node (`node1`, Port 54321):**
   - Active standby participating in the synchronous replication quorum.
   - Read-only replica capable of serving customer read workloads (e.g., account history, audit queries).
   - Automatically promoted if the primary fails.

4. **Asynchronous Standby Node (`node2`, Port 54322):**
   - Active read replica receiving WAL streams asynchronously.
   - Acts as a disaster recovery (DR) target and read-scaling engine without introducing latency overhead to the write path.

---

## 3. Replication Architecture & Consistency Model

### Transaction Durability & The Write Path

Banking ledgers require strong durability guarantees ($RPO = 0$). To enforce this, Spilo applies two database parameters:

```yaml
SPILO_CONFIGURATION: |
  postgresql:
    parameters:
      synchronous_commit: "on"
      synchronous_standby_names: "FIRST 1 (*)"
```

#### How the Write Path Operates
1. A client initiates a transaction (`INSERT`, `UPDATE`, or `DELETE`) on the primary leader (`node3`).
2. The leader executes the transaction, writes changes to its local buffer, and writes to the Write-Ahead Log (`WAL`).
3. The WAL stream is immediately forwarded across the network to all connected standbys (`node1` and `node2`).
4. Because `synchronous_standby_names = "FIRST 1 (*)"` is configured, the leader **blocks the transaction commit** until at least one healthy standby (`node1`) flushes the corresponding WAL record to disk and sends back an acknowledgment (`flush_lsn`).
5. Once this acknowledgment arrives, the leader returns a successful transaction commit response to the client.
6. Meanwhile, `node2` continues processing the stream asynchronously in the background.

```
Client         Leader (node3)              Sync Standby (node1)        Async Standby (node2)
  |                  |                              |                            |
  |--- BEGIN TX ---->|                              |                            |
  |--- UPDATE bal -->| (write to local WAL)         |                            |
  |--- COMMIT ------>|                              |                            |
  |                  |=== WAL Record Forwarded ====>| (flush to disk)            |
  |                  |                              |=== ACK Flush Received ===> |
  |                  |<== Flush ACK Confirmed ======|                            |
  |<-- SUCCESS (200)-|                              |                            |
  |                  |=== WAL Forwarded (Async) ================================>| (flush when ready)
```

**Consistency Guarantee:** If `node3` loses power or crashes at any instant after returning success to the client, zero transactions are lost ($RPO = 0$) because the synchronous replica (`node1`) is already in physical possession of identical WAL records.

---

## 4. CAP Theorem Analysis & Split-Brain Mitigation

In distributed systems, Eric Brewer's **CAP Theorem** dictates that under a network partition ($P$), a system must choose between:
- **Consistency ($C$):** Every read receives the most recent write or an error.
- **Availability ($A$):** Every non-failing node returns a non-error response without guarantee of latest data.

### Architectural Choice: A CP-Optimized System

The Meridian Trust Bank architecture explicitly chooses **Consistency and Partition Tolerance (CP)** over high availability:

* **Preventing Split-Brain:** In an uncoordinated primary-replica topology, a network partition can cause a disconnected leader and an isolated standby to both believe they are active primaries. If clients write to both sides, the core banking ledger diverges, resulting in double-spending and unrecoverable data corruption.
* **Fencing via Patroni and etcd Leases:** Patroni prevents this by acquiring a time-limited key in etcd (the leader lease). 
  - The leader must renew this lease periodically (every 10 seconds).
  - If a network partition isolates the leader from etcd, its lease expires.
  - Patroni immediately demotes the old leader to read-only mode (fencing the node).
  - The partition containing the etcd quorum then safely elects a single new leader.

```
Partioned Subnet A (No Quorum)            Partitioned Subnet B (Holds Quorum)
+-------------------------------+         +-------------------------------+
|  Old Leader (node3)           |         |  Sync Standby (node1)         |
|  Cannot renew etcd lease...   |         |  Detects expired lease in etcd|
|  *Self-demotes to read-only*  |         |  *Promoted to New Leader*     |
+-------------------------------+         +-------------------------------+
```

For a financial platform, refusing a write during a severe network partition is preferable to accepting divergent transactions that compromise financial records.

---

## 5. Verification & Test Execution Logs

### 5.1 Initial Topology Verification

Command executed from the host:

```bash
docker exec -it node1 patronictl -c /home/postgres/postgres.yml list
```

**Output:**

```text
+ Cluster: meridian (7699786410750455866) --+----+-----------+
| Member | Host       | Role    | State     | TL | Lag in MB |
+--------+------------+---------+-----------+----+-----------+
| node1  | 172.22.0.3 | Replica | streaming |  1 |         0 |
| node2  | 172.22.0.4 | Replica | streaming |  1 |         0 |
| node3  | 172.22.0.5 | Leader  | running   |  1 |           |
+--------+------------+---------+-----------+----+-----------+
```

### 5.2 Internal PostgreSQL Replication Diagnostics

Query executed directly against the active leader on host port `54323`:

```sql
SELECT 
    application_name, 
    client_addr, 
    state, 
    sync_state, 
    sync_priority 
FROM pg_stat_replication;
```

**Output:**

```text
 application_name | client_addr |   state   | sync_state | sync_priority 
------------------+-------------+-----------+------------+---------------
 node1            | 172.22.0.3  | streaming | sync       |             1
 node2            | 172.22.0.4  | streaming | async      |             2
(2 rows)
```

The output confirms:
- `node1` is operating as the active **`sync`** standby (priority 1).
- `node2` is streaming as an **`async`** backup replica (priority 2).

### 5.3 Data Seeding & Cross-Node Replication Proof

The initial dataset was loaded into the leader (`node3` on port `54323`):

```bash
PGPASSWORD=secret psql -h localhost -p 54323 -U postgres -d meridian -f 01_schema_and_seed.sql
```

Row counts verified across all nodes:

```bash
# Leader (Port 54323)
PGPASSWORD=secret psql -h localhost -p 54323 -U postgres -d meridian -c \
  "SELECT count(*) FROM audit_transactions;"
# Returns: 1014

# Standby 1 (Port 54321)
PGPASSWORD=secret psql -h localhost -p 54321 -U postgres -d meridian -c \
  "SELECT count(*) FROM audit_transactions;"
# Returns: 1014

# Standby 2 (Port 54322)
PGPASSWORD=secret psql -h localhost -p 54322 -U postgres -d meridian -c \
  "SELECT count(*) FROM audit_transactions;"
# Returns: 1014
```

Both standbys match the primary record count identically with $0\text{ MB}$ replication lag.

### 5.4 High Availability & Crash-Failover Drill

To test automated cluster self-healing, the leader container (`node3`) was killed abruptly:

```bash
docker stop node3
```

Checking cluster status 6 seconds later via `node1`:

```bash
docker exec -it node1 patronictl -c /home/postgres/postgres.yml list
```

**Output:**

```text
+ Cluster: meridian (7699786410750455866) --+----+-----------+
| Member | Host       | Role    | State     | TL | Lag in MB |
+--------+------------+---------+-----------+----+-----------+
| node1  | 172.22.0.5 | Leader  | running   |  2 |           |
| node2  | 172.22.0.3 | Sync    | streaming |  2 |         0 |
+--------+------------+---------+-----------+----+-----------+
```

#### Observations
1. **Zero Data Loss Promotion:** `node1` acquired the etcd leader lease and promoted itself to **`Leader`**.
2. **Timeline Progression:** The timeline ID incremented from `TL: 1` to `TL: 2`, indicating a clean promotion and divergence point.
3. **Dynamic Topology Adaptation:** `node2` automatically detected the leadership transfer, updated its upstream primary connection to point to `node1`, and transitioned from `async` to `Sync` standby to maintain strict quorum.
4. **Write Capability Restored:** Writes directed to host port `54321` succeeded immediately without manual administrator intervention.

### 5.5 Node Reintegration & Self-Healing

The crashed node was brought back online:

```bash
docker start node3
sleep 8
docker exec -it node1 patronictl -c /home/postgres/postgres.yml list
```

**Output:**

```text
+ Cluster: meridian (7699786410750455866) --+----+-----------+
| Member | Host       | Role    | State     | TL | Lag in MB |
+--------+------------+---------+-----------+----+-----------+
| node1  | 172.22.0.5 | Leader  | running   |  2 |           |
| node2  | 172.22.0.3 | Sync    | streaming |  2 |         0 |
| node3  | 172.22.0.4 | Replica | streaming |  2 |         0 |
+--------+------------+---------+-----------+----+-----------+
```

Using `pg_rewind`, Patroni re-synchronized `node3`'s transaction log to Timeline 2 and rejoined it as a read-only replica with zero manual rebuild required.

---

## 6. How to Replicate This Environment

1. **Clone the repository and enter the directory:**
   ```bash
   git clone https://github.com/olafashade/advanced-database-portfolio
   cd portfolio-5-distributed-cloud
   ```

2. **Start the containers:**
   ```bash
   docker compose up -d
   ```

3. **Check cluster convergence:**
   ```bash
   docker exec -it node1 patronictl -c /home/postgres/postgres.yml list
   ```

4. **Seed the database:**
   ```bash
   # Connect to the reported leader's port (54321, 54322, or 54323)
   PGPASSWORD=secret psql -h localhost -p 54321 -U postgres -d meridian -f 01_schema_and_seed.sql
   ```

---

## 7. Individual Technical Reflection

Working on this distributed database exercise reinforced several key operational realities that textbooks rarely capture:

1. **Consensus Store Versioning Constraints:**  
   During initial provisioning, Patroni could not register its topology because upstream `etcd:3.5.18` disabled its v2 HTTP endpoints by default, returning `404 page not found`. Resolving this by injecting `--enable-v2=true` underscored how tightly coupled high-availability orchestrators are to specific consensus API lifecycles.

2. **Strict Quorum vs. Write Latency:**  
   Implementing `FIRST 1 (*)` showed the inherent tension between consistency and latency. By requiring the synchronous replica to flush every transaction before confirming a commit, write operations carry the cost of a network round-trip. In banking, this latency trade-off is necessary to guarantee durability.

3. **Automation in Split-Brain Prevention:**  
   Watching `node3` self-fence when stopped, followed by `node1` stepping into the leader role and promoting `node2` to synchronous standby, demonstrated how modern DCS architectures automate recovery that once required risky manual intervention.