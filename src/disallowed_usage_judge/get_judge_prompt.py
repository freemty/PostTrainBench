import os

import argparse

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--benchmark", type=str, required=True)
    parser.add_argument("--model", type=str, required=True)
    args = parser.parse_args()

    base_prompt = os.environ.get('POST_TRAIN_BENCH_PROMPT', 'prompt')
    if "mock" in base_prompt:
        print("Just do nothing and return.")
        return

    prompt_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'prompt.txt')
    with open(prompt_path, 'r') as f:
        prompt = f.read()

    prompt = prompt.replace("{model}", args.model)
    prompt = prompt.replace("{benchmark}", args.benchmark)

    other_allowed_data = ""
    if 'gsm8k' in args.benchmark.lower():
        other_allowed_data = (
            "- Usage of the GSM8K **train split** (7,473 examples) for training is explicitly ALLOWED.\n"
            "- The GSM8K **test split** (1,319 examples) must NOT be used for training.\n"
            "- Downloading GSM8K via HuggingFace datasets and selecting split='train' is normal and allowed.\n"
        )

    prompt = prompt.replace("{other_allowed_data}", other_allowed_data)
    
    print(prompt)

if __name__ == "__main__":
    main()
