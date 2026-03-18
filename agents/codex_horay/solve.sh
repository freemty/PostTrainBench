#!/bin/bash
# codex_horay agent: uses codex CLI with Horay.ai proxy
# Supports GPT models (g5.2-rxj) and Gemini models (ge3.1-pro-rxj) on CN servers
# AGENT_CONFIG should be a horay model alias (e.g., g5.2-rxj, ge3.1-pro-rxj)

unset ANTHROPIC_API_KEY
unset GEMINI_API_KEY
unset OPENAI_API_KEY

codex --search exec --json \
  -c model_reasoning_summary=detailed \
  -c "model_provider=\"horay\"" \
  -c "disable_response_storage=true" \
  --skip-git-repo-check --yolo \
  --model "$AGENT_CONFIG" \
  "$PROMPT"
