# Skilled Agent CHANGELOG

Versioned agent iterations. Each `claude_vNN/` folder is an immutable snapshot.

## claude_v02 — 2026-03-25

Reflection-pipeline-driven update. Generated from `reflect/runs/exp02a/` (58 evidence → 18 patterns → 12 harness changes).

### CLAUDE.md v1.1 → v2 (+54 lines)
- hc-001: Library version gotchas table (TRL 0.27.2 / transformers 4.57.3 API renames)
- hc-002: Single GPU fact + explicit DDP/DataParallel prohibition
- hc-008: CN network constraints + HF_HOME fallback path + pre-cached dataset emphasis
- hc-011: Fast startup protocol (10 turns to first training)

### time-budget.md v1 → v2 (+56 lines)
- hc-003: Wait strategy strengthened (`wait $PID`, sleep >60s prohibition)
- hc-004: Exit strategy with 50%/75% checkpoints + ETA calculation
- hc-009: SIGTERM handler template + save_steps checkpoint protection

### gsm8k.md v1.1 → v2 (+21 lines)
- hc-005: Format-first protocol (read eval source within 5 turns)
- hc-010: Data scaling decision tree (self-eval before adding data)

### bfcl.md v1.1 → v2 (+8 lines)
- hc-006: Template-first format alignment (locate jinja within 5 turns)

### model-packaging.md v1 → v2 (+34 lines)
- hc-007: Two-stage self-eval protocol (--limit eval before final submission)
- hc-012: Safe process management (pkill -f prohibition, pgrep + kill pattern)

### Evidence chain
- Source: `reflect/runs/exp02a/` (6 jobs, 58 evidence items, 18 patterns)
- 13 confirmed patterns addressed, 5 provisional deferred
- Full traceability: harness_change → pattern_ids → evidence_ids → solve_out line numbers

---

## claude_v01 v1.1 — 2026-03-25

Restructured per "Skill vs CLAUDE.md vs 自动化" layering principle.

### Breaking changes
- CLAUDE.md stripped to environment facts only (paths, versions, pre-cached datasets, eval params)
- Decision logic moved to dedicated skill files

### New skills
- `time-budget.md` v1: 时间分配表、ETA 计算、wait 策略、迭代停止决策
- `model-packaging.md` v1: LoRA merge 流程、文件完整性清单、退出前自检、OOM 降级

### Updated skills
- `gsm8k.md` v1→v1.1: 移除 eval 参数（→ CLAUDE.md）、新增训练策略决策树（按时间预算分支）
- `bfcl.md` v1→v1.1: 移除 eval 参数（→ CLAUDE.md）、新增训练策略决策树

### CLAUDE.md v1→v1.1
- 新增预缓存数据集表（211 个数据集中的关键 9 个 + 完整列表路径）
- 新增 eval 参数表（per-task --max-connections / --gpu-memory-utilization）
- 移除决策逻辑（时间管理、LoRA vs SFT、completion-only loss → skills）
- 移除可自动化项（python3 提示、preprocessor_config 提示 → 已由 run_task.sh 处理）

---

## claude_v01 v1 — 2026-03-25 (superseded)

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

---

## claude_v00 — 2026-03-25

Baseline snapshot. Naked agent with zero injected knowledge — identical to `agents/claude/`.

- No `home/` directory (no CLAUDE.md, no skills)
- `solve.sh` unchanged from upstream
- Used in exp00a, exp01b, exp02a as the unaugmented baseline
