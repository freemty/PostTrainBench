#!/bin/bash
# lemma agent — local-lemma as agent runtime
# Requires: local-lemma bind-mounted at /opt/local-lemma

unset GEMINI_API_KEY
unset CODEX_API_KEY

# Re-export critical env vars so agent subprocesses (evaluate.py, vllm, huggingface_hub) see them
export VLLM_API_KEY="${VLLM_API_KEY:-inspectai}"
export HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"
export HF_HOME="${HF_HOME:-/home/ben/hf_cache}"
export UV_INDEX_URL="${UV_INDEX_URL:-https://mirrors.aliyun.com/pypi/simple/}"

LEMMA_ROOT="/opt/local-lemma"

# Ensure ripgrep is in PATH (lemma requires it for grep tool)
# rg is bind-mounted from host at /opt/rg-bin/ by run_task.sh
if [ -x "/opt/rg-bin/rg" ]; then
    export PATH="/opt/rg-bin:$PATH"
elif which rg >/dev/null 2>&1; then
    : # already in PATH
else
    echo "WARNING: ripgrep (rg) not found — lemma grep tool may fail"
fi

if [ ! -d "$LEMMA_ROOT/local_backend" ]; then
    echo "ERROR: local-lemma not found at $LEMMA_ROOT"
    echo "Ensure run_task.sh has --bind for local-lemma"
    exit 1
fi

# Add lemma to PYTHONPATH (avoid pip install — /tmp is bind-mounted, uv unreachable)
export PYTHONPATH="$LEMMA_ROOT:$PYTHONPATH"

# Install lemma's missing dependencies via uv
# Search order: bind-mounted uv, container uv, PATH uv
UV_BIN=""
for candidate in "/opt/uv-bin/uv" "/root/.local/bin/uv" "$(which uv 2>/dev/null)"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
        UV_BIN="$candidate"
        break
    fi
done

if [ -n "$UV_BIN" ]; then
    echo "Installing lemma deps (uv pip install -e)..."
    "$UV_BIN" pip install --system -e "$LEMMA_ROOT" 2>&1 | tail -10
    echo "Lemma deps installed."
else
    echo "ERROR: no uv found in container — cannot install lemma deps"
    exit 1
fi

# Map AGENT_CONFIG to lemma model arg
case "$AGENT_CONFIG" in
    *opus*) LEMMA_MODEL="opus" ;;
    *)      LEMMA_MODEL="sonnet" ;;
esac

# Generate lemma config with PTB Bedrock credentials from container env vars
LEMMA_CONFIG_DIR="$LEMMA_ROOT/lead_agent/agents"
python3 -c "
import yaml, os

bedrock_cfg = {
    'provider': 'bedrock',
    'vendor': 'anthropic',
    'aws_access_key': os.environ.get('AWS_ACCESS_KEY_ID', ''),
    'aws_secret_key': os.environ.get('AWS_SECRET_ACCESS_KEY', ''),
    'aws_region': os.environ.get('AWS_REGION', 'us-east-1'),
    'temperature': 1.0,
}

model_id = 'global.anthropic.claude-opus-4-6-v1' if '$LEMMA_MODEL' == 'opus' else 'global.anthropic.claude-sonnet-4-6'

config = {
    'llm': {**bedrock_cfg, 'model': model_id, 'max_tokens': 30000, 'max_context_tokens': 96000, 'thinking_budget_tokens': 4000},
    'compression': {**bedrock_cfg, 'model': model_id, 'max_tokens': 20000},
    'phase': {**bedrock_cfg, 'model': model_id, 'max_tokens': 32000, 'max_context_tokens': 96000, 'thinking_budget_tokens': 4000},
    'token_count': {
        'vendor': 'anthropic', 'provider': 'bedrock', 'model': model_id,
        'aws_access_key': os.environ.get('AWS_ACCESS_KEY_ID', ''),
        'aws_secret_key': os.environ.get('AWS_SECRET_ACCESS_KEY', ''),
        'aws_region': os.environ.get('AWS_REGION', 'us-east-1'),
        'method': 'accurate', 'max_tokens': 4001,
    },
}

with open('$LEMMA_CONFIG_DIR/config.yaml', 'w') as f:
    yaml.dump(config, f, default_flow_style=False)
print(f'Generated lemma config: model={model_id}, region={config[\"llm\"][\"aws_region\"]}')
"

# Dry-run: single turn only (agent says PONG and exits)
if [ "${DRY_RUN:-}" = "true" ]; then
    MAX_TURNS="--max-turns 1"
else
    MAX_TURNS="--max-turns -1"
fi

# Run lemma in batch mode
python3 -m local_backend.run \
    --repo-root "$LEMMA_ROOT" \
    --working-dir /home/ben/task \
    --user "$PROMPT" \
    $MAX_TURNS \
    --model "$LEMMA_MODEL" \
    --auto-confirm
