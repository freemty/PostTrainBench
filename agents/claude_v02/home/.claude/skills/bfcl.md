---
name: bfcl-post-training
version: v2.0
description: Use when the benchmark-id is bfcl — data selection, jinja template alignment, and training strategy for function calling.
---

# BFCL Post-Training

Best result: 87.0% (full SFT, 400 samples, 50 steps, ~6 min).

## Data Selection

- **Primary**: `NousResearch/hermes-function-calling-v1` (~6,500 samples)
- **Backup**: `glaiveai/glaive-function-calling-v2` (112K, needs JSON parse fix)
- **Key insight**: 400 samples with perfect format > 40K with approximate format.

## Format Alignment (THIS IS WHY 87% WAS ACHIEVED)

**Before writing ANY data prep code**, read the eval source:
1. Read `evaluate.py` to find the bfcl task entry point
2. Locate the jinja template used for inference (e.g., `templates/gemma3_tool_calling.jinja`)
3. Use the EXACT same template when formatting training data

```python
template = open("templates/gemma3_tool_calling.jinja").read()
rendered = tokenizer.apply_chat_template(
    messages, tokenize=False, add_generation_prompt=False,
    chat_template=template, tools=tools  # Pass tool definitions!
)
```

Output format: `<tool_call>\n{"name": "func", "arguments": {...}}\n</tool_call>`

### Key insight from exp02a
- codex achieved 87% with 400 format-aligned samples via full SFT
- Agents using 40K+ misaligned samples either timed out or failed
- Template alignment is the single biggest factor — get this right first, optimize data size second

## Training Strategy Decision

```
Data < 2K samples?
  → Full SFT (NOT LoRA). Simpler, no merge needed. lr=2e-5
Data > 2K?
  → LoRA r=64, lr=2e-5, 1 epoch
Always:
  → max_length=2048 (function calling needs long context)
  → gradient_accumulation_steps=8 with batch_size=1
```

## Quick Path (< 30 min)

1. Load hermes dataset → format with gemma3_tool_calling.jinja
2. Full SFT, 400-1800 samples, 50-100 steps (~6 min)
3. Copy output as `final_model/` (no merge for full SFT)
4. Eval `--limit 20` → if >80%, done
5. If not, increase to 1800 samples
