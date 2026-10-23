#!/usr/bin/env bash
# ==============================================================================
# test_failover.sh - Meridian Trust Bank HA Cluster
# Simulates primary node crash, automatic failover, and self-healing rejoin.
# ==============================================================================
set -euo pipefail

DB_NAME="meridian"
DB_USER="postgres"
export PGPASSWORD="secret"

# Identify surviving observer node for running patronictl commands
OBSERVER="node1"

echo "================================================================="
echo "1. Initial Cluster State Before Failure"
echo "================================================================="
docker exec -it "${OBSERVER}" patronictl -c /home/postgres/postgres.yml list

LEADER_CONTAINER=$(docker exec "${OBSERVER}" patronictl -c /home/postgres/postgres.yml list -f json | \
  grep -B 2 -A 5 '"role": "leader"' | grep '"member":' | head -n1 | cut -d'"' -f4)

if [ -z "${LEADER_CONTAINER}" ]; then
  echo "Error: No current leader found."
  exit 1
fi

echo ""
echo "Active Leader to be crashed: ${LEADER_CONTAINER}"
echo ""

# Pick surviving observer container if node1 is the one being crashed
if [ "${LEADER_CONTAINER}" == "node1" ]; then
  OBSERVER="node2"
fi

echo "================================================================="
echo "2. Simulating Abrupt Hardware / Kernel Failure (Stopping ${LEADER_CONTAINER})"
echo "================================================================="
docker stop "${LEADER_CONTAINER}"
echo "${LEADER_CONTAINER} stopped."

echo ""
echo "Waiting 12 seconds for etcd TTL expiration and Patroni leader election..."
sleep 12

echo "================================================================="
echo "3. Topology After Failover (Checking New Leader Promotion)"
echo "================================================================="
docker exec -it "${OBSERVER}" patronictl -c /home/postgres/postgres.yml list

NEW_LEADER=$(docker exec "${OBSERVER}" patronictl -c /home/postgres/postgres.yml list -f json | \
  grep -B 2 -A 5 '"role": "leader"' | grep '"member":' | head -n1 | cut -d'"' -f4)

case "$NEW_LEADER" in
  node1) NEW_PORT=54321 ;;
  node2) NEW_PORT=54322 ;;
  node3) NEW_PORT=54323 ;;
  *)
    echo "Error: Failed to detect new leader."
    exit 1
    ;;
esac

echo ""
echo "Promotion Succeeded! New Leader is: ${NEW_LEADER} on host port ${NEW_PORT}"
echo ""

echo "================================================================="
echo "4. Testing Write Operation on Newly Promoted Primary"
echo "================================================================="
FAILOVER_TXN="FAILOVER-TEST-$(date +%s)"
psql -h localhost -p "${NEW_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -c "
INSERT INTO audit_transactions (account_id, change_type, amount, balance_after, reference_code)
VALUES (2, 'Transfer_In', 50000.00, 50050000.00, '${FAILOVER_TXN}');
"
echo "Successfully wrote transaction ${FAILOVER_TXN} to promoted primary."
echo ""

echo "================================================================="
echo "5. Restoring Crashed Node (${LEADER_CONTAINER}) and Testing Rejoin"
echo "================================================================="
docker start "${LEADER_CONTAINER}"
echo "Restarted ${LEADER_CONTAINER}. Waiting 10 seconds for Patroni to stream & heal..."
sleep 10

echo "================================================================="
echo "6. Final Cluster State (Demoted Node Rejoined as Follower)"
echo "================================================================="
docker exec -it "${OBSERVER}" patronictl -c /home/postgres/postgres.yml list

echo ""
echo "Failover drill completed successfully. Capture this terminal output for your portfolio documentation."