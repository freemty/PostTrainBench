#!/bin/bash
# lemma agent — local-lemma as agent runtime
# Requires: local-lemma bind-mounted at /opt/local-lemma

unset GEMINI_API_KEY
unset CODEX_API_KEY

LEMMA_ROOT="/opt/local-lemma"

if [ ! -d "$LEMMA_ROOT/local_backend" ]; then
    echo "ERROR: local-lemma not found at $LEMMA_ROOT"
    echo "Ensure run_task.sh has --bind for local-lemma"
    exit 1
fi

# Install lemma dependencies if needed (first run only in writable-tmpfs)
if ! python3 -c "import local_backend" 2>/dev/null; then
    echo "Installing local-lemma dependencies..."
    cd "$LEMMA_ROOT" && pip install -e . --quiet 2>&1 | tail -5
    cd /home/ben/task
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

model_id = 'anthropic.claude-opus-4-6-v1' if '$LEMMA_MODEL' == 'opus' else 'anthropic.claude-sonnet-4-6-v1'

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

# Run lemma in batch mode
python3 -m local_backend.run \
    --repo-root "$LEMMA_ROOT" \
    --working-dir /home/ben/task \
    --user "$PROMPT" \
    --max-turns -1 \
    --model "$LEMMA_MODEL" \
    --auto-confirm
