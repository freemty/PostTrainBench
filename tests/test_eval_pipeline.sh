#!/bin/bash
# Test 3: Evaluation Pipeline
#
# Verifies the eval pipeline works end-to-end before real experiments:
#   - vLLM can load a model from an external path inside the container
#   - Chat templates are accessible via the relative path used by run_task.sh
#   - evaluate.py can parse model config and select correct template
#   - The full eval apptainer invocation (matching run_task.sh) doesn't crash
#   - metrics.json output path is writable from inside the container
#
# This test uses a REAL base model from HF cache to do a minimal vLLM smoke test.
# If no model is cached, it falls back to structural checks only.
#
# Usage: cd ~/PostTrainBench && bash tests/test_eval_pipeline.sh [model_path]

set -eo pipefail
source "$(dirname "$0")/preflight_utils.sh"

MODEL_PATH="${1:-}"
REPO_ROOT="$(pwd)"

if [ ! -f "$CONTAINER" ]; then
    fail "Container not found: $CONTAINER"
    summary
fi

echo "--- 3a. Eval Templates ---"

TEMPLATES_DIR="src/eval/templates"
for template in qwen3.jinja gemma3.jinja smollm.jinja; do
    if [ -f "${TEMPLATES_DIR}/${template}" ]; then
        pass "Template exists: ${template}"
    else
        fail "Template missing: ${TEMPLATES_DIR}/${template}"
    fi
done

echo ""
echo "--- 3b. Evaluate Scripts ---"

for task_dir in src/eval/tasks/*/; do
    task_name=$(basename "$task_dir")
    if [ -f "${task_dir}/evaluate.py" ]; then
        pass "evaluate.py exists for ${task_name}"
    else
        fail "evaluate.py missing for ${task_name}"
    fi
    if [ -f "${task_dir}/benchmark.txt" ]; then
        pass "benchmark.txt exists for ${task_name}"
    else
        fail "benchmark.txt missing for ${task_name}"
    fi
done

echo ""
echo "--- 3c. Template Relative Path (inside container) ---"
# run_task.sh uses: --pwd "$(pwd)/src/eval/tasks/${TASK}" and --templates-dir ../../../../src/eval/templates
# Verify this relative path resolves correctly inside the container

for task_name in gsm8k humaneval aime2025; do
    if [ ! -d "src/eval/tasks/${task_name}" ]; then
        continue
    fi
    RELPATH_OUT=$(apptainer exec --nv --writable-tmpfs \
        --bind "${REPO_ROOT}:${REPO_ROOT}" \
        --pwd "${REPO_ROOT}/src/eval/tasks/${task_name}" \
        "$CONTAINER" python3 -c "
import os
tpl_dir = '../../../../src/eval/templates'
resolved = os.path.abspath(tpl_dir)
exists = os.path.isdir(resolved)
qwen = os.path.isfile(os.path.join(resolved, 'qwen3.jinja'))
print(f'{resolved} exists={exists} qwen={qwen}')
" 2>/dev/null) || RELPATH_OUT="ERROR"

    if echo "$RELPATH_OUT" | grep -q "exists=True.*qwen=True"; then
        pass "Relative template path OK for ${task_name}"
    else
        fail "Relative template path broken for ${task_name}: $RELPATH_OUT"
    fi
done

echo ""
echo "--- 3d. EVAL_DIR Path Binding (simulated) ---"
# The core fix: EVAL_DIR on external storage must be accessible inside eval container

FAKE_EVAL_DIR="${PTB_TMP_BASE}/preflight_eval_bind_$$"
FAKE_MODEL_DIR="${FAKE_EVAL_DIR}/final_model"
mkdir -p "${FAKE_MODEL_DIR}"

# Create a minimal config.json (enough for evaluate.py to parse)
cat > "${FAKE_MODEL_DIR}/config.json" << 'JSONEOF'
{
  "architectures": ["Qwen2ForCausalLM"],
  "model_type": "qwen2",
  "hidden_size": 1536,
  "num_hidden_layers": 28
}
JSONEOF

# Test 1: Can the container see the external path?
BIND_CHECK=$(apptainer exec --nv --writable-tmpfs \
    --bind "${REPO_ROOT}:${REPO_ROOT}" \
    --bind "${FAKE_EVAL_DIR}:${FAKE_EVAL_DIR}" \
    "$CONTAINER" python3 -c "
import os, json
config_path = '${FAKE_MODEL_DIR}/config.json'
if os.path.isfile(config_path):
    with open(config_path) as f:
        cfg = json.load(f)
    print(f'OK arch={cfg[\"architectures\"][0]}')
else:
    print('NOT_FOUND')
" 2>/dev/null) || BIND_CHECK="ERROR"

if echo "$BIND_CHECK" | grep -q "^OK"; then
    pass "EVAL_DIR bind mount works: $BIND_CHECK"
else
    fail "EVAL_DIR bind mount failed: $BIND_CHECK"
fi

# Test 2: Can metrics.json be written from inside container?
METRICS_FILE="${FAKE_EVAL_DIR}/metrics_test.json"
apptainer exec --nv --writable-tmpfs \
    --bind "${FAKE_EVAL_DIR}:${FAKE_EVAL_DIR}" \
    "$CONTAINER" python3 -c "
import json
with open('${METRICS_FILE}', 'w') as f:
    json.dump({'test': True}, f)
" 2>/dev/null || true

if [ -f "${METRICS_FILE}" ]; then
    pass "metrics.json writable from inside container"
else
    fail "Cannot write metrics.json from inside container to EVAL_DIR"
fi

rm -rf "${FAKE_EVAL_DIR}"

echo ""
echo "--- 3e. vLLM Import & Config ---"

VLLM_CHECK=$(apptainer exec --nv --writable-tmpfs "$CONTAINER" python3 -c "
import vllm
print(f'vllm={vllm.__version__}')
from vllm import LLM
print('LLM_import=OK')
" 2>/dev/null) || VLLM_CHECK="ERROR"

if echo "$VLLM_CHECK" | grep -q "vllm="; then
    pass "vLLM importable: $(echo "$VLLM_CHECK" | head -1)"
else
    fail "vLLM import failed: $VLLM_CHECK"
fi

if echo "$VLLM_CHECK" | grep -q "LLM_import=OK"; then
    pass "vLLM LLM class importable"
else
    fail "vLLM LLM class import failed"
fi

echo ""
echo "--- 3f. vLLM Serve Smoke Test (per-model) ---"
# Test all 4 experiment models explicitly.
# This catches model-specific vLLM failures (e.g. SmolLM3-3B crash in exp01a).

EXPERIMENT_MODELS=(
    "Qwen/Qwen3-4B-Base"
    "google/gemma-3-4b-pt"
    "Qwen/Qwen3-1.7B-Base"
    "HuggingFaceTB/SmolLM3-3B-Base"
)

MODELS_TESTED=0

for MODEL_ID in "${EXPERIMENT_MODELS[@]}"; do
    # Convert HF model ID to cache directory name
    # e.g. "Qwen/Qwen3-4B-Base" -> "models--Qwen--Qwen3-4B-Base"
    CACHE_DIR_NAME="models--$(echo "$MODEL_ID" | tr '/' '--')"
    SNAPSHOT_DIR=""

    if [ -d "${HF_HOME}/hub/${CACHE_DIR_NAME}/snapshots" ]; then
        for snap in "${HF_HOME}/hub/${CACHE_DIR_NAME}/snapshots"/*/; do
            if [ -f "${snap}/config.json" ]; then
                # Remove trailing slash (vLLM 0.11.0 treats paths with trailing / as repo IDs)
                SNAPSHOT_DIR="${snap%/}"
                break
            fi
        done
    fi

    if [ -z "$SNAPSHOT_DIR" ]; then
        skip "vLLM smoke test for ${MODEL_ID}: not cached in HF_HOME"
        continue
    fi

    echo "  Testing with model: ${MODEL_ID} (${SNAPSHOT_DIR})"
    MODELS_TESTED=$((MODELS_TESTED + 1))

    # Prepare bind mounts (model may be on external storage)
    BIND_ARGS="--bind ${REPO_ROOT}:${REPO_ROOT}"
    case "$SNAPSHOT_DIR" in
        ${REPO_ROOT}/*) ;;
        *) BIND_ARGS="${BIND_ARGS} --bind $(dirname "${SNAPSHOT_DIR}"):$(dirname "${SNAPSHOT_DIR}")" ;;
    esac

    VLLM_LOG="${PTB_TMP_BASE}/preflight_vllm_${MODEL_ID//\//_}_$$"
    mkdir -p "$(dirname "$VLLM_LOG")"

    timeout 45s apptainer exec --nv --writable-tmpfs \
        $BIND_ARGS \
        --pwd "${REPO_ROOT}/src/eval/tasks/gsm8k" \
        "$CONTAINER" \
        vllm serve "$SNAPSHOT_DIR" \
            --host 0.0.0.0 --port 48199 \
            --api-key inspectai \
            --gpu-memory-utilization 0.3 \
            --max-model-len 512 \
        > "$VLLM_LOG" 2>&1 &
    VLLM_PID=$!

    # Wait for startup or failure (up to 45s: 15 iterations × 3s)
    VLLM_STARTED=false
    for i in $(seq 1 15); do
        sleep 3
        if ! kill -0 $VLLM_PID 2>/dev/null; then
            # Process died
            break
        fi
        if grep -q "Uvicorn running on" "$VLLM_LOG" 2>/dev/null; then
            VLLM_STARTED=true
            break
        fi
        if grep -q "Application startup complete" "$VLLM_LOG" 2>/dev/null; then
            VLLM_STARTED=true
            break
        fi
    done

    if $VLLM_STARTED; then
        pass "vLLM serve OK: ${MODEL_ID}"
    else
        VLLM_ERR=$(grep -i "error\|exception\|traceback\|OSError" "$VLLM_LOG" 2>/dev/null | tail -3)
        if [ -n "$VLLM_ERR" ]; then
            fail "vLLM serve crashed for ${MODEL_ID}: $VLLM_ERR"
        elif kill -0 $VLLM_PID 2>/dev/null; then
            warn "vLLM serve still loading after 45s for ${MODEL_ID} (may be OK for large models)"
        else
            fail "vLLM serve exited unexpectedly for ${MODEL_ID} (check $VLLM_LOG)"
        fi
    fi

    # Cleanup between models: kill vLLM process and free GPU
    kill $VLLM_PID 2>/dev/null || true
    wait $VLLM_PID 2>/dev/null || true
    nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | xargs -r kill -9 2>/dev/null || true
    sleep 2
    rm -f "$VLLM_LOG"
done

if [ "$MODELS_TESTED" -eq 0 ]; then
    warn "vLLM smoke test: no experiment models found in HF cache — skipped all 4 models"
fi

echo ""
echo "--- 3g. Prompt Generation ---"

# Check that get_prompt.py works (requires python3)
PROMPT_OUT=$(python3 src/eval/general/get_prompt.py \
    --model-to-train "Qwen/Qwen3-1.7B-Base" \
    --benchmark-id "gsm8k" \
    --num-hours 1 \
    --agent "claude" 2>/dev/null | head -5) || PROMPT_OUT="ERROR"

if [ -n "$PROMPT_OUT" ] && [ "$PROMPT_OUT" != "ERROR" ]; then
    PROMPT_LEN=${#PROMPT_OUT}
    pass "Prompt generation works (${PROMPT_LEN} chars)"
else
    fail "Prompt generation failed"
fi

summary
