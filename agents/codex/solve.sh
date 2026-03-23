#!/bin/bash

unset ANTHROPIC_API_KEY
unset GEMINI_API_KEY

# Defensive: ensure .codex is a directory (prevents ENOTDIR-class crashes)
[ -f "$HOME/.codex" ] && rm -f "$HOME/.codex"
mkdir -p "$HOME/.codex"

codex --search exec --json -c model_reasoning_summary=detailed --skip-git-repo-check --yolo --model "$AGENT_CONFIG" "$PROMPT"