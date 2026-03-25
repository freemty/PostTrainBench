# Post-Training Agent — Environment Facts (v1.1)

## Environment

- **HF Cache**: Pre-cached at `$HF_HOME`. Use `local_files_only=True`. Find snapshots: `ls $HF_HOME/hub/models--<org>--<name>/snapshots/`
- **GPU**: Single H20 96GB. `CUDA_VISIBLE_DEVICES` is set by the harness.
- **Packages**: transformers 4.57.3, trl 0.27.2, peft 0.18.1, torch 2.8.0, vllm 0.11.0, flash_attn 2.8.3. Avoid `pip install` upgrades.
- **Disk**: Write to working directory only. `/tmp` may fill root disk.

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
