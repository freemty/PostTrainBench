#!/bin/bash
# preflight_fleet.sh - Run preflight on all fleet nodes in parallel
# Usage: bash scripts/preflight_fleet.sh [--skip-api] [node_ip ...]
# Run from online00 (bastion).

set -euo pipefail

ALL_NODES=(172.31.10.163 172.31.10.168 172.31.10.161 172.31.10.166 172.31.10.165 172.31.10.167 172.31.10.175 172.31.10.173)
SKIP_API_FLAG=""
NODES=()

for arg in "$@"; do
    case "$arg" in
        --skip-api) SKIP_API_FLAG="--skip-api" ;;
        *) NODES+=("$arg") ;;
    esac
done

if [ ${#NODES[@]} -eq 0 ]; then
    NODES=("${ALL_NODES[@]}")
fi

RESULTS_DIR="/tmp/preflight_fleet_$$"
mkdir -p "$RESULTS_DIR"
trap "rm -rf '$RESULTS_DIR'" EXIT

echo "=== Fleet Preflight: ${#NODES[@]} nodes ==="
echo ""

# Launch preflight on all nodes in parallel
PIDS=()
for ip in "${NODES[@]}"; do
    (
        echo "[$ip] Starting preflight..."
        ssh -o ConnectTimeout=10 "$ip" \
            "cd ~/PostTrainBench && bash tests/preflight.sh $SKIP_API_FLAG" \
            > "$RESULTS_DIR/$ip.log" 2>&1
        echo $? > "$RESULTS_DIR/$ip.exit"
    ) &
    PIDS+=($!)
done

# Wait for all
for pid in "${PIDS[@]}"; do
    wait $pid 2>/dev/null || true
done

# Aggregate results
echo ""
echo "=== Fleet Preflight Results ==="
echo ""

FLEET_PASS=0
FLEET_FAIL=0
for ip in "${NODES[@]}"; do
    EXIT_CODE=$(cat "$RESULTS_DIR/$ip.exit" 2>/dev/null || echo "999")
    FAILS=$(grep -c '^\s*\[FAIL\]' "$RESULTS_DIR/$ip.log" 2>/dev/null || echo "?")
    WARNS=$(grep -c '^\s*\[WARN\]' "$RESULTS_DIR/$ip.log" 2>/dev/null || echo "?")

    if [ "$EXIT_CODE" = "0" ]; then
        echo "  [PASS] $ip (${FAILS} fails, ${WARNS} warns)"
        FLEET_PASS=$((FLEET_PASS + 1))
    else
        echo "  [FAIL] $ip (exit=$EXIT_CODE, ${FAILS} fails, ${WARNS} warns)"
        grep '^\s*\[FAIL\]' "$RESULTS_DIR/$ip.log" 2>/dev/null | sed 's/^/         /'
        FLEET_FAIL=$((FLEET_FAIL + 1))
    fi
done

echo ""
echo "=== Summary: ${FLEET_PASS} passed, ${FLEET_FAIL} failed ==="

# Cross-node consistency check
echo ""
echo "--- Cross-Node Consistency ---"

echo "  HF Cache sizes:"
for ip in "${NODES[@]}"; do
    HF_SIZE=$(grep -o 'HF cache exists:.*' "$RESULTS_DIR/$ip.log" 2>/dev/null | head -1)
    echo "    $ip: ${HF_SIZE:-unknown}"
done

echo "  Container sizes:"
for ip in "${NODES[@]}"; do
    CTR_SIZE=$(grep -o 'Container exists:.*' "$RESULTS_DIR/$ip.log" 2>/dev/null | head -1)
    echo "    $ip: ${CTR_SIZE:-unknown}"
done

echo "  Disk space (results dir):"
for ip in "${NODES[@]}"; do
    DISK=$(grep -o 'Results dir:.*' "$RESULTS_DIR/$ip.log" 2>/dev/null | head -1)
    echo "    $ip: ${DISK:-unknown}"
done

exit $FLEET_FAIL
