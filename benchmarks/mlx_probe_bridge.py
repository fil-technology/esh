"""Measurement wrapper for esh serve (used by mlx_conversation_cache_validation.py)'s MLX worker (ESH_MLX_VLM_BRIDGE points here). Loads the real bridge named by
PROBE_BRIDGE, tees every worker event with a timestamp to PROBE_LOG, and lets PROBE_PRESSURE_FLAG (a file path) stand
in for the system's critical-memory signal. Then runs the bridge's normal entry point."""
import importlib.util
import json
import os
import sys
import time

real = os.environ["PROBE_BRIDGE"]
sys.path.insert(0, os.path.dirname(real))
spec = importlib.util.spec_from_file_location("mlx_vlm_bridge", real)
bridge = importlib.util.module_from_spec(spec)
sys.modules["mlx_vlm_bridge"] = bridge
spec.loader.exec_module(bridge)

_emit = bridge._emit_json_line
log_path = os.environ.get("PROBE_LOG")


def emit(payload):
    if log_path and payload.get("event") in ("done", "error", "ready", "caches-dropped"):
        with open(log_path, "a") as f:
            f.write(json.dumps({"t": time.time(), **payload}) + "\n")
    _emit(payload)


bridge._emit_json_line = emit
flag = os.environ.get("PROBE_PRESSURE_FLAG")
if flag:
    _real_pressure = bridge._mem_pressure_critical
    bridge._mem_pressure_critical = lambda: os.path.exists(flag) or _real_pressure()
bridge.main()
