"""Auto-merge LoRA adapter into base model for eval.

Usage: python3 auto_merge_lora.py <final_model_dir> <base_model_name>

Detects adapter_config.json in final_model_dir. If found:
1. Loads base model from HF cache (CPU only)
2. Loads and merges LoRA adapter
3. Saves merged model back to final_model_dir
4. Copies missing tokenizer/preprocessor files from base cache

Memory: ~20GB RAM for gemma-3-4b merge. Fails gracefully on OOM.
"""
import sys
import os
import shutil
from pathlib import Path


def main():
    final_model_dir = Path(sys.argv[1])
    base_model_name = sys.argv[2]

    adapter_config = final_model_dir / "adapter_config.json"
    if not adapter_config.exists():
        print("No adapter_config.json found, skipping merge")
        return

    print(f"AUTO-MERGE: detected LoRA adapter, merging into base model...")

    try:
        from peft import PeftModel
        from transformers import AutoModelForCausalLM, AutoTokenizer

        base_model = AutoModelForCausalLM.from_pretrained(
            base_model_name,
            torch_dtype="auto",
            device_map="cpu",
        )

        model = PeftModel.from_pretrained(base_model, str(final_model_dir))
        merged = model.merge_and_unload()

        # Back up adapter files before overwriting
        backup_dir = final_model_dir.parent / "lora_adapter_backup"
        backup_dir.mkdir(exist_ok=True)
        for f in ["adapter_config.json", "adapter_model.safetensors", "adapter_model.bin"]:
            src = final_model_dir / f
            if src.exists():
                shutil.move(str(src), str(backup_dir / f))

        merged.save_pretrained(str(final_model_dir))

        tokenizer = AutoTokenizer.from_pretrained(base_model_name)
        tokenizer.save_pretrained(str(final_model_dir))

        # Copy preprocessor_config.json from base cache if missing
        hf_home = os.environ.get("HF_HOME", "")
        if hf_home:
            model_safe = base_model_name.replace("/", "--")
            base_cache = Path(hf_home) / "hub" / f"models--{model_safe}"
            base_snap = next(base_cache.glob("snapshots/*/"), None)
            if base_snap:
                for f in ["preprocessor_config.json", "processor_config.json"]:
                    src = base_snap / f
                    dst = final_model_dir / f
                    if src.exists() and not dst.exists():
                        shutil.copy2(str(src), str(dst))
                        print(f"AUTO-MERGE: copied {f} from base cache")

        print(f"AUTO-MERGE: done — merged model saved to {final_model_dir}")

    except Exception as e:
        import traceback
        print(f"AUTO-MERGE: failed — {e}")
        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
