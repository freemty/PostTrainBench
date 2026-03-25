"""Container environment verification for preflight dry-run.

Usage: python3 preflight_env_check.py
Reads env vars: HF_HOME, HF_TOKEN, MODEL_TO_TRAIN
Outputs JSON with check results. Exit 0 if all pass, 1 if any fail.
"""
import os
import sys
import json
import glob
import tempfile


def main():
    checks = {}

    hf_home = os.environ.get("HF_HOME", "")
    checks["hf_home_set"] = bool(hf_home)
    checks["hf_home_exists"] = os.path.isdir(hf_home) if hf_home else False
    checks["hf_token_set"] = bool(os.environ.get("HF_TOKEN", ""))

    try:
        import torch
        checks["gpu_count"] = torch.cuda.device_count()
        checks["gpu_ok"] = checks["gpu_count"] == 1
    except Exception:
        checks["gpu_count"] = -1
        checks["gpu_ok"] = False

    try:
        with tempfile.NamedTemporaryFile(dir="/tmp", delete=True) as f:
            f.write(b"test")
        checks["tmp_writable"] = True
    except Exception:
        checks["tmp_writable"] = False

    model_name = os.environ.get("MODEL_TO_TRAIN", "")
    if hf_home and model_name:
        model_safe = model_name.replace("/", "--")
        model_dir = os.path.join(hf_home, "hub", f"models--{model_safe}")
        checks["model_cached"] = os.path.isdir(model_dir)
        if checks["model_cached"]:
            safetensors = glob.glob(
                os.path.join(model_dir, "**", "*.safetensors"), recursive=True
            )
            checks["model_safetensors"] = len(safetensors)
            snaps = glob.glob(os.path.join(model_dir, "snapshots", "*"))
            checks["preprocessor_config_available"] = any(
                os.path.isfile(os.path.join(s, "preprocessor_config.json"))
                for s in snaps
            ) if snaps else False
        else:
            checks["preprocessor_config_available"] = False
    else:
        checks["model_cached"] = False
        checks["preprocessor_config_available"] = False

    checks["container_env_exists"] = os.path.isfile("/home/ben/.container_env")

    failed = []
    if not checks.get("hf_home_set"):
        failed.append("HF_HOME not set")
    if not checks.get("hf_home_exists"):
        failed.append("HF_HOME dir missing")
    if not checks.get("hf_token_set"):
        failed.append("HF_TOKEN not set")
    if not checks.get("gpu_ok"):
        failed.append(f"GPU count={checks.get('gpu_count', -1)}, expected 1")
    if not checks.get("tmp_writable"):
        failed.append("/tmp not writable")
    if not checks.get("model_cached"):
        failed.append("base model not in HF cache")
    if checks.get("model_cached") and not checks.get("preprocessor_config_available"):
        failed.append("preprocessor_config.json missing")
    if not checks.get("container_env_exists"):
        failed.append(".container_env not found")

    print(json.dumps({"ok": len(failed) == 0, "failed": failed, "checks": checks}))
    sys.exit(0 if len(failed) == 0 else 1)


if __name__ == "__main__":
    main()
