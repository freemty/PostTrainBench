# Post-Training Agent — Environment & Workflow Rules (v1)

You are autonomously post-training a small LLM. These rules are extracted from 3 rounds of prior experiments (12+ agent runs). Follow them to avoid repeating known failures.

## Environment (MUST READ FIRST)

- **Python**: Use `python3`, not `python`. Container only has python3.
- **HF Cache**: Models are pre-cached at `$HF_HOME` (usually `/home/ben/hf_cache`). Do NOT re-download models. Use `local_files_only=True` or find the snapshot path directly: `ls $HF_HOME/hub/models--<org>--<name>/snapshots/`
- **GPU**: Single H20 96GB. You have ONE GPU only (`CUDA_VISIBLE_DEVICES` is set). Do NOT attempt multi-GPU DDP — it will fail or steal other jobs' GPUs.
- **Packages**: transformers 4.57.3, trl 0.27.2, peft 0.18.1, torch 2.8.0, vllm 0.11.0, flash_attn 2.8.3. Do NOT `pip install` upgrades unless absolutely necessary.
- **Disk**: Write everything to your working directory. Do NOT write to `/tmp` (may fill root disk).

## Workflow (TIME IS YOUR SCARCEST RESOURCE)

### Time Budget Strategy
1. **First 10 minutes**: Explore environment + run baseline eval (`python3 evaluate.py --limit 50`). Know your starting point.
2. **Minutes 10-30**: Prepare data + write training script. ONE script, get it right.
3. **By 30 minutes**: Training MUST be running. If not, simplify immediately.
4. **At 50% budget**: You MUST have a `final_model/` saved (even if not great). This is your insurance.
5. **After 50%**: Iterate to improve. Each iteration: train → merge → eval subset → decide.
6. **Last 10%**: Stop training. Merge best checkpoint. Run full eval. Verify `final_model/` is loadable.

### Training Rules
- **Do NOT rewrite scripts from scratch**. Fix the bug in the existing script. Each restart costs 1-2 min (model reload).
- **Calculate time before training**: `total_steps = (n_samples × epochs) / (batch_size × grad_accum)`, then `total_minutes = total_steps × seconds_per_step / 60`. If > 60% of remaining budget, reduce data or epochs.
- **Use `wait $PID`** instead of `sleep` loops. Sleep wastes API tokens and context window.
- **Completion-only loss**: When using SFT, ONLY compute loss on the assistant response, NOT the prompt. Full-sequence loss produces models that can't stop generating. This is the single most common training bug.

### LoRA vs Full SFT Decision
- **If model ≤ 4B params + single H20 96GB**: Full SFT is viable and simpler. No merge step needed.
- **If using LoRA**: You MUST `model.merge_and_unload()` and `model.save_pretrained("final_model")` before eval. The eval system cannot load LoRA adapters directly.

### Gemma-3 Specific (google/gemma-3-4b-pt)
- After merge, copy `preprocessor_config.json` from the base model cache into `final_model/`:
  ```bash
  cp $HF_HOME/hub/models--google--gemma-3-4b-pt/snapshots/*/preprocessor_config.json final_model/
  ```
  Without this file, vLLM will crash because gemma-3 is detected as multimodal.
- Merge on CPU first if `device_map="auto"` causes issues:
  ```python
  model = AutoModelForCausalLM.from_pretrained(base_path, torch_dtype=torch.bfloat16, device_map=None)
  model = model.to("cuda:0")
  ```

### Eval Integration
- The evaluation runs AFTER your session ends via `evaluate.py`. You cannot fix eval bugs post-mortem.
- **Always self-eval before finishing**: `python3 evaluate.py --limit 50 --model-path ./final_model`
- If eval fails, the most common causes are: (1) missing preprocessor_config.json, (2) LoRA not merged, (3) tokenizer files missing from final_model.
