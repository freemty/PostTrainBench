#!/bin/bash
# Build an Apptainer container with validation.
#
# Usage: bash containers/build_container.sh <container_name>
#   e.g.: bash containers/build_container.sh standard
#
# Enforces:
#   - .def must reference requirements-direct.txt (no unpinned deps)
#   - Auto-selects docker-daemon bootstrap if base image exists locally (avoids Docker Hub GFW issues)
#   - Verifies key package versions after build

set -eo pipefail

container="${1:?Usage: build_container.sh <container_name>}"

export POST_TRAIN_BENCH_CONTAINERS_DIR="${POST_TRAIN_BENCH_CONTAINERS_DIR:-containers}"
export APPTAINER_BIND=""

DEF_FILE="containers/${container}.def"
SIF_FILE="${POST_TRAIN_BENCH_CONTAINERS_DIR}/${container}.sif"

if [ ! -f "$DEF_FILE" ]; then
    echo "ERROR: Definition file not found: $DEF_FILE"
    exit 1
fi

# --- Validation: .def must use requirements-direct.txt ---
if ! grep -q 'requirements-direct.txt' "$DEF_FILE"; then
    echo "ERROR: $DEF_FILE does not reference requirements-direct.txt"
    echo "All containers must pin Python dependencies via requirements-direct.txt."
    echo "Add to %files:  containers/requirements-direct.txt /opt/requirements-direct.txt"
    echo "Add to %post:   uv pip install --system --no-cache -r /opt/requirements-direct.txt"
    exit 1
fi
echo "[OK] $DEF_FILE uses requirements-direct.txt"

# --- Auto-select bootstrap: prefer docker-daemon if base image exists locally ---
BASE_IMAGE=$(grep '^From:' "$DEF_FILE" | head -1 | awk '{print $2}')
BOOTSTRAP=$(grep '^Bootstrap:' "$DEF_FILE" | head -1 | awk '{print $2}')

if [ "$BOOTSTRAP" = "docker" ] && [ -n "$BASE_IMAGE" ]; then
    # Check if base image exists in local Docker daemon
    if docker image inspect "$BASE_IMAGE" >/dev/null 2>&1; then
        echo "[INFO] Base image '$BASE_IMAGE' found in local Docker. Switching to docker-daemon bootstrap."
        PATCHED_DEF=$(mktemp /tmp/container_def_XXXXXX.def)
        sed 's/^Bootstrap: docker$/Bootstrap: docker-daemon/' "$DEF_FILE" > "$PATCHED_DEF"
        DEF_FILE="$PATCHED_DEF"
    else
        echo "[WARN] Base image '$BASE_IMAGE' not in local Docker. Using remote Docker Hub (may be slow in CN)."
    fi
elif [ "$BOOTSTRAP" = "docker-daemon" ] && [ -n "$BASE_IMAGE" ]; then
    if ! docker image inspect "$BASE_IMAGE" >/dev/null 2>&1; then
        echo "[WARN] Bootstrap is docker-daemon but '$BASE_IMAGE' not found locally."
        echo "  Pull it first: docker pull $BASE_IMAGE"
        echo "  Or change Bootstrap to 'docker' to pull from remote."
        exit 1
    fi
    echo "[OK] docker-daemon bootstrap, base image exists locally"
fi

# --- Ensure APPTAINER_TMPDIR is on local disk (not network FS) ---
if [ -z "${APPTAINER_TMPDIR:-}" ]; then
    export APPTAINER_TMPDIR="/tmp/apptainer_build_$$"
    mkdir -p "$APPTAINER_TMPDIR"
    echo "[INFO] APPTAINER_TMPDIR set to $APPTAINER_TMPDIR (local disk, not network FS)"
fi

# --- Build ---
echo ""
echo "Building $SIF_FILE from $DEF_FILE ..."
echo "Started: $(date)"

apptainer build --force "$SIF_FILE" "$DEF_FILE"
BUILD_EXIT=$?

echo "Finished: $(date)"

# Cleanup temp files
if [ -n "${PATCHED_DEF:-}" ] && [ -f "${PATCHED_DEF:-}" ]; then
    rm -f "$PATCHED_DEF"
fi
rm -rf "/tmp/apptainer_build_$$" 2>/dev/null || true

if [ $BUILD_EXIT -ne 0 ]; then
    echo "ERROR: Build failed with exit code $BUILD_EXIT"
    exit $BUILD_EXIT
fi

# --- Post-build verification ---
echo ""
echo "--- Verifying package versions ---"

VERIFY_OUT=$(apptainer exec "$SIF_FILE" python3 -c "
import json, importlib
pkgs = ['transformers', 'vllm', 'torch', 'tokenizers', 'datasets', 'trl', 'peft', 'accelerate', 'inspect_ai']
result = {}
for p in pkgs:
    try:
        m = importlib.import_module(p)
        result[p] = getattr(m, '__version__', 'ok')
    except ImportError:
        result[p] = 'MISSING'
print(json.dumps(result))
" 2>/dev/null) || VERIFY_OUT="{}"

echo "$VERIFY_OUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
# Expected versions from requirements-direct.txt
expected = {'transformers': '4.57.3', 'tokenizers': '0.22.2', 'datasets': '4.5.0',
            'trl': '0.27.2', 'peft': '0.18.1', 'accelerate': '1.12.0'}
ok = True
for pkg, ver in sorted(d.items()):
    exp = expected.get(pkg)
    if ver == 'MISSING':
        print(f'  [FAIL] {pkg}: MISSING')
        ok = False
    elif exp and ver != exp:
        print(f'  [WARN] {pkg}: {ver} (expected {exp})')
        ok = False
    else:
        marker = f' (expected {exp})' if exp else ''
        print(f'  [OK]   {pkg}: {ver}{marker}')
if ok:
    print('\nAll versions match. Container is ready.')
else:
    print('\nWARNING: Version mismatch detected. Check requirements-direct.txt.')
    sys.exit(1)
"

echo ""
echo "Container built: $SIF_FILE ($(du -sh "$SIF_FILE" | cut -f1))"
