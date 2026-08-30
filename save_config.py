#!/usr/bin/env python3
"""
Helper to modify homelab.json configuration securely from QML.
Reads service payloads via stdin to prevent command-line secret exposure.
"""

import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import time

DEFAULT_CONFIG = Path.home() / ".config" / "omarchy" / "homelab.json"
MAX_CONFIG_BYTES = 512 * 1024  # 512 KB ceiling


def load_config(path=DEFAULT_CONFIG):
    if not path.exists():
        return {"version": 1, "refreshIntervalSeconds": 30, "services": []}
    try:
        st = path.stat()
        if st.st_uid != os.getuid() or not stat.S_ISREG(st.st_mode):
            return {"version": 1, "refreshIntervalSeconds": 30, "services": []}
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
            return data if isinstance(data, dict) else {"version": 1, "refreshIntervalSeconds": 30, "services": []}
    except Exception:
        return {"version": 1, "refreshIntervalSeconds": 30, "services": []}


def save_config(cfg, path=DEFAULT_CONFIG):
    path.parent.mkdir(parents=True, exist_ok=True)
    raw_bytes = (json.dumps(cfg, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    if len(raw_bytes) > MAX_CONFIG_BYTES:
        print(f"Error: Config size {len(raw_bytes)} exceeds {MAX_CONFIG_BYTES} limit", file=sys.stderr)
        return

    handle, temp_name = tempfile.mkstemp(dir=str(path.parent), suffix=".tmp")
    try:
        os.fchmod(handle, 0o600)
        with os.fdopen(handle, "wb") as stream:
            stream.write(raw_bytes)
            stream.flush()
            os.fsync(stream.fileno())
        if path.exists():
            st = path.lstat()
            if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid():
                path.unlink(missing_ok=True)
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
    if not service_json_str or not service_json_str.strip():
        return
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
    elif action == "save":
        # Read payload securely from stdin
        stdin_content = sys.stdin.read().strip()
        add_or_update_service(stdin_content)
