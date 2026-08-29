# Homelab Monitor & Launcher Sidepanel (`kiryuuki.oma-lab`)

A native, high-performance **Homelab Monitoring & Interactive Launcher** plugin for the **Omarchy Desktop Shell**.

![Homelab Plugin Preview](preview.png)

---

## Features

- 󰒋 **Native Omarchy Bar Widget & Right-Aligned Flyout**: Smooth popout panel designed to match the native aesthetic, borders, typography, and corner radius tokens of Omarchy.
- 󰟀 **Deep Telemetry & Live Widgets**:
  - **Proxmox VE**: Live cluster CPU, RAM, and storage utilization gauges, with real-time running/stopped counts and status lists for QEMU Virtual Machines and LXC Containers.
  - **n8n**: Comprehensive workflow monitor (retrieving up to 250+ workflows), automatically sorted with **Active workflows (`ON`) at the top** and interactive 1-click on/off toggles.
  - **Jellyfin / Emby**: Real-time active streams, user sessions, media playback progress (`%`), transcoding badges, and pause states.
  - **Overseerr / Jellyseerr**: Pending media request queue with **1-Click Approve (`✓`)** and **Decline (`✕`)** actions.
  - **Sonarr / Radarr / Prowlarr / Bazarr**: Live download queue tracking with progress bars, download speed, and ETA countdowns.
  - **KASM Workspaces**: Container streaming session monitoring with dual-auth key + secret support.
  - **Dokploy & Portainer**: Container stack health and **1-Click Restart (`󰑐`)** actions.
- 󰑐 **Graceful Healthcheck Fallback**: If an app's deep API encounters connection issues or authentication limits, the engine cascades to lightweight healthcheck endpoints (`/api/__healthcheck`, `/healthz`, root ping), marking the service as online with an amber `API Warning` badge so your launcher bookmarks always work.
- 󰏫 **In-Panel Service Manager & Endpoint Sniffer**:
  - **Auto-Sniff & Discover**: Probes remote APIs, validates credentials, and auto-detects selectable widget components.
  - **Edit & Delete**: Edit existing services in-place or toggle them on/off with checkboxes.
  - **Context-Aware Auth Fields**: Dynamically adjusts input fields for single API keys or dual credentials (Proxmox Token ID + Secret UUID, KASM Key + Secret).
- 󰖟 **DashboardIcons.com Integration**:
  - Automatically fetches and caches official vector SVG logos from the [homarr-labs/dashboard-icons](https://github.com/homarr-labs/dashboard-icons) repository for over 500+ self-hosted apps.
  - Offline-first cache in `~/.local/state/omarchy/homelab-icons/` for zero startup latency.
- 󰅃 **Persistent Expansion State**: Open cards stay expanded across background telemetry poll cycles.

---

## App Integration Guides

### Proxmox VE
- **Header**: `Authorization: PVEAPIToken=USER@REALM!TOKENID=SECRET`
- **Permissions**:
  1. In Proxmox Web UI, go to **Datacenter** $\rightarrow$ **Permissions** $\rightarrow$ **Add** $\rightarrow$ **API Token Permission**.
  2. Path: `/`
  3. API Token: `USER@REALM!TOKENID`
  4. Role: `PVEAuditor` (or `PVESysAdmin` / `Administrator`)
  5. Propagate: **Checked**

### KASM Workspaces
- **Credentials**: Enter both **API Key** and **API Key Secret** created in the KASM Admin Panel.
- **Fallback**: Automatically falls back to `/api/__healthcheck` if API access is restricted.

### n8n
- **Credentials**: Enter your API key created in n8n **Settings** $\rightarrow$ **n8n API**.
- **Features**: Automatically sorts active workflows first with live status switches.

---

## Installation

### Method 1: Via Omarchy Plugin Manager
```bash
omaplug install kiryuuki.oma-lab
```

### Method 2: Manual Installation (Git Clone)
```bash
mkdir -p ~/.config/omarchy/plugins
git clone https://github.com/yuuki/omarchy-homelab.git ~/.config/omarchy/plugins/kiryuuki.oma-lab
chmod +x ~/.config/omarchy/plugins/kiryuuki.oma-lab/homelab_engine.py
chmod +x ~/.config/omarchy/plugins/kiryuuki.oma-lab/save_config.py
```

### Register in `shell.json`
Add `{"id": "kiryuuki.oma-lab"}` to your `bar.layout.right` in `~/.config/omarchy/shell.json`:

```json
{
  "bar": {
    "layout": {
      "right": [
        { "id": "kiryuuki.oma-lab" }
      ]
    }
  }
}
```

Then restart the shell:
```bash
omarchy restart shell
```

---

## Keyboard Shortcuts

When the panel is open:
- <kbd>r</kbd>: Trigger instant manual telemetry refresh
- <kbd>Esc</kbd>: Close panel
- <kbd>j</kbd> / <kbd>k</kbd> or <kbd>↓</kbd> / <kbd>↑</kbd>: Navigate through services

---

## License

MIT License. Designed for the Omarchy Desktop Environment.
