#!/bin/bash
# DEPRECATED: Use tests/preflight_v2.sh instead.
# This script runs independent test scripts that don't share code paths with run_task.sh.
# preflight_v2.sh uses run_task.sh --dry-run for complete coverage.
#
# PostTrainBench Preflight Test Suite (legacy)
#
# Run ALL pre-experiment checks in sequence. Exit code = total failures.
# Usage: cd ~/PostTrainBench && bash tests/preflight.sh [--skip-api]
#
# Options:
#   --skip-api    Skip agent API tests (expensive, uses real API calls)

set -eo pipefail

SKIP_API=false
for arg in "$@"; do
    case "$arg" in
        --skip-api) SKIP_API=true ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOTAL_PASS=0; TOTAL_FAIL=0; TOTAL_WARN=0

run_test() {
    local test_script="$1"
    local test_name="$2"
    echo ""
    echo "================================================================"
    echo "  $test_name"
    echo "================================================================"

    if bash "$test_script"; then
        echo "  >> $test_name: ALL PASSED"
    else
        local exit_code=$?
        echo "  >> $test_name: $exit_code FAILURE(S)"
        TOTAL_FAIL=$((TOTAL_FAIL + exit_code))
    fi
}

echo "============================================"
echo "  PostTrainBench Preflight Test Suite"
echo "  $(date)"
echo "============================================"

run_test "${SCRIPT_DIR}/test_host_env.sh" "1. Host Environment"
run_test "${SCRIPT_DIR}/test_container_env.sh" "2. Container Environment"
run_test "${SCRIPT_DIR}/test_eval_pipeline.sh" "3. Evaluation Pipeline"
run_test "${SCRIPT_DIR}/test_network.sh" "4. Network & Cache Completeness"

# Run agent env check for all agents that have a manifest
echo ""
echo "================================================================"
echo "  3b. Agent Environment Verification"
echo "================================================================"
AGENT_ENV_CHECKED=0
for agent_dir in agents/*/; do
    agent_name=$(basename "$agent_dir")
    if [ -f "${agent_dir}/manifest.json" ]; then
        echo "  Checking agent: ${agent_name}"
        bash tests/test_agent_env.sh "$agent_name" --local 2>&1 | grep -E '^\s+\[(PASS|FAIL|WARN|SKIP)\]'
        AGENT_ENV_CHECKED=$((AGENT_ENV_CHECKED + 1))
    fi
done
if [ $AGENT_ENV_CHECKED -eq 0 ]; then
    echo "  (no agents with manifest.json found)"
fi

if [ "$SKIP_API" = false ]; then
    run_test "${SCRIPT_DIR}/test_bedrock_connectivity.sh" "4. Agent API (Bedrock)"
else
    echo ""
    echo "================================================================"
    echo "  4. Agent API (Bedrock) — SKIPPED (--skip-api)"
    echo "================================================================"
fi

if [ "$SKIP_API" = false ]; then
    run_test "${SCRIPT_DIR}/test_horay_connectivity.sh" "5. Agent API (Horay)"
else
    echo ""
    echo "================================================================"
    echo "  5. Agent API (Horay) — SKIPPED (--skip-api)"
    echo "================================================================"
fi

echo ""
echo "============================================"
echo "  Preflight Summary"
echo "  Failures: $TOTAL_FAIL"
if [ $TOTAL_FAIL -eq 0 ]; then
    echo "  Status: READY TO LAUNCH"
else
    echo "  Status: NOT READY — fix failures above"
fi
echo "============================================"
exit $TOTAL_FAIL
