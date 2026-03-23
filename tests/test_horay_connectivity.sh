#!/bin/bash
# DEPRECATED: Covered by run_task.sh --dry-run agent PONG test (codex_horay uses real Horay API).
# Test 5: Horay.ai Proxy Connectivity
#
# Verifies codex can reach Horay.ai API from inside the container.
# Usage: cd ~/PostTrainBench && bash tests/test_horay_connectivity.sh

set -eo pipefail
source "$(dirname "$0")/preflight_utils.sh"

echo "--- 5a. Horay API Key ---"

if [ -z "${HORAY_API_KEY:-}" ]; then
    warn "HORAY_API_KEY not set — skipping Horay connectivity test"
    summary
fi
pass "HORAY_API_KEY is set"

echo ""
echo "--- 5b. Horay API Ping (host) ---"

HORAY_BASE="${OPENAI_BASE_URL:-https://api.horay.ai}"
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' -m 10 "${HORAY_BASE}/v1/models" \
    -H "Authorization: Bearer ${HORAY_API_KEY}" 2>/dev/null) || HTTP_CODE="000"

if [ "$HTTP_CODE" = "200" ]; then
    pass "Horay API reachable (HTTP $HTTP_CODE)"
elif [ "$HTTP_CODE" = "000" ]; then
    fail "Horay API unreachable (connection failed)"
else
    warn "Horay API returned HTTP $HTTP_CODE (may still work for responses)"
fi

echo ""
echo "--- 5c. Codex via Horay (inside container) ---"

if [ ! -f "$CONTAINER" ]; then
    fail "Container not found, skipping container test"
    summary
fi

TEST_TMP="${PTB_TMP_BASE}/preflight_horay_$$"
JOB_DIR="${TEST_TMP}/job_dir"
JOB_TMP="${TEST_TMP}/tmp"
mkdir -p "${JOB_DIR}" "${JOB_TMP}"

if [ -d "containers/other_home_data/.codex" ]; then
    cp -r "containers/other_home_data/.codex" "${JOB_DIR}/"
fi

CODEX_OUT=$(timeout 60s apptainer exec \
    -c \
    --env PATH="/root/.local/bin:/home/ben/.local/bin:$PATH" \
    --env HORAY_API_KEY="${HORAY_API_KEY}" \
    --env PYTHONNOUSERSITE="1" \
    --bind "${JOB_TMP}:/tmp" \
    --home "${JOB_DIR}:/home/ben" \
    --writable-tmpfs \
    "$CONTAINER" \
    codex --search exec --json \
        -c 'model_provider="horay"' \
        -c 'disable_response_storage=true' \
        --skip-git-repo-check --yolo \
        --model "g5.2-rxj" \
        "Reply with exactly one word: pong" 2>&1) || true

if echo "$CODEX_OUT" | grep -iq "pong"; then
    pass "Codex via Horay responded inside container"
elif echo "$CODEX_OUT" | grep -iq "error\|unauthorized\|forbidden"; then
    fail "Codex via Horay auth error: ${CODEX_OUT:0:150}"
elif echo "$CODEX_OUT" | grep -iq "timeout\|timed out"; then
    fail "Codex via Horay timeout: ${CODEX_OUT:0:150}"
else
    warn "Codex via Horay unexpected response: ${CODEX_OUT:0:150}"
fi

rm -rf "${TEST_TMP}"
summary
