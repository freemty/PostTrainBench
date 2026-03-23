#!/bin/bash
# DEPRECATED: Covered by run_task.sh --dry-run agent PONG test (real API call through real agent).
# PostTrainBench Bedrock Connectivity Test
#
# Verifies that Claude Code can reach AWS Bedrock from inside the Apptainer container,
# mimicking the exact environment used by run_task.sh.
#
# Usage: bash tests/test_bedrock_connectivity.sh
#   Run from PostTrainBench repo root on the GPU server.

set -eo pipefail

# Provide defaults before sourcing (set_env_vars.sh uses set_default helper)
export POST_TRAIN_BENCH_JOB_SCHEDULER="${POST_TRAIN_BENCH_JOB_SCHEDULER:-none}"
source src/commit_utils/set_env_vars.sh

PASS=0; FAIL=0; WARN=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
warn() { echo "[WARN] $1"; WARN=$((WARN + 1)); }

echo "========== Bedrock Connectivity Test =========="
echo ""

# --- Step 1: Host-side config checks ---
echo "--- 1. Host Config ---"

CLAUDE_SETTINGS="$HOME/.claude/settings.local.json"
if [ -f "$CLAUDE_SETTINGS" ]; then
    pass "~/.claude/settings.local.json exists"

    if grep -q 'CLAUDE_CODE_USE_BEDROCK\|"bedrock"\|primaryProvider' "$CLAUDE_SETTINGS" 2>/dev/null; then
        pass "Bedrock enabled in settings"
    else
        warn "settings.local.json exists but no bedrock config found"
    fi

    if grep -q 'AWS_ACCESS_KEY_ID\|awsAccessKeyId' "$CLAUDE_SETTINGS" 2>/dev/null; then
        pass "AWS credentials in settings"
    elif [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then
        pass "AWS credentials in env vars (AWS_ACCESS_KEY_ID set)"
    else
        fail "No AWS credentials found (neither in settings nor env)"
    fi
else
    if [ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ]; then
        warn "No settings.local.json, but AWS env vars set — may work"
    else
        fail "No settings.local.json and no AWS env vars"
    fi
fi

# --- Step 2: Container prerequisites ---
echo ""
echo "--- 2. Container ---"

CONTAINER="${POST_TRAIN_BENCH_CONTAINERS_DIR}/${POST_TRAIN_BENCH_CONTAINER_NAME}.sif"
if [ -f "$CONTAINER" ]; then
    pass "Container exists: $CONTAINER"
else
    fail "Container not found: $CONTAINER"
    echo "Cannot proceed without container. Aborting."
    exit 1
fi

if which apptainer >/dev/null 2>&1; then
    pass "Apptainer installed"
else
    fail "Apptainer not found"
    echo "Cannot proceed without apptainer. Aborting."
    exit 1
fi

# --- Step 3: Simulate job dir (like run_task.sh) ---
echo ""
echo "--- 3. Simulated Job Dir ---"

TEST_TMP="/tmp/posttrain_bedrock_test_$$"
JOB_DIR="${TEST_TMP}/job_dir"
JOB_TMP="${TEST_TMP}/tmp"
mkdir -p "${JOB_DIR}" "${JOB_TMP}"

# Copy .claude config (same logic as our run_task.sh patch)
if [ -d "$HOME/.claude" ]; then
    mkdir -p "${JOB_DIR}/.claude"
    cp "$HOME/.claude/settings.local.json" "${JOB_DIR}/.claude/" 2>/dev/null && \
        pass "Copied settings.local.json to job dir" || \
        warn "No settings.local.json to copy"
    cp "$HOME/.claude/settings.json" "${JOB_DIR}/.claude/" 2>/dev/null || true
else
    warn "No ~/.claude directory on host"
fi

# Copy .codex config (same as run_task.sh)
if [ -d "containers/other_home_data/.codex" ]; then
    cp -r "containers/other_home_data/.codex" "${JOB_DIR}/"
fi

pass "Job dir created at ${JOB_DIR}"

# --- Step 4: Claude Code ping inside container ---
echo ""
echo "--- 4. Claude Code Inside Container ---"

# Check claude exists in container
if apptainer exec "$CONTAINER" which claude >/dev/null 2>&1; then
    pass "claude CLI found in container"
else
    fail "claude CLI not found in container"
    echo "Install claude in container or bind-mount from host."
    rm -rf "$TEST_TMP"
    exit 1
fi

# The actual connectivity test: ask claude to say "pong"
echo ""
echo "--- 5. Bedrock API Call (inside container) ---"
echo "Sending test prompt via claude CLI..."

CLAUDE_OUTPUT=$(timeout 60s apptainer exec \
    --nv \
    -c \
    --env PATH="/root/.local/bin:/home/ben/.local/bin:$PATH" \
    --env ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" \
    --env AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}" \
    --env AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}" \
    --env AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}" \
    --env PYTHONNOUSERSITE="1" \
    --bind "${JOB_TMP}:/tmp" \
    --home "${JOB_DIR}:/home/ben" \
    --writable-tmpfs \
    "$CONTAINER" \
    claude --print --model sonnet "Reply with exactly one word: pong" 2>&1) || true

echo "  Response: ${CLAUDE_OUTPUT:0:200}"

if echo "$CLAUDE_OUTPUT" | grep -iq "pong"; then
    pass "Claude Code responded via Bedrock"
elif echo "$CLAUDE_OUTPUT" | grep -iq "error\|unauthorized\|forbidden\|credential\|token"; then
    fail "Auth error: ${CLAUDE_OUTPUT:0:150}"
elif echo "$CLAUDE_OUTPUT" | grep -iq "timeout\|timed out\|connection"; then
    fail "Network error: ${CLAUDE_OUTPUT:0:150}"
else
    warn "Unexpected response (check manually): ${CLAUDE_OUTPUT:0:150}"
fi

# --- Step 6: Test with actual AGENT_CONFIG model names (as used by commit.sh) ---
echo ""
echo "--- 6. Model Name Mapping (commit.sh → Bedrock) ---"

# Copy solve.sh into job dir (same as run_task.sh does)
cp "agents/claude/solve.sh" "${JOB_DIR}/agent_solve.sh"

for TEST_MODEL in "claude-sonnet-4-5" "claude-opus-4-6"; do
    echo "Testing model: $TEST_MODEL ..."
    MODEL_OUTPUT=$(timeout 90s apptainer exec \
        --nv \
        -c \
        --env PATH="/root/.local/bin:/home/ben/.local/bin:$PATH" \
        --env ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" \
        --env AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}" \
        --env AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}" \
        --env AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}" \
        --env PYTHONNOUSERSITE="1" \
        --env AGENT_CONFIG="$TEST_MODEL" \
        --env PROMPT="Reply with exactly one word: pong" \
        --env BASH_MAX_TIMEOUT_MS="60000" \
        --bind "${JOB_TMP}:/tmp" \
        --home "${JOB_DIR}:/home/ben" \
        --writable-tmpfs \
        "$CONTAINER" \
        bash /home/ben/agent_solve.sh 2>&1) || true

    SHORT="${MODEL_OUTPUT:0:200}"
    if echo "$MODEL_OUTPUT" | grep -iq "pong"; then
        pass "$TEST_MODEL → Bedrock OK"
    elif echo "$MODEL_OUTPUT" | grep -iq "invalid\|error\|unauthorized"; then
        fail "$TEST_MODEL → ${SHORT}"
    else
        warn "$TEST_MODEL → unexpected: ${SHORT}"
    fi
done

# --- Cleanup ---
echo ""
echo "--- Cleanup ---"
rm -rf "$TEST_TMP"
echo "Removed $TEST_TMP"

# --- Summary ---
echo ""
echo "========================================="
echo "Results: $PASS passed, $FAIL failed, $WARN warnings"
if [ $FAIL -eq 0 ]; then
    echo "Status: READY — Bedrock connectivity verified"
else
    echo "Status: NOT READY — fix $FAIL failed items"
fi
echo "========================================="
exit $FAIL
