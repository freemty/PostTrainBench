#!/bin/bash
# preflight_fleet.sh — run preflight_v2 across all fleet nodes in parallel
#
# Usage:
#   bash scripts/preflight_fleet.sh --exp exp02b \
#     --slots "claude:0:claude-opus-4-6,lemma:1:claude-opus-4-6,codex_horay:2:g5.2-rxj" \
#     --model google/gemma-3-4b-pt --tasks-file fleet_tasks.txt
#
# fleet_tasks.txt format (IP + task per line):
#   172.31.10.168 gsm8k
#   172.31.10.161 aime2025
#   ...
#
# If --tasks-file is omitted, runs the same task on all default nodes.

set -euo pipefail

ALL_NODES=(172.31.10.163 172.31.10.168 172.31.10.161 172.31.10.166 172.31.10.165 172.31.10.167 172.31.10.175 172.31.10.173)

EXP="" SLOTS="" MODEL="" TASKS_FILE="" TASK=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --exp) EXP="$2"; shift 2 ;;
        --slots) SLOTS="$2"; shift 2 ;;
        --model) MODEL="$2"; shift 2 ;;
        --task) TASK="$2"; shift 2 ;;
        --tasks-file) TASKS_FILE="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

if [ -z "$EXP" ] || [ -z "$SLOTS" ] || [ -z "$MODEL" ]; then
    echo "Usage: bash scripts/preflight_fleet.sh --exp <id> --slots <config> --model <model> [--task <task> | --tasks-file <file>]"
    exit 1
fi

LOG_DIR="/tmp/preflight_fleet_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOG_DIR"

echo "============================================"
echo "  Fleet Preflight v2"
echo "  Exp: $EXP | Model: $MODEL"
echo "  Logs: $LOG_DIR"
echo "============================================"
echo ""

# Build node+task pairs
NODES=()
TASKS=()
if [ -n "$TASKS_FILE" ] && [ -f "$TASKS_FILE" ]; then
    while read -r ip task; do
        [ -z "$ip" ] && continue
        NODES+=("$ip")
        TASKS+=("$task")
    done < "$TASKS_FILE"
elif [ -n "$TASK" ]; then
    for ip in "${ALL_NODES[@]}"; do
        NODES+=("$ip")
        TASKS+=("$TASK")
    done
else
    echo "ERROR: specify --task or --tasks-file"
    exit 1
fi

# Launch preflight on each node in parallel
PIDS=()
for i in "${!NODES[@]}"; do
    ip="${NODES[$i]}"
    task="${TASKS[$i]}"
    echo "Launching: $ip ($task)"
    ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$ip" \
        "cd ~/PostTrainBench && source ~/.fleet_env && \
         bash tests/preflight_v2.sh --exp '$EXP' --slots '$SLOTS' --model '$MODEL' --task '$task'" \
        > "$LOG_DIR/${ip}_${task}.log" 2>&1 &
    PIDS+=($!)
done

echo ""
echo "Waiting for ${#PIDS[@]} nodes..."

# Wait and collect exit codes
RESULTS=()
for i in "${!PIDS[@]}"; do
    set +e
    wait "${PIDS[$i]}" 2>/dev/null
    RESULTS+=($?)
    set -e
done

# Summary
echo ""
echo "============================================"
echo "  Fleet Preflight Summary"
echo "============================================"
FLEET_FAIL=0
for i in "${!NODES[@]}"; do
    ip="${NODES[$i]}"
    task="${TASKS[$i]}"
    rc="${RESULTS[$i]}"
    if [ "$rc" -eq 0 ]; then
        echo "  [PASS] $ip ($task)"
    else
        echo "  [FAIL] $ip ($task) — exit $rc"
        grep -E "FAIL|FAST-FAIL" "$LOG_DIR/${ip}_${task}.log" 2>/dev/null | head -3 | sed 's/^/    /'
        FLEET_FAIL=1
    fi
done

echo ""
if [ $FLEET_FAIL -eq 0 ]; then
    echo "  ALL NODES PASSED — safe to launch fleet"
else
    echo "  SOME NODES FAILED — DO NOT LAUNCH"
    echo "  Full logs: $LOG_DIR/"
fi
echo "============================================"

exit $FLEET_FAIL
