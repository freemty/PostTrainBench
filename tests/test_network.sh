#!/usr/bin/env bash
# test_network.sh — Network reachability + HF cache completeness check
# Usage: bash tests/test_network.sh [--task <task>...] [--model <model>...]
#
# No-args mode: checks HF/PyPI connectivity only.
# With --task/--model: also checks cache completeness.
#
# Examples:
#   bash tests/test_network.sh --task gsm8k --task humaneval --model Qwen/Qwen3-4B
#   bash tests/test_network.sh  # connectivity only

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"
source "${SCRIPT_DIR}/preflight_utils.sh"

TASKS=()
MODELS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --task) TASKS+=("$2"); shift 2 ;;
        --model) MODELS+=("$2"); shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"
HF_HOME="${HF_HOME:-${HOME}/.cache/huggingface}"

# ── Network Reachability ─────────────────────────────────────
echo "--- Network Reachability ---"

hf_reachable=false
if curl -m 5 -sf "${HF_ENDPOINT}/api/models" -o /dev/null 2>/dev/null; then
    pass "HF_ENDPOINT (${HF_ENDPOINT}) reachable"
    hf_reachable=true
else
    fail "HF_ENDPOINT (${HF_ENDPOINT}) unreachable"
fi

if curl -m 5 -sf "https://huggingface.co/api/models" -o /dev/null 2>/dev/null; then
    pass "huggingface.co direct reachable"
    hf_reachable=true
else
    warn "huggingface.co direct unreachable"
fi

pypi_reachable=false
pypi_url="${UV_INDEX_URL:-https://mirrors.aliyun.com/pypi/simple/}"
if curl -m 5 -sf "${pypi_url}pip/" -o /dev/null 2>/dev/null; then
    pass "PyPI mirror (${pypi_url}) reachable"
    pypi_reachable=true
else
    fail "PyPI mirror (${pypi_url}) unreachable"
fi

# ── End-to-End Verification ──────────────────────────────────
echo "--- End-to-End Verification ---"

if [ "$hf_reachable" = true ]; then
    if curl -m 10 -sfI "${HF_ENDPOINT}/api/datasets/openai/gsm8k" -o /dev/null 2>/dev/null; then
        pass "HF API: datasets/openai/gsm8k accessible"
    else
        fail "HF API: datasets/openai/gsm8k NOT accessible"
    fi
else
    skip "HF API check (HF unreachable)"
fi

if [ "$pypi_reachable" = true ]; then
    if command -v uv >/dev/null 2>&1; then
        if uv pip install --dry-run httpx 2>/dev/null; then
            pass "uv pip install --dry-run httpx"
        else
            warn "uv pip install --dry-run failed (may not support --dry-run)"
        fi
    else
        skip "uv not available on host"
    fi
else
    skip "PyPI check (PyPI unreachable)"
fi

# ── Cache Completeness ───────────────────────────────────────
echo "--- Cache Completeness ---"

if [ ${#MODELS[@]} -eq 0 ] && [ ${#TASKS[@]} -eq 0 ]; then
    skip "No --model or --task specified, skipping cache check"
fi

for model in "${MODELS[@]}"; do
    model_org=$(echo "$model" | cut -d'/' -f1)
    model_name=$(echo "$model" | cut -d'/' -f2)
    cache_dir="${HF_HOME}/hub/models--${model_org}--${model_name}"

    if [ -d "$cache_dir" ]; then
        st_count=$(find "$cache_dir" -name "*.safetensors" -size +0c 2>/dev/null | head -1 | wc -l)
        if [ "$st_count" -gt 0 ]; then
            pass "Model cached: ${model}"
        else
            fail "Model cached but no valid safetensors: ${model}"
        fi
    else
        if [ "$hf_reachable" = true ]; then
            warn "Model not cached: ${model} (HF reachable, can download at runtime)"
        else
            fail "Model not cached: ${model} (HF unreachable!)"
        fi
    fi
done

for task in "${TASKS[@]}"; do
    deps_file="${REPO_ROOT}/src/eval/tasks/${task}/dataset_deps.json"
    if [ ! -f "$deps_file" ]; then
        warn "No dataset_deps.json for task: ${task}"
        continue
    fi

    read -r dataset_id is_local revision < <(python3 -c "
import json; d=json.load(open('${deps_file}'))
print(d.get('dataset_id') or '', d.get('local', False), d.get('revision') or '')
")

    if [ "$is_local" = "True" ]; then
        pass "Eval dataset: ${task} (local JSONL)"
        continue
    fi

    if [ -z "$dataset_id" ]; then
        warn "Eval dataset: ${task} — no dataset_id in deps"
        continue
    fi

    ds_org=$(echo "$dataset_id" | cut -d'/' -f1)
    ds_name=$(echo "$dataset_id" | cut -d'/' -f2)
    ds_cache="${HF_HOME}/datasets/${ds_org}--${ds_name}"

    if [ -d "$ds_cache" ]; then
        if [ -n "$revision" ]; then
            snap="${ds_cache}/snapshots/${revision}"
            if [ -d "$snap" ]; then
                pass "Eval dataset cached: ${dataset_id} (rev ${revision:0:7})"
            else
                fail "Eval dataset cached but revision snapshot missing: ${dataset_id}@${revision:0:7}"
            fi
        else
            pass "Eval dataset cached: ${dataset_id}"
        fi
    else
        if [ "$hf_reachable" = true ]; then
            warn "Eval dataset not cached: ${dataset_id} (HF reachable, can download)"
        else
            fail "Eval dataset not cached: ${dataset_id} (HF unreachable!)"
        fi
    fi
done

summary
