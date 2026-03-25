# claude_v01 — Skill-Augmented Claude Agent (v1)

First iteration of skill-injected Claude Code agent. Knowledge extracted from exp00a/01b/02a (12+ runs).

## Skill Inventory

| Skill | Scope | Source |
|-------|-------|--------|
| `CLAUDE.md` | Environment rules + workflow constraints | exp00a/01b/02a ANALYSIS.md |
| `gsm8k.md` | GSM8K data, format, training config | exp00a (75.97%), exp01b (51.9%), exp02a (57.9%) |
| `bfcl.md` | BFCL data, jinja alignment, SFT config | exp02a codex (87.0%) |

## Injection

`run_task.sh` copies `home/` into job dir. `CLAUDE.md` auto-loaded by Claude Code; `.claude/skills/*.md` discoverable via frontmatter.

## Version History

See `agents/CHANGELOG.md`.
