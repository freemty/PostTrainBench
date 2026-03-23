#!/bin/bash
# DEPRECATED: Covered by preflight_v2.sh fast-fail checks + run_task.sh --dry-run.
# Test 1: Host Environment
#
# Verifies the host machine is ready before launching experiments:
#   - python3, apptainer, fuse-overlayfs available
#   - GPU accessible
#   - Disk space sufficient
#   - Required env vars / config files present
#   - Container .sif file exists
#   - Results & tmp directories writable on large disk
#
# Usage: cd ~/PostTrainBench && bash tests/test_host_env.sh

set -eo pipefail
source "$(dirname "$0")/preflight_utils.sh"

echo "--- 1a. Required Binaries ---"

for cmd in python3 apptainer fuse-overlayfs fusermount nvidia-smi uuidgen; do
    if which "$cmd" >/dev/null 2>&1; then
        pass "$cmd found: $(which $cmd)"
    else
        case "$cmd" in
            fuse-overlayfs|fusermount)
                fail "$cmd not found (required for HF cache overlay)";;
            *)
                fail "$cmd not found";;
        esac
    fi
done

# python (not python3) is NOT required but check if it exists
if which python >/dev/null 2>&1; then
    pass "python symlink exists ($(python --version 2>&1))"
else
    warn "No 'python' command — ensure all scripts use 'python3'"
fi

echo ""
echo "--- 1b. GPU ---"

if nvidia-smi >/dev/null 2>&1; then
    # Read all GPU info at once to avoid SIGPIPE from head/awk on 8-GPU machines
    GPU_INFO=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>/dev/null || true)
    GPU_COUNT=$(echo "$GPU_INFO" | wc -l | tr -d ' ')
    GPU_NAME=$(echo "$GPU_INFO" | head -1 | cut -d',' -f1 | xargs)
    GPU_MEM=$(echo "$GPU_INFO" | head -1 | cut -d',' -f2 | xargs)
    pass "GPU detected: ${GPU_COUNT}x ${GPU_NAME} (${GPU_MEM} MiB each)"

    if [ "${GPU_MEM:-0}" -ge 20000 ]; then
        pass "GPU memory >= 20GB (sufficient for training + vLLM)"
    else
        warn "GPU memory ${GPU_MEM} MiB — may be tight for larger models"
    fi
else
    fail "nvidia-smi failed — no GPU or drivers missing"
fi

echo ""
echo "--- 1c. Disk Space ---"

check_disk() {
    local path="$1"
    local min_gb="$2"
    local label="$3"

    if [ ! -d "$path" ]; then
        path="$(dirname "$path")"
    fi

    if [ -d "$path" ]; then
        # Use df -P for POSIX portable output (single-line per filesystem)
        local avail_kb=$(df -P "$path" 2>/dev/null | tail -1 | awk '{print $4}')
        local avail_gb=$((avail_kb / 1024 / 1024))
        if [ "$avail_gb" -ge "$min_gb" ]; then
            pass "$label: ${avail_gb}GB available (>= ${min_gb}GB)"
        else
            fail "$label: only ${avail_gb}GB available (need ${min_gb}GB)"
        fi
    else
        warn "$label: path $path does not exist"
    fi
}

check_disk "${POST_TRAIN_BENCH_RESULTS_DIR}" 50 "Results dir"
check_disk "${PTB_TMP_BASE}" 100 "Tmp dir (overlays + job tmp)"
check_disk "/tmp" 5 "System /tmp"

echo ""
echo "--- 1d. Writable Directories ---"

for dir_path in "${POST_TRAIN_BENCH_RESULTS_DIR}" "${PTB_TMP_BASE}"; do
    mkdir -p "$dir_path" 2>/dev/null || true
    TEST_FILE="${dir_path}/.preflight_write_test_$$"
    if echo "test" > "$TEST_FILE" 2>/dev/null; then
        rm -f "$TEST_FILE"
        pass "$dir_path is writable"
    else
        fail "$dir_path is NOT writable"
    fi
done

echo ""
echo "--- 1e. Container ---"

if [ -f "$CONTAINER" ]; then
    CONTAINER_SIZE=$(du -sh "$CONTAINER" 2>/dev/null | cut -f1)
    pass "Container exists: $CONTAINER ($CONTAINER_SIZE)"
else
    fail "Container not found: $CONTAINER"
fi

echo ""
echo "--- 1f. HF Cache ---"

if [ -d "${HF_HOME}" ]; then
    HF_SIZE=$(du -sh "${HF_HOME}" 2>/dev/null | cut -f1)
    pass "HF cache exists: ${HF_HOME} ($HF_SIZE)"
else
    warn "HF cache dir not found: ${HF_HOME} — first run will download models"
fi

echo ""
echo "--- 1g. Agent API Credentials ---"

# Claude / Bedrock
CLAUDE_SETTINGS="$HOME/.claude/settings.local.json"
if [ -f "$CLAUDE_SETTINGS" ]; then
    if grep -q 'CLAUDE_CODE_USE_BEDROCK' "$CLAUDE_SETTINGS" 2>/dev/null; then
        pass "Bedrock config found in settings.local.json"
        if grep -q 'AWS_ACCESS_KEY_ID' "$CLAUDE_SETTINGS" 2>/dev/null; then
            pass "AWS credentials in Bedrock config"
        elif [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then
            pass "AWS credentials via env var"
        else
            fail "Bedrock enabled but no AWS credentials found"
        fi
    else
        if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
            pass "ANTHROPIC_API_KEY set (direct API mode)"
        else
            warn "No Bedrock config and no ANTHROPIC_API_KEY"
        fi
    fi
else
    if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        pass "ANTHROPIC_API_KEY set"
    else
        warn "No Claude credentials configured"
    fi
fi

# Codex / OpenAI
if [ -n "${OPENAI_API_KEY:-}" ] || [ -n "${CODEX_API_KEY:-}" ]; then
    pass "OpenAI/Codex API key set"
else
    warn "No OPENAI_API_KEY or CODEX_API_KEY (codex agent won't work)"
fi

# Gemini
if [ -n "${GEMINI_API_KEY:-}" ]; then
    pass "GEMINI_API_KEY set"
else
    warn "No GEMINI_API_KEY (gemini agent won't work)"
fi

echo ""
echo "--- 1h. Lemma Agent Dependencies ---"

# local-lemma path
LOCAL_LEMMA="${LOCAL_LEMMA_PATH:-$(dirname "${POST_TRAIN_BENCH_ROOT:-$(pwd)}")/local-lemma}"
if [ -d "$LOCAL_LEMMA/local_backend" ]; then
    pass "local-lemma found: $LOCAL_LEMMA"
else
    warn "local-lemma not found at $LOCAL_LEMMA (lemma agent won't work)"
fi

# uv binary (needed inside container for lemma deps)
UV_BIN=$(find /tmp -maxdepth 2 -name uv -type f -executable 2>/dev/null | head -1)
if [ -n "$UV_BIN" ]; then
    pass "uv binary found: $UV_BIN"
else
    warn "uv binary not found in /tmp (lemma may fail to install deps)"
fi

# ripgrep (lemma grep tool)
if which rg >/dev/null 2>&1; then
    pass "ripgrep found: $(which rg)"
else
    warn "ripgrep (rg) not found (lemma grep tool may fail)"
fi

# Horay.ai (codex_horay agent)
if [ -n "${HORAY_API_KEY:-}" ]; then
    pass "HORAY_API_KEY set"
else
    warn "No HORAY_API_KEY (codex_horay agent won't work)"
fi

echo ""
echo "--- 1i. Non-Interactive SSH Env Vars ---"
# Simulate the exact command launch_fleet.sh uses: ssh <host> 'command'
# This catches the ~/.bashrc [ -z "$PS1" ] && return guard

NI_ENV=$(ssh localhost 'echo "AWS=${AWS_ACCESS_KEY_ID:+SET}" "HORAY=${HORAY_API_KEY:+SET}" "HF=${HF_HOME:+SET}"' 2>/dev/null) || NI_ENV="SSH_FAILED"

if [ "$NI_ENV" = "SSH_FAILED" ]; then
    skip "Cannot ssh to localhost (passwordless SSH not configured)"
elif echo "$NI_ENV" | grep -q "AWS=SET"; then
    pass "AWS_ACCESS_KEY_ID visible in non-interactive SSH"
else
    fail "AWS_ACCESS_KEY_ID NOT visible in non-interactive SSH (bashrc guard?)"
fi
if echo "$NI_ENV" | grep -q "HF=SET"; then
    pass "HF_HOME visible in non-interactive SSH"
elif [ "$NI_ENV" != "SSH_FAILED" ]; then
    fail "HF_HOME NOT visible in non-interactive SSH"
fi

echo ""
echo "--- 1j. Stale Overlay Mounts ---"
# Check for leftover fuse-overlayfs mounts from previous experiments

STALE_MOUNTS=$(mount 2>/dev/null | grep -c "fuse-overlayfs" || true)
if [ "$STALE_MOUNTS" -eq 0 ]; then
    pass "No stale fuse-overlayfs mounts"
else
    fail "$STALE_MOUNTS stale fuse-overlayfs mount(s) found — run: mount | grep fuse-overlayfs | awk '{print \$3}' | xargs -I{} fusermount -u {}"
fi

summary
