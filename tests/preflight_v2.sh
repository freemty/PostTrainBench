#!/bin/bash
# preflight_v2.sh — one entry, one pipeline, one report
#
# Core principle: preflight walks the SAME code path as launch (run_task.sh --dry-run).
# No independent check scripts. If run_task.sh changes, preflight changes with it.
#
# Usage:
#   cd ~/PostTrainBench && source ~/.fleet_env && \
#   bash tests/preflight_v2.sh --exp exp02b \
#     --slots "claude:0:claude-opus-4-6,lemma:1:claude-opus-4-6,codex_horay:2:g5.2-rxj" \
#     --model google/gemma-3-4b-pt --task gsm8k
#
# Fleet usage (from bastion):
#   bash scripts/preflight_fleet.sh --exp exp02b --slots '...' --model '...' --tasks-file fleet_tasks.txt

set -euo pipefail
source "$(dirname "$0")/preflight_utils.sh"

# ── Parse args ──
EXP="" SLOTS="" MODEL="" TASK=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --exp) EXP="$2"; shift 2 ;;
        --slots) SLOTS="$2"; shift 2 ;;
        --model) MODEL="$2"; shift 2 ;;
        --task) TASK="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

if [ -z "$EXP" ] || [ -z "$SLOTS" ] || [ -z "$MODEL" ] || [ -z "$TASK" ]; then
    echo "Usage: bash tests/preflight_v2.sh --exp <id> --slots <agent:gpu:config,...> --model <model> --task <task>"
    exit 1
fi

export POST_TRAIN_BENCH_EXPERIMENT_NAME="_${EXP}"

echo "============================================"
echo "  PREFLIGHT v2 — $(hostname)"
echo "  Exp: $EXP | Task: $TASK | Model: $MODEL"
echo "============================================"

# ── Fast-fail ──
echo ""
echo "--- Fast-fail checks ---"
FAST_FAIL=0

# Memory
AVAIL_MEM=$(free -g | awk '/Mem:/{print $7}')
if [ "$AVAIL_MEM" -lt 50 ]; then
    fail "Available memory ${AVAIL_MEM}GB < 50GB"; FAST_FAIL=1
else
    pass "Memory: ${AVAIL_MEM}GB available"
fi

# Disk
AVAIL_DISK=$(df -BG "$PTB_TMP_BASE" | awk 'NR==2{gsub("G",""); print $4}')
N_SLOTS=$(echo "$SLOTS" | tr ',' '\n' | wc -l)
NEEDED_DISK=$((N_SLOTS * 50))
if [ "$AVAIL_DISK" -lt "$NEEDED_DISK" ]; then
    fail "Disk: ${AVAIL_DISK}GB < ${NEEDED_DISK}GB needed for $N_SLOTS slots"; FAST_FAIL=1
else
    pass "Disk: ${AVAIL_DISK}GB available (need ${NEEDED_DISK}GB)"
fi

# OOM history (last hour) — dmesg -T may not be available on all kernels
OOM_COUNT=$(dmesg -T 2>/dev/null | grep -ci "oom\|killed process" || echo 0)
if [ "$OOM_COUNT" -gt 0 ]; then
    warn "OOM events in dmesg: $OOM_COUNT (check if recent)"
else
    pass "No OOM events in dmesg"
fi

# Zombie processes from previous experiments
ZOMBIES=$(pgrep -f "run_task\.sh|claude --print|local_backend\.run|codex --search" 2>/dev/null | wc -l || true)
if [ "$ZOMBIES" -gt 0 ]; then
    fail "$ZOMBIES orphan processes found — run cleanup first"
    pgrep -af "run_task\.sh|claude --print|local_backend\.run|codex --search" 2>/dev/null | head -5 || true
    FAST_FAIL=1
else
    pass "No orphan processes"
fi

# GPU idle check for each requested slot
IFS=',' read -ra SLOT_ARRAY <<< "$SLOTS"
for slot in "${SLOT_ARRAY[@]}"; do
    gpu=$(echo "$slot" | cut -d: -f2)
    GPU_PROCS=$(nvidia-smi --id="$gpu" --query-compute-apps=pid --format=csv,noheader 2>/dev/null | grep -c . || true)
    if [ "$GPU_PROCS" -gt 0 ]; then
        fail "GPU $gpu has $GPU_PROCS active processes"; FAST_FAIL=1
    else
        pass "GPU $gpu idle"
    fi
done

# Container exists
if [ ! -f "$CONTAINER" ]; then
    fail "Container not found: $CONTAINER"; FAST_FAIL=1
else
    pass "Container: $(basename "$CONTAINER")"
fi

if [ $FAST_FAIL -gt 0 ]; then
    echo ""
    echo "FAST-FAIL: fix the above before proceeding"
    exit 1
fi

# ── API connectivity (per unique agent type) ──
echo ""
echo "--- API connectivity ---"
API_FAIL=0

# Collect unique agent types from slots
declare -A SEEN_AGENTS
for slot in "${SLOT_ARRAY[@]}"; do
    agent=$(echo "$slot" | cut -d: -f1)
    SEEN_AGENTS["$agent"]=1
done

for agent in "${!SEEN_AGENTS[@]}"; do
    case "$agent" in
        claude|claude_v2|claude_non_api|lemma)
            # These use Bedrock (via Claude CLI with CLAUDE_CODE_USE_BEDROCK=1)
            if [ "${CLAUDE_CODE_USE_BEDROCK:-}" = "1" ]; then
                if aws bedrock-runtime invoke-model \
                    --model-id "global.anthropic.claude-sonnet-4-6" \
                    --cli-binary-format raw-in-base64-out \
                    --body '{"anthropic_version":"bedrock-2023-05-31","max_tokens":5,"messages":[{"role":"user","content":"ping"}]}' \
                    /tmp/preflight_bedrock_test.json >/dev/null 2>&1; then
                    pass "Bedrock API: OK (for $agent)"
                else
                    fail "Bedrock API: FAILED (for $agent) — check AWS creds/region"
                    API_FAIL=1
                fi
            elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
                if curl -sf --max-time 10 https://api.anthropic.com/v1/messages \
                    -H "x-api-key: ${ANTHROPIC_API_KEY}" \
                    -H "anthropic-version: 2023-06-01" \
                    -H "content-type: application/json" \
                    -d '{"model":"claude-sonnet-4-5-20250514","max_tokens":5,"messages":[{"role":"user","content":"ping"}]}' \
                    >/dev/null 2>&1; then
                    pass "Anthropic API: OK (for $agent)"
                else
                    fail "Anthropic API: FAILED (for $agent)"
                    API_FAIL=1
                fi
            else
                fail "No API auth for $agent (need CLAUDE_CODE_USE_BEDROCK=1 or ANTHROPIC_API_KEY)"
                API_FAIL=1
            fi
            ;;
        codex_horay)
            # codex_horay uses Horay proxy
            if [ -z "${HORAY_API_KEY:-}" ]; then
                fail "HORAY_API_KEY not set (for $agent)"
                API_FAIL=1
            else
                # Try both known Horay endpoints
                HORAY_OK=false
                for endpoint in "https://sr-endpoint.horay.ai" "https://openrouter.horay.ai"; do
                    if curl -sf --max-time 10 "${endpoint}/v1/chat/completions" \
                        -H "Authorization: Bearer ${HORAY_API_KEY}" \
                        -H "Content-Type: application/json" \
                        -d '{"model":"g5.2-rxj","messages":[{"role":"user","content":"ping"}],"max_tokens":5}' \
                        >/dev/null 2>&1; then
                        pass "Horay API: OK at ${endpoint} (for $agent)"
                        HORAY_OK=true
                        break
                    fi
                done
                if [ "$HORAY_OK" = false ]; then
                    fail "Horay API: FAILED — all endpoints unreachable (for $agent)"
                    API_FAIL=1
                fi
            fi
            ;;
        codex|codexhigh|codexlow)
            # codex uses OpenAI API (direct or via proxy)
            if [ -z "${OPENAI_API_KEY:-}" ]; then
                fail "OPENAI_API_KEY not set (for $agent)"
                API_FAIL=1
            else
                OPENAI_URL="${OPENAI_BASE_URL:-https://api.openai.com}/v1/chat/completions"
                if curl -sf --max-time 15 "$OPENAI_URL" \
                    -H "Authorization: Bearer ${OPENAI_API_KEY}" \
                    -H "Content-Type: application/json" \
                    -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"ping"}],"max_tokens":5}' \
                    >/dev/null 2>&1; then
                    pass "OpenAI API: OK (for $agent)"
                else
                    fail "OpenAI API: FAILED at ${OPENAI_URL} (for $agent)"
                    API_FAIL=1
                fi
            fi
            ;;
        gemini)
            if [ -z "${GEMINI_API_KEY:-}" ]; then
                fail "GEMINI_API_KEY not set (for $agent)"
                API_FAIL=1
            else
                if curl -sf --max-time 10 \
                    "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=${GEMINI_API_KEY}" \
                    -H "Content-Type: application/json" \
                    -d '{"contents":[{"parts":[{"text":"ping"}]}]}' \
                    >/dev/null 2>&1; then
                    pass "Gemini API: OK (for $agent)"
                else
                    fail "Gemini API: FAILED (for $agent)"
                    API_FAIL=1
                fi
            fi
            ;;
        *)
            warn "Unknown agent type: $agent — skipping API check"
            ;;
    esac
done

if [ $API_FAIL -gt 0 ]; then
    echo ""
    echo "API-FAIL: fix API connectivity before proceeding"
    exit 1
fi

echo ""
echo "--- Per-slot dry-run ---"

# GPU cleanup: kill all processes on a specific GPU (by index)
cleanup_gpu() {
    local gpu_id="$1"
    local pids
    pids=$(nvidia-smi --id="$gpu_id" --query-compute-apps=pid --format=csv,noheader 2>/dev/null | grep -v '^$' || true)
    if [ -n "$pids" ]; then
        echo "  [cleanup] Killing residual GPU $gpu_id processes"
        echo "$pids" | while read -r pid; do
            pid=$(echo "$pid" | tr -d ' ')
            [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null || true
        done
        sleep 2
    fi
    # Kill orphaned vllm/ray not visible via nvidia-smi (e.g. APIServer, ray workers)
    local orphans
    orphans=$(pgrep -f "vllm serve|ray::IDLE|EngineCore" 2>/dev/null || true)
    if [ -n "$orphans" ]; then
        echo "  [cleanup] Killing orphaned vllm/ray"
        echo "$orphans" | while read -r pid; do
            kill -9 "$pid" 2>/dev/null || true
        done
        sleep 1
    fi
}

# ── Per-slot dry-run ──
PASS_COUNT=0
FAIL_COUNT=0
FAILED_SLOTS=()

for slot in "${SLOT_ARRAY[@]}"; do
    agent=$(echo "$slot" | cut -d: -f1)
    gpu=$(echo "$slot" | cut -d: -f2)
    config=$(echo "$slot" | cut -d: -f3)

    # Pre-clean GPU before each slot
    cleanup_gpu "$gpu"

    echo ""
    echo "=== $agent on GPU $gpu (config: $config) ==="

    set +e
    CUDA_VISIBLE_DEVICES=$gpu bash src/run_task.sh \
        "$TASK" "$agent" "$MODEL" "dryrun_${EXP}_g${gpu}" 0 "$config" --dry-run
    EXIT_CODE=$?
    set -e

    # Post-clean GPU after each slot
    cleanup_gpu "$gpu"

    if [ $EXIT_CODE -eq 0 ]; then
        pass "$agent GPU $gpu: PASS"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        fail "$agent GPU $gpu: FAIL (exit $EXIT_CODE)"
        # Best effort: find the dryrun solve_out for diagnosis
        DRYRUN_EVAL="${POST_TRAIN_BENCH_RESULTS_DIR}/${agent}_${config}_0h_${EXP}/${TASK}_$(echo "$MODEL" | tr '/:' '_')_dryrun_${EXP}_g${gpu}"
        if [ -f "$DRYRUN_EVAL/solve_out.txt" ]; then
            echo "  --- solve_out tail ---"
            tail -20 "$DRYRUN_EVAL/solve_out.txt" | sed 's/^/  /'
        fi
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_SLOTS+=("$agent:GPU$gpu")
    fi
done

# ── Summary ──
TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo ""
echo "============================================"
if [ $FAIL_COUNT -eq 0 ]; then
    echo "  ALL $TOTAL SLOTS PASSED"
    echo "  Safe to launch — estimated runtime: 10h"
    echo "============================================"
    exit 0
else
    echo "  $FAIL_COUNT/$TOTAL SLOTS FAILED: ${FAILED_SLOTS[*]}"
    echo "  DO NOT LAUNCH"
    echo "============================================"
    exit 1
fi
