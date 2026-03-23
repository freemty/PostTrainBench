#!/bin/bash
# DEPRECATED: Covered by run_task.sh --dry-run (same apptainer flags, same container).
# Test 2: Container Environment
#
# Verifies the Apptainer container is functional:
#   - GPU passthrough works inside container
#   - python3 + key packages available (torch, transformers, vllm, trl, peft)
#   - Agent CLIs available (claude, codex, gemini)
#   - Non-root user creation works (Claude Code requirement)
#   - fuse-overlayfs HF cache mount works
#   - Path binding: custom external dirs accessible inside container
#
# Usage: cd ~/PostTrainBench && bash tests/test_container_env.sh

set +e
source "$(dirname "$0")/preflight_utils.sh"

if [ ! -f "$CONTAINER" ]; then
    fail "Container not found: $CONTAINER"
    summary
fi

# Helper: run command inside container
container_exec() {
    apptainer exec --nv --writable-tmpfs "$CONTAINER" "$@"
}

echo "--- 2a. GPU Passthrough ---"

GPU_OUT=$(container_exec python3 -c "
import torch
if torch.cuda.is_available():
    print(f'OK {torch.cuda.device_count()} {torch.cuda.get_device_name(0)}')
else:
    print('NO_CUDA')
" 2>/dev/null) || GPU_OUT="ERROR"

if echo "$GPU_OUT" | grep -q "^OK"; then
    pass "CUDA inside container: $GPU_OUT"
else
    fail "CUDA not available inside container: $GPU_OUT"
fi

# Tensor write test
TENSOR_OUT=$(container_exec python3 -c "
import torch
t = torch.zeros(1, device='cuda')
t[0] = 42.0
print(f'OK {t.item()}')
" 2>/dev/null) || TENSOR_OUT="ERROR"

if echo "$TENSOR_OUT" | grep -q "^OK 42"; then
    pass "CUDA tensor write works"
else
    fail "CUDA tensor write failed: $TENSOR_OUT"
fi

echo ""
echo "--- 2b. Python Packages ---"

PACKAGES="torch transformers datasets vllm trl peft accelerate inspect_ai"
PKG_RESULT=$(container_exec python3 -c "
import importlib, json
results = {}
for pkg in '$PACKAGES'.split():
    try:
        m = importlib.import_module(pkg)
        results[pkg] = getattr(m, '__version__', 'ok')
    except ImportError:
        results[pkg] = 'MISSING'
print(json.dumps(results))
" 2>/dev/null) || PKG_RESULT="{}"

for pkg in $PACKAGES; do
    ver=$(echo "$PKG_RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$pkg','ERROR'))" 2>/dev/null)
    if [ "$ver" = "MISSING" ] || [ "$ver" = "ERROR" ]; then
        fail "Package $pkg: $ver"
    else
        pass "Package $pkg: $ver"
    fi
done

echo ""
echo "--- 2c. Agent CLIs ---"

for cli in claude codex gemini; do
    if container_exec which "$cli" >/dev/null 2>&1; then
        CLI_VER=$(container_exec "$cli" --version 2>/dev/null | head -1) || CLI_VER="(version unknown)"
        pass "$cli CLI: $CLI_VER"
    else
        case "$cli" in
            claude) fail "$cli CLI not found (required for claude agent)" ;;
            *)      warn "$cli CLI not found" ;;
        esac
    fi
done

echo ""
echo "--- 2d. Non-Root User Creation ---"
# Claude Code requires non-root for --dangerously-skip-permissions

USER_OUT=$(apptainer exec --nv --writable-tmpfs -c \
    --home "/tmp/test_home:/home/ben" \
    "$CONTAINER" bash -c '
    useradd -m -s /bin/bash ben 2>/dev/null || true
    chown ben:ben /home/ben 2>/dev/null || true
    su -s /bin/bash -c "whoami && echo HOME=\$HOME" ben
' 2>/dev/null) || USER_OUT="ERROR"

if echo "$USER_OUT" | grep -q "ben"; then
    pass "Non-root user 'ben' creation works"
else
    fail "Non-root user creation failed: $USER_OUT"
fi

echo ""
echo "--- 2d2. Agent CLI Init (simulated JOB_DIR) ---"
# Simulates the full JOB_DIR setup from run_task.sh for each agent CLI,
# verifying the CLI can initialize without crashes (ENOTDIR, missing config, etc.).
# Each test mirrors what run_task.sh + solve.sh does: create home, copy config, run as ben.

CLI_TEST_HOME="${PTB_TMP_BASE}/preflight_cli_init_$$"

# --- claude ---
mkdir -p "${CLI_TEST_HOME}/.claude" "${CLI_TEST_HOME}/.codex" "${CLI_TEST_HOME}/task"
if [ -d "$HOME/.claude" ]; then
    cp "$HOME/.claude/settings.local.json" "${CLI_TEST_HOME}/.claude/" 2>/dev/null || true
    cp "$HOME/.claude/settings.json" "${CLI_TEST_HOME}/.claude/" 2>/dev/null || true
fi
if [ -d "containers/other_home_data/.codex" ]; then
    cp -r "containers/other_home_data/.codex/." "${CLI_TEST_HOME}/.codex/" 2>/dev/null || true
fi

CLAUDE_OUT=$(apptainer exec --nv --writable-tmpfs \
    --home "${CLI_TEST_HOME}:/home/ben" \
    --pwd "/home/ben/task" \
    "$CONTAINER" bash -c '
    useradd -m -s /bin/bash ben 2>/dev/null || true
    [ -f /home/ben/.claude ] && rm -f /home/ben/.claude
    mkdir -p /home/ben/.claude/debug /home/ben/.claude/cache /home/ben/.claude/projects
    chown -R ben:ben /home/ben/.claude /home/ben/.codex /home/ben/task 2>/dev/null || true
    su -s /bin/bash -c "
        export HOME=/home/ben
        mkdir -p \$HOME/.claude/debug \$HOME/.claude/cache \$HOME/.claude/projects
        claude --version 2>&1 | head -1
    " ben
' 2>&1) || CLAUDE_OUT="ERROR: $CLAUDE_OUT"

if echo "$CLAUDE_OUT" | grep -qE "[0-9]+\.[0-9]+|claude"; then
    pass "claude CLI init: $(echo "$CLAUDE_OUT" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | tail -1 || echo ok)"
else
    fail "claude CLI init failed: $(echo "$CLAUDE_OUT" | tail -3)"
fi

# --- codex ---
CODEX_OUT=$(apptainer exec --nv --writable-tmpfs \
    --home "${CLI_TEST_HOME}:/home/ben" \
    --pwd "/home/ben/task" \
    "$CONTAINER" bash -c '
    useradd -m -s /bin/bash ben 2>/dev/null || true
    chown -R ben:ben /home/ben/.codex 2>/dev/null || true
    su -s /bin/bash -c "
        export HOME=/home/ben
        codex --version 2>&1 | head -1
    " ben
' 2>&1) || CODEX_OUT="ERROR: $CODEX_OUT"

if echo "$CODEX_OUT" | grep -qE "[0-9]+\.[0-9]+|codex"; then
    pass "codex CLI init: $(echo "$CODEX_OUT" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | tail -1 || echo ok)"
else
    fail "codex CLI init failed: $(echo "$CODEX_OUT" | tail -3)"
fi

# --- gemini ---
# gemini --version outputs Node.js deprecation warnings, so test with --help instead
GEMINI_OUT=$(apptainer exec --nv --writable-tmpfs \
    --home "${CLI_TEST_HOME}:/home/ben" \
    --pwd "/home/ben/task" \
    "$CONTAINER" bash -c '
    useradd -m -s /bin/bash ben 2>/dev/null || true
    mkdir -p /home/ben/.config/gemini /home/ben/.cache/gemini 2>/dev/null || true
    su -s /bin/bash -c "
        export HOME=/home/ben
        mkdir -p \$HOME/.config/gemini \$HOME/.cache/gemini
        gemini --help 2>&1 | head -3
    " ben
' 2>&1) || GEMINI_OUT="ERROR: $GEMINI_OUT"

if echo "$GEMINI_OUT" | grep -qiE "gemini|usage|options"; then
    pass "gemini CLI init: responds to --help"
else
    fail "gemini CLI init failed: $(echo "$GEMINI_OUT" | tail -3)"
fi

# --- lemma (uv install + Python import + config generation) ---
# Mirrors solve.sh: uv pip install, then import local_backend
LOCAL_LEMMA="${LOCAL_LEMMA_PATH:-$(dirname "$(pwd)")/local-lemma}"
UV_HOST_BIN=$(find /tmp -maxdepth 2 -name uv -type f -executable 2>/dev/null | head -1)
UV_HOST_DIR="${UV_HOST_BIN:+$(dirname "$UV_HOST_BIN")}"
RG_HOST_DIR="$(dirname "$(which rg 2>/dev/null || echo /usr/bin/rg)")"

if [ -d "$LOCAL_LEMMA/local_backend" ]; then
    LEMMA_OUT=$(apptainer exec --nv --writable-tmpfs \
        --bind "${LOCAL_LEMMA}:/opt/local-lemma" \
        ${UV_HOST_DIR:+--bind "${UV_HOST_DIR}:/opt/uv-bin"} \
        ${RG_HOST_DIR:+--bind "${RG_HOST_DIR}:/opt/rg-bin"} \
        --home "${CLI_TEST_HOME}:/home/ben" \
        --pwd "/home/ben/task" \
        "$CONTAINER" bash -c '
        export PYTHONPATH="/opt/local-lemma:$PYTHONPATH"
        # Install deps (same as lemma solve.sh)
        UV_BIN="/opt/uv-bin/uv"
        if [ -x "$UV_BIN" ]; then
            "$UV_BIN" pip install --system -e /opt/local-lemma --quiet 2>&1 | tail -3
        fi
        python3 -c "
from local_backend.run import main
import yaml
print(\"lemma import OK\")
config = {\"llm\": {\"provider\": \"bedrock\", \"model\": \"test\"}}
yaml.dump(config)
print(\"yaml config OK\")
"
    ' 2>&1) || LEMMA_OUT="ERROR: $LEMMA_OUT"

    if echo "$LEMMA_OUT" | grep -q "lemma import OK"; then
        pass "lemma init: uv install + import + config generation"
    else
        fail "lemma init failed: $(echo "$LEMMA_OUT" | tail -3)"
    fi
else
    warn "lemma: local-lemma not found at ${LOCAL_LEMMA} (skipped)"
fi

rm -rf "${CLI_TEST_HOME}"

echo ""
echo "--- 2e. fuse-overlayfs ---"

TEST_TMP="${PTB_TMP_BASE}/preflight_overlay_test_$$"
mkdir -p "${TEST_TMP}/lower" "${TEST_TMP}/upper" "${TEST_TMP}/work" "${TEST_TMP}/merged"
echo "test_data" > "${TEST_TMP}/lower/test_file.txt"

OVERLAY_OK=false
if fuse-overlayfs -o "lowerdir=${TEST_TMP}/lower,upperdir=${TEST_TMP}/upper,workdir=${TEST_TMP}/work" "${TEST_TMP}/merged" 2>/dev/null; then
    if [ -f "${TEST_TMP}/merged/test_file.txt" ]; then
        # Test COW: write to merged, verify lower unchanged
        echo "modified" > "${TEST_TMP}/merged/test_file.txt"
        LOWER_CONTENT=$(cat "${TEST_TMP}/lower/test_file.txt")
        MERGED_CONTENT=$(cat "${TEST_TMP}/merged/test_file.txt")
        if [ "$LOWER_CONTENT" = "test_data" ] && [ "$MERGED_CONTENT" = "modified" ]; then
            pass "fuse-overlayfs COW works correctly"
            OVERLAY_OK=true
        else
            fail "fuse-overlayfs COW broken (lower=$LOWER_CONTENT, merged=$MERGED_CONTENT)"
        fi
    else
        fail "fuse-overlayfs mounted but test file not visible"
    fi
    fusermount -u "${TEST_TMP}/merged" 2>/dev/null || true
else
    fail "fuse-overlayfs mount failed"
fi
rm -rf "${TEST_TMP}"

echo ""
echo "--- 2f. External Path Binding ---"
# Verify that paths outside REPO_ROOT can be bind-mounted (the vLLM eval fix)

BIND_TEST_DIR="${PTB_TMP_BASE}/preflight_bind_test_$$"
mkdir -p "${BIND_TEST_DIR}"
echo "bind_test_sentinel" > "${BIND_TEST_DIR}/sentinel.txt"

BIND_OUT=$(apptainer exec --nv --writable-tmpfs \
    --bind "${BIND_TEST_DIR}:${BIND_TEST_DIR}" \
    "$CONTAINER" cat "${BIND_TEST_DIR}/sentinel.txt" 2>/dev/null) || BIND_OUT="ERROR"

if [ "$BIND_OUT" = "bind_test_sentinel" ]; then
    pass "External path binding works (${BIND_TEST_DIR})"
else
    fail "External path binding failed: $BIND_OUT"
fi
rm -rf "${BIND_TEST_DIR}"

summary
