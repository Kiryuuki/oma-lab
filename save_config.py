#!/usr/bin/env python3
"""Helper to modify homelab.json configuration from QML."""

import json
import os
import sys
import tempfile
import time
from pathlib import Path

DEFAULT_CONFIG = Path.home() / ".config" / "omarchy" / "homelab.json"


def load_config(path=DEFAULT_CONFIG):
    if not path.exists():
        return {"version": 1, "refreshIntervalSeconds": 30, "services": []}
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def save_config(cfg, path=DEFAULT_CONFIG):
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, temp_name = tempfile.mkstemp(dir=str(path.parent), suffix=".tmp")
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            json.dump(cfg, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp_name, path)
    except BaseException:
        Path(temp_name).unlink(missing_ok=True)
        raise


def toggle_service(service_id):
    cfg = load_config()
    for s in cfg.get("services", []):
        if s.get("id") == service_id:
            s["enabled"] = not s.get("enabled", True)
            break
    save_config(cfg)
    print(f"Toggled {service_id}")


def delete_service(service_id):
    cfg = load_config()
    cfg["services"] = [s for s in cfg.get("services", []) if s.get("id") != service_id]
    save_config(cfg)
    print(f"Deleted {service_id}")


def add_or_update_service(service_json_str):
    new_s = json.loads(service_json_str)
    cfg = load_config()
    services = cfg.setdefault("services", [])

    s_id = new_s.get("id") or f"{new_s.get('type', 'app')}-{int(time.time())}"
    new_s["id"] = s_id

    found = False
    for idx, s in enumerate(services):
        if s.get("id") == s_id:
            services[idx] = new_s
            found = True
            break
    if not found:
        services.append(new_s)

    save_config(cfg)
    print(f"Saved service {s_id}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(1)
    action = sys.argv[1]
    if action == "toggle" and len(sys.argv) >= 3:
        toggle_service(sys.argv[2])
    elif action == "delete" and len(sys.argv) >= 3:
        delete_service(sys.argv[2])
    elif action == "save" and len(sys.argv) >= 3:
        add_or_update_service(sys.argv[2])
