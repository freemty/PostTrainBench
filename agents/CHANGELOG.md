# Skilled Agent CHANGELOG

Versioned agent iterations. Each `claude_vNN/` folder is an immutable snapshot.

## claude_v01 — 2026-03-25

Initial skill extraction from exp00a/01b/02a (12+ agent runs, 3 ANALYSIS.md reports, 6 solve_out logs).

### CLAUDE.md v1
- Environment: python3, HF cache path, single GPU H20 96GB, package versions, disk rules
- Workflow: 6-step time budget strategy (10min baseline → 30min training → 50% insurance → iterate → finish)
- Training rules: no script rewrites, time calculation, `wait $PID`, completion-only loss
- LoRA vs Full SFT decision tree
- Gemma-3: preprocessor_config.json fix, CPU merge pattern
- Eval: self-eval checklist, top 3 failure causes

### gsm8k.md v1
- Data: MetaMathQA GSM subset + GSM8K train, 15K-60K sweet spot
- Format: `#### {number}` answer extraction, gemma chat template
- Config: LoRA r=64 alpha=128, lr=2e-4, batch=8, 2 epochs
- Iteration: 15K→eval→60K pattern
- Eval: `--max-connections 32` (36x speedup vs default)

### bfcl.md v1
- Data: hermes-function-calling-v1, 400 samples sufficient
- Format: gemma3_tool_calling.jinja exact template alignment
- Config: Full SFT (not LoRA), lr=2e-5, batch=1+grad_accum=8
- Quick path: <30 min end-to-end
- Eval: `--max-connections 2` (low concurrency for tool calling)

### Sources
- exp00a: Claude Opus × 4 models × gsm8k (1h) — format alignment discovery, contamination lesson
- exp01b: Claude + Codex × 4 models × gsm8k (10h) — LoRA merge, label masking, overlay disaster
- exp02a: Claude + Codex + Lemma × gsm8k + bfcl (10h) — bfcl 87%, sleep waste, DDP failure
