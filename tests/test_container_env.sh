#!/bin/bash
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

set -eo pipefail
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
