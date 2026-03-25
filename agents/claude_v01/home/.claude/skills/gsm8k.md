---
name: gsm8k-post-training
version: v1
description: Use when the benchmark-id is gsm8k — covers data selection, format alignment, training config, and eval parameters for math reasoning post-training.
---

# GSM8K Post-Training Skill

Best known result: 57.9% (LoRA + 247K samples, 10h) and 51.9% (LoRA + 60K samples, 3h active).

## Data
- **Primary**: MetaMathQA GSM subset (~120K samples of chain-of-thought math). `load_dataset("meta-math/MetaMathQA", split="train")`, filter by `'GSM' in x['type']`.
- **Supplement**: GSM8K train split (7,473 samples). `load_dataset("openai/gsm8k", "main", split="train")`
- **Total**: 15K-60K samples is the sweet spot. 240K works but takes longer. <15K is insufficient.
- **NEVER use GSM8K test data** — contamination judge will flag it.

## Format Alignment (THIS IS THE #1 FACTOR)
Read `evaluate.py` and the gsm8k inspect task source to understand the exact eval format. Your training data format MUST match. For gemma-3:
```
<start_of_turn>user
[math question]<end_of_turn>
<start_of_turn>model
[step-by-step solution]
#### [numeric answer]<end_of_turn>
```
The answer line MUST end with `#### {number}` — this is how the eval extracts the final answer.

## Training Config (proven on H20 96GB)
```python
# LoRA config
LoraConfig(
    r=64, lora_alpha=128, lora_dropout=0.05,
    target_modules=["q_proj","k_proj","v_proj","o_proj","gate_proj","up_proj","down_proj"],
    bias="none", task_type="CAUSAL_LM"
)

# Training args
SFTConfig(
    num_train_epochs=2,
    per_device_train_batch_size=8,
    learning_rate=2e-4,
    lr_scheduler_type="cosine",
    warmup_ratio=0.05,
    bf16=True,
    gradient_checkpointing=True,
    optim="adamw_torch_fused",
    save_steps=500,
    save_total_limit=2,
    max_length=512,  # NOT max_seq_length (deprecated in trl 0.27.2)
    logging_steps=50,
)
```

## Quick Iteration Pattern
1. Train on 15K samples, 1 epoch (~20 min on H20)
2. Merge LoRA, eval `--limit 50` (~2 min)
3. If >25%, scale to 60K samples, 2 epochs
4. Merge best checkpoint, eval `--limit 150`
5. Save as `final_model/`

## Eval Command
```bash
python3 evaluate.py --model-path ./final_model --limit 50 --max-connections 32 --gpu-memory-utilization 0.5
```
`--max-connections 32` is critical — default of 2 takes 3+ hours for 1319 questions.
