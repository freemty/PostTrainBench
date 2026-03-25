---
name: gsm8k-post-training
version: v2.0
description: Use when the benchmark-id is gsm8k — data selection, format alignment, and training strategy for math reasoning.
---

# GSM8K Post-Training

Best results: 57.9% (LoRA + 247K, 10h) and 51.9% (LoRA + 60K, 3h active).

## Data Selection

- **Primary**: MetaMathQA GSM subset (~120K chain-of-thought math). Filter: `'GSM' in x['type']`
- **Supplement**: GSM8K train (7,473 samples)
- **Sweet spot**: 15K-60K samples. <15K insufficient, >240K diminishing returns.
- **NEVER use GSM8K test** — contamination judge flags it.

### Scaling decisions
- Start with 15K samples, 1 epoch (~20 min). Self-eval with `--limit 50`.
- Only scale up if: (1) loss is still decreasing at end of training, AND (2) self-eval shows improvement over baseline.
- Cross-domain datasets (MetaMathQA non-GSM, MATH, etc.) can introduce format noise. Always self-eval after adding new data sources.
- If self-eval shows regression after adding data, REVERT to the smaller dataset model.

### Why this matters (exp02a evidence)
- lemma_gsm8k MetaMathQA mix degraded accuracy from 32% to 22% (format mismatch noise)
- codex_bfcl achieved 87% with only 400 precisely formatted samples
- More data is NOT always better — format alignment matters more than quantity

## Format Alignment (THE #1 FACTOR)

**Before writing ANY data prep code**, read the eval source:
1. Read `evaluate.py` to find the task entry point
2. Read the inspect_evals task source for gsm8k (prompt template, answer extraction regex)
3. Identify the exact output format the scorer expects (e.g., `#### {number}`)

Your training format MUST match eval format exactly.

For gemma-3:
```
<start_of_turn>user
[math question]<end_of_turn>
<start_of_turn>model
[step-by-step solution]
#### [numeric answer]<end_of_turn>
```

The `#### {number}` line is how eval extracts the answer. Missing this = 0% accuracy.

### Data quality > Data quantity
- 400 precisely formatted samples can outperform 40K misaligned samples (exp02a evidence)
- Cross-domain data (e.g., MetaMathQA non-GSM subsets) can introduce format noise — always self-eval after training with mixed data
- If mixing datasets, verify EVERY source matches the eval format before training

## Training Strategy Decision

```
Time budget > 5h AND data > 30K?
  → LoRA r=64, 2 epochs, lr=2e-4
Time budget 1-5h?
  → LoRA r=64, 1 epoch on 15K, lr=2e-4
Time budget < 1h?
  → Full SFT on 7K GSM8K train, 1 epoch (simpler, no merge)
```

### LoRA Config (proven)
```python
LoraConfig(r=64, lora_alpha=128, lora_dropout=0.05,
    target_modules=["q_proj","k_proj","v_proj","o_proj","gate_proj","up_proj","down_proj"],
    bias="none", task_type="CAUSAL_LM")
```

### SFTConfig (proven)
```python
SFTConfig(per_device_train_batch_size=8, learning_rate=2e-4,
    lr_scheduler_type="cosine", warmup_ratio=0.05, bf16=True,
    gradient_checkpointing=True, optim="adamw_torch_fused",
    max_length=512, save_steps=500, save_total_limit=2)
```

## Quick Iteration

1. Train 15K, 1 epoch (~20 min) → merge → eval `--limit 50`
2. If >25% → scale to 60K, 2 epochs
3. Merge best checkpoint → eval `--limit 150`
4. Save as `final_model/`
