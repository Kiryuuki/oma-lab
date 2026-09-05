#!/usr/bin/env python3
"""Multi-service Homelab telemetry poller for Omarchy."""

import argparse
import concurrent.futures
import ipaddress
import json
import os
import stat
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import ssl
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_CONFIG = Path.home() / ".config" / "omarchy" / "homelab.json"
DEFAULT_STATE = Path.home() / ".local" / "state" / "omarchy" / "homelab-status.json"

MAX_RESPONSE_BYTES = 512 * 1024  # 512 KB
MAX_ERROR_BYTES = 32 * 1024     # 32 KB
MAX_STATE_BYTES = 512 * 1024    # 512 KB

# Strict verified TLS context
SSL_VERIFIED_CTX = ssl.create_default_context()

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


def is_loopback(hostname: str) -> bool:
    if not hostname:
        return False
    h = hostname.lower().strip("[]")
    if h in ("localhost", "127.0.0.1", "::1"):
        return True
    try:
        ip = ipaddress.ip_address(h)
        return ip.is_loopback
    except ValueError:
        return False


def validate_service_url(url: str, has_credentials: bool = False) -> tuple:
    """
    Validates URL scheme and destination.
    Insecure HTTP is strictly rejected when credentials are present,
    unless targeting validated loopback addresses (127.0.0.1, ::1, localhost).
    """
    url = (url or "").strip()
    if not url:
        raise ValueError("URL cannot be empty")
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme not in ("https", "http"):
        raise ValueError(f"Invalid URL scheme: {parsed.scheme}. Must be https:// or http://")
    if not parsed.netloc or not parsed.hostname:
        raise ValueError("Invalid URL host")

    if parsed.scheme == "http" and has_credentials:
        if not is_loopback(parsed.hostname):
            raise ValueError(
                f"Insecure HTTP scheme is not allowed with credentials for host '{parsed.hostname}' "
                "unless using a literal loopback address (127.0.0.1, ::1, localhost)"
            )
    return url, parsed


class SafeRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Restricts HTTP/HTTPS redirects strictly to the same canonical scheme, host, and port."""
    def __init__(self, allow_http_loopback: bool = False):
        super().__init__()
        self.allow_http_loopback = allow_http_loopback

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        orig_parsed = urllib.parse.urlsplit(req.full_url)
        new_parsed = urllib.parse.urlsplit(newurl)

        if orig_parsed.scheme == "https" and new_parsed.scheme == "http":
            raise urllib.error.HTTPError(
                newurl, code, "Protocol downgrade from HTTPS to HTTP during redirect is forbidden", headers, fp
            )

        if new_parsed.scheme not in ("https", "http"):
            raise urllib.error.HTTPError(
                newurl, code, f"Unsupported redirect scheme: {new_parsed.scheme}", headers, fp
            )

        orig_port = orig_parsed.port or (443 if orig_parsed.scheme == "https" else 80)
        new_port = new_parsed.port or (443 if new_parsed.scheme == "https" else 80)

        if (orig_parsed.scheme != new_parsed.scheme or
            (orig_parsed.hostname or "").lower() != (new_parsed.hostname or "").lower() or
            orig_port != new_port):
            raise urllib.error.HTTPError(
                newurl, code, "Cross-origin redirects are forbidden to prevent credential leakage", headers, fp
            )

        return super().redirect_request(req, fp, code, msg, headers, newurl)


def read_bounded(resp, max_bytes: int = MAX_RESPONSE_BYTES, chunk_size: int = 16384) -> bytes:
    """Reads response body with strict upper byte ceiling to prevent unbounded memory consumption."""
    content_length = resp.headers.get("Content-Length")
    if content_length and content_length.isdigit() and int(content_length) > max_bytes:
        raise ValueError(f"Response Content-Length {content_length} exceeds ceiling of {max_bytes} bytes")

    chunks = []
    total = 0
    while True:
        chunk = resp.read(chunk_size)
        if not chunk:
            break
        total += len(chunk)
        if total > max_bytes:
            raise ValueError(f"Response size exceeded ceiling of {max_bytes} bytes")
        chunks.append(chunk)
    return b"".join(chunks)


def write_atomic(path, doc):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    raw_bytes = (json.dumps(doc, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    if len(raw_bytes) > MAX_STATE_BYTES:
        raise ValueError(f"Payload size {len(raw_bytes)} exceeds ceiling {MAX_STATE_BYTES}")

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


def make_request(url, headers=None, method="GET", timeout=3.5):
    headers = headers or {}
    headers.setdefault("User-Agent", "omarchy-homelab/1.0")

    has_creds = False
    for k in headers:
        if k.lower() in ("authorization", "x-api-key", "x-emby-token", "x-n8n-api-key", "token"):
            has_creds = True
            break

    try:
        valid_url, parsed = validate_service_url(url, has_credentials=has_creds)
    except Exception as e:
        return {
            "ok": False,
            "status": 0,
            "latencyMs": 0,
            "error": f"URL validation error: {str(e)}",
            "json": None,
        }

    allow_loopback = is_loopback(parsed.hostname or "")
    opener = urllib.request.build_opener(
        urllib.request.HTTPSHandler(context=SSL_VERIFIED_CTX),
        SafeRedirectHandler(allow_http_loopback=allow_loopback),
    )
    req = urllib.request.Request(valid_url, headers=headers, method=method)
    start_t = time.perf_counter()
    try:
        with opener.open(req, timeout=timeout) as resp:
            latency = int((time.perf_counter() - start_t) * 1000)
            final_url = resp.geturl()
            final_parsed = urllib.parse.urlsplit(final_url)
            if has_creds and final_parsed.scheme == "http" and not is_loopback(final_parsed.hostname or ""):
                raise ValueError("Final redirected URL resolved to insecure HTTP with credentials")

            data = read_bounded(resp, max_bytes=MAX_RESPONSE_BYTES)
            charset = resp.headers.get_content_charset() or "utf-8"
            text = data.decode(charset, errors="ignore")
            try:
                parsed_json = json.loads(text)
            except Exception:
                parsed_json = None
            return {
                "ok": True,
                "status": resp.status,
                "latencyMs": latency,
                "json": parsed_json,
                "text": text,
            }
    except urllib.error.HTTPError as e:
        latency = int((time.perf_counter() - start_t) * 1000)
        try:
            raw_err = read_bounded(e, max_bytes=MAX_ERROR_BYTES)
            err_json = json.loads(raw_err.decode("utf-8", errors="ignore"))
        except Exception:
            err_json = None
        return {
            "ok": False,
            "status": e.code,
            "latencyMs": latency,
            "error": f"HTTP {e.code}",
            "json": err_json,
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
            active_sessions = [s for s in resp["json"] if s.get("NowPlayingItem")][:50]
            count = len(active_sessions)
            if count > 0:
                item_names = [s["NowPlayingItem"].get("Name", "Media") for s in active_sessions[:2]]
                res["statusText"] = f"{count} active: {', '.join(item_names)}"
                res["badge"] = f"{count} stream{'s' if count != 1 else ''}"
                res["badgeType"] = "success"
            else:
                res["statusText"] = f"Online · Idle ({resp['latencyMs']}ms)"
        else:
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
                records = resp["json"]["records"][:100]
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
            workflows = resp["json"].get("data", [])[:100]
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
        "services": results[:200],
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
