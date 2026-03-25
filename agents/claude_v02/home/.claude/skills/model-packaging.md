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
| `preprocessor_config.json` | If gemma-3 | vLLM requires this for gemma-3 models |

If any missing, copy from base model cache: `cp $HF_HOME/hub/models--<org>--<name>/snapshots/*/<file> final_model/`

## Self-Verification Before Exit

### Two-stage evaluation protocol
1. **Quick check (20 samples)**: `python3 evaluate.py --model-path ./final_model --limit 20`
   - If score > baseline: proceed to full eval or submit
   - If score < baseline: something is wrong — check format alignment
   - If score = 0: output format is completely wrong
2. **Confirmation check (50-100 samples)**: Run only if quick check passes

### Between training iterations
After each training run, run the quick check (`--limit 20`) to decide:
- Score improving? → iterate further (more data, more epochs)
- Score regressing? → STOP. Revert to previous model. Do NOT continue.
- Score plateaued? → Submit current model. Diminishing returns from more training.

### File verification
1. `ls -la final_model/*.safetensors` — files exist and size > 1MB
2. Quick load test:
   ```python
   from transformers import AutoModelForCausalLM
   m = AutoModelForCausalLM.from_pretrained("final_model", device_map="cpu")
   print(f"Loaded: {m.config.model_type}, {sum(p.numel() for p in m.parameters())/1e9:.1f}B params")
   ```

### Why this matters (exp02a evidence)
- Self-eval caught MetaMathQA regression (32%->22% in lemma_gsm8k)
- codex_bfcl validated 100% on 20 samples before submitting (final: 87%)
- claude_gsm8k confirmed 48% checkpoint viability via self-eval

## Error Recovery: OOM During Merge

OOM on merge?降级阶梯（一步到位，不要逐个试）:
1. `device_map=None` + `.to("cuda:0")` (不用 auto)
2. 如果还 OOM → `torch_dtype=torch.float16` (不用 bfloat16)
3. 如果还 OOM → CPU-only merge: `device_map="cpu"`, 慢但保证成功

## Error Recovery: Process Management

When you need to kill a stuck training process:

1. **Find PID**: `pgrep -f "your_script_name"` — note the specific PIDs
2. **Verify**: `ps -p <pid> -o pid,cmd` — confirm it is YOUR process, not SSH or another job
3. **Kill**: `kill -9 <pid>` — one PID at a time

**NEVER use**:
- `pkill -f <pattern>` — matches SSH command arguments, can kill your own session
- `killall python3` — kills ALL Python processes including other jobs
- `kill -9 -1` — kills everything

### Why this matters (exp02a evidence)
- lemma_gsm8k used `pkill -f python3` and killed all Python processes including potentially itself
