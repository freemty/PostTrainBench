#!/bin/bash
# Shared test utilities for preflight tests.
# Source this file: source "$(dirname "$0")/preflight_utils.sh"

PASS=0; FAIL=0; WARN=0

pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
warn() { echo "  [WARN] $1"; WARN=$((WARN + 1)); }
skip() { echo "  [SKIP] $1"; }

summary() {
    echo ""
    echo "  Results: $PASS passed, $FAIL failed, $WARN warnings"
    exit $FAIL
}

# Load PostTrainBench env vars
export POST_TRAIN_BENCH_JOB_SCHEDULER="${POST_TRAIN_BENCH_JOB_SCHEDULER:-none}"
source src/commit_utils/set_env_vars.sh

CONTAINER="${POST_TRAIN_BENCH_CONTAINERS_DIR}/${POST_TRAIN_BENCH_CONTAINER_NAME}.sif"

# Tmp dir on large disk (same logic as run_task.sh)
PTB_TMP_BASE="${POST_TRAIN_BENCH_TMP_DIR:-$(dirname "${POST_TRAIN_BENCH_RESULTS_DIR}")/tmp}"
