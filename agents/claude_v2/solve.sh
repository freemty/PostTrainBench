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

# Claude Code forbids --dangerously-skip-permissions as root.
# If running as root, create a non-root user and re-exec as that user.
if [ "$(id -u)" -eq 0 ]; then
    useradd -m -s /bin/bash ben 2>/dev/null || true
    # Ensure .claude is a directory with required subdirs (prevents ENOTDIR crash)
    [ -f /home/ben/.claude ] && rm -f /home/ben/.claude
    mkdir -p /home/ben/.claude/{debug,cache,projects}
    # Chown home dir (non-recursive) + working subdirs. Skip hf_cache (hundreds of GB via overlayfs)
    chown ben:ben /home/ben 2>/dev/null || true
    chown -R ben:ben /home/ben/.claude /home/ben/.codex /home/ben/task 2>/dev/null || true
    chown ben:ben /home/ben/*.py /home/ben/*.sh 2>/dev/null || true
    # Re-exec this script as ben, preserving env
    exec su -s /bin/bash -c "
        export BASH_MAX_TIMEOUT_MS='$BASH_MAX_TIMEOUT_MS'
        export AGENT_CONFIG='$AGENT_CONFIG'
        export PROMPT='$PROMPT'
        export HOME=/home/ben
        export PATH='/root/.local/bin:/home/ben/.local/bin:$PATH'
        mkdir -p \\\$HOME/.claude/{debug,cache,projects}
        claude --print --verbose --model \"\$AGENT_CONFIG\" --output-format stream-json \
            --dangerously-skip-permissions \"\$PROMPT\"
    " ben
else
    claude --print --verbose --model "$AGENT_CONFIG" --output-format stream-json \
        --dangerously-skip-permissions "$PROMPT"
fi
