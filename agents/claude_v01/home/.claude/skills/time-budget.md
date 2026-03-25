---
name: time-budget-management
version: v1
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

## Script Discipline

- Do NOT rewrite training scripts from scratch after a bug. Fix the bug in place.
- Each restart costs 1-2 min (model reload + data load). 3 restarts = 5 min wasted.

## Decision: When to Stop Iterating

- v2 accuracy > v1 AND time remaining > 20%? → Try v3
- v2 accuracy < v1? → Submit v1 as final_model (overfitting or data noise)
- Time remaining < 15%? → Stop. Merge best checkpoint. Eval. Done.
