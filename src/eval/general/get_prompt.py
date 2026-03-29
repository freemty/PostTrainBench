#!/usr/bin/env python3
import argparse
import os
import subprocess
from pathlib import Path

INSPECT_EVALS = [
    "aime2025",
    "bfcl",
    "gpqamain",
    "gsm8k",
    "humaneval",
    "humanevalplus",
]

def read_benchmark_name(benchmark_id: str) -> str:
    """Resolve the human-readable benchmark name from the benchmark_id."""
    bench_file = Path("src/eval/tasks") / benchmark_id / "benchmark.txt"
    if not bench_file.is_file():
        raise FileNotFoundError(f"Benchmark file not found for id '{benchmark_id}': {bench_file}")
    return bench_file.read_text(encoding="utf-8").strip()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--agent', type=str, required=True)
    parser.add_argument('--model-to-train', type=str, required=True)
    parser.add_argument('--benchmark-id', type=str, required=True)
    parser.add_argument('--num-hours', type=str, required=True)

    args = parser.parse_args()

    benchmark_name = read_benchmark_name(args.benchmark_id)

    base_prompt = os.environ.get('POST_TRAIN_BENCH_PROMPT', 'prompt')

    template_path = f'src/eval/general/{base_prompt}.txt'

    with open(template_path, 'r') as f:
        template = f.read()

    datetime = subprocess.run(['date', '-u'], capture_output=True, text=True).stdout.strip()

    # Build environment specification from runtime env vars.
    # This tells agents about infrastructure paths so they don't waste time discovering them.
    env_spec_lines = []

    hf_home = os.environ.get('HF_HOME') or os.environ.get('HF_HOME_NEW')
    if hf_home:
        env_spec_lines.append(f"- HuggingFace cache is at `{hf_home}`. Datasets cache is at `{hf_home}/datasets`.")

    hf_endpoint = os.environ.get('HF_ENDPOINT')
    if hf_endpoint:
        env_spec_lines.append(f"- HuggingFace mirror endpoint: `{hf_endpoint}`. Use this instead of huggingface.co for downloads.")

    uv_index = os.environ.get('UV_INDEX_URL')
    if uv_index:
        env_spec_lines.append(f"- PyPI mirror: `{uv_index}`. Use `uv pip install --system --index-url {uv_index} <pkg>` for package installation.")

    # Network constraints + local cache inventory
    # Scan HF cache to tell agent exactly what's available locally
    cached_models = []
    cached_datasets = []
    if hf_home:
        hub_dir = Path(hf_home) / "hub"
        ds_dir = Path(hf_home) / "datasets"
        if hub_dir.is_dir():
            cached_models = sorted(
                d.name.replace("models--", "").replace("--", "/")
                for d in hub_dir.iterdir()
                if d.is_dir() and d.name.startswith("models--")
            )
        if ds_dir.is_dir():
            cached_datasets = sorted(
                d.name.replace("datasets--", "").replace("--", "/")
                for d in ds_dir.iterdir()
                if d.is_dir() and d.name.startswith("datasets--")
            )

    net_lines = ["- **Internet is restricted.** Direct access to huggingface.co, github.com, and most foreign sites is blocked or extremely slow. Prefer locally cached data over downloading."]
    if cached_models:
        net_lines.append(f"- **Locally cached models**: {', '.join(f'`{m}`' for m in cached_models)}")
    if cached_datasets:
        net_lines.append(f"- **Locally cached datasets**: {', '.join(f'`{d}`' for d in cached_datasets)}")
    if cached_models or cached_datasets:
        net_lines.append("- These are ready to use with `transformers`/`datasets` — no download needed. Anything NOT listed above may be unreachable.")

    env_spec_lines.extend(net_lines)

    # Single GPU — prevent DDP/DataParallel attempts
    env_spec_lines.append("- You have exactly **1 GPU** (CUDA device 0). Do NOT use DataParallel, DDP, or multi-GPU training — it will fail.")

    # Persistent log directory (survives container teardown)
    eval_dir = os.environ.get('EVAL_DIR')
    if eval_dir:
        env_spec_lines.append(f"- Persistent log directory: `{eval_dir}` (shared filesystem, survives container teardown). Write training logs, loss curves, and metrics here so they are preserved. Do NOT write model weights or checkpoints here — only lightweight text/JSON logs.")

    if env_spec_lines:
        env_versions = "\n## Environment\n" + "\n".join(env_spec_lines) + "\n\n"
    else:
        env_versions = ""

    result = template.replace('{model}', args.model_to_train)
    result = result.replace('{benchmark}', benchmark_name)
    result = result.replace('{num_hours}', args.num_hours)

    if args.benchmark_id in INSPECT_EVALS:
        result = result.replace('{setup_other}', "- A final note: the evaluate.py script sometimes outputs ERROR warnings. Do not be alarmed by this, this is normal behavior for inspect-ai. Also if you run into issues with the evaluate.py script, this is likely due to memory constraints on the GPU. In this case please decrease --max-connections or --max-tokens.\n")
    else:
        result = result.replace('{setup_other}', "")

    result = result.replace('{env_versions}', env_versions)
    result = result.replace('{datetime}', datetime)

    if args.agent == 'claude':
        result += """
You are running in a non-interactive mode. So make sure every process you are running finishes before you write your last message.
"""
    print(result)

if __name__ == '__main__':
    main()
