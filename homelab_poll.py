#!/usr/bin/env python3
"""Multi-service Homelab telemetry poller for Omarchy."""

import argparse
import concurrent.futures
import json
import os
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_CONFIG = Path.home() / ".config" / "omarchy" / "homelab.json"
DEFAULT_STATE = Path.home() / ".local" / "state" / "omarchy" / "homelab-status.json"

ICON_MAP = {
    "jellyfin": "󰟀",
    "overseerr": "󰑈",
    "jellyseerr": "󰑈",
    "sonarr": "󰇮",
    "radarr": "󰚌",
    "prowlarr": "󰛄",
    "bazarr": "󰈙",
    "n8n": "󰒓",
    "dokploy": "󰡨",
    "portainer": "󰡨",
    "proxmox": "󰢹",
    "generic": "󰖟",
}


def write_atomic(path, doc):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, temp_name = tempfile.mkstemp(dir=str(path.parent), suffix=".tmp")
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            json.dump(doc, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp_name, path)
    except BaseException:
        Path(temp_name).unlink(missing_ok=True)
        raise


def make_request(url, headers=None, method="GET", timeout=3.5):
    headers = headers or {}
    headers.setdefault("User-Agent", "omarchy-homelab/1.0")
    req = urllib.request.Request(url, headers=headers, method=method)
    start_t = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            latency = int((time.perf_counter() - start_t) * 1000)
            data = resp.read()
            charset = resp.headers.get_content_charset() or "utf-8"
            text = data.decode(charset, errors="ignore")
            try:
                parsed = json.loads(text)
            except Exception:
                parsed = None
            return {
                "ok": True,
                "status": resp.status,
                "latencyMs": latency,
                "json": parsed,
                "text": text,
            }
    except urllib.error.HTTPError as e:
        latency = int((time.perf_counter() - start_t) * 1000)
        return {
            "ok": False,
            "status": e.code,
            "latencyMs": latency,
            "error": f"HTTP {e.code}",
        }
    except Exception as e:
        return {
            "ok": False,
            "status": 0,
            "latencyMs": 0,
            "error": str(e) or "Unreachable",
        }


def poll_service(service):
    s_type = service.get("type", "generic").lower()
    s_name = service.get("name") or s_type.capitalize()
    raw_url = service.get("url", "").rstrip("/")
    api_key = service.get("apiKey", "").strip()
    icon = service.get("icon") or ICON_MAP.get(s_type, "󰖟")

    res = {
        "id": service.get("id"),
        "type": s_type,
        "name": s_name,
        "url": raw_url,
        "enabled": service.get("enabled", True),
        "online": False,
        "latencyMs": 0,
        "statusText": "Disabled" if not service.get("enabled", True) else "Checking...",
        "badge": None,
        "badgeType": "info",
        "icon": icon,
        "details": {},
    }

    if not res["enabled"]:
        return res

    if not raw_url:
        res["statusText"] = "No URL configured"
        return res

    # 1. Jellyfin
    if s_type == "jellyfin":
        url = f"{raw_url}/Sessions"
        headers = {}
        if api_key:
            headers["X-Emby-Token"] = api_key
            headers["Authorization"] = f'MediaBrowser Token="{api_key}"'
        resp = make_request(url, headers=headers)
        if resp["ok"] and isinstance(resp.get("json"), list):
            res["online"] = True
            res["latencyMs"] = resp["latencyMs"]
            active_sessions = [s for s in resp["json"] if s.get("NowPlayingItem")]
            count = len(active_sessions)
            if count > 0:
                item_names = [s["NowPlayingItem"].get("Name", "Media") for s in active_sessions[:2]]
                res["statusText"] = f"{count} active: {', '.join(item_names)}"
                res["badge"] = f"{count} stream{'s' if count != 1 else ''}"
                res["badgeType"] = "success"
            else:
                res["statusText"] = f"Online · Idle ({resp['latencyMs']}ms)"
        else:
            # Fallback to root ping
            ping_resp = make_request(f"{raw_url}/System/Info/Public")
            if ping_resp["ok"]:
                res["online"] = True
                res["latencyMs"] = ping_resp["latencyMs"]
                res["statusText"] = f"Online ({ping_resp['latencyMs']}ms)"
            else:
                res["statusText"] = resp.get("error") or "Offline"

    # 2. Overseerr / Jellyseerr
    elif s_type in ("overseerr", "jellyseerr"):
        url = f"{raw_url}/api/v1/request/count"
        headers = {"X-Api-Key": api_key} if api_key else {}
        resp = make_request(url, headers=headers)
        if resp["ok"] and isinstance(resp.get("json"), dict):
            res["online"] = True
            res["latencyMs"] = resp["latencyMs"]
            pending = resp["json"].get("pending", 0)
            processing = resp["json"].get("processing", 0)
            if pending > 0:
                res["statusText"] = f"{pending} request{'s' if pending != 1 else ''} pending"
                res["badge"] = f"{pending} pending"
                res["badgeType"] = "warning"
            elif processing > 0:
                res["statusText"] = f"{processing} request{'s' if processing != 1 else ''} processing"
                res["badge"] = f"{processing} active"
                res["badgeType"] = "info"
            else:
                res["statusText"] = f"Online · No pending requests ({resp['latencyMs']}ms)"
        else:
            ping_resp = make_request(f"{raw_url}/api/v1/status")
            if ping_resp["ok"]:
                res["online"] = True
                res["latencyMs"] = ping_resp["latencyMs"]
                res["statusText"] = f"Online ({ping_resp['latencyMs']}ms)"
            else:
                res["statusText"] = resp.get("error") or "Offline"

    # 3. Sonarr / Radarr / Prowlarr
    elif s_type in ("sonarr", "radarr", "prowlarr", "bazarr"):
        url = f"{raw_url}/api/v3/queue" if s_type != "bazarr" else f"{raw_url}/api/system/status"
        headers = {"X-Api-Key": api_key} if api_key else {}
        resp = make_request(url, headers=headers)
        if resp["ok"]:
            res["online"] = True
            res["latencyMs"] = resp["latencyMs"]
            if isinstance(resp.get("json"), dict) and "records" in resp["json"]:
                records = resp["json"]["records"]
                total = len(records)
                if total > 0:
                    first = records[0].get("title", "Item")
                    res["statusText"] = f"{total} in queue · {first}"
                    res["badge"] = f"{total} downloading"
                    res["badgeType"] = "info"
                else:
                    res["statusText"] = f"Online · Queue empty ({resp['latencyMs']}ms)"
            else:
                res["statusText"] = f"Online ({resp['latencyMs']}ms)"
        else:
            # Fallback ping
            ping_resp = make_request(f"{raw_url}/api/v3/system/status", headers=headers)
            if ping_resp["ok"]:
                res["online"] = True
                res["latencyMs"] = ping_resp["latencyMs"]
                res["statusText"] = f"Online ({ping_resp['latencyMs']}ms)"
            else:
                res["statusText"] = resp.get("error") or "Offline"

    # 4. n8n
    elif s_type == "n8n":
        url = f"{raw_url}/api/v1/workflows"
        headers = {"X-N8N-API-KEY": api_key} if api_key else {}
        resp = make_request(url, headers=headers)
        if resp["ok"] and isinstance(resp.get("json"), dict):
            res["online"] = True
            res["latencyMs"] = resp["latencyMs"]
            workflows = resp["json"].get("data", [])
            active = sum(1 for w in workflows if w.get("active"))
            res["statusText"] = f"{active} active / {len(workflows)} total workflows"
            if active > 0:
                res["badge"] = f"{active} active"
                res["badgeType"] = "success"
        else:
            ping_resp = make_request(f"{raw_url}/healthz")
            if ping_resp["ok"]:
                res["online"] = True
                res["latencyMs"] = ping_resp["latencyMs"]
                res["statusText"] = f"Online ({ping_resp['latencyMs']}ms)"
            else:
                res["statusText"] = resp.get("error") or "Offline"

    # 5. Dokploy
    elif s_type == "dokploy":
        # Check standard endpoints with Authorization
        headers = {"Authorization": f"Bearer {api_key}"} if api_key else {}
        resp = make_request(f"{raw_url}/api/v1/version", headers=headers)
        if resp["ok"]:
            res["online"] = True
            res["latencyMs"] = resp["latencyMs"]
            v = resp.get("json", {}).get("version", "")
            app_name = resp.get("json", {}).get("app_name", "Dokploy")
            res["statusText"] = f"Online · {app_name} {v} ({resp['latencyMs']}ms)".strip()
        else:
            ping_resp = make_request(raw_url, headers=headers)
            if ping_resp["ok"]:
                res["online"] = True
                res["latencyMs"] = ping_resp["latencyMs"]
                res["statusText"] = f"Online ({ping_resp['latencyMs']}ms)"
            else:
                res["statusText"] = resp.get("error") or "Offline"

    # 6. Generic HTTP / Web
    else:
        headers = {"Authorization": f"Bearer {api_key}"} if api_key else {}
        resp = make_request(raw_url, headers=headers)
        if resp["ok"]:
            res["online"] = True
            res["latencyMs"] = resp["latencyMs"]
            res["statusText"] = f"Online ({resp['latencyMs']}ms)"
        else:
            res["statusText"] = resp.get("error") or "Offline"

    return res


def poll_all(config_path=DEFAULT_CONFIG, out_path=DEFAULT_STATE):
    if not Path(config_path).exists():
        print(f"Config {config_path} not found.", file=sys.stderr)
        return

    with open(config_path, "r", encoding="utf-8") as f:
        cfg = json.load(f)

    services = cfg.get("services", [])
    results = []

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
        futures = [executor.submit(poll_service, s) for s in services]
        for f in concurrent.futures.as_completed(futures):
            try:
                results.append(f.result())
            except Exception as e:
                print(f"Error polling service: {e}", file=sys.stderr)

    # Sort in original order of config
    order_map = {s.get("id"): idx for idx, s in enumerate(services)}
    results.sort(key=lambda r: order_map.get(r.get("id"), 999))

    total_enabled = sum(1 for r in results if r.get("enabled"))
    total_online = sum(1 for r in results if r.get("enabled") and r.get("online"))
    alerts = sum(1 for r in results if r.get("enabled") and not r.get("online"))

    doc = {
        "version": 1,
        "lastChecked": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "total": len(results),
            "enabled": total_enabled,
            "online": total_online,
            "alerts": alerts,
        },
        "services": results,
    }

    write_atomic(out_path, doc)
    print(f"Successfully polled {len(results)} services ({total_online}/{total_enabled} online) to {out_path}")


def main():
    parser = argparse.ArgumentParser(description="Homelab Poller")
    parser.add_argument("--config", default=DEFAULT_CONFIG, help="Path to homelab.json")
    parser.add_argument("--out", default=DEFAULT_STATE, help="Path to output status JSON")
    args = parser.parse_args()
    poll_all(args.config, args.out)


if __name__ == "__main__":
    main()
