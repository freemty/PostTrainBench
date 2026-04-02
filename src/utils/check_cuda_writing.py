#!/usr/bin/env python3
import os
from pathlib import Path
import subprocess
import torch

def get_gpu_processes(gpu_index):
    """Get processes running on a specific GPU using nvidia-smi."""
    try:
        result = subprocess.run(
            ["nvidia-smi", "--id=" + str(gpu_index),
             "--query-compute-apps=pid,used_memory",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, check=True
        )
        processes = []
        for line in result.stdout.strip().split("\n"):
            if line.strip():
                pid, mem = line.split(",")
                processes.append((int(pid.strip()), float(mem.strip())))
        return processes
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None

def check_gpu():
    if not torch.cuda.is_available():
        print("CUDA is not available")
        return False

    device_count = torch.cuda.device_count()
    print(f"CUDA available with {device_count} device(s)")

    supported_gpu_found = False
    target_index = None
    for i in range(device_count):
        name = torch.cuda.get_device_name(i)
        props = torch.cuda.get_device_properties(i)
        print(f"  GPU {i}: {name} ({props.total_memory / 1e9:.1f} GB)")

        if any(gpu_type in name for gpu_type in ["H100", "H20", "A100", "A800", "L20", "L40"]):
            supported_gpu_found = True
            if target_index is None:
                target_index = i

    if supported_gpu_found:
        print(f"Supported GPU detected (using GPU {target_index})")
    else:
        print("No supported GPU found (need H100/H20/A100/A800/L20/L40)")
        return False

    # Use CUDA_VISIBLE_DEVICES for nvidia-smi query (physical GPU ID)
    # Inside container, torch sees GPU 0 but nvidia-smi --id needs the physical ID
    cuda_vis = os.environ.get("CUDA_VISIBLE_DEVICES", str(target_index))
    physical_gpu = cuda_vis.split(",")[0] if cuda_vis else str(target_index)
    processes = get_gpu_processes(physical_gpu)
    if processes is None:
        print(f"Could not check processes on physical GPU {physical_gpu} (nvidia-smi failed)")
    elif processes:
        print(f"GPU {physical_gpu} has {len(processes)} process(es) running:")
        for pid, mem in processes:
            print(f"    PID {pid}: {mem:.1f} MiB")
        return False
    else:
        print(f"GPU {physical_gpu} is idle (no processes running)")

    # Check that writing a CUDA tensor works
    try:
        x = torch.randn(1, device="cuda")
    except Exception as e:
        print(e)
        return False

    print("Writing a cuda tensor works")
    return True

if __name__ == "__main__":
    cuda_available = check_gpu()
    if not cuda_available:
        Path("cuda_not_available").touch()

    import sys
    sys.exit(0 if cuda_available else 1)
