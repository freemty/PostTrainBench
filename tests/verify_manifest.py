#!/usr/bin/env python3
"""Verify agent environment matches manifest.json expectations.

Usage: python3 verify_manifest.py <manifest.json> <snapshot.txt> <job_dir>

manifest.json schema:
{
  "required_files": ["/home/ben/CLAUDE.md", ...],
  "forbidden_files": ["/home/ben/.claude/skills/brainstorming.md", ...],
  "required_strings": {
    "/home/ben/CLAUDE.md": ["Process Rules", "Meta Rules"]
  },
  "required_cli": ["claude"]
}

Exit code: number of failures (0 = all pass).
"""
import json
import sys
from pathlib import Path


def main():
    if len(sys.argv) < 4:
        print(f"Usage: {sys.argv[0]} <manifest.json> <snapshot.txt> <job_dir>")
        sys.exit(1)

    manifest_path, snapshot_path, job_dir = sys.argv[1], sys.argv[2], sys.argv[3]

    with open(manifest_path) as f:
        manifest = json.load(f)

    with open(snapshot_path) as f:
        snapshot = f.read()

    failures = 0

    # Check required files exist in JOB_DIR
    for container_path in manifest.get("required_files", []):
        local_path = container_path.replace("/home/ben", job_dir, 1)
        if Path(local_path).exists():
            print(f"  [PASS] required: {container_path}")
        else:
            print(f"  [FAIL] missing:  {container_path}")
            failures += 1

    # Check forbidden files do NOT exist
    for container_path in manifest.get("forbidden_files", []):
        local_path = container_path.replace("/home/ben", job_dir, 1)
        if Path(local_path).exists():
            print(f"  [FAIL] forbidden file exists: {container_path}")
            failures += 1
        else:
            print(f"  [PASS] forbidden absent: {container_path}")

    # Check required strings in specific files
    for container_path, strings in manifest.get("required_strings", {}).items():
        local_path = container_path.replace("/home/ben", job_dir, 1)
        if not Path(local_path).exists():
            print(f"  [FAIL] file not found for string check: {container_path}")
            failures += len(strings)
            continue
        content = Path(local_path).read_text()
        for s in strings:
            if s in content:
                print(f"  [PASS] '{s}' found in {container_path}")
            else:
                print(f"  [FAIL] '{s}' NOT found in {container_path}")
                failures += 1

    # Check required CLIs (from snapshot, container mode only)
    for cli in manifest.get("required_cli", []):
        cli_line = f"{cli}:"
        if cli_line in snapshot and "not found" not in snapshot.split(cli_line)[1].split("\n")[0]:
            print(f"  [PASS] CLI: {cli}")
        elif "local mode" in snapshot:
            print(f"  [SKIP] CLI check (local mode): {cli}")
        else:
            print(f"  [FAIL] CLI not found: {cli}")
            failures += 1

    print(f"\n  Manifest: {failures} failure(s)")
    sys.exit(min(failures, 125))


if __name__ == "__main__":
    main()
