---
name: time-budget-management
version: v2
description: Use when a post-training task has a time budget — guides time allocation, training ETA estimation, checkpoint insurance, and wait strategies.
---

# Time Budget Management

## Time Allocation

| Phase | Budget % | What to do |
|-------|----------|-----------|
| Explore + baseline | 0-10% | Read evaluate.py, run `--limit 50` baseline, check timer |
| Data prep + first training | 10-30% | ONE script. Training MUST start by 30% mark. |
| Training + iteration | 30-50% | Train → merge → eval subset → decide next |
| **Insurance checkpoint** | **50%** | **MUST save a final_model/ here, even if mediocre** |
| Improve | 50-90% | Iterate: bigger data, more epochs, fix format |
| Finish | 90-100% | Stop training. Merge best. Full eval. Verify loadable. |

## Exit Strategy (MANDATORY)

| Budget consumed | Required state |
|-----------------|----------------|
| 50% | A merged, loadable `final_model/` MUST exist — even if mediocre |
| 75% | Stop new experiments. Enter merge/eval/cleanup phase. |
| 90% | No new training. Verify final_model loads. Run eval if not done. |

### Insurance checkpoint protocol
1. After first successful training run completes, IMMEDIATELY merge and save as `final_model/`
2. Further iterations save to `final_model_v2/`, `final_model_v3/` — NEVER overwrite the insurance copy
3. Before session exit, verify best model is at `final_model/` path

### Why this matters (exp02a evidence)
- 5/6 jobs lacked exit strategy: claude_bfcl and lemma_bfcl produced no final_model
- codex_gsm8k used only 38min of 10h budget (premature exit)
- claude_gsm8k checkpoint-5000 became the 57.9% result only because it was merged as insurance

## Before Starting Training

Calculate ETA:
```
total_steps = (n_samples × epochs) / (batch_size × grad_accum)
total_minutes = total_steps × seconds_per_step / 60
```
If `total_minutes > 60% of remaining budget` → reduce data or epochs immediately.

## Wait Strategy

- **Use `wait $PID`**, NOT `sleep N`. Sleep wastes API tokens and context window.
- Alternative: `tail -f training.log --pid=$PID`
- NEVER: `while true; do sleep 300; check_status; done`
- If you must check progress mid-training, use ONE `sleep 120` then check, not a polling loop.
- **While waiting**, prepare downstream scripts (merge script, eval command, fallback plan). Do NOT idle.

### Why this matters (exp02a evidence)
- claude_gsm8k wasted ~1-2h in sleep-poll loops
- lemma_bfcl spent 77% of job time (5.3h of 6.9h) in sleep-poll loops
- Productive wait = prepare merge/eval scripts so they are ready the instant training finishes

## Script Discipline

- Do NOT rewrite training scripts from scratch after a bug. Fix the bug in place.
- Each restart costs 1-2 min (model reload + data load). 3 restarts = 5 min wasted.

## Decision: When to Stop Iterating

- v2 accuracy > v1 AND time remaining > 20%? → Try v3
- v2 accuracy < v1? → Submit v1 as final_model (overfitting or data noise)
- Time remaining < 15%? → Stop. Merge best checkpoint. Eval. Done.

## Signal Handling for Background Training

All background training scripts MUST handle SIGTERM gracefully:

```python
import signal, sys

def save_on_signal(signum, frame):
    print("SIGTERM received, saving checkpoint...")
    if trainer and hasattr(trainer, 'save_model'):
        trainer.save_model("final_model_emergency")
    sys.exit(0)

signal.signal(signal.SIGTERM, save_on_signal)
```

Or in bash wrapper:
```bash
trap 'echo "SIGTERM caught"; kill $TRAIN_PID; wait $TRAIN_PID; python3 merge_checkpoint.py' SIGTERM
```

### Why this matters (exp02a evidence)
- lemma_bfcl lost 79% complete training (step 1954/2477) when timeout fired
- claude_bfcl lost all training progress when session ended mid-step
- A SIGTERM handler + the insurance checkpoint (see Exit Strategy above) provides double protection

### Decision tree
- Launching training in background? -> Add SIGTERM handler to the script
- Training in foreground with Trainer API? -> Set `save_steps` to checkpoint every 10% of total steps
- Using nohup? -> SIGTERM handler is your ONLY protection against timeout
