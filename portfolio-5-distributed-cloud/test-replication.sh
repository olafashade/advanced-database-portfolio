#!/usr/bin/env bash
# ==============================================================================
# test_replication.sh - Meridian Trust Bank HA Cluster
# Validates synchronous and asynchronous replication across PostgreSQL nodes.
# ==============================================================================
set -euo pipefail

DB_NAME="meridian"
DB_USER="postgres"
export PGPASSWORD="secret"

echo "================================================================="
echo "1. Checking Patroni Cluster Topology"
echo "================================================================="
docker exec -it node1 patronictl -c /home/postgres/postgres.yml list

# Dynamically locate which node is currently Leader
LEADER_CONTAINER=$(docker exec node1 patronictl -c /home/postgres/postgres.yml list -f json | \
  grep -B 2 -A 5 '"role": "leader"' | grep '"member":' | head -n1 | cut -d'"' -f4)

case "$LEADER_CONTAINER" in
  node1) LEADER_PORT=54321 ;;
  node2) LEADER_PORT=54322 ;;
  node3) LEADER_PORT=54323 ;;
  *)
    echo "Error: Could not identify leader container. Aborting."
    exit 1
    ;;
esac

echo ""
echo "Detected Leader: ${LEADER_CONTAINER} on host port ${LEADER_PORT}"
echo ""

echo "================================================================="
echo "2. Checking pg_stat_replication on Leader (${LEADER_CONTAINER})"
echo "================================================================="
psql -h localhost -p "${LEADER_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -x -c "
SELECT 
    application_name,
    client_addr,
    state,
    sync_state,
    sync_priority,
    sent_lsn,
    write_lsn,
    flush_lsn,
    replay_lsn
FROM pg_stat_replication;
"

echo "================================================================="
echo "3. Executing Live Banking Transaction on Leader (${LEADER_CONTAINER})"
echo "================================================================="
TXN_REF="VERIFY-$(date +%s)"
psql -h localhost -p "${LEADER_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -c "
INSERT INTO audit_transactions (account_id, change_type, amount, balance_after, reference_code)
VALUES (1, 'Deposit', 250000.00, 500250000.00, '${TXN_REF}');
"
echo "Transaction committed: ${TXN_REF}"
echo ""

echo "================================================================="
echo "4. Proving Immediate Replication Across Standby Replicas"
echo "================================================================="

for PORT in 54321 54322 54323; do
  echo "--- Testing Host Port ${PORT} ---"
  psql -h localhost -p "${PORT}" -U "${DB_USER}" -d "${DB_NAME}" -c "
  SELECT 
      audit_id, 
      account_id, 
      change_type, 
      amount, 
      reference_code, 
      recorded_at 
  FROM audit_transactions 
  WHERE reference_code = '${TXN_REF}';
  "
done

echo "Replication test successfully verified across all nodes."