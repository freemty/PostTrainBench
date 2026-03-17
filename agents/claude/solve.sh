#!/bin/bash
unset GEMINI_API_KEY
unset CODEX_API_KEY

export BASH_MAX_TIMEOUT_MS="36000000"

# Map model names to Bedrock model IDs when using Bedrock
if grep -q 'CLAUDE_CODE_USE_BEDROCK' "$HOME/.claude/settings.local.json" 2>/dev/null || \
   [ "${CLAUDE_CODE_USE_BEDROCK:-}" = "1" ]; then
    case "$AGENT_CONFIG" in
        claude-sonnet-4-5|claude-sonnet-4-5-20250514)
            AGENT_CONFIG="anthropic.claude-sonnet-4-5-v1" ;;
        claude-opus-4-5|claude-opus-4-5-20250514)
            AGENT_CONFIG="anthropic.claude-opus-4-5-v1" ;;
        claude-sonnet-4-6|claude-sonnet-4-6-*)
            AGENT_CONFIG="global.anthropic.claude-sonnet-4-6" ;;
        claude-opus-4-6|claude-opus-4-6-*)
            AGENT_CONFIG="global.anthropic.claude-opus-4-6-v1" ;;
    esac
fi

claude --print --verbose --model "$AGENT_CONFIG" --output-format stream-json \
    --dangerously-skip-permissions "$PROMPT"