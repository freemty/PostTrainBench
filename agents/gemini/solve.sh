#!/bin/bash

export GEMINI_SANDBOX="false"

# Defensive: ensure CLI config dirs exist (prevents ENOTDIR-class crashes)
mkdir -p "$HOME/.config/gemini" "$HOME/.cache/gemini" 2>/dev/null || true

gemini --yolo --model "$AGENT_CONFIG" --output-format stream-json -p "$PROMPT"