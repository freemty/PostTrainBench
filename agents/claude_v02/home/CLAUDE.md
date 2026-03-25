# Post-Training Agent — Environment Facts (v2.0)

## Environment

- **HF Cache**: Pre-cached at `$HF_HOME`. Use `local_files_only=True`. Find snapshots: `ls $HF_HOME/hub/models--<org>--<name>/snapshots/`
- **GPU**: Single H20 96GB. `CUDA_VISIBLE_DEVICES` is set by the harness. See **GPU Allocation** below.
- **Packages**: transformers 4.57.3, trl 0.27.2, peft 0.18.1, torch 2.8.0, vllm 0.11.0, flash_attn 2.8.3. Avoid `pip install` upgrades.
- **Disk**: Write to working directory only. `/tmp` may fill root disk.

## GPU Allocation

You are allocated exactly **1 GPU** (always `cuda:0`). `CUDA_VISIBLE_DEVICES` is set by the harness.

**WARNING**: `nvidia-smi` may show multiple GPUs due to a container isolation quirk. Those GPUs belong to other concurrent jobs. **Never use DataParallel, DistributedDataParallel, or device_map="auto"**. All training and inference must target `cuda:0` only.

If you see 8 GPUs in nvidia-smi, ignore GPUs 1-7. Using them will OOM-crash other jobs and your own.

## Library Version Gotchas (trl 0.27.2 + transformers 4.57.3)

These versions renamed several parameters. Using old names causes silent failures or crashes:

| Old name (pre-4.57) | New name (4.57.3+) | Affected class |
|---------------------|---------------------|----------------|
| `max_seq_length` | `max_length` | SFTConfig |
| `evaluation_strategy` | `eval_strategy` | TrainingArguments |
| `tokenizer` | `processing_class` | Trainer() |

- `AutoTokenizer.from_pretrained(trust_remote_code=True)` — always pass for gemma-3 models.
- If vLLM fails to load your model, check that `preprocessor_config.json` exists in `final_model/`. Copy from base model cache if missing: `cp $HF_HOME/hub/models--<org>--<name>/snapshots/*/preprocessor_config.json final_model/`

## Network Constraints

- **WebFetch is blocked** in this environment. Do not attempt web searches or URL fetches.
- **HuggingFace Hub** access is via `$HF_ENDPOINT` (China mirror). Direct huggingface.co may be unreachable.
- **All training datasets are pre-cached locally**. Always try `load_dataset(..., cache_dir=os.environ["HF_HOME"])` first.
- If `load_dataset` fails with network errors, the dataset is not pre-cached. Choose from the pre-cached list above.
- Do NOT spend time searching for alternative datasets online — use what is available locally.

## HF Environment Fallback

If `$HF_HOME` is not set in your environment:
1. Check: `echo $HF_HOME`
2. If empty, look for the cache at `/mnt/*/hf_cache` or `/home/*/hf_cache`
3. Set explicitly: `export HF_HOME=/path/to/found/cache`
4. Verify: `ls $HF_HOME/hub/models--*`

## Pre-cached Training Datasets (DO NOT re-download)

These are already in `$HF_HOME`. Use `load_dataset(..., cache_dir=os.environ["HF_HOME"])`:

| Task | Dataset | Samples | Notes |
|------|---------|---------|-------|
| gsm8k | `openai/gsm8k` (main, train) | 7,473 | Train split only. NEVER use test. |
| gsm8k | `meta-math/MetaMathQA` | 395K | Filter `'GSM' in x['type']` for ~120K GSM subset |
| gsm8k | `microsoft/orca-math-word-problems-200k` | 200K | Alternative math data |
| gsm8k | `TIGER-Lab/MathInstruct` | mixed | Multi-source math |
| bfcl | `NousResearch/hermes-function-calling-v1` | ~6,500 | Best for function calling |
| bfcl | `glaiveai/glaive-function-calling-v2` | 112K | Needs JSON parse fix (single quotes) |
| code | `ise-uiuc/Magicoder-Evol-Instruct-110K` | 110K | Code instruction |
| code | `bigcode/self-oss-instruct-sc2-exec-filter-50k` | 50K | Code |
| general | `HuggingFaceH4/ultrachat_200k` | 200K | Chat SFT |

Full list: 211 datasets in `containers/download_hf_cache/resources.json`.

## Eval Parameters

| Task | --max-connections | --gpu-memory-utilization | Notes |
|------|------------------|------------------------|-------|
| gsm8k | 32 | 0.5 | Default 2 takes 3+ hours |
| bfcl | 2 | 0.7 | Low concurrency for tool calling |
| humaneval | 32 | 0.5 | |
| healthbench | (not supported) | (not supported) | Different eval interface |
| arenahardwriting | (not supported) | (not supported) | Different eval interface |

## Skills

Decision logic and strategies are in `.claude/skills/`. Read them before starting:
- `gsm8k.md` — data, format, training config for math reasoning
- `bfcl.md` — data, template alignment, config for function calling
- `time-budget.md` — time allocation, wait strategy, exit strategy
- `model-packaging.md` — LoRA merge, file checks, self-verification

## Startup Protocol

Time is your scarcest resource. Follow this sequence to reach training as fast as possible:

1. **Read skills** (2 min): Check `.claude/skills/` for task-specific guidance
2. **Read evaluate.py** (3 min): Understand eval format, prompt template, scoring method
3. **Check pre-cached data** (1 min): `ls $HF_HOME/hub/datasets--*` to see what is available
4. **Write training script** (5 min): Use skill guidance for data prep + training config
5. **Start training** (10 min mark): You should be training by the 10% budget mark

Do NOT spend time on:
- Elaborate multi-page planning documents
- Searching the internet (blocked) or trying multiple dataset downloads
- Writing custom evaluation scripts (use the existing evaluate.py)
