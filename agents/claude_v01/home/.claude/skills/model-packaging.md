---
name: model-artifact-packaging
version: v1
description: Use after training completes — guides LoRA merge, file completeness checks, and self-verification before session exit.
---

# Model Artifact Packaging

## Decision: What to Save

```
Full SFT?
  → Yes → Copy output dir as final_model/. No merge needed.
  → No (LoRA/QLoRA/PEFT) → MUST merge before saving.
```

## LoRA Merge

```python
from peft import PeftModel
from transformers import AutoModelForCausalLM

# Load on CPU first to avoid device_map issues
model = AutoModelForCausalLM.from_pretrained(
    base_model_path, torch_dtype=torch.bfloat16, device_map=None
)
model = model.to("cuda:0")
model = PeftModel.from_pretrained(model, adapter_path)
merged = model.merge_and_unload()
merged.save_pretrained("final_model", safe_serialization=True)
tokenizer.save_pretrained("final_model")
```

**Do NOT** use `device_map="auto"` — causes Gemma3 vision_tower offload errors.

## File Completeness Checklist

After saving, verify these exist in `final_model/`:

| File | Required | Why |
|------|----------|-----|
| `*.safetensors` (size > 0) | Yes | Model weights. 0-byte = corrupted. |
| `config.json` | Yes | Architecture definition |
| `tokenizer.json` | Yes | Tokenizer |
| `tokenizer_config.json` | Yes | Chat template etc. |
| `special_tokens_map.json` | Yes | EOS/BOS tokens |

If any missing, copy from base model cache: `cp $HF_HOME/hub/models--<org>--<name>/snapshots/*/<file> final_model/`

## Self-Verification Before Exit

1. `ls -la final_model/*.safetensors` — files exist and size > 1MB
2. Quick load test:
   ```python
   from transformers import AutoModelForCausalLM
   m = AutoModelForCausalLM.from_pretrained("final_model", device_map="cpu")
   print(f"Loaded: {m.config.model_type}, {sum(p.numel() for p in m.parameters())/1e9:.1f}B params")
   ```
3. Eval sanity check: `python3 evaluate.py --model-path ./final_model --limit 20`
4. If eval score < baseline → something is wrong. Check format alignment.

## Error Recovery: OOM During Merge

OOM on merge?降级阶梯（一步到位，不要逐个试）:
1. `device_map=None` + `.to("cuda:0")` (不用 auto)
2. 如果还 OOM → `torch_dtype=torch.float16` (不用 bfloat16)
3. 如果还 OOM → CPU-only merge: `device_map="cpu"`, 慢但保证成功
