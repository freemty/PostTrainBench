#!/bin/bash
# Test: Agent Environment Dry-Run
#
# Assembles JOB_DIR exactly like run_task.sh, then dumps what the agent
# would see inside the container. Optionally verifies against manifest.json.
#
# Usage:
#   bash tests/test_agent_env.sh <agent> [task]
#   bash tests/test_agent_env.sh claude_v2 gsm8k
#
# Without a running container (local-only mode):
#   bash tests/test_agent_env.sh <agent> --local

set -eo pipefail

AGENT="${1:?Usage: test_agent_env.sh <agent> [task|--local]}"
TASK="${2:-gsm8k}"
LOCAL_ONLY=false
[ "$TASK" = "--local" ] && LOCAL_ONLY=true && TASK="gsm8k"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

source tests/preflight_utils.sh

# --- 1. Assemble JOB_DIR (mirrors run_task.sh logic) ---
JOB_DIR=$(mktemp -d "${PTB_TMP_BASE}/dryrun_${AGENT}_XXXX")
trap 'rm -rf "$JOB_DIR"' EXIT

mkdir -p "${JOB_DIR}/task" "${JOB_DIR}/.claude"

# Task files
cp "src/eval/tasks/${TASK}/evaluate.py" "${JOB_DIR}/task/" 2>/dev/null || warn "No evaluate.py for task ${TASK}"
if [ -d "src/eval/tasks/${TASK}/task_context" ]; then
    cp -r "src/eval/tasks/${TASK}/task_context/"* "${JOB_DIR}/task/"
fi
cp -r "src/eval/templates" "${JOB_DIR}/task/" 2>/dev/null || true

# Agent solve script
cp "agents/${AGENT}/solve.sh" "${JOB_DIR}/agent_solve.sh" 2>/dev/null || fail "agents/${AGENT}/solve.sh not found"

# Codex config
cp -r "containers/other_home_data/.codex" "${JOB_DIR}/" 2>/dev/null || true

# Claude settings (current mechanism)
cp "$HOME/.claude/settings.local.json" "${JOB_DIR}/.claude/" 2>/dev/null || true
cp "$HOME/.claude/settings.json" "${JOB_DIR}/.claude/" 2>/dev/null || true

# Home overlay (new mechanism)
if [ -d "agents/${AGENT}/home" ]; then
    cp -r "agents/${AGENT}/home/." "${JOB_DIR}/"
    pass "Home overlay applied from agents/${AGENT}/home/"
else
    warn "No home/ directory for agent ${AGENT}"
fi

# Timer placeholder
printf '#!/bin/bash\necho "DRY RUN: timer not active"\n' > "${JOB_DIR}/task/timer.sh"

# --- 2. Snapshot ---
SNAPSHOT_FILE="${JOB_DIR}/_snapshot.txt"

if [ "$LOCAL_ONLY" = true ]; then
    {
        echo "=== Agent Environment Snapshot (local mode) ==="
        echo "agent: ${AGENT}"
        echo "task: ${TASK}"
        echo ""
        echo "--- File Tree ---"
        find "$JOB_DIR" -not -path "*/node_modules/*" -not -name "_snapshot.txt" \
            | sed "s|${JOB_DIR}|/home/ben|g" | sort
        echo ""
        echo "--- CLAUDE.md ---"
        cat "${JOB_DIR}/CLAUDE.md" 2>/dev/null || echo "(none)"
        echo ""
        echo "--- .claude/skills ---"
        find "${JOB_DIR}/.claude/skills" -name "*.md" 2>/dev/null \
            | sed "s|${JOB_DIR}|/home/ben|g" | sort || echo "(none)"
        echo ""
        echo "--- .claude/agents ---"
        find "${JOB_DIR}/.claude/agents" -name "*.md" 2>/dev/null \
            | sed "s|${JOB_DIR}|/home/ben|g" | sort || echo "(none)"
    } > "$SNAPSHOT_FILE"
else
    apptainer exec --nv -c \
        --home "${JOB_DIR}:/home/ben" \
        --pwd "/home/ben/task" \
        --writable-tmpfs \
        "$CONTAINER" bash -c '
echo "=== Agent Environment Snapshot (container mode) ==="
echo "agent: '"${AGENT}"'"
echo "task: '"${TASK}"'"
echo ""
echo "--- File Tree ---"
find /home/ben -maxdepth 4 -not -path "*/node_modules/*" | sort
echo ""
echo "--- CLAUDE.md ---"
cat /home/ben/CLAUDE.md 2>/dev/null || echo "(none)"
echo ""
echo "--- .claude/settings.json ---"
cat /home/ben/.claude/settings.json 2>/dev/null || echo "(none)"
echo ""
echo "--- .claude/skills ---"
find /home/ben/.claude/skills -name "*.md" 2>/dev/null | sort || echo "(none)"
echo ""
echo "--- .claude/agents ---"
find /home/ben/.claude/agents -name "*.md" 2>/dev/null | sort || echo "(none)"
echo ""
echo "--- CLI versions ---"
for cmd in claude codex gemini; do
    ver=$($cmd --version 2>/dev/null | head -1) && echo "$cmd: $ver" || echo "$cmd: not found"
done
' > "$SNAPSHOT_FILE"
fi

echo ""
echo "=== Snapshot ==="
cat "$SNAPSHOT_FILE"

# --- 3. Manifest verification ---
MANIFEST="agents/${AGENT}/manifest.json"
if [ -f "$MANIFEST" ]; then
    echo ""
    echo "=== Manifest Verification ==="
    if python3 tests/verify_manifest.py "$MANIFEST" "$SNAPSHOT_FILE" "$JOB_DIR"; then
        pass "Manifest verification passed"
    else
        fail "Manifest verification failed"
    fi
else
    warn "No manifest.json for agent ${AGENT} — skipping verification"
fi

summary
