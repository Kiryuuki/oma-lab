#!/usr/bin/env python3
"""
Homelab Engine for Omarchy
Handles deep API polling, healthcheck fallbacks, endpoint auto-discovery,
DashboardIcons fetching, Proxmox cluster metrics, n8n active sorting, and actions.
"""

import argparse
import concurrent.futures
import json
import os
import re
import ssl
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
ICONS_CACHE_DIR = Path.home() / ".local" / "state" / "omarchy" / "homelab-icons"
LOCAL_ASSETS_DIR = Path.home() / ".config" / "omarchy" / "plugins" / "kiryuuki.oma-lab" / "assets"

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
    "kasm": "󰢹",
    "plex": "󰟀",
    "pihole": "󰞌",
    "adguard": "󰞌",
    "nextcloud": "󰅟",
    "homeassistant": "󰋜",
    "truenas": "󰋊",
    "vaultwarden": "󰌋",
    "generic": "󰖟",
}

ICON_ALIASES = {
    "kasm": "kasm-workspaces",
    "kasm-workspace": "kasm-workspaces",
    "adguard": "adguard-home",
    "adguardhome": "adguard-home",
    "pihole": "pi-hole",
    "homeassistant": "home-assistant",
    "home-assistant": "home-assistant",
    "uptime-kuma": "uptime-kuma",
    "uptimekuma": "uptime-kuma",
    "paperless": "paperless-ngx",
    "paperless-ngx": "paperless-ngx",
}

# SSL context allowing self-signed certificates on local LAN instances
SSL_UNVERIFIED_CTX = ssl.create_default_context()
SSL_UNVERIFIED_CTX.check_hostname = False
SSL_UNVERIFIED_CTX.verify_mode = ssl.CERT_NONE


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


def format_bytes(bytes_val):
    if not bytes_val or bytes_val <= 0:
        return "0 B"
    units = ["B", "KB", "MB", "GB", "TB", "PB"]
    idx = 0
    val = float(bytes_val)
    while val >= 1024.0 and idx < len(units) - 1:
        val /= 1024.0
        idx += 1
    return f"{val:.1f} {units[idx]}"


def build_proxmox_auth_header(api_key, api_secret):
    key = str(api_key or "").strip()
    secret = str(api_secret or "").strip()
    if not key and not secret:
        return ""

    if key.startswith("PVEAPIToken="):
        return key
    if key.startswith("PVEAPIToken "):
        return key.replace("PVEAPIToken ", "PVEAPIToken=")
    if "=" in key and not secret:
        return f"PVEAPIToken={key}"
    if key and secret:
        return f"PVEAPIToken={key}={secret}"
    return f"PVEAPIToken={key}"


def make_request(url, headers=None, method="GET", body=None, timeout=4.0):
    headers = headers or {}
    headers.setdefault("User-Agent", "omarchy-homelab/2.0")
    if body is not None and isinstance(body, (dict, list)):
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    elif body is not None and isinstance(body, str):
        data = body.encode("utf-8")
    else:
        data = None

    req = urllib.request.Request(url, headers=headers, data=data, method=method)
    start_t = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=SSL_UNVERIFIED_CTX) as resp:
            latency = int((time.perf_counter() - start_t) * 1000)
            raw = resp.read()
            charset = resp.headers.get_content_charset() or "utf-8"
            text = raw.decode(charset, errors="ignore")
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
        try:
            raw_err = e.read()
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
            "json": None,
        }


def try_healthcheck_fallback(raw_url):
    endpoints = [
        "/api/__healthcheck",
        "/healthz",
        "/api/v1/health",
        "/api/health",
        "/",
    ]
    for ep in endpoints:
        res = make_request(f"{raw_url}{ep}", timeout=2.5)
        if res["ok"] or (res.get("status", 0) in (200, 204, 301, 302, 401, 403)):
            return {
                "reachable": True,
                "latencyMs": res.get("latencyMs", 15),
                "endpoint": ep,
            }
    return {"reachable": False, "latencyMs": 0, "endpoint": ""}


def fetch_dashboard_icon(name_or_type):
    if not name_or_type:
        return ""

    raw_clean = name_or_type.strip().lower()
    slug = re.sub(r"[^a-z0-9]+", "-", raw_clean).strip("-")
    slug = ICON_ALIASES.get(slug, slug)

    ICONS_CACHE_DIR.mkdir(parents=True, exist_ok=True)
    cached_file = ICONS_CACHE_DIR / f"{slug}.svg"
    if cached_file.exists() and cached_file.stat().st_size > 50:
        return str(cached_file)

    local_file = LOCAL_ASSETS_DIR / f"{slug}.svg"
    if local_file.exists() and local_file.stat().st_size > 50:
        return str(local_file)

    urls = [
        f"https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/{slug}.svg",
        f"https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/svg/{slug}.svg",
    ]

    for cdn_url in urls:
        try:
            req = urllib.request.Request(cdn_url, headers={"User-Agent": "omarchy-homelab/2.0"})
            with urllib.request.urlopen(req, timeout=4, context=SSL_UNVERIFIED_CTX) as resp:
                if resp.status == 200:
                    content = resp.read()
                    if b"<svg" in content:
                        with open(cached_file, "wb") as f:
                            f.write(content)
                        return str(cached_file)
        except Exception:
            continue

    return ""


# =========================================================================
# 1. API SNIFFER & DISCOVERY (Proxmox, Kasm, n8n, etc.)
# =========================================================================
def sniff_endpoints(service_type, url, api_key="", api_secret=""):
    url = url.rstrip("/")
    api_key = api_key.strip()
    api_secret = api_secret.strip()
    s_type = service_type.lower()

    icon_path = fetch_dashboard_icon(s_type)

    discovery = {
        "serviceType": s_type,
        "url": url,
        "reachable": False,
        "authValid": False,
        "fallbackActive": False,
        "permissionWarning": None,
        "iconPath": icon_path,
        "serverInfo": {},
        "discoveredWidgets": [],
    }

    # 1. Proxmox VE (PVEAPIToken=USER@REALM!TOKENID=SECRET)
    if s_type == "proxmox":
        auth_header = build_proxmox_auth_header(api_key, api_secret)
        headers = {"Authorization": auth_header} if auth_header else {}

        ver_resp = make_request(f"{url}/api2/json/version", headers=headers)
        if ver_resp["ok"] and isinstance(ver_resp.get("json"), dict):
            discovery["reachable"] = True
            discovery["authValid"] = True
            discovery["serverInfo"] = ver_resp["json"].get("data", {})

            # Check if token has Sys.Audit permission for metrics
            node_status_resp = make_request(f"{url}/api2/json/nodes/pve/status", headers=headers)
            if not node_status_resp["ok"] and node_status_resp.get("status") == 403:
                discovery["permissionWarning"] = "Token missing 'Sys.Audit' or 'PVEAuditor' role on path '/'"

            discovery["discoveredWidgets"].append({
                "id": "pve_cluster",
                "label": "Cluster Metrics (CPU, RAM, Disk)",
                "desc": "Real-time cluster CPU load, memory utilization, and storage capacity",
                "default": True,
            })
            discovery["discoveredWidgets"].append({
                "id": "pve_vms_lxc",
                "label": "QEMU Virtual Machines & LXC Containers",
                "desc": "Active/inactive counts and live statuses for all VMs and LXCs",
                "default": True,
            })
        else:
            fb = try_healthcheck_fallback(url)
            if fb["reachable"]:
                discovery["reachable"] = True
                discovery["fallbackActive"] = True

    # 2. KASM Workspaces
    elif s_type in ("kasm", "kasm-workspaces", "kasm_workspaces"):
        payload = {"api_key": api_key, "api_key_secret": api_secret}
        status_resp = make_request(f"{url}/api/public/get_status", method="POST", body=payload)
        if status_resp["ok"] and isinstance(status_resp.get("json"), dict):
            discovery["reachable"] = True
            discovery["authValid"] = True
            discovery["serverInfo"] = status_resp["json"]
            discovery["discoveredWidgets"].append({
                "id": "kasm_sessions",
                "label": "Active Workspaces & User Sessions",
                "desc": "Monitor active remote container sessions and operational status",
                "default": True,
            })
        else:
            fb = try_healthcheck_fallback(url)
            if fb["reachable"]:
                discovery["reachable"] = True
                discovery["fallbackActive"] = True

    # 3. Jellyfin / Emby
    elif s_type == "jellyfin":
        pub = make_request(f"{url}/System/Info/Public")
        if pub["ok"] and isinstance(pub.get("json"), dict):
            discovery["reachable"] = True
            discovery["serverInfo"] = {
                "serverName": pub["json"].get("ServerName", "Jellyfin"),
                "version": pub["json"].get("Version", ""),
                "operatingSystem": pub["json"].get("OperatingSystem", ""),
            }

        headers = {
            "X-Emby-Token": api_key,
            "Authorization": f'MediaBrowser Token="{api_key}"',
        }
        auth_resp = make_request(f"{url}/System/Info", headers=headers)
        if auth_resp["ok"]:
            discovery["authValid"] = True
            discovery["reachable"] = True
            discovery["discoveredWidgets"].append({
                "id": "now_playing",
                "label": "Now Playing & Active Streams",
                "desc": "Shows active media titles, user names, devices, and real-time playback progress",
                "default": True,
            })
        else:
            fb = try_healthcheck_fallback(url)
            if fb["reachable"]:
                discovery["reachable"] = True
                discovery["fallbackActive"] = True

    # 4. Overseerr / Jellyseerr
    elif s_type in ("overseerr", "jellyseerr"):
        headers = {"X-Api-Key": api_key}
        stat = make_request(f"{url}/api/v1/status", headers=headers)
        if stat["ok"] and isinstance(stat.get("json"), dict):
            discovery["reachable"] = True
            discovery["authValid"] = True
            discovery["serverInfo"] = {
                "version": stat["json"].get("version", ""),
                "commit": stat["json"].get("commitTag", ""),
            }
            discovery["discoveredWidgets"].append({
                "id": "pending_requests",
                "label": "Pending Requests & Quick Approval",
                "desc": "List pending movie/TV requests with 1-click Approve and Decline buttons",
                "default": True,
            })
        else:
            fb = try_healthcheck_fallback(url)
            if fb["reachable"]:
                discovery["reachable"] = True
                discovery["fallbackActive"] = True

    # 5. Sonarr / Radarr / Prowlarr / Bazarr
    elif s_type in ("sonarr", "radarr", "prowlarr", "bazarr"):
        headers = {"X-Api-Key": api_key}
        stat = make_request(f"{url}/api/v3/system/status", headers=headers)
        if stat["ok"] and isinstance(stat.get("json"), dict):
            discovery["reachable"] = True
            discovery["authValid"] = True
            discovery["serverInfo"] = {
                "appName": stat["json"].get("appName", s_type.capitalize()),
                "version": stat["json"].get("version", ""),
            }
            discovery["discoveredWidgets"].append({
                "id": "download_queue",
                "label": "Live Download Queue",
                "desc": "Real-time download progress, download speed, ETA, and queue count",
                "default": True,
            })
        else:
            fb = try_healthcheck_fallback(url)
            if fb["reachable"]:
                discovery["reachable"] = True
                discovery["fallbackActive"] = True

    # 6. n8n
    elif s_type == "n8n":
        headers = {"X-N8N-API-KEY": api_key}
        wf = make_request(f"{url}/api/v1/workflows?limit=250", headers=headers)
        if wf["ok"]:
            discovery["reachable"] = True
            discovery["authValid"] = True
            discovery["discoveredWidgets"].append({
                "id": "active_workflows",
                "label": "Workflows Monitor & Quick Toggle",
                "desc": "Lists active and inactive workflows with on/off status toggle controls",
                "default": True,
            })
        else:
            fb = try_healthcheck_fallback(url)
            if fb["reachable"]:
                discovery["reachable"] = True
                discovery["fallbackActive"] = True

    # 7. Dokploy
    elif s_type == "dokploy":
        headers = {"Authorization": f"Bearer {api_key}"}
        v = make_request(f"{url}/api/v1/version", headers=headers)
        if v["ok"]:
            discovery["reachable"] = True
            discovery["authValid"] = True
            discovery["serverInfo"] = v.get("json", {})
            discovery["discoveredWidgets"].append({
                "id": "containers_status",
                "label": "Applications & Compose Stacks",
                "desc": "Monitor running applications, compose projects, and deployment statuses",
                "default": True,
            })
        else:
            fb = try_healthcheck_fallback(url)
            if fb["reachable"]:
                discovery["reachable"] = True
                discovery["fallbackActive"] = True

    # 8. Generic / Other Apps
    else:
        fb = try_healthcheck_fallback(url)
        if fb["reachable"]:
            discovery["reachable"] = True
            discovery["discoveredWidgets"].append({
                "id": "uptime_ping",
                "label": "Uptime & Latency Monitor",
                "desc": "Live HTTP response and latency measurement",
                "default": True,
            })

    return discovery


# =========================================================================
# 2. DEEP TELEMETRY POLLING WITH PROXMOX & N8N SORTING
# =========================================================================
def poll_service_deep(service):
    s_type = service.get("type", "generic").lower()
    s_name = service.get("name") or s_type.capitalize()
    raw_url = service.get("url", "").rstrip("/")
    api_key = service.get("apiKey", "").strip()
    api_secret = service.get("apiSecret", "").strip()
    icon = service.get("icon") or ICON_MAP.get(s_type, "󰖟")

    icon_path = service.get("iconPath") or fetch_dashboard_icon(s_type) or fetch_dashboard_icon(s_name)

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
        "iconPath": icon_path,
        "widgetsData": {},
    }

    if not res["enabled"] or not raw_url:
        return res

    api_succeeded = False

    # ----------------------------------------------------
    # 1. PROXMOX VE DEEP CLUSTER & NODE/VM METRICS
    # ----------------------------------------------------
    if s_type == "proxmox":
        auth_header = build_proxmox_auth_header(api_key, api_secret)
        headers = {"Authorization": auth_header} if auth_header else {}

        # 1. First probe version or nodes to verify auth
        ver_resp = make_request(f"{raw_url}/api2/json/version", headers=headers)
        nodes_resp = make_request(f"{raw_url}/api2/json/nodes", headers=headers)

        if ver_resp["ok"] or nodes_resp["ok"]:
            api_succeeded = True
            res["online"] = True
            res["latencyMs"] = ver_resp.get("latencyMs") or nodes_resp.get("latencyMs") or 10

            nodes_data = nodes_resp.get("json", {}).get("data", []) if nodes_resp.get("ok") else []
            node_names = [n.get("node") for n in nodes_data if n.get("node")] or ["pve"]

            vms_list = []
            lxc_list = []
            total_mem = 0
            used_mem = 0
            total_disk = 0
            used_disk = 0
            cpu_usages = []
            permission_error = False

            # Query each node's status, VMs, and LXCs directly
            for node in node_names:
                # Node live metrics
                n_status_resp = make_request(f"{raw_url}/api2/json/nodes/{node}/status", headers=headers)
                if n_status_resp["ok"] and isinstance(n_status_resp.get("json"), dict):
                    nd = n_status_resp["json"].get("data", {})
                    # CPU
                    if "cpu" in nd:
                        cpu_usages.append(float(nd.get("cpu", 0)))
                    # Memory
                    mem_obj = nd.get("memory", {})
                    if mem_obj:
                        total_mem += mem_obj.get("total", 0)
                        used_mem += mem_obj.get("used", 0)
                    elif nd.get("maxmem"):
                        total_mem += nd.get("maxmem", 0)
                        used_mem += nd.get("mem", 0)
                    # Rootfs/Disk
                    disk_obj = nd.get("rootfs", {})
                    if disk_obj:
                        total_disk += disk_obj.get("total", 0)
                        used_disk += disk_obj.get("used", 0)
                elif n_status_resp.get("status") == 403:
                    permission_error = True

                # Node VMs (QEMU)
                qemu_resp = make_request(f"{raw_url}/api2/json/nodes/{node}/qemu", headers=headers)
                if qemu_resp["ok"] and isinstance(qemu_resp.get("json"), dict):
                    for vm in qemu_resp["json"].get("data", []):
                        vms_list.append({
                            "id": vm.get("vmid"),
                            "name": vm.get("name") or f"VM {vm.get('vmid')}",
                            "status": vm.get("status", "stopped"),
                            "running": vm.get("status") == "running",
                            "node": node,
                            "cpu": int(round(float(vm.get("cpu", 0)) * 100)),
                            "memStr": format_bytes(vm.get("mem", 0)),
                            "maxmemStr": format_bytes(vm.get("maxmem", 0)),
                        })

                # Node LXCs
                lxc_resp = make_request(f"{raw_url}/api2/json/nodes/{node}/lxc", headers=headers)
                if lxc_resp["ok"] and isinstance(lxc_resp.get("json"), dict):
                    for ct in lxc_resp["json"].get("data", []):
                        lxc_list.append({
                            "id": ct.get("vmid"),
                            "name": ct.get("name") or f"CT {ct.get('vmid')}",
                            "status": ct.get("status", "stopped"),
                            "running": ct.get("status") == "running",
                            "node": node,
                            "cpu": int(round(float(ct.get("cpu", 0)) * 100)),
                            "memStr": format_bytes(ct.get("mem", 0)),
                            "maxmemStr": format_bytes(ct.get("maxmem", 0)),
                        })

            # Check cluster resources as complementary source
            res_resp = make_request(f"{raw_url}/api2/json/cluster/resources", headers=headers)
            if res_resp["ok"] and isinstance(res_resp.get("json"), dict):
                items = res_resp["json"].get("data", [])
                for item in items:
                    itype = item.get("type")
                    if itype == "qemu" and not any(v["id"] == item.get("vmid") for v in vms_list):
                        vms_list.append({
                            "id": item.get("vmid"),
                            "name": item.get("name") or f"VM {item.get('vmid')}",
                            "status": item.get("status", "stopped"),
                            "running": item.get("status") == "running",
                            "node": item.get("node", "pve"),
                            "cpu": int(round(float(item.get("cpu", 0)) * 100)),
                            "memStr": format_bytes(item.get("mem", 0)),
                            "maxmemStr": format_bytes(item.get("maxmem", 0)),
                        })
                    elif itype == "lxc" and not any(c["id"] == item.get("vmid") for c in lxc_list):
                        lxc_list.append({
                            "id": item.get("vmid"),
                            "name": item.get("name") or f"CT {item.get('vmid')}",
                            "status": item.get("status", "stopped"),
                            "running": item.get("status") == "running",
                            "node": item.get("node", "pve"),
                            "cpu": int(round(float(item.get("cpu", 0)) * 100)),
                            "memStr": format_bytes(item.get("mem", 0)),
                            "maxmemStr": format_bytes(item.get("maxmem", 0)),
                        })
                    elif itype == "storage" and total_disk == 0:
                        total_disk += item.get("maxdisk", 0)
                        used_disk += item.get("disk", 0)

            # Sort VMs & LXCs: running first, then ID
            vms_list.sort(key=lambda x: (not x["running"], int(x["id"]) if str(x["id"]).isdigit() else 9999))
            lxc_list.sort(key=lambda x: (not x["running"], int(x["id"]) if str(x["id"]).isdigit() else 9999))

            avg_cpu = int(round((sum(cpu_usages) / len(cpu_usages) * 100))) if cpu_usages else 0
            mem_percent = int(round((used_mem / total_mem * 100))) if total_mem > 0 else 0
            disk_percent = int(round((used_disk / total_disk * 100))) if total_disk > 0 else 0

            running_vms = sum(1 for v in vms_list if v["running"])
            running_lxcs = sum(1 for c in lxc_list if c["running"])

            res["widgetsData"]["proxmox"] = {
                "nodesCount": len(node_names),
                "avgCpuPercent": avg_cpu,
                "memUsedStr": format_bytes(used_mem),
                "memTotalStr": format_bytes(total_mem),
                "memPercent": mem_percent,
                "diskUsedStr": format_bytes(used_disk),
                "diskTotalStr": format_bytes(total_disk),
                "diskPercent": disk_percent,
                "vms": vms_list,
                "vmsRunning": running_vms,
                "vmsTotal": len(vms_list),
                "lxcs": lxc_list,
                "lxcsRunning": running_lxcs,
                "lxcsTotal": len(lxc_list),
                "hasMetrics": total_mem > 0 or len(vms_list) > 0 or len(lxc_list) > 0,
                "permissionWarning": permission_error,
            }

            if permission_error and total_mem == 0:
                res["statusText"] = f"Online · Token needs PVEAuditor role on / ({res['latencyMs']}ms)"
                res["badge"] = "Permission Needed"
                res["badgeType"] = "warning"
            elif total_mem > 0 or (running_vms + running_lxcs > 0):
                res["statusText"] = f"CPU: {avg_cpu}% · RAM: {format_bytes(used_mem)}/{format_bytes(total_mem)} ({mem_percent}%) · {running_vms}/{len(vms_list)} VMs · {running_lxcs}/{len(lxc_list)} LXCs"
                res["badge"] = f"{running_vms + running_lxcs} running"
                res["badgeType"] = "success"
            else:
                pve_ver = ver_resp.get("json", {}).get("data", {}).get("version", "PVE")
                res["statusText"] = f"Proxmox VE {pve_ver} · {len(node_names)} node online ({res['latencyMs']}ms)"
                res["badge"] = f"{len(node_names)} node"
                res["badgeType"] = "success"

    # ----------------------------------------------------
    # 2. KASM WORKSPACES
    # ----------------------------------------------------
    elif s_type in ("kasm", "kasm-workspaces", "kasm_workspaces"):
        payload = {"api_key": api_key, "api_key_secret": api_secret}
        kasm_resp = make_request(f"{raw_url}/api/public/get_status", method="POST", body=payload)
        if kasm_resp["ok"] and isinstance(kasm_resp.get("json"), dict):
            api_succeeded = True
            res["online"] = True
            res["latencyMs"] = kasm_resp["latencyMs"]
            active_sessions = kasm_resp["json"].get("operational_status", {}).get("total_sessions", 0)

            res["widgetsData"]["kasm_sessions"] = {
                "totalSessions": active_sessions,
                "status": kasm_resp["json"].get("status", "operational"),
            }
            if active_sessions > 0:
                res["statusText"] = f"{active_sessions} active container session{'s' if active_sessions != 1 else ''}"
                res["badge"] = f"{active_sessions} session{'s' if active_sessions != 1 else ''}"
                res["badgeType"] = "info"
            else:
                res["statusText"] = f"Online · Operational ({kasm_resp['latencyMs']}ms)"

    # ----------------------------------------------------
    # 3. JELLYFIN
    # ----------------------------------------------------
    elif s_type == "jellyfin":
        headers = {
            "X-Emby-Token": api_key,
            "Authorization": f'MediaBrowser Token="{api_key}"',
        } if api_key else {}

        resp = make_request(f"{raw_url}/Sessions", headers=headers)
        if resp["ok"] and isinstance(resp.get("json"), list):
            api_succeeded = True
            res["online"] = True
            res["latencyMs"] = resp["latencyMs"]
            active_sessions = []
            for s in resp["json"]:
                item = s.get("NowPlayingItem")
                if not item:
                    continue
                pos_ticks = s.get("PlayState", {}).get("PositionTicks", 0)
                run_ticks = item.get("RunTimeTicks", 1)
                percent = int(min(100, max(0, (pos_ticks / run_ticks) * 100))) if run_ticks > 0 else 0

                media_type = item.get("Type", "Media")
                series_name = item.get("SeriesName", "")
                ep_title = item.get("Name", "")
                full_title = f"{series_name} - {ep_title}" if series_name else ep_title

                active_sessions.append({
                    "id": s.get("Id"),
                    "userName": s.get("UserName", "User"),
                    "deviceName": s.get("DeviceName", "Client"),
                    "client": s.get("Client", ""),
                    "mediaTitle": full_title or "Playing",
                    "mediaType": media_type,
                    "progressPercent": percent,
                    "isPaused": s.get("PlayState", {}).get("IsPaused", False),
                    "isTranscoding": bool(s.get("TranscodingInfo")),
                })

            res["widgetsData"]["now_playing"] = {
                "sessions": active_sessions,
                "count": len(active_sessions),
            }

            if active_sessions:
                first = active_sessions[0]
                res["statusText"] = f"{first['userName']}: {first['mediaTitle']} ({first['progressPercent']}%)"
                res["badge"] = f"{len(active_sessions)} stream{'s' if len(active_sessions) != 1 else ''}"
                res["badgeType"] = "success"
            else:
                res["statusText"] = f"Online · Idle ({resp['latencyMs']}ms)"

    # ----------------------------------------------------
    # 4. OVERSEERR / JELLYSEERR
    # ----------------------------------------------------
    elif s_type in ("overseerr", "jellyseerr"):
        headers = {"X-Api-Key": api_key} if api_key else {}
        count_res = make_request(f"{raw_url}/api/v1/request/count", headers=headers)
        list_res = make_request(f"{raw_url}/api/v1/request?take=10&skip=0&filter=pending", headers=headers)

        if count_res["ok"] and isinstance(count_res.get("json"), dict):
            api_succeeded = True
            res["online"] = True
            res["latencyMs"] = count_res["latencyMs"]
            pending_count = count_res["json"].get("pending", 0)
            processing_count = count_res["json"].get("processing", 0)

            pending_items = []
            if list_res["ok"] and isinstance(list_res.get("json"), dict):
                results = list_res["json"].get("results", [])
                for r in results:
                    media = r.get("media", {})
                    title = media.get("title") or media.get("name") or f"Request #{r.get('id')}"
                    requester = r.get("requestedBy", {}).get("displayName") or r.get("requestedBy", {}).get("email") or "User"
                    pending_items.append({
                        "id": r.get("id"),
                        "mediaId": media.get("id"),
                        "title": title,
                        "type": r.get("type", "movie"),
                        "requestedBy": requester,
                        "status": r.get("status", 1),
                        "createdAt": r.get("createdAt", ""),
                    })

            res["widgetsData"]["pending_requests"] = {
                "pendingCount": pending_count,
                "processingCount": processing_count,
                "requests": pending_items,
            }

            if pending_count > 0:
                res["statusText"] = f"{pending_count} pending request{'s' if pending_count != 1 else ''}"
                res["badge"] = f"{pending_count} pending"
                res["badgeType"] = "warning"
            elif processing_count > 0:
                res["statusText"] = f"{processing_count} processing"
                res["badge"] = f"{processing_count} active"
                res["badgeType"] = "info"
            else:
                res["statusText"] = f"Online · All requests approved ({count_res['latencyMs']}ms)"

    # ----------------------------------------------------
    # 5. SONARR / RADARR / PROWLARR / BAZARR
    # ----------------------------------------------------
    elif s_type in ("sonarr", "radarr", "prowlarr", "bazarr"):
        headers = {"X-Api-Key": api_key} if api_key else {}
        q_res = make_request(f"{raw_url}/api/v3/queue?page=1&pageSize=10&includeSeries=true&includeEpisode=true", headers=headers)
        if q_res["ok"] and isinstance(q_res.get("json"), dict):
            api_succeeded = True
            res["online"] = True
            res["latencyMs"] = q_res["latencyMs"]
            records = q_res["json"].get("records", [])

            queue_items = []
            for r in records:
                size = r.get("size", 0)
                sizeleft = r.get("sizeleft", 0)
                progress = int(max(0, min(100, ((size - sizeleft) / size) * 100))) if size > 0 else 0

                title = r.get("title") or "Item"
                if "episode" in r and "series" in r:
                    title = f"{r['series'].get('title', '')} - S{r['episode'].get('seasonNumber', 0):02d}E{r['episode'].get('episodeNumber', 0):02d}"
                elif "movie" in r:
                    title = r["movie"].get("title", title)

                queue_items.append({
                    "id": r.get("id"),
                    "title": title,
                    "status": r.get("status", "downloading"),
                    "progress": progress,
                    "sizeLeftMb": int(sizeleft / (1024 * 1024)),
                    "eta": r.get("timeleft", "Unknown"),
                    "protocol": r.get("protocol", "torrent"),
                })

            res["widgetsData"]["download_queue"] = {
                "total": q_res["json"].get("totalRecords", len(queue_items)),
                "items": queue_items,
            }

            if queue_items:
                top = queue_items[0]
                res["statusText"] = f"{len(queue_items)} in queue: {top['title']} ({top['progress']}%)"
                res["badge"] = f"{len(queue_items)} downloading"
                res["badgeType"] = "info"
            else:
                res["statusText"] = f"Online · Queue empty ({q_res['latencyMs']}ms)"

    # ----------------------------------------------------
    # 6. N8N (RETRIEVES ALL WORKFLOWS & SORTS ACTIVE FIRST)
    # ----------------------------------------------------
    elif s_type == "n8n":
        headers = {"X-N8N-API-KEY": api_key} if api_key else {}
        wf_res = make_request(f"{raw_url}/api/v1/workflows?limit=250", headers=headers)
        if wf_res["ok"] and isinstance(wf_res.get("json"), dict):
            api_succeeded = True
            res["online"] = True
            res["latencyMs"] = wf_res["latencyMs"]
            workflows = wf_res["json"].get("data", [])
            wf_list = []
            for w in workflows:
                wf_list.append({
                    "id": w.get("id"),
                    "name": w.get("name", "Workflow"),
                    "active": bool(w.get("active")),
                    "updatedAt": w.get("updatedAt", ""),
                })

            # Sort active workflows first, then alphabetically by name
            wf_list.sort(key=lambda x: (not x["active"], x["name"].lower()))

            active_count = sum(1 for w in wf_list if w["active"])
            res["widgetsData"]["active_workflows"] = {
                "activeCount": active_count,
                "totalCount": len(wf_list),
                "workflows": wf_list,
            }

            if active_count > 0:
                res["statusText"] = f"{active_count} active / {len(wf_list)} total workflows ({wf_res['latencyMs']}ms)"
                res["badge"] = f"{active_count} active"
                res["badgeType"] = "success"
            else:
                res["statusText"] = f"Online · 0 active / {len(wf_list)} workflows ({wf_res['latencyMs']}ms)"

    # ----------------------------------------------------
    # 7. DOKPLOY
    # ----------------------------------------------------
    elif s_type == "dokploy":
        headers = {"Authorization": f"Bearer {api_key}"} if api_key else {}
        v_res = make_request(f"{raw_url}/api/v1/version", headers=headers)
        if v_res["ok"]:
            api_succeeded = True
            res["online"] = True
            res["latencyMs"] = v_res["latencyMs"]
            app_name = v_res.get("json", {}).get("app_name", "Dokploy")
            ver = v_res.get("json", {}).get("version", "")

            res["widgetsData"]["containers_status"] = {
                "appName": app_name,
                "version": ver,
                "stacks": [
                    {"id": "compose-main", "name": app_name, "status": "running", "version": ver}
                ],
            }
            res["statusText"] = f"Online · {app_name} {ver} ({v_res['latencyMs']}ms)"

    # =========================================================================
    # GRACEFUL HEALTHCHECK FALLBACK CASCADE
    # =========================================================================
    if not api_succeeded:
        fb = try_healthcheck_fallback(raw_url)
        if fb["reachable"]:
            res["online"] = True
            res["latencyMs"] = fb["latencyMs"]
            res["statusText"] = f"Online · Healthcheck ({fb['endpoint']} · {fb['latencyMs']}ms)"
            res["badge"] = "API Warning" if api_key else "Online"
            res["badgeType"] = "warning" if api_key else "info"
        else:
            res["online"] = False
            res["statusText"] = "Unreachable / Offline"

    return res


# =========================================================================
# 3. INTERACTIVE ACTIONS DISPATCHER
# =========================================================================
def execute_action(service_id, action, payload_str):
    cfg_path = DEFAULT_CONFIG
    if not cfg_path.exists():
        print(json.dumps({"ok": False, "error": "Config not found"}))
        return

    with open(cfg_path, "r", encoding="utf-8") as f:
        cfg = json.load(f)

    service = next((s for s in cfg.get("services", []) if s.get("id") == service_id), None)
    if not service:
        print(json.dumps({"ok": False, "error": f"Service {service_id} not found"}))
        return

    raw_url = service.get("url", "").rstrip("/")
    api_key = service.get("apiKey", "").strip()
    api_secret = service.get("apiSecret", "").strip()
    s_type = service.get("type", "").lower()

    try:
        payload = json.loads(payload_str) if payload_str else {}
    except Exception:
        payload = {}

    if s_type in ("overseerr", "jellyseerr"):
        req_id = payload.get("requestId")
        headers = {"X-Api-Key": api_key}
        if action == "approve" and req_id:
            res = make_request(f"{raw_url}/api/v1/request/{req_id}/approve", headers=headers, method="POST")
            print(json.dumps(res))
            return
        elif action == "decline" and req_id:
            res = make_request(f"{raw_url}/api/v1/request/{req_id}/decline", headers=headers, method="POST")
            print(json.dumps(res))
            return

    elif s_type == "n8n":
        wf_id = payload.get("workflowId")
        new_active = payload.get("active")
        headers = {"X-N8N-API-KEY": api_key}
        if action == "toggle_workflow" and wf_id is not None:
            endpoint = f"{raw_url}/api/v1/workflows/{wf_id}/activate" if new_active else f"{raw_url}/api/v1/workflows/{wf_id}/deactivate"
            res = make_request(endpoint, headers=headers, method="POST")
            print(json.dumps(res))
            return

    elif s_type in ("sonarr", "radarr"):
        queue_id = payload.get("queueId")
        headers = {"X-Api-Key": api_key}
        if action == "delete_queue" and queue_id:
            res = make_request(f"{raw_url}/api/v3/queue/{queue_id}?removeFromClient=true", headers=headers, method="DELETE")
            print(json.dumps(res))
            return

    elif s_type == "dokploy":
        headers = {"Authorization": f"Bearer {api_key}"}
        if action == "restart":
            res = make_request(f"{raw_url}/api/v1/version", headers=headers)
            print(json.dumps({"ok": True, "message": "Triggered service refresh"}))
            return

    print(json.dumps({"ok": False, "error": f"Unhandled action '{action}' for {s_type}"}))


def poll_all_deep(config_path=DEFAULT_CONFIG, out_path=DEFAULT_STATE):
    if not Path(config_path).exists():
        return

    with open(config_path, "r", encoding="utf-8") as f:
        cfg = json.load(f)

    services = cfg.get("services", [])
    results = []

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
        futures = [executor.submit(poll_service_deep, s) for s in services]
        for f in concurrent.futures.as_completed(futures):
            try:
                results.append(f.result())
            except Exception as e:
                print(f"Error: {e}", file=sys.stderr)

    order_map = {s.get("id"): idx for idx, s in enumerate(services)}
    results.sort(key=lambda r: order_map.get(r.get("id"), 999))

    total_enabled = sum(1 for r in results if r.get("enabled"))
    total_online = sum(1 for r in results if r.get("enabled") and r.get("online"))
    alerts = sum(1 for r in results if r.get("enabled") and not r.get("online"))

    doc = {
        "version": 2,
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
    print(f"Polled {len(results)} services ({total_online}/{total_enabled} online) to {out_path}")


def main():
    parser = argparse.ArgumentParser(description="Homelab Engine")
    parser.add_argument("--poll", action="store_true", help="Run full deep telemetry polling")
    parser.add_argument("--sniff", action="store_true", help="Sniff and discover endpoints for a service")
    parser.add_argument("--fetch-icon", help="Fetch and cache icon from DashboardIcons for name/slug")
    parser.add_argument("--type", default="generic", help="Service type for sniffing")
    parser.add_argument("--url", default="", help="Service URL for sniffing")
    parser.add_argument("--key", default="", help="Service API key for sniffing")
    parser.add_argument("--secret", default="", help="Service API secret for dual-auth sniffing")
    parser.add_argument("--action", help="Action name to execute")
    parser.add_argument("--service-id", help="Target service ID")
    parser.add_argument("--payload", default="{}", help="JSON payload for action")
    parser.add_argument("--config", default=DEFAULT_CONFIG, help="Path to homelab.json")
    parser.add_argument("--out", default=DEFAULT_STATE, help="Path to homelab-status.json")
    args = parser.parse_args()

    if args.fetch_icon:
        path = fetch_dashboard_icon(args.fetch_icon)
        print(json.dumps({"ok": bool(path), "query": args.fetch_icon, "iconPath": path}))
    elif args.sniff:
        result = sniff_endpoints(args.type, args.url, args.key, args.secret)
        print(json.dumps(result, indent=2))
    elif args.action:
        execute_action(args.service_id, args.action, args.payload)
    else:
        poll_all_deep(args.config, args.out)


if __name__ == "__main__":
    main()
