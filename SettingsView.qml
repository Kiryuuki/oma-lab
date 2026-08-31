import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Column {
  id: root

  property color foreground: Color.foreground
  property color dim: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.70)
  property color subtle: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.45)
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family
  property var rawConfig: ({ services: [] })

  signal serviceToggled(string serviceId)
  signal serviceDeleted(string serviceId)
  signal serviceSaved(var serviceObj)
  signal refreshRequested()

  property string editingId: ""
  property string selectedType: "jellyfin"
  property string formName: "Jellyfin"
  property string formUrl: "http://"
  property string formApiKey: ""
  property string formApiSecret: ""
  property string previewIconPath: ""
  property bool addingNew: false

  // Discovery State
  property bool isSniffing: false
  property var sniffResult: null
  property var selectedWidgets: []

  spacing: Style.space(10)
  width: parent ? parent.width : Style.space(520)

  function getApiKeyLabel(type) {
    var t = String(type || "").toLowerCase()
    if (t === "proxmox") return "PVE Token ID (e.g. root@pam!monitoring)"
    if (t === "kasm" || t === "kasm-workspaces") return "API Key"
    if (t === "jellyfin" || t === "emby") return "API Token / Emby Token"
    if (t === "sonarr" || t === "radarr" || t === "prowlarr" || t === "bazarr" || t === "overseerr" || t === "jellyseerr") return "API Key"
    if (t === "dokploy" || t === "portainer") return "Bearer Token / API Key"
    if (t === "n8n") return "X-N8N-API-KEY"
    return "API Key / Token (leave blank for basic healthcheck)"
  }

  function getApiSecretLabel(type) {
    var t = String(type || "").toLowerCase()
    if (t === "proxmox") return "PVE Token Secret UUID (e.g. 12345678-1234-1234-1234-123456789abc)"
    if (t === "kasm" || t === "kasm-workspaces") return "API Key Secret"
    return "API Secret / Token Secret (optional)"
  }

  function isSecretFieldRelevant(type) {
    var t = String(type || "").toLowerCase()
    return t === "proxmox" || t === "kasm" || t === "kasm-workspaces" || t === "truenas" || t === "generic"
  }

  function editService(srv) {
    root.editingId = srv.id || ""
    root.selectedType = srv.type || "generic"
    nameInput.text = srv.name || ""
    urlInput.text = srv.url || ""
    keyInput.text = srv.apiKey || ""
    secretInput.text = srv.apiSecret || ""
    root.previewIconPath = srv.iconPath || ""
    root.selectedWidgets = srv.widgets || []
    root.sniffResult = null
    root.addingNew = true
    if (!root.previewIconPath) root.queryIcon(srv.name || srv.type)
  }

  // Icon Fetch Process
  Process {
    id: iconFetchProcess
    property string fetchQuery: ""
    command: ["/usr/bin/python3", (Quickshell.env("HOME") || "") + "/.config/omarchy/plugins/kiryuuki.oma-lab/homelab_engine.py", "--fetch-icon", fetchQuery]
    stdout: StdioCollector {
      id: iconOut
      waitForEnd: true
      onStreamFinished: {
        try {
          var res = JSON.parse(iconOut.text)
          if (res && res.iconPath) {
            root.previewIconPath = res.iconPath
          }
        } catch (e) {}
      }
    }
  }

  function queryIcon(name) {
    if (!name || name.trim().length === 0) return
    iconFetchProcess.fetchQuery = name.trim()
    iconFetchProcess.running = true
  }

  function handleSniffOutput(outText) {
    root.isSniffing = false
    try {
      var res = JSON.parse(outText)
      root.sniffResult = res
      if (res && res.iconPath) {
        root.previewIconPath = res.iconPath
      }
      var wList = []
      if (res && res.discoveredWidgets) {
        for (var i = 0; i < res.discoveredWidgets.length; i++) {
          if (res.discoveredWidgets[i].default) wList.push(res.discoveredWidgets[i].id)
        }
      }
      root.selectedWidgets = wList
    } catch (e) {
      root.sniffResult = { reachable: false, error: "Failed to parse response" }
    }
  }

  // Sniffer Process
  Process {
    id: sniffProcess
    command: ["/usr/bin/python3", (Quickshell.env("HOME") || "") + "/.config/omarchy/plugins/kiryuuki.oma-lab/homelab_engine.py", "--sniff"]
    stdout: StdioCollector {
      id: sniffOut
      waitForEnd: true
      onStreamFinished: root.handleSniffOutput(sniffOut.text)
    }
  }

  function runSniff() {
    root.isSniffing = true
    root.sniffResult = null
    var probePayload = {
      type: root.selectedType,
      url: urlInput.text.trim(),
      apiKey: keyInput.text.trim(),
      apiSecret: secretInput.text.trim()
    }
    sniffProcess.running = true
    sniffProcess.stdin.write(JSON.stringify(probePayload) + "\n")
    sniffProcess.stdin.close()
  }

  function toggleWidgetSelection(widgetId) {
    var idx = root.selectedWidgets.indexOf(widgetId)
    var list = root.selectedWidgets.slice()
    if (idx === -1) list.push(widgetId)
    else list.splice(idx, 1)
    root.selectedWidgets = list
  }

  // --- SECTION 1: CONFIGURED SERVICES LIST ---
  RowLayout {
    width: parent.width
    Text {
      textFormat: Text.PlainText
      text: "CONFIGURED HOMELAB SERVICES"
      color: root.subtle
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1
    }

    Item { Layout.fillWidth: true }

    BorderSurface {
      implicitWidth: addBtnText.implicitWidth + Style.space(12)
      implicitHeight: Style.space(26)
      radius: Style.cornerRadius
      color: root.addingNew ? Style.selectedFillFor(root.foreground, root.foreground) : "transparent"
      borderSpec: Border.controlSpec(root.addingNew ? "selected" : "normal", Color.accent, Color.accent)

      Text {
        id: addBtnText
        textFormat: Text.PlainText
        anchors.centerIn: parent
        text: root.addingNew ? "− Close Form" : "+ Add Service"
        color: Color.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: {
          root.addingNew = !root.addingNew
          root.editingId = ""
          root.sniffResult = null
          if (root.addingNew) {
            root.selectedType = "jellyfin"
            nameInput.text = "Jellyfin"
            urlInput.text = "http://"
            keyInput.text = ""
            secretInput.text = ""
            root.queryIcon("jellyfin")
          }
        }
      }
    }
  }

  Repeater {
    model: root.rawConfig && root.rawConfig.services ? root.rawConfig.services : []

    BorderSurface {
      required property var modelData
      width: parent.width
      implicitHeight: Style.space(42)
      radius: Style.cornerRadius
      color: Style.hoverFillFor(root.foreground, root.foreground)
      borderSpec: Border.controlSpec("normal", root.subtle, Color.accent)

      RowLayout {
        anchors.fill: parent
        anchors.leftMargin: Style.space(8)
        anchors.rightMargin: Style.space(8)
        spacing: Style.space(8)

        // Toggle checkbox
        BorderSurface {
          implicitWidth: Style.space(20)
          implicitHeight: Style.space(20)
          radius: Style.space(4)
          color: modelData.enabled !== false ? Color.accent : "transparent"
          borderSpec: Border.controlSpec(modelData.enabled !== false ? "selected" : "normal", modelData.enabled !== false ? Color.accent : root.subtle, Color.accent)

          Text {
            textFormat: Text.PlainText
            anchors.centerIn: parent
            text: "✓"
            color: "white"
            visible: modelData.enabled !== false
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.serviceToggled(modelData.id)
          }
        }

        // Official Asset Logo or Fallback
        Item {
          width: Style.space(24)
          height: Style.space(24)

          Image {
            id: itemAssetImg
            anchors.fill: parent
            source: Model.getAssetForType(modelData.type, modelData.iconPath)
            visible: source !== "" && status === Image.Ready
            fillMode: Image.PreserveAspectFit
            smooth: true
          }

          Text {
            textFormat: Text.PlainText
            anchors.centerIn: parent
            visible: itemAssetImg.visible === false
            text: modelData.icon || Model.getIconForType(modelData.type)
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
        }

        // App Details
        Column {
          Layout.fillWidth: true
          spacing: 1

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: modelData.name || modelData.type
            color: modelData.enabled !== false ? root.foreground : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            elide: Text.ElideRight
          }
          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: modelData.url || ""
            color: root.subtle
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        // Action Buttons: Edit (󰏫) & Delete (✕)
        Row {
          spacing: Style.space(4)

          PanelActionButton {
            iconText: "󰏫"
            tooltipText: "Edit Service Settings"
            foreground: Color.accent
            onClicked: root.editService(modelData)
          }

          PanelActionButton {
            iconText: "✕"
            tooltipText: "Delete Service"
            foreground: root.subtle
            onClicked: root.serviceDeleted(modelData.id)
          }
        }
      }
    }
  }

  // --- SECTION 2: ADD / EDIT & AUTO-DISCOVERY FORM ---
  Column {
    visible: root.addingNew
    width: parent.width
    spacing: Style.space(8)

    BorderSurface {
      width: parent.width
      implicitHeight: formCol.implicitHeight + Style.space(16)
      radius: Style.cornerRadius
      color: Style.hoverFillFor(root.foreground, root.foreground)
      borderSpec: Border.controlSpec("focus", Color.accent, Color.accent)

      Column {
        id: formCol
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Style.space(8)
        spacing: Style.space(8)

        RowLayout {
          width: parent.width
          Text {
            textFormat: Text.PlainText
            text: root.editingId !== "" ? "EDIT SERVICE SETTINGS" : "ADD & AUTO-DISCOVER SERVICE"
            color: Color.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1
          }

          Item { Layout.fillWidth: true }

          // Live Icon Preview Box (from DashboardIcons)
          Item {
            width: Style.space(26)
            height: Style.space(26)

            Rectangle {
              anchors.fill: parent
              radius: Style.space(4)
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
              border.width: Style.spacing.hairline
              border.color: Color.accent

              Image {
                anchors.fill: parent
                anchors.margins: 2
                source: Model.getAssetForType(root.selectedType, root.previewIconPath)
                visible: source !== "" && status === Image.Ready
                fillMode: Image.PreserveAspectFit
                smooth: true
              }
            }
          }
        }

        // Service Type Selection Pills
        Grid {
          columns: 4
          rowSpacing: Style.space(4)
          columnSpacing: Style.space(4)
          width: parent.width

          Repeater {
            model: Model.SERVICE_TYPES

            BorderSurface {
              required property var modelData
              readonly property bool isSelected: root.selectedType === modelData.id

              width: (parent.width - Style.space(12)) / 4
              implicitHeight: Style.space(28)
              radius: Style.cornerRadius
              color: isSelected ? Style.selectedFillFor(root.foreground, root.foreground) : "transparent"
              borderSpec: Border.controlSpec(isSelected ? "selected" : "normal", isSelected ? Color.accent : root.subtle, Color.accent)

              Row {
                anchors.centerIn: parent
                spacing: Style.space(4)

                Text {
                  textFormat: Text.PlainText
                  text: modelData.defaultIcon
                  color: parent.parent.isSelected ? Color.accent : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                Text {
                  textFormat: Text.PlainText
                  text: modelData.name.split(" ")[0]
                  color: parent.parent.isSelected ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: parent.parent.isSelected
                  elide: Text.ElideRight
                }
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.selectedType = modelData.id
                  root.sniffResult = null
                  var namePart = modelData.name.split(" ")[0]
                  if (root.editingId === "") {
                    nameInput.text = namePart
                  }
                  root.queryIcon(modelData.slug || namePart)
                }
              }
            }
          }
        }

        // Row 1: Name Input
        Column {
          width: parent.width
          spacing: Style.space(2)
          Text { textFormat: Text.PlainText; text: "App Display Name"; color: root.subtle; font.pixelSize: Style.font.caption; font.family: root.fontFamily }

          BorderSurface {
            width: parent.width
            implicitHeight: Style.space(34)
            radius: Style.cornerRadius
            color: "transparent"
            borderSpec: nameInput.activeFocus ? Border.controlSpec("selected", Color.accent, Color.accent) : Border.controlSpec("normal", root.subtle, Color.accent)

            TextInput {
              id: nameInput
              anchors.fill: parent
              anchors.margins: Style.space(6)
              text: "Jellyfin"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              selectByMouse: true
              clip: true
              onEditingFinished: root.queryIcon(text)
            }
          }
        }

        // Row 2: URL Input
        Column {
          width: parent.width
          spacing: Style.space(2)
          Text { textFormat: Text.PlainText; text: "Service URL (HTTPS / LAN IP / Domain)"; color: root.subtle; font.pixelSize: Style.font.caption; font.family: root.fontFamily }

          BorderSurface {
            width: parent.width
            implicitHeight: Style.space(34)
            radius: Style.cornerRadius
            color: "transparent"
            borderSpec: urlInput.activeFocus ? Border.controlSpec("selected", Color.accent, Color.accent) : Border.controlSpec("normal", root.subtle, Color.accent)

            TextInput {
              id: urlInput
              anchors.fill: parent
              anchors.margins: Style.space(6)
              text: "http://"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              selectByMouse: true
              clip: true
            }
          }
        }

        // Row 3 (Full Width): Contextual API Key / Token ID Input
        Column {
          width: parent.width
          spacing: Style.space(2)
          Text {
            textFormat: Text.PlainText
            text: root.getApiKeyLabel(root.selectedType)
            color: root.subtle
            font.pixelSize: Style.font.caption
            font.family: root.fontFamily
          }

          BorderSurface {
            width: parent.width
            implicitHeight: Style.space(34)
            radius: Style.cornerRadius
            color: "transparent"
            borderSpec: keyInput.activeFocus ? Border.controlSpec("selected", Color.accent, Color.accent) : Border.controlSpec("normal", root.subtle, Color.accent)

            TextInput {
              id: keyInput
              anchors.fill: parent
              anchors.margins: Style.space(6)
              text: ""
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              selectByMouse: true
              echoMode: TextInput.Password
              clip: true
            }
          }
        }

        // Row 4 (Full Width): Contextual API Secret / UUID Input
        Column {
          visible: root.isSecretFieldRelevant(root.selectedType)
          width: parent.width
          spacing: Style.space(2)
          Text {
            textFormat: Text.PlainText
            text: root.getApiSecretLabel(root.selectedType)
            color: root.subtle
            font.pixelSize: Style.font.caption
            font.family: root.fontFamily
          }

          BorderSurface {
            width: parent.width
            implicitHeight: Style.space(34)
            radius: Style.cornerRadius
            color: "transparent"
            borderSpec: secretInput.activeFocus ? Border.controlSpec("selected", Color.accent, Color.accent) : Border.controlSpec("normal", root.subtle, Color.accent)

            TextInput {
              id: secretInput
              anchors.fill: parent
              anchors.margins: Style.space(6)
              text: ""
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              selectByMouse: true
              echoMode: TextInput.Password
              clip: true
            }
          }
        }

        // Sniff & Discover Button
        BorderSurface {
          width: parent.width
          implicitHeight: Style.space(32)
          radius: Style.cornerRadius
          color: Style.hoverFillFor(root.foreground, root.foreground)
          borderSpec: Border.controlSpec("focus", Color.accent, Color.accent)

          Row {
            anchors.centerIn: parent
            spacing: Style.space(6)

            Text {
              textFormat: Text.PlainText
              text: root.isSniffing ? "" : "󰑐"
              color: Color.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
            Text {
              textFormat: Text.PlainText
              text: root.isSniffing ? "Probing Endpoints..." : "Auto-Sniff & Discover Endpoints"
              color: Color.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }

          MouseArea {
            anchors.fill: parent
            enabled: !root.isSniffing
            cursorShape: Qt.PointingHandCursor
            onClicked: root.runSniff()
          }
        }

        // Discovery Results & Checkbox List
        Column {
          visible: root.sniffResult !== null
          width: parent.width
          spacing: Style.space(6)

          BorderSurface {
            width: parent.width
            implicitHeight: Style.space(28)
            radius: Style.cornerRadius
            color: "transparent"
            borderSpec: Border.controlSpec("normal", root.sniffResult && root.sniffResult.reachable ? (root.sniffResult.fallbackActive ? "#e5c07b" : "#87c095") : "#e06c75", Color.accent)

            Text {
              textFormat: Text.PlainText
              anchors.centerIn: parent
              text: {
                if (!root.sniffResult || !root.sniffResult.reachable) return "✕ Unreachable or Host Offline"
                if (root.sniffResult.fallbackActive) return "⚠ Reachable via Healthcheck Fallback (API Auth Inactive)"
                return "✓ Full API Connection & Auth Verified"
              }
              color: root.sniffResult && root.sniffResult.reachable ? (root.sniffResult.fallbackActive ? "#e5c07b" : "#87c095") : "#e06c75"
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }

          Text {
            textFormat: Text.PlainText
            text: "SELECT WIDGETS TO DISPLAY:"
            color: root.subtle
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          Repeater {
            model: root.sniffResult && root.sniffResult.discoveredWidgets ? root.sniffResult.discoveredWidgets : []

            BorderSurface {
              required property var modelData
              readonly property bool isSelected: root.selectedWidgets.indexOf(modelData.id) !== -1

              width: parent.width
              implicitHeight: Style.space(36)
              radius: Style.cornerRadius
              color: isSelected ? Style.selectedFillFor(root.foreground, root.foreground) : "transparent"
              borderSpec: Border.controlSpec(isSelected ? "selected" : "normal", isSelected ? Color.accent : root.subtle, Color.accent)

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(8)
                spacing: Style.space(8)

                Text {
                  textFormat: Text.PlainText
                  text: parent.parent.isSelected ? "☑" : "☐"
                  color: parent.parent.isSelected ? Color.accent : root.subtle
                  font.pixelSize: Style.font.body
                }

                Column {
                  Layout.fillWidth: true
                  spacing: 1

                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    text: modelData.label
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    elide: Text.ElideRight
                  }
                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    text: modelData.desc
                    color: root.subtle
                    font.family: root.fontFamily
                    font.pixelSize: 9
                    elide: Text.ElideRight
                  }
                }
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.toggleWidgetSelection(modelData.id)
              }
            }
          }
        }

        // Save Button
        BorderSurface {
          width: parent.width
          implicitHeight: Style.space(34)
          radius: Style.cornerRadius
          color: Color.accent
          borderSpec: Border.controlSpec("normal", Color.accent, Color.accent)

          Text {
            textFormat: Text.PlainText
            anchors.centerIn: parent
            text: root.editingId !== "" ? "Update Service Settings" : "Save & Enable Service"
            color: "white"
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              var serviceId = root.editingId !== "" ? root.editingId : (root.selectedType + "-" + Date.now())
              var payload = {
                id: serviceId,
                type: root.selectedType,
                name: nameInput.text.trim() || root.selectedType,
                url: urlInput.text.trim(),
                apiKey: keyInput.text.trim(),
                apiSecret: secretInput.text.trim(),
                iconPath: root.previewIconPath,
                widgets: root.selectedWidgets,
                enabled: true
              }
              root.serviceSaved(payload)
              root.addingNew = false
              root.editingId = ""
              root.sniffResult = null
            }
          }
        }
      }
    }
  }
}
