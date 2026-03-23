#!/bin/bash

unset ANTHROPIC_API_KEY
unset GEMINI_API_KEY

[ -f "$HOME/.codex" ] && rm -f "$HOME/.codex"
mkdir -p "$HOME/.codex"

file=/home/ben/.codex/config.toml
tmp="$(mktemp)"
printf 'model_reasoning_effort = "high"\n\n' > "$tmp"
[ -f "$file" ] && cat "$file" >> "$tmp"
mv "$tmp" "$file"

codex --search exec --skip-git-repo-check --yolo --model "$AGENT_CONFIG" "$PROMPT"