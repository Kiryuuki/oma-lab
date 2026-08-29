// Model and helper functions for Homelab monitor

var ICON_MAP = {
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
  "generic": "󰖟"
}

var SERVICE_TYPES = [
  { id: "jellyfin", name: "Jellyfin", defaultIcon: "󰟀", asset: "assets/jellyfin.svg", slug: "jellyfin" },
  { id: "overseerr", name: "Overseerr / Jellyseerr", defaultIcon: "󰑈", asset: "assets/overseerr.svg", slug: "overseerr" },
  { id: "sonarr", name: "Sonarr", defaultIcon: "󰇮", asset: "assets/sonarr.svg", slug: "sonarr" },
  { id: "radarr", name: "Radarr", defaultIcon: "󰚌", asset: "assets/radarr.svg", slug: "radarr" },
  { id: "kasm", name: "KASM Workspaces", defaultIcon: "󰢹", asset: "assets/kasm.svg", slug: "kasm-workspaces" },
  { id: "prowlarr", name: "Prowlarr", defaultIcon: "󰛄", asset: "assets/prowlarr.svg", slug: "prowlarr" },
  { id: "bazarr", name: "Bazarr", defaultIcon: "󰈙", asset: "assets/bazarr.svg", slug: "bazarr" },
  { id: "n8n", name: "n8n", defaultIcon: "󰒓", asset: "assets/n8n.svg", slug: "n8n" },
  { id: "dokploy", name: "Dokploy", defaultIcon: "󰡨", asset: "assets/dokploy.svg", slug: "dokploy" },
  { id: "portainer", name: "Portainer", defaultIcon: "󰡨", asset: "assets/portainer.svg", slug: "portainer" },
  { id: "proxmox", name: "Proxmox", defaultIcon: "󰢹", asset: "assets/proxmox.svg", slug: "proxmox" },
  { id: "generic", name: "Generic Web App", defaultIcon: "󰖟", asset: "", slug: "" }
]

function getIconForType(type) {
  var key = String(type || "generic").toLowerCase()
  return ICON_MAP[key] || "󰖟"
}

function getAssetForType(type, customIconPath) {
  if (customIconPath && String(customIconPath).trim().length > 0) {
    var p = String(customIconPath).trim()
    return p.startsWith("file://") ? p : "file://" + p
  }

  var key = String(type || "generic").toLowerCase()
  var match = SERVICE_TYPES.find(function(t) { return t.id === key })
  if (match && match.asset) {
    return Qt.resolvedUrl(match.asset)
  }
  return ""
}

function safeUrl(url) {
  var text = String(url || "").trim()
  if (/^https?:\/\//i.test(text)) return text
  if (text.length > 0) return "http://" + text
  return ""
}

function parseState(rawText) {
  if (!rawText) return { services: [], summary: { total: 0, online: 0, alerts: 0, enabled: 0 } }
  try {
    var parsed = JSON.parse(rawText)
    return parsed && parsed.services ? parsed : { services: [], summary: { total: 0, online: 0, alerts: 0, enabled: 0 } }
  } catch (e) {
    return { services: [], summary: { total: 0, online: 0, alerts: 0, enabled: 0 } }
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    ICON_MAP: ICON_MAP,
    SERVICE_TYPES: SERVICE_TYPES,
    getIconForType: getIconForType,
    getAssetForType: getAssetForType,
    safeUrl: safeUrl,
    parseState: parseState
  }
}
