# BFCL (Function Calling) Post-Training Skill

Best known result: 87.0% (full SFT, 400 samples, 50 steps, ~6 min training).

## Winning Strategy

### Data
- **Primary**: `NousResearch/hermes-function-calling-v1` — high-quality function calling conversations with tool definitions. ~6500 samples.
- **Backup**: `glaiveai/glaive-function-calling-v2` — 112K samples but needs JSON parsing fix (single quotes in arguments).
- **Do NOT try**: `gorilla-llm/Berkeley-Function-Calling-Leaderboard` or `Salesforce/xlam-function-calling-60k` — unreachable from CN servers.
- **Key insight**: 400 samples with perfect format alignment beats 40K samples with approximate format.

### Format Alignment (THIS IS WHY 87% WAS ACHIEVED)
Use the EXACT same jinja template as evaluate.py: `templates/gemma3_tool_calling.jinja`

```python
template = open("templates/gemma3_tool_calling.jinja").read()
rendered = tokenizer.apply_chat_template(
    messages,
    tokenize=False,
    add_generation_prompt=False,
    chat_template=template,
    tools=tools  # Pass the tool definitions!
)
```

The eval uses `<tool_call>\n{"name": "func", "arguments": {...}}\n</tool_call>` format. Your training data MUST produce this exact pattern.

### Training Config (proven on H20 96GB)
Full SFT (NOT LoRA) — simpler and better for small data:
```python
TrainingArguments(
    num_train_epochs=1,
    per_device_train_batch_size=1,
    gradient_accumulation_steps=8,  # effective batch = 8
    learning_rate=2e-5,  # 10x lower than gsm8k
    lr_scheduler_type="cosine",
    warmup_ratio=0.03,
    bf16=True,
    gradient_checkpointing=True,
    max_length=2048,  # function calling needs longer context
    save_total_limit=2,
)
```

### Quick Path (< 30 minutes total)
1. Load hermes dataset, format with gemma3_tool_calling.jinja
2. Full SFT on 400-1800 samples, 50-100 steps (~6 min)
3. Copy output directly as `final_model/` (no merge needed for full SFT)
4. Copy `preprocessor_config.json` from base model cache
5. Eval: `python3 evaluate.py --model-path ./final_model --limit 20`
6. If >80%, done. If not, increase to 1800 samples.

### Eval Command
```bash
python3 evaluate.py --model-path ./final_model --limit 100 --max-connections 2 --gpu-memory-utilization 0.7
```
Note: BFCL uses `--max-connections 2` (not 32 like gsm8k) for stability with vLLM tool calling.
