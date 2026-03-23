#!/bin/bash

export EVALUATION_TASK="$1"
AGENT="$2"
MODEL_TO_TRAIN="$3"
CLUSTER_ID="$4"
NUM_HOURS="$5"
AGENT_CONFIG="$6"

SKIP_NETWORK_PROBE=false
DRY_RUN=false
for arg in "${@:7}"; do
    case "$arg" in
        --skip-network-probe) SKIP_NETWORK_PROBE=true ;;
        --dry-run) DRY_RUN=true ;;
    esac
done

source src/commit_utils/set_env_vars.sh

# --- Quick sanity checks (fail fast before allocating resources) ---
SANITY_FAIL=0
sanity_fail() { echo "SANITY FAIL: $1" >&2; SANITY_FAIL=$((SANITY_FAIL + 1)); }

CONTAINER="${POST_TRAIN_BENCH_CONTAINERS_DIR}/${POST_TRAIN_BENCH_CONTAINER_NAME}.sif"
[ -f "$CONTAINER" ] || sanity_fail "Container not found: $CONTAINER"
[ -f "agents/${AGENT}/solve.sh" ] || sanity_fail "Agent script not found: agents/${AGENT}/solve.sh"
[ -d "src/eval/tasks/${EVALUATION_TASK}" ] || sanity_fail "Unknown eval task: ${EVALUATION_TASK}"
which python3 >/dev/null 2>&1 || sanity_fail "python3 not found"
which apptainer >/dev/null 2>&1 || sanity_fail "apptainer not found"
nvidia-smi >/dev/null 2>&1 || sanity_fail "nvidia-smi failed (no GPU?)"

if [ $SANITY_FAIL -gt 0 ]; then
    echo "Aborting: $SANITY_FAIL sanity check(s) failed. Run 'bash tests/preflight.sh' for full diagnostics." >&2
    exit 1
fi

RESULT_PREFIX_SAFE=$(echo "$MODEL_TO_TRAIN" | tr '/:' '_')

AGENT_CONFIG_SAFE=$(echo "$AGENT_CONFIG" | tr '/:' '_')

RANDOM_UUID=$(uuidgen)

export EVAL_DIR="${POST_TRAIN_BENCH_RESULTS_DIR}/${AGENT}_${AGENT_CONFIG_SAFE}_${NUM_HOURS}h${POST_TRAIN_BENCH_EXPERIMENT_NAME}/${EVALUATION_TASK}_${RESULT_PREFIX_SAFE}_${CLUSTER_ID}"

mkdir -p ${EVAL_DIR}

# ── Dry-run mode: override params, short timeout, PONG prompt ──
if [ "$DRY_RUN" = true ]; then
    NUM_HOURS=0
    PROMPT="Reply with exactly the word PONG and nothing else."
    export DRY_RUN=true
    echo "DRY-RUN mode: agent PONG test + vLLM smoke test"
fi

if [ "$DRY_RUN" = false ]; then
exec 1>${EVAL_DIR}/output.log
exec 2>${EVAL_DIR}/error.log
fi

echo "$@"

# Use large storage for tmp (root disk is too small)
PTB_TMP_BASE="${POST_TRAIN_BENCH_TMP_DIR:-$(dirname "${POST_TRAIN_BENCH_RESULTS_DIR}")/tmp}"
mkdir -p "${PTB_TMP_BASE}"
export TMP_SUBDIR="${PTB_TMP_BASE}/posttrain_container_${EVALUATION_TASK}_${RESULT_PREFIX_SAFE}_${RANDOM_UUID}"

JOB_DIR="${TMP_SUBDIR}/job_dir"
JOB_TMP="${TMP_SUBDIR}/tmp"
# Direct bind-mount: no overlay, share HF cache read-write
# (Hive pattern: overlay COW caused 38TB disk explosion + weight corruption in exp01b)
export HF_MERGED="${HF_HOME}"

mkdir -p "${JOB_DIR}"
mkdir -p "${JOB_TMP}"
chmod 1777 "${JOB_TMP}"

echo "Preparing job directory..." 
mkdir -p "${JOB_DIR}"

mkdir "${JOB_DIR}/task"

cp "src/eval/tasks/${EVALUATION_TASK}/evaluate.py" "${JOB_DIR}/task"
if [ -d "src/eval/tasks/${EVALUATION_TASK}/evaluation_code" ]; then
    cp -r "src/eval/tasks/${EVALUATION_TASK}/evaluation_code" "${JOB_DIR}/task"
fi
cp -r src/eval/templates "${JOB_DIR}/task/"

if [ -d "src/eval/tasks/${EVALUATION_TASK}/task_context" ]; then
    cp -r src/eval/tasks/${EVALUATION_TASK}/task_context/* "${JOB_DIR}/task"
fi
cp -r "containers/other_home_data/.codex" "${JOB_DIR}/"

# Copy Claude Code config if present (for Bedrock auth)
if [ -d "$HOME/.claude" ]; then
    mkdir -p "${JOB_DIR}/.claude"
    cp "$HOME/.claude/settings.local.json" "${JOB_DIR}/.claude/" 2>/dev/null
    cp "$HOME/.claude/settings.json" "${JOB_DIR}/.claude/" 2>/dev/null
    # Create subdirs claude CLI needs at runtime (prevents ENOTDIR)
    mkdir -p "${JOB_DIR}/.claude/debug"
    mkdir -p "${JOB_DIR}/.claude/cache"
    mkdir -p "${JOB_DIR}/.claude/projects"
    # Pre-create project-specific dir: claude CLI converts pwd '/' -> '-'
    # e.g. /home/ben/task -> -home-ben-task
    CLAUDE_PROJECT_DIR=$(echo "/home/ben/task" | tr '/' '-')
    mkdir -p "${JOB_DIR}/.claude/projects/${CLAUDE_PROJECT_DIR}"
fi

# Copy agent home overlay (skills, agents, CLAUDE.md, etc.)
if [ -d "agents/${AGENT}/home" ]; then
    cp -r "agents/${AGENT}/home/." "${JOB_DIR}/"
fi

BENCHMARK=$(cat src/eval/tasks/${EVALUATION_TASK}/benchmark.txt)
if [ "$DRY_RUN" = false ]; then
    PROMPT=$(python3 src/eval/general/get_prompt.py --model-to-train "$MODEL_TO_TRAIN" --benchmark-id "$EVALUATION_TASK" --num-hours "$NUM_HOURS" --agent "${AGENT}")
fi
echo "$PROMPT" > "${EVAL_DIR}/prompt.txt"

bash src/utils/create_timer.sh $NUM_HOURS $JOB_DIR/task/timer.sh

# set openai api keys appropriately
export CODEX_API_KEY="${OPENAI_API_KEY}"
unset OPENAI_API_KEY
if [ "$EVALUATION_TASK" == "arenahardwriting" ] || [ "$EVALUATION_TASK" == "healthbench" ]; then
    export OPENAI_API_KEY="${CODEX_API_KEY}"
fi

# Auto-detect local-lemma for bind-mount (lemma agent needs this)
if [ "$AGENT" = "lemma" ]; then
    LOCAL_LEMMA_BIND="${LOCAL_LEMMA_PATH:-$(dirname "$(pwd)")/local-lemma}"
    if [ ! -d "$LOCAL_LEMMA_BIND/local_backend" ]; then
        echo "ERROR: lemma agent requires local-lemma at $LOCAL_LEMMA_BIND"
        echo "Set LOCAL_LEMMA_PATH or place local-lemma next to PostTrainBench"
        exit 1
    fi
    export LOCAL_LEMMA_BIND
    # Find uv binary on host for installing lemma deps inside container
    # Container's /tmp is bind-mounted so the original uv at /tmp/tmp.*/uv is hidden
    UV_HOST_BIN=$(find /tmp -maxdepth 2 -name uv -type f -executable 2>/dev/null | head -1)
    if [ -n "$UV_HOST_BIN" ]; then
        export UV_HOST_DIR="$(dirname "$UV_HOST_BIN")"
    fi
    # Find ripgrep on host (lemma requires it for grep tool)
    RG_HOST_BIN=$(which rg 2>/dev/null)
    if [ -n "$RG_HOST_BIN" ]; then
        export RG_HOST_DIR="$(dirname "$RG_HOST_BIN")"
    fi
fi

# Copy scripts needed inside the container
cp src/utils/check_cuda.py "${JOB_DIR}/check_cuda.py"
cp src/utils/check_cuda_writing.py "${JOB_DIR}/check_cuda_writing.py"
cp "agents/${AGENT}/solve.sh" "${JOB_DIR}/agent_solve.sh"

# Copy agent-specific auth if present (e.g. for non-API agents)
if [ -f "agents/${AGENT}/auth.json" ]; then
    cp "agents/${AGENT}/auth.json" "${JOB_DIR}/.codex/auth.json"
fi
if [ -f "agents/${AGENT}/oauth_token" ]; then
    cp "agents/${AGENT}/oauth_token" "${JOB_DIR}/oauth_token"
fi

# Utils
# No-op overlay wrapper: HF_MERGED already points to HF_HOME (direct bind-mount).
# Kept as wrapper so solve_task/run_evaluation call sites don't change.
with_huggingface_overlay() {
    "$@"
}

with_record_the_time() {
    local begin=$(date --iso-8601=seconds)
    "$@"
    local exit_code=$?
    local end=$(date --iso-8601=seconds)
    
    local time_taken=$(( $(date --date="$end" +%s) - $(date --date="$begin" +%s) ))
    printf '%02d:%02d:%02d\n' \
        $(( time_taken / 3600 )) \
        $(( (time_taken % 3600) / 60 )) \
        $(( time_taken % 60 )) > "${EVAL_DIR}/time_taken.txt"
    
    return $exit_code
}

SOLVE_OUT="${EVAL_DIR}/solve_out.txt"

solve_and_persist() {
    solve_task
    local solve_exit=$?

    # Copy final_model NOW while overlay is still mounted
    # exp01b lesson: cp after overlay unmount produces 0-byte shells
    if [ -d "${JOB_DIR}/task/final_model" ]; then
        echo "Persisting final_model to results dir (overlay still active)..."
        cp -r "${JOB_DIR}/task/final_model" "$EVAL_DIR/final_model"
        echo "final_model persisted: $(du -sh "$EVAL_DIR/final_model" 2>/dev/null | cut -f1)"
    else
        echo "WARNING: No final_model found after solve"
    fi

    return $solve_exit
}

# --- Network probe (runs on HOST, not inside container) ---
# Detects HF/PyPI mirrors, validates cache, sets env vars for container passthrough.
# Depends on globals: REPO_ROOT, EVAL_DIR, HF_HOME
network_probe() {
    local task="$1"
    local model="$2"

    echo "=== NETWORK PROBE ==="

    # 1. HF endpoint selection
    local hf_unreachable=false
    if [ -n "${HF_ENDPOINT:-}" ]; then
        local hf_speed
        hf_speed=$(curl -m 5 -s -o /dev/null -w '%{speed_download}' "${HF_ENDPOINT}/api/models" 2>/dev/null || echo "0")
        hf_speed="${hf_speed//[^0-9.]/}"
        if awk "BEGIN{exit(${hf_speed:-0} > 1000 ? 0 : 1)}"; then
            echo "  [INFO] HF_ENDPOINT=${HF_ENDPOINT} reachable (${hf_speed} B/s)"
        else
            echo "  [WARN] HF_ENDPOINT=${HF_ENDPOINT} unreachable, probing alternatives..."
            unset HF_ENDPOINT
        fi
    fi

    if [ -z "${HF_ENDPOINT:-}" ]; then
        local speed_mirror speed_direct
        speed_mirror=$(curl -m 5 -s -o /dev/null -w '%{speed_download}' "https://hf-mirror.com/api/models" 2>/dev/null || echo "0")
        speed_mirror="${speed_mirror//[^0-9.]/}"
        speed_direct=$(curl -m 5 -s -o /dev/null -w '%{speed_download}' "https://huggingface.co/api/models" 2>/dev/null || echo "0")
        speed_direct="${speed_direct//[^0-9.]/}"

        local max_speed
        max_speed=$(awk "BEGIN{print (${speed_mirror:-0} > ${speed_direct:-0}) ? ${speed_mirror:-0} : ${speed_direct:-0}}")
        if awk "BEGIN{exit(${max_speed:-0} > 1000 ? 0 : 1)}"; then
            if awk "BEGIN{exit(${speed_mirror:-0} >= ${speed_direct:-0} ? 0 : 1)}"; then
                export HF_ENDPOINT="https://hf-mirror.com"
            else
                export HF_ENDPOINT="https://huggingface.co"
            fi
            echo "  [INFO] Auto-selected HF_ENDPOINT=${HF_ENDPOINT}"
        else
            hf_unreachable=true
            echo "  [WARN] Both hf-mirror.com and huggingface.co unreachable"
        fi
    fi

    # 2. PyPI mirror selection
    if [ -z "${UV_INDEX_URL:-}" ]; then
        local speed_aliyun speed_pypi
        speed_aliyun=$(curl -m 5 -s -o /dev/null -w '%{speed_download}' "https://mirrors.aliyun.com/pypi/simple/pip/" 2>/dev/null || echo "0")
        speed_aliyun="${speed_aliyun//[^0-9.]/}"
        speed_pypi=$(curl -m 5 -s -o /dev/null -w '%{speed_download}' "https://pypi.org/simple/pip/" 2>/dev/null || echo "0")
        speed_pypi="${speed_pypi//[^0-9.]/}"

        if awk "BEGIN{exit(${speed_aliyun:-0} >= ${speed_pypi:-0} ? 0 : 1)}" && \
           awk "BEGIN{exit(${speed_aliyun:-0} > 1000 ? 0 : 1)}"; then
            export UV_INDEX_URL="https://mirrors.aliyun.com/pypi/simple/"
            echo "  [INFO] Auto-selected UV_INDEX_URL=${UV_INDEX_URL}"
        elif awk "BEGIN{exit(${speed_pypi:-0} > 1000 ? 0 : 1)}"; then
            echo "  [INFO] pypi.org reachable, using default"
        fi
    else
        echo "  [INFO] UV_INDEX_URL=${UV_INDEX_URL} (from host)"
    fi

    # 3. Cache completeness check
    local model_ok=true
    local eval_ok=true
    local cache_missing=()

    # 3a. Model cache (check host $HF_HOME, which gets bind-mounted into container)
    local model_org model_name model_cache_dir
    model_org=$(echo "$model" | cut -d'/' -f1)
    model_name=$(echo "$model" | cut -d'/' -f2)
    model_cache_dir="${HF_HOME}/hub/models--${model_org}--${model_name}"
    if [ -d "$model_cache_dir" ]; then
        local safetensor_count
        safetensor_count=$(find "$model_cache_dir" -name "*.safetensors" -size +0c 2>/dev/null | head -1 | wc -l)
        if [ "$safetensor_count" -gt 0 ]; then
            echo "  [PASS] Model cache: ${model_org}/${model_name}"
        else
            model_ok=false
            cache_missing+=("model:${model}")
            echo "  [FAIL] Model cache: ${model_org}/${model_name} — no valid safetensors"
        fi
    else
        model_ok=false
        cache_missing+=("model:${model}")
        echo "  [FAIL] Model cache: ${model_org}/${model_name} — directory missing"
    fi

    # 3b. Eval dataset cache
    local deps_file="${REPO_ROOT}/src/eval/tasks/${task}/dataset_deps.json"
    if [ -f "$deps_file" ]; then
        local dataset_id is_local revision
        IFS='|' read -r dataset_id is_local revision < <(python3 -c "
import json; d=json.load(open('${deps_file}'))
print('|'.join([d.get('dataset_id') or '', str(d.get('local', False)), d.get('revision') or '']))
")

        if [ "$is_local" = "True" ]; then
            echo "  [SKIP] Eval dataset: local JSONL (${task})"
        elif [ -n "$dataset_id" ]; then
            local ds_org ds_name ds_cache_dir
            ds_org=$(echo "$dataset_id" | cut -d'/' -f1)
            ds_name=$(echo "$dataset_id" | cut -d'/' -f2)
            ds_cache_dir="${HF_HOME}/datasets/${ds_org}--${ds_name}"

            if [ -d "$ds_cache_dir" ]; then
                if [ -n "$revision" ]; then
                    local snap_dir="${ds_cache_dir}/snapshots/${revision}"
                    if [ -d "$snap_dir" ]; then
                        echo "  [PASS] Eval dataset: ${dataset_id} (revision ${revision:0:7})"
                    else
                        eval_ok=false
                        cache_missing+=("dataset:${dataset_id}@${revision:0:7}")
                        echo "  [FAIL] Eval dataset: ${dataset_id} — revision snapshot missing"
                    fi
                else
                    echo "  [PASS] Eval dataset: ${dataset_id}"
                fi
            else
                eval_ok=false
                cache_missing+=("dataset:${dataset_id}")
                echo "  [FAIL] Eval dataset: ${dataset_id} — directory missing"
            fi
        fi
    else
        echo "  [WARN] No dataset_deps.json for task: ${task}"
    fi

    # 4. Decision
    if [ "$hf_unreachable" = true ]; then
        if [ "$model_ok" = true ] && [ "$eval_ok" = true ]; then
            echo "  [WARN] HF offline, but cache sufficient — continuing"
        else
            echo "  [FATAL] HF offline and cache incomplete: ${cache_missing[*]}"
            echo "{\"status\":\"error\",\"error_type\":\"network_probe_failed\",\"error_message\":\"HF unreachable and cache missing: ${cache_missing[*]}\",\"timestamp\":\"$(date -Iseconds)\",\"hf_reachable\":false,\"cache_missing\":[$(printf '\"%s\",' "${cache_missing[@]}" | sed 's/,$//')]}" > "${EVAL_DIR}/status.json"
            return 1
        fi
    else
        echo "  [INFO] Network OK — HF reachable as fallback"
    fi

    echo "=== NETWORK PROBE DONE ==="
    return 0
}

resolve_gpu_uuid() {
    local cuda_dev="${1:-${CUDA_VISIBLE_DEVICES:-0}}"
    local uuid
    uuid=$(nvidia-smi --query-gpu=uuid --format=csv,noheader -i "$cuda_dev" 2>/dev/null | head -1)
    echo "${uuid:-$cuda_dev}"
}

solve_task() {
    # Resolve GPU UUID for --nvccli hardware isolation (index-based fails for non-GPU-0)
    export NVIDIA_VISIBLE_DEVICES="$(resolve_gpu_uuid)"

    # Dry-run: 1 min timeout (PONG should take <30s). Normal: full budget + 5 min grace.
    local TIMEOUT_MINS
    if [ "$DRY_RUN" = true ]; then
        TIMEOUT_MINS=1
    else
        TIMEOUT_MINS=$((NUM_HOURS * 60 + 5))
    fi

    timeout --signal=TERM --kill-after=30s "${TIMEOUT_MINS}m" \
    apptainer exec \
        --nvccli \
        --env PATH="/root/.local/bin:/home/ben/.local/bin:$PATH" \
        --env HF_HOME="${HF_HOME_NEW}" \
        --env ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}" \
        --env CODEX_API_KEY="${CODEX_API_KEY}" \
        --env GEMINI_API_KEY="${GEMINI_API_KEY}" \
        --env HORAY_API_KEY="${HORAY_API_KEY}" \
        --env AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}" \
        --env AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}" \
        --env AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}" \
        --env VLLM_API_KEY="inspectai" \
        --env PYTHONNOUSERSITE="1" \
        --env PROMPT="${PROMPT}" \
        --env AGENT_CONFIG="${AGENT_CONFIG}" \
        --env NVIDIA_VISIBLE_DEVICES="${NVIDIA_VISIBLE_DEVICES}" \
        --env CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0}" \
        --env LEMMA_MAAS_BASE_URL="${LEMMA_MAAS_BASE_URL:-}" \
        --env LEMMA_MAAS_API_KEY="${LEMMA_MAAS_API_KEY:-}" \
        --env HF_ENDPOINT="${HF_ENDPOINT:-}" \
        --env HF_TOKEN="${HF_TOKEN:-}" \
        --env UV_INDEX_URL="${UV_INDEX_URL:-}" \
        --bind "${JOB_TMP}:/tmp" \
        --bind "${HF_MERGED}:${HF_HOME_NEW}" \
        ${LOCAL_LEMMA_BIND:+--bind "${LOCAL_LEMMA_BIND}:/opt/local-lemma"} \
        ${UV_HOST_DIR:+--bind "${UV_HOST_DIR}:/opt/uv-bin"} \
        ${RG_HOST_DIR:+--bind "${RG_HOST_DIR}:/opt/rg-bin"} \
        --home "${JOB_DIR}:/home/ben" \
        --pwd "/home/ben/task" \
        --writable-tmpfs \
        "${POST_TRAIN_BENCH_CONTAINERS_DIR}/${POST_TRAIN_BENCH_CONTAINER_NAME}.sif" \
        bash -c "python3 /home/ben/check_cuda.py && python3 /home/ben/check_cuda_writing.py && bash /home/ben/agent_solve.sh" > "${SOLVE_OUT}" 2>&1
}

export REPO_ROOT="$(pwd)"

if [ "$SKIP_NETWORK_PROBE" = false ]; then
    if ! network_probe "$EVALUATION_TASK" "$MODEL_TO_TRAIN"; then
        echo "Network probe FAILED — aborting job"
        exit 1
    fi
fi

echo "================================"
echo "========= RUNNING TASK ========="
echo "================================"

with_huggingface_overlay with_record_the_time solve_and_persist
SOLVE_EXIT=$?

# ── Dry-run: check PONG + vLLM smoke test, then exit ──
if [ "$DRY_RUN" = true ]; then
    cleanup_dryrun() { rm -rf "${TMP_SUBDIR}" "${EVAL_DIR}" 2>/dev/null; }
    trap cleanup_dryrun EXIT

    # Step 1: Agent PONG check
    if grep -q "PONG" "${SOLVE_OUT}" 2>/dev/null; then
        echo "DRY-RUN: agent PONG — OK"
    else
        echo "DRY-RUN FAIL: no PONG in solve_out (exit=$SOLVE_EXIT)"
        echo "--- solve_out tail ---"
        tail -20 "${SOLVE_OUT}" 2>/dev/null
        exit 1
    fi

    # Step 2: vLLM eval chain test — serve base model, health check, one inference
    echo "DRY-RUN: testing vLLM eval chain with base model..."
    export NVIDIA_VISIBLE_DEVICES="$(resolve_gpu_uuid)"
    VLLM_PORT=$((40000 + RANDOM % 10000))

    # Determine chat template
    CHAT_TEMPLATE=""
    case "$MODEL_TO_TRAIN" in
        *gemma*)  CHAT_TEMPLATE="src/eval/templates/gemma3.jinja" ;;
        *Qwen*)   CHAT_TEMPLATE="src/eval/templates/qwen3.jinja" ;;
        *SmolLM*) CHAT_TEMPLATE="src/eval/templates/smollm.jinja" ;;
    esac
    TEMPLATE_ARG=""
    [ -n "$CHAT_TEMPLATE" ] && TEMPLATE_ARG="--chat-template ${REPO_ROOT}/${CHAT_TEMPLATE}"

    timeout 150s apptainer exec --nvccli \
        --env "HF_HOME=${HF_MERGED}" \
        --env VLLM_API_KEY="inspectai" \
        --env HF_ENDPOINT="${HF_ENDPOINT:-}" \
        --env TMPDIR="${JOB_TMP}" \
        --writable-tmpfs \
        --bind "${HF_MERGED}:${HF_MERGED}" \
        --bind "${REPO_ROOT}:${REPO_ROOT}" \
        "${CONTAINER}" \
        vllm serve "${MODEL_TO_TRAIN}" \
            --host 0.0.0.0 --port ${VLLM_PORT} \
            --api-key inspectai \
            --gpu-memory-utilization 0.5 \
            --max-model-len 512 \
            ${TEMPLATE_ARG} \
        > "${EVAL_DIR}/dryrun_vllm.log" 2>&1 &
    VLLM_PID=$!

    # Wait for health (up to 120s, faster polling initially)
    VLLM_OK=false
    for i in $(seq 1 60); do
        if curl -sf "http://localhost:${VLLM_PORT}/health" >/dev/null 2>&1; then
            VLLM_OK=true; break
        fi
        if ! kill -0 $VLLM_PID 2>/dev/null; then
            echo "DRY-RUN FAIL: vLLM process died"
            tail -20 "${EVAL_DIR}/dryrun_vllm.log" 2>/dev/null
            exit 1
        fi
        [ $i -le 20 ] && sleep 1 || sleep 3
    done

    if [ "$VLLM_OK" = false ]; then
        echo "DRY-RUN FAIL: vLLM health timeout (120s)"
        kill $VLLM_PID 2>/dev/null; wait $VLLM_PID 2>/dev/null
        tail -20 "${EVAL_DIR}/dryrun_vllm.log" 2>/dev/null
        exit 1
    fi

    # One chat completion
    RESP=$(curl -sf -X POST "http://localhost:${VLLM_PORT}/v1/chat/completions" \
        -H "Authorization: Bearer inspectai" \
        -H "Content-Type: application/json" \
        -d '{"model":"'"${MODEL_TO_TRAIN}"'","messages":[{"role":"user","content":"Say hi"}],"max_tokens":5}' \
        2>/dev/null)

    kill $VLLM_PID 2>/dev/null; wait $VLLM_PID 2>/dev/null

    if echo "$RESP" | python3 -c "import sys,json; c=json.load(sys.stdin)['choices'][0]; print('OK')" >/dev/null 2>&1; then
        echo "DRY-RUN: vLLM inference — OK"
    else
        echo "DRY-RUN FAIL: vLLM inference failed"
        echo "  response: $RESP"
        exit 1
    fi

    echo ""
    echo "DRY-RUN PASS: agent + vLLM all OK"
    exit 0
fi

# Detect silent training failure: compare final_model vs base_model checksums
if [ -d "$EVAL_DIR/final_model" ]; then
    FINAL_CKSUM=$(find "$EVAL_DIR/final_model" -name "*.safetensors" -exec sha256sum {} + 2>/dev/null | sort | sha256sum | cut -d' ' -f1)
    BASE_MODEL_HF=$(echo "$MODEL_TO_TRAIN" | sed 's|/|--|g')
    BASE_CKSUM=$(find "${HF_HOME}/hub/models--${BASE_MODEL_HF}" -name "*.safetensors" -exec sha256sum {} + 2>/dev/null | sort | sha256sum | cut -d' ' -f1)

    if [ "$FINAL_CKSUM" = "$BASE_CKSUM" ] && [ -n "$FINAL_CKSUM" ]; then
        echo "WARNING: final_model checksum matches base_model — training may have failed silently"
        echo "TRAINING_SILENT_FAIL" > "$EVAL_DIR/training_status.txt"
    else
        echo "TRAINING_OK" > "$EVAL_DIR/training_status.txt"
    fi
fi

echo "--- SOLVE DIAGNOSTICS ---"
echo "exit_code: $SOLVE_EXIT"
if [ $SOLVE_EXIT -eq 0 ]; then
    echo "status: exited normally"
elif [ $SOLVE_EXIT -eq 124 ]; then
    echo "status: killed by timeout (reached ${NUM_HOURS}h limit)"
elif [ $SOLVE_EXIT -gt 128 ]; then
    echo "status: killed by signal $((SOLVE_EXIT - 128)) ($(kill -l $((SOLVE_EXIT - 128)) 2>/dev/null || echo unknown))"
else
    echo "status: exited with error code $SOLVE_EXIT"
fi
echo "final_model_files: $(ls "${JOB_DIR}/task/final_model/" 2>/dev/null | wc -l)"
echo "hostname: $(hostname)"
echo "fuse_overlayfs_alive: $(ps aux 2>/dev/null | grep fuse-overlay | grep -v grep | wc -l)"
echo "disk_job_dir: $(du -sh "${JOB_DIR}" 2>/dev/null | cut -f1)"
echo "disk_tmp: $(du -sh "${JOB_TMP}" 2>/dev/null | cut -f1)"
echo "memory: $(free -m 2>/dev/null | grep Mem | awk '{print "total=" $2 "MB used=" $3 "MB free=" $4 "MB"}')"
echo "--- END SOLVE DIAGNOSTICS ---"

echo "============================================"
echo "=== TASK COMPLETE, PARSING AGENT TRACE ==="
echo "============================================"

# Parse agent trace into human-readable format
TRACE_PARSER="agents/${AGENT}/human_readable_trace.py"
if [ -f "$TRACE_PARSER" ]; then
    python3 "$TRACE_PARSER" "${SOLVE_OUT}" -o "${EVAL_DIR}/solve_parsed.txt"
    cp "${EVAL_DIR}/solve_parsed.txt" "${JOB_DIR}/solve_parsed.txt"
else
    echo "Warning: No trace parser found at $TRACE_PARSER, using raw output"
    cp "${SOLVE_OUT}" "${JOB_DIR}/solve_parsed.txt"
fi

echo "========================================="
echo "=== RUNNING CONTAMINATION JUDGE ==="
echo "========================================="

JUDGE_TASK=$(python3 src/disallowed_usage_judge/get_judge_prompt.py --benchmark "${BENCHMARK}" --model "${MODEL_TO_TRAIN}")

with_huggingface_overlay apptainer exec \
    --nv \
    -c \
    --env PATH="/root/.local/bin:/home/ben/.local/bin:$PATH" \
    --env HF_HOME="${HF_HOME_NEW}" \
    --env CODEX_API_KEY="${CODEX_API_KEY}" \
    --env HORAY_API_KEY="${HORAY_API_KEY}" \
    --env VLLM_API_KEY="inspectai" \
    --env PYTHONNOUSERSITE="1" \
    --env HF_ENDPOINT="${HF_ENDPOINT:-}" \
    --env HF_TOKEN="${HF_TOKEN:-}" \
    --bind "${JOB_TMP}:/tmp" \
    --bind "${HF_MERGED}:${HF_HOME_NEW}" \
    --home "${JOB_DIR}:/home/ben" \
    --pwd "/home/ben/task" \
    --writable-tmpfs \
    ${POST_TRAIN_BENCH_CONTAINERS_DIR}/${POST_TRAIN_BENCH_CONTAINER_NAME}.sif codex --search -a never exec --json -c model_reasoning_summary=detailed -c 'model_provider="horay"' -c 'disable_response_storage=true' --skip-git-repo-check --yolo --model "g5.2-rxj" "$JUDGE_TASK" 2>&1 | tee "${EVAL_DIR}/judge_output.json"

# Convert judge JSON output to human-readable format
python3 agents/codex/human_readable_trace.py "${EVAL_DIR}/judge_output.json" -o "${EVAL_DIR}/judge_output.txt"

cp "${JOB_DIR}/task/contamination_judgement.txt" "${EVAL_DIR}/contamination_judgement.txt"
cp "${JOB_DIR}/task/disallowed_model_judgement.txt" "${EVAL_DIR}/disallowed_model_judgement.txt"

echo "============================="
echo "======== CLEANING UP ========"
echo "============================="

echo "Task directory contents:"
tree ${JOB_DIR}/task
echo "================================"

# Fallback: copy if not already persisted by solve_and_persist
if [ -d "${JOB_DIR}/task/final_model" ] && [ ! -d "$EVAL_DIR/final_model" ]; then
    cp -r "${JOB_DIR}/task/final_model" "$EVAL_DIR/final_model"
fi

python3 containers/delete_hf_models.py "${JOB_DIR}/task"

cp -r "${JOB_DIR}/task" "$EVAL_DIR/task"

rm -rf "${TMP_SUBDIR}"

echo "================================"
echo "========= EVALUATING ==========="
echo "================================"

# Guard: skip eval if final_model is missing or empty
# Distinguish between agent crash (exit 1) vs agent ran full time but no model (exit 0)
SOLVE_TIME_SECS=-1
if [ -f "$EVAL_DIR/time_taken.txt" ]; then
    IFS=: read -r hh mm ss < "$EVAL_DIR/time_taken.txt"
    SOLVE_TIME_SECS=$(( 10#${hh:-0} * 3600 + 10#${mm:-0} * 60 + 10#${ss:-0} ))
fi
BUDGET_SECS=$((NUM_HOURS * 3600))
# Agent crash = non-zero exit OR ran less than 10% of budget OR no time_taken.txt
AGENT_CRASHED=false
if [ "${SOLVE_EXIT:-0}" -ne 0 ] && [ "${SOLVE_EXIT:-0}" -ne 124 ]; then
    AGENT_CRASHED=true
elif [ "$SOLVE_TIME_SECS" -eq -1 ]; then
    # time_taken.txt missing = solve phase didn't complete normally
    AGENT_CRASHED=true
elif [ "$SOLVE_TIME_SECS" -gt 0 ] && [ "$SOLVE_TIME_SECS" -lt $((BUDGET_SECS / 10)) ]; then
    AGENT_CRASHED=true
fi

NO_MODEL=false
if [ ! -d "$EVAL_DIR/final_model" ]; then
    NO_MODEL=true
else
    SAFETENSOR_COUNT=$(find "$EVAL_DIR/final_model" -name "*.safetensors" -size +0c 2>/dev/null | wc -l)
    [ "$SAFETENSOR_COUNT" -eq 0 ] && NO_MODEL=true
fi

if [ "$NO_MODEL" = true ]; then
    if [ "$AGENT_CRASHED" = true ]; then
        echo "AGENT CRASH: no final_model, solve_exit=${SOLVE_EXIT:-?}, ran ${SOLVE_TIME_SECS}s of ${BUDGET_SECS}s budget"
        echo "{\"error\": \"agent_crash\", \"solve_exit\": ${SOLVE_EXIT:-0}, \"solve_time_secs\": $SOLVE_TIME_SECS, \"accuracy\": null}" > "${EVAL_DIR}/metrics.json"
        exit 1
    else
        echo "SKIP EVAL: agent completed but no final_model (ran ${SOLVE_TIME_SECS}s)"
        echo "{\"error\": \"no_final_model\", \"solve_time_secs\": $SOLVE_TIME_SECS, \"accuracy\": null}" > "${EVAL_DIR}/metrics.json"
        exit 0
    fi
fi
echo "final_model OK: $SAFETENSOR_COUNT safetensors files"

export REPO_ROOT="$(pwd)"

export TMP_HF_CACHE="${PTB_TMP_BASE}/hf_cache_90afd0"

export EVAL_COUNTER=0

run_evaluation() {
    local max_tokens_arg="$1"
    local eval_num="$2"
    # Kill ALL GPU processes on our device (training may have leaked to other contexts)
    nvidia-smi --id="${CUDA_VISIBLE_DEVICES:-0}" --query-compute-apps=pid --format=csv,noheader | xargs -r kill -9 2>/dev/null || true
    # Kill leaked vLLM server processes (scoped to avoid killing the running agent)
    pgrep -u "$(id -u)" -f "vllm serve|vllm.entrypoints" | grep -v "^$$" | xargs -r kill -9 2>/dev/null || true
    # Wait for GPU memory to actually free
    for _wait in $(seq 1 10); do
        GPU_USED=$(nvidia-smi --id="${CUDA_VISIBLE_DEVICES:-0}" --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1)
        [ "${GPU_USED:-99999}" -lt 500 ] && break
        sleep 2
    done
    with_huggingface_overlay apptainer exec \
        --nv \
        --env "HF_HOME=${TMP_HF_CACHE}" \
        --env OPENAI_API_KEY="${OPENAI_API_KEY}" \
        --env VLLM_API_KEY="inspectai" \
        --env PYTHONNOUSERSITE="1" \
        --env HF_ENDPOINT="${HF_ENDPOINT:-}" \
        --env HF_TOKEN="${HF_TOKEN:-}" \
        --writable-tmpfs \
        --bind "${REPO_ROOT}:${REPO_ROOT}" \
        --bind "${HF_MERGED}:${TMP_HF_CACHE}" \
        --bind "${EVAL_DIR}:${EVAL_DIR}" \
        --pwd "$(pwd)/src/eval/tasks/${EVALUATION_TASK}" \
        ${POST_TRAIN_BENCH_CONTAINERS_DIR}/${POST_TRAIN_BENCH_CONTAINER_NAME}.sif python "evaluate.py" \
            --model-path "$EVAL_DIR/final_model" \
            --templates-dir ../../../../src/eval/templates \
            --limit -1 \
            ${max_tokens_arg} \
            --json-output-file "${EVAL_DIR}/metrics.json" > "$EVAL_DIR/final_eval_${eval_num}.txt"
}

run_evaluation_with_retry() {
    local max_retries="$1"
    local max_tokens_arg="$2"

    for ((attempt=1; attempt<=max_retries; attempt++)); do
        sleep 5
        if [ -f "${EVAL_DIR}/metrics.json" ]; then
            return 0
        fi

        EVAL_COUNTER=$((EVAL_COUNTER + 1))
        export EVAL_COUNTER
        echo "Evaluation attempt $EVAL_COUNTER (phase attempt $attempt of $max_retries)"

        timeout --signal=TERM --kill-after=60s 28800s bash -c "$(declare -f run_evaluation with_huggingface_overlay); run_evaluation \"$max_tokens_arg\" \"$EVAL_COUNTER\""

        if [ -f "${EVAL_DIR}/metrics.json" ]; then
            return 0
        fi
    done

    return 1
}

# First evaluation: up to 4 attempts
run_evaluation_with_retry 4 ""

# Second evaluation with adjusted max tokens: up to 2 attempts
case "${EVALUATION_TASK}" in
    aime2025)
        MAX_TOKENS_ARG="--max-tokens 12000"
        ;;
    arenahardwriting)
        MAX_TOKENS_ARG="--max-new-tokens 12288"
        ;;
    bfcl)
        MAX_TOKENS_ARG="--max-tokens 12000"
        ;;
    gpqamain)
        MAX_TOKENS_ARG="--max-tokens 12000"
        ;;
    gsm8k)
        MAX_TOKENS_ARG="--max-tokens 3000"
        ;;
    healthbench)
        MAX_TOKENS_ARG="--max-new-tokens 12288"
        ;;
    humaneval)
        MAX_TOKENS_ARG="--max-tokens 3000"
        ;;
    *)
        MAX_TOKENS_ARG=""
        ;;
esac

run_evaluation_with_retry 3 "$MAX_TOKENS_ARG"

# Third evaluation with further adjusted max tokens: up to 2 attempts
case "${EVALUATION_TASK}" in
    aime2025)
        MAX_TOKENS_ARG="--max-tokens 8000"
        ;;
    arenahardwriting)
        MAX_TOKENS_ARG="--max-new-tokens 8192"
        ;;
    bfcl)
        MAX_TOKENS_ARG="--max-tokens 8000"
        ;;
    gpqamain)
        MAX_TOKENS_ARG="--max-tokens 8000"
        ;;
    gsm8k)
        MAX_TOKENS_ARG="--max-tokens 2000"
        ;;
    healthbench)
        MAX_TOKENS_ARG="--max-new-tokens 8192"
        ;;
    humaneval)
        MAX_TOKENS_ARG="--max-tokens 2000"
        ;;
    *)
        MAX_TOKENS_ARG=""
        ;;
esac

run_evaluation_with_retry 2 "$MAX_TOKENS_ARG"

echo $(cat "$EVAL_DIR/final_eval_${EVAL_COUNTER}.txt")

echo "================================"
echo "======= EVALUATION DONE ========"
echo "================================"