#!/bin/bash
# codex_horay agent: uses codex CLI with Horay.ai proxy
# Supports GPT models (g5.2-rxj) and Gemini models (ge3.1-pro-rxj) on CN servers
# AGENT_CONFIG should be a horay model alias (e.g., g5.2-rxj, ge3.1-pro-rxj)

unset ANTHROPIC_API_KEY
unset GEMINI_API_KEY
unset OPENAI_API_KEY

# Gemini models need chat completions API (responses API returns 502)
if [[ "$AGENT_CONFIG" == ge* ]]; then
    HORAY_PROVIDER="horay_chat"
else
    HORAY_PROVIDER="horay"
fi

# exp01b original command — --search before exec enables multi-turn autonomous mode
codex --search exec --json \
  -c model_reasoning_summary=detailed \
  -c "model_provider=\"${HORAY_PROVIDER}\"" \
  -c "disable_response_storage=true" \
  --skip-git-repo-check --yolo \
  --model "$AGENT_CONFIG" \
  "$PROMPT"
