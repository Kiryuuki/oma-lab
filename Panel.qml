import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: panelRoot
  moduleName: "kiryuuki.oma-lab"
  ipcTarget: "kiryuuki.oma-lab"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property color foreground: (bar && bar.foreground !== undefined) ? bar.foreground : Color.foreground
  readonly property color urgent: (bar && bar.urgent !== undefined) ? bar.urgent : Color.urgent
  readonly property color dim: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.70)
  readonly property color subtle: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.45)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Main Tab Navigation: "overview" | "settings"
  property string activeViewTab: "overview"
  property string activeCategory: "all"

  property var homelabState: ({ services: [], summary: { total: 0, online: 0, alerts: 0, enabled: 0 } })
  property var homelabConfig: ({ services: [] })
  property bool isRefreshing: false

  // Persistent card expansion map (survives state file updates!)
  property var expandedMap: ({})

  function isExpanded(serviceId) {
    return Boolean(panelRoot.expandedMap[serviceId])
  }

  function toggleExpanded(serviceId) {
    if (!serviceId) return
    var copy = Object.assign({}, panelRoot.expandedMap)
    copy[serviceId] = !copy[serviceId]
    panelRoot.expandedMap = copy
  }

  readonly property int totalEnabled: homelabState.summary ? (homelabState.summary.enabled || 0) : 0
  readonly property int totalOnline: homelabState.summary ? (homelabState.summary.online || 0) : 0
  readonly property int totalAlerts: homelabState.summary ? (homelabState.summary.alerts || 0) : 0

  readonly property var categoryList: [
    { id: "all", label: "All Apps" },
    { id: "media", label: "Media & Streaming" },
    { id: "downloads", label: "Arr & Downloads" },
    { id: "infra", label: "Infrastructure & KASM" },
    { id: "automation", label: "Automations" }
  ]

  function open() {
    refresh()
    panelRoot.controller.show()
    Qt.callLater(function() {
      if (panelRoot.opened && panelRoot.bar && "centerHoverRevealSuppressed" in panelRoot.bar) {
        panelRoot.bar.centerHoverRevealSuppressed = true
      }
    })
  }

  function close() {
    if (panelRoot.bar && "centerHoverRevealSuppressed" in panelRoot.bar) {
      panelRoot.bar.centerHoverRevealSuppressed = false
    }
    panelRoot.controller.hide()
  }

  function toggle() {
    if (panelRoot.opened) panelRoot.close()
    else panelRoot.open()
  }

  function refresh() {
    panelRoot.isRefreshing = true
    pollerProcess.running = true
  }

  function launchApp(url) {
    if (!url) return
    Qt.openUrlExternally(url)
    panelRoot.close()
  }

  function isServiceInCategory(service, category) {
    if (category === "all") return true
    var t = String(service.type || "").toLowerCase()
    if (category === "media") return t === "jellyfin" || t === "overseerr" || t === "jellyseerr" || t === "plex" || t === "emby"
    if (category === "downloads") return t === "sonarr" || t === "radarr" || t === "prowlarr" || t === "bazarr" || t === "qbittorrent" || t === "transmission"
    if (category === "infra") return t === "dokploy" || t === "portainer" || t === "proxmox" || t === "kasm" || t === "kasm-workspaces" || t === "truenas"
    if (category === "automation") return t === "n8n" || t === "homeassistant"
    return true
  }

  // Live status JSON loader
  FileView {
    id: statusFile
    path: (Quickshell.env("HOME") || "") + "/.local/state/omarchy/homelab-status.json"
    watchChanges: true
    printErrors: false
    onLoaded: {
      panelRoot.homelabState = Model.parseState(text())
      panelRoot.isRefreshing = false
    }
    onLoadFailed: {
      panelRoot.homelabState = { services: [], summary: { total: 0, online: 0, alerts: 0, enabled: 0 } }
      panelRoot.isRefreshing = false
    }
    onFileChanged: reload()
  }

  // Config JSON loader
  FileView {
    id: configFile
    path: (Quickshell.env("HOME") || "") + "/.config/omarchy/homelab.json"
    watchChanges: true
    printErrors: false
    onLoaded: {
      try {
        panelRoot.homelabConfig = JSON.parse(text())
      } catch (e) {
        panelRoot.homelabConfig = { services: [] }
      }
    }
    onFileChanged: reload()
  }

  // Background Poller Process (Deep Telemetry)
  Process {
    id: pollerProcess
    command: ["/usr/bin/python3", (Quickshell.env("HOME") || "") + "/.config/omarchy/plugins/kiryuuki.oma-lab/homelab_engine.py", "--poll"]
    onExited: function(code) {
      statusFile.reload()
      panelRoot.isRefreshing = false
    }
  }

  // Interactive Action Dispatcher Process
  Process {
    id: actionProcess
    property var actionArgs: []
    command: ["/usr/bin/python3", (Quickshell.env("HOME") || "") + "/.config/omarchy/plugins/kiryuuki.oma-lab/homelab_engine.py", "--action"].concat(actionArgs)
    onExited: function(code) {
      panelRoot.refresh()
    }
  }

  function dispatchAction(serviceId, actionName, payload) {
    actionProcess.actionArgs = [
      actionName,
      "--service-id", serviceId,
      "--payload", JSON.stringify(payload || {})
    ]
    actionProcess.running = true
  }

  // Config modifier process
  Process {
    id: saveProcess
    property var pendingArgs: []
    command: ["/usr/bin/python3", (Quickshell.env("HOME") || "") + "/.config/omarchy/plugins/kiryuuki.oma-lab/save_config.py"].concat(pendingArgs)
    onExited: function(code) {
      configFile.reload()
      panelRoot.refresh()
    }
  }

  function toggleService(serviceId) {
    saveProcess.pendingArgs = ["toggle", serviceId]
    saveProcess.running = true
  }

  function deleteService(serviceId) {
    saveProcess.pendingArgs = ["delete", serviceId]
    saveProcess.running = true
  }

  function saveService(serviceObj) {
    saveProcess.pendingArgs = ["save"]
    saveProcess.running = true
    saveProcess.stdin.write(JSON.stringify(serviceObj) + "\n")
    saveProcess.stdin.close()
  }

  // Periodic polling timer (every 15s)
  Timer {
    interval: 15000
    running: true
    repeat: true
    onTriggered: panelRoot.refresh()
  }

  property int selectedIndex: 0
  readonly property var visibleServices: (panelRoot.homelabState.services || []).filter(function(s) { return panelRoot.isServiceInCategory(s, panelRoot.activeCategory) })

  KeyboardPanel {
    id: panel
    anchorItem: panelRoot.anchorItem
    owner: panelRoot.barIdentity
    bar: panelRoot.bar
    open: panelRoot.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(540))
    contentHeight: panel.fittedContentHeight(mainColumn.implicitHeight, Style.space(700))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: panelRoot.close()
      onTabRequested: function(direction) { panelRoot.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) {
          var maxIdx = Math.max(0, panelRoot.visibleServices.length - 1)
          panelRoot.selectedIndex = Math.max(0, Math.min(maxIdx, panelRoot.selectedIndex + dy))
          scrollArea.contentY = Math.max(0, Math.min(scrollArea.contentHeight - scrollArea.height, panelRoot.selectedIndex * Style.space(90)))
        }
      }
      onActivateRequested: {
        if (panelRoot.visibleServices && panelRoot.visibleServices[panelRoot.selectedIndex]) {
          var s = panelRoot.visibleServices[panelRoot.selectedIndex]
          if (s.url) panelRoot.launchApp(s.url)
        }
      }
      onReturnRequested: {
        if (panelRoot.visibleServices && panelRoot.visibleServices[panelRoot.selectedIndex]) {
          var s = panelRoot.visibleServices[panelRoot.selectedIndex]
          if (s.url) panelRoot.launchApp(s.url)
        }
      }
      onDeleteRequested: {
        if (panelRoot.visibleServices && panelRoot.visibleServices[panelRoot.selectedIndex]) {
          var s = panelRoot.visibleServices[panelRoot.selectedIndex]
          if (s.id) panelRoot.toggleExpanded(s.id)
        }
      }
      onTextKey: function(t) {
        if (t === "r" || t === "R") panelRoot.refresh()
        else if (t === "s" || t === "S") panelRoot.settingsOpen = !panelRoot.settingsOpen
        else if (t === "1") { panelRoot.activeCategory = "all"; panelRoot.selectedIndex = 0 }
        else if (t === "2") { panelRoot.activeCategory = "media"; panelRoot.selectedIndex = 0 }
        else if (t === "3") { panelRoot.activeCategory = "downloads"; panelRoot.selectedIndex = 0 }
        else if (t === "4") { panelRoot.activeCategory = "infra"; panelRoot.selectedIndex = 0 }
        else if (t === "5") { panelRoot.activeCategory = "automation"; panelRoot.selectedIndex = 0 }
        else if (t === "e" || t === "E" || t === " ") {
          if (panelRoot.visibleServices && panelRoot.visibleServices[panelRoot.selectedIndex]) {
            var s = panelRoot.visibleServices[panelRoot.selectedIndex]
            if (s.id) panelRoot.toggleExpanded(s.id)
          }
        }
      }

      Flickable {
        id: scrollArea
        anchors.fill: parent
        contentWidth: mainColumn.width
        contentHeight: mainColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: mainColumn
          width: scrollArea.width
          spacing: Style.space(8)

          // ------------------ HEADER ------------------
          Item {
            width: parent.width
            implicitHeight: Math.max(headerIcon.implicitHeight, headerTextCol.implicitHeight)

            Text {
              id: headerIcon
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "󰒋"
              color: Color.accent
              font.family: panelRoot.fontFamily
              font.pixelSize: Style.font.display
            }

            Column {
              id: headerTextCol
              anchors.left: headerIcon.right
              anchors.leftMargin: Style.space(10)
              anchors.right: headerBtns.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(1)

              RowLayout {
                spacing: Style.space(8)

                Text {
                  textFormat: Text.PlainText
                  text: "Homelab Monitor"
                  color: panelRoot.foreground
                  font.family: panelRoot.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                }

                BorderSurface {
                  implicitWidth: badgeText.implicitWidth + Style.space(8)
                  implicitHeight: badgeText.implicitHeight + Style.space(4)
                  color: "transparent"
                  borderSpec: Border.controlSpec("normal", panelRoot.totalAlerts > 0 ? "#e06c75" : "#87c095", Color.accent)
                  radius: Style.cornerRadius

                  Text {
                    id: badgeText
                    textFormat: Text.PlainText
                    anchors.centerIn: parent
                    text: panelRoot.totalOnline + "/" + panelRoot.totalEnabled + " Online"
                    color: panelRoot.totalAlerts > 0 ? "#e06c75" : "#87c095"
                    font.family: panelRoot.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                }
              }

              Text {
                textFormat: Text.PlainText
                text: "Deep Telemetry · Live Streams · Queues & Actions"
                color: panelRoot.dim
                font.family: panelRoot.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Row {
              id: headerBtns
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(4)

              PanelActionButton {
                iconText: panelRoot.isRefreshing ? "" : "󰑐"
                tooltipText: "Refresh Telemetry (r)"
                foreground: Color.accent
                onClicked: panelRoot.refresh()
              }

              PanelActionButton {
                iconText: "✕"
                tooltipText: "Close (Esc)"
                onClicked: panelRoot.close()
              }
            }
          }

          // ------------------ TOP VIEW SELECTOR TABS ------------------
          Row {
            width: parent.width
            spacing: Style.space(6)

            // Tab 1: Overview
            BorderSurface {
              readonly property bool isSelected: panelRoot.activeViewTab === "overview"
              width: (parent.width - Style.space(6)) / 2
              implicitHeight: Style.space(32)
              radius: Style.cornerRadius
              color: isSelected ? Style.selectedFillFor(panelRoot.foreground, panelRoot.foreground) : "transparent"
              borderSpec: isSelected
                ? Border.controlSpec("selected", Color.accent, Color.accent)
                : Border.controlSpec("normal", panelRoot.dim, Color.accent)

              Row {
                anchors.centerIn: parent
                spacing: Style.space(6)
                Text { textFormat: Text.PlainText; text: "󰒋"; color: Color.accent; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.body }
                Text { textFormat: Text.PlainText; text: "Overview & Widgets"; color: parent.parent.isSelected ? Color.accent : panelRoot.foreground; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: parent.parent.isSelected }
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: panelRoot.activeViewTab = "overview"
              }
            }

            // Tab 2: Service Manager / Settings
            BorderSurface {
              readonly property bool isSelected: panelRoot.activeViewTab === "settings"
              width: (parent.width - Style.space(6)) / 2
              implicitHeight: Style.space(32)
              radius: Style.cornerRadius
              color: isSelected ? Style.selectedFillFor(panelRoot.foreground, panelRoot.foreground) : "transparent"
              borderSpec: isSelected
                ? Border.controlSpec("selected", Color.accent, Color.accent)
                : Border.controlSpec("normal", panelRoot.dim, Color.accent)

              Row {
                anchors.centerIn: parent
                spacing: Style.space(6)
                Text { textFormat: Text.PlainText; text: "󰒓"; color: Color.accent; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.body }
                Text { textFormat: Text.PlainText; text: "Service Manager"; color: parent.parent.isSelected ? Color.accent : panelRoot.foreground; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: parent.parent.isSelected }
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: panelRoot.activeViewTab = "settings"
              }
            }
          }

          // =========================================================================
          // VIEW 1: OVERVIEW & WIDGETS
          // =========================================================================
          Column {
            visible: panelRoot.activeViewTab === "overview"
            width: parent.width
            spacing: Style.space(8)

            // Category Filter Pills
            ScrollView {
              width: parent.width
              implicitHeight: Style.space(28)
              contentWidth: catRow.implicitWidth
              ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
              ScrollBar.vertical.policy: ScrollBar.AlwaysOff

              Row {
                id: catRow
                spacing: Style.space(5)

                Repeater {
                  model: panelRoot.categoryList
                  delegate: BorderSurface {
                    readonly property bool isSelected: panelRoot.activeCategory === modelData.id
                    implicitWidth: catText.implicitWidth + Style.space(12)
                    implicitHeight: Style.space(26)
                    radius: Style.cornerRadius
                    color: isSelected ? Style.selectedFillFor(panelRoot.foreground, panelRoot.foreground) : "transparent"
                    borderSpec: isSelected
                      ? Border.controlSpec("selected", Color.accent, Color.accent)
                      : Border.controlSpec("normal", panelRoot.dim, Color.accent)

                    Text {
                      id: catText
                      textFormat: Text.PlainText
                      anchors.centerIn: parent
                      text: modelData.label
                      color: isSelected ? Color.accent : panelRoot.foreground
                      font.family: panelRoot.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: isSelected
                    }

                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: panelRoot.activeCategory = modelData.id
                    }
                  }
                }
              }
            }

            // List of Service Cards (with persistent expanded state!)
            Column {
              width: parent.width
              spacing: Style.space(8)

              Repeater {
                model: panelRoot.homelabState.services || []

                AppCard {
                  required property var modelData
                  visible: panelRoot.isServiceInCategory(modelData, panelRoot.activeCategory)
                  serviceData: modelData
                  foreground: panelRoot.foreground
                  dim: panelRoot.dim
                  subtle: panelRoot.subtle
                  fontFamily: panelRoot.fontFamily
                  isSelected: (panelRoot.visibleServices[panelRoot.selectedIndex] !== undefined) && (panelRoot.visibleServices[panelRoot.selectedIndex].id === modelData.id)
                  expanded: panelRoot.isExpanded(modelData.id)
                  onExpandToggled: function(id) { panelRoot.toggleExpanded(id) }
                  onLaunchRequested: function(url) { panelRoot.launchApp(url) }
                  onActionRequested: function(sId, actName, pld) { panelRoot.dispatchAction(sId, actName, pld) }
                }
              }

              // Empty State
              BorderSurface {
                visible: (panelRoot.homelabState.services || []).length === 0
                width: parent.width
                implicitHeight: Style.space(90)
                radius: Style.cornerRadius
                color: "transparent"
                borderSpec: Border.controlSpec("normal", panelRoot.subtle, Color.accent)

                Column {
                  anchors.centerIn: parent
                  spacing: Style.space(4)

                  Text {
                    textFormat: Text.PlainText
                    text: "No Homelab Services Added"
                    color: panelRoot.foreground
                    font.family: panelRoot.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                    anchors.horizontalCenter: parent.horizontalCenter
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: "Click the Service Manager tab above to add & auto-discover your apps."
                    color: panelRoot.dim
                    font.family: panelRoot.fontFamily
                    font.pixelSize: Style.font.caption
                    anchors.horizontalCenter: parent.horizontalCenter
                  }
                }
              }
            }
          }

          // =========================================================================
          // VIEW 2: SERVICE MANAGER / SETTINGS
          // =========================================================================
          SettingsView {
            id: settingsView
            visible: panelRoot.activeViewTab === "settings"
            width: parent.width
            foreground: panelRoot.foreground
            dim: panelRoot.dim
            subtle: panelRoot.subtle
            urgent: panelRoot.urgent
            fontFamily: panelRoot.fontFamily
            rawConfig: panelRoot.homelabConfig
            onServiceToggled: function(id) { panelRoot.toggleService(id) }
            onServiceDeleted: function(id) { panelRoot.deleteService(id) }
            onServiceSaved: function(obj) { panelRoot.saveService(obj) }
            onRefreshRequested: panelRoot.refresh()
          }
        }
      }
    }
  }
}
