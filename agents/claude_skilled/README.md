# claude_skilled — Skill-Augmented Claude Agent

Claude Code agent with pre-extracted experiment knowledge injected via native CLAUDE.md + `.claude/skills/` mechanism.

## Purpose

Validate that knowledge extracted from prior experiment logs (exp00a/01b/02a) measurably improves agent performance on post-training tasks. This is Step 0 of the meta-learning loop.

## Skill Inventory

| Skill | Version | Scope | Source |
|-------|---------|-------|--------|
| `CLAUDE.md` | v1 | Environment rules + workflow constraints | exp00a/01b/02a ANALYSIS.md |
| `gsm8k.md` | v1 | GSM8K data, format, training config | exp00a (75.97%), exp01b (51.9%), exp02a (57.9%) |
| `bfcl.md` | v1 | BFCL data, jinja alignment, SFT config | exp02a codex (87.0%) |

## Injection Mechanism

`run_task.sh` copies `home/` into the job working directory:
```bash
if [ -d "agents/${AGENT}/home" ]; then
    cp -r "agents/${AGENT}/home/." "${JOB_DIR}/"
fi
```

- `CLAUDE.md` → auto-loaded by Claude Code as project rules
- `.claude/skills/*.md` → discoverable by Claude Code via frontmatter

## Versioning

- Each skill file has a `version` field in YAML frontmatter
- Version history tracked in `CHANGELOG.md`
- Convention: never overwrite — increment version, document delta
