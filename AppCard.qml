import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "Model.js" as Model

BorderSurface {
  id: root

  property var serviceData: ({})
  property color foreground: Color.foreground
  property color dim: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.70)
  property color subtle: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.45)
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family
  property bool expanded: false
  property bool isSelected: false

  signal launchRequested(string url)
  signal actionRequested(string serviceId, string actionName, var payload)
  signal expandToggled(string serviceId)

  readonly property bool isOnline: serviceData && serviceData.online === true
  readonly property bool isEnabled: serviceData && serviceData.enabled !== false
  readonly property string serviceId: serviceData ? (serviceData.id || "") : ""
  readonly property string serviceName: serviceData ? (serviceData.name || "App") : "App"
  readonly property string serviceType: serviceData ? (serviceData.type || "generic") : "generic"
  readonly property string serviceUrl: serviceData ? (serviceData.url || "") : ""
  readonly property string statusText: serviceData ? (serviceData.statusText || "") : ""
  readonly property string badgeText: serviceData && serviceData.badge ? String(serviceData.badge) : ""
  readonly property string iconGlyph: serviceData && serviceData.icon ? serviceData.icon : Model.getIconForType(serviceType)
  readonly property string officialAsset: Model.getAssetForType(serviceType, serviceData ? serviceData.iconPath : "")
  readonly property var widgetsData: serviceData && serviceData.widgetsData ? serviceData.widgetsData : ({})

  readonly property color statusColor: !isEnabled ? root.subtle : (isOnline ? "#87c095" : "#e06c75")

  width: parent ? parent.width : Style.space(520)
  implicitHeight: cardCol.implicitHeight + Style.space(16)
  radius: Style.cornerRadius
  color: isSelected
    ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.16)
    : Style.hoverFillFor(root.foreground, root.foreground)
  borderSpec: isSelected
    ? Border.controlSpec("focus", Color.accent, Color.accent)
    : (root.expanded
      ? Border.controlSpec("selected", Color.accent, Color.accent)
      : (hoverArea.containsMouse ? Border.controlSpec("focus", Color.accent, Color.accent) : Border.controlSpec("normal", root.subtle, Color.accent)))

  Behavior on borderSpec { ColorAnimation { duration: 120 } }

  Column {
    id: cardCol
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.margins: Style.space(8)
    spacing: Style.space(8)

    // ==========================================
    // TOP HEADER ROW
    // ==========================================
    Item {
      id: headerRow
      width: parent.width
      implicitHeight: Math.max(iconBox.implicitHeight, headerTextCol.implicitHeight)

      MouseArea {
        id: hoverArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.expandToggled(root.serviceId)
      }

      RowLayout {
        anchors.fill: parent
        spacing: Style.space(10)

        // Official SVG Logo or Fallback Glyph
        Item {
          id: iconBox
          width: Style.space(34)
          height: Style.space(34)

          Rectangle {
            anchors.fill: parent
            radius: Style.cornerRadius
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
            border.width: Style.spacing.hairline
            border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)

            Image {
              id: officialImg
              anchors.fill: parent
              anchors.margins: Style.space(4)
              source: root.officialAsset
              visible: root.officialAsset !== "" && status === Image.Ready
              fillMode: Image.PreserveAspectFit
              smooth: true
              mipmap: true
            }

            Text {
              textFormat: Text.PlainText
              anchors.centerIn: parent
              visible: root.officialAsset === "" || officialImg.status !== Image.Ready
              text: root.iconGlyph
              color: root.isEnabled ? root.foreground : root.subtle
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
            }
          }

          // Online / Offline Status Dot
          Rectangle {
            width: Style.space(9)
            height: width
            radius: width / 2
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.rightMargin: -Style.space(1)
            anchors.bottomMargin: -Style.space(1)
            color: root.statusColor
            border.width: Style.space(1.5)
            border.color: "#18181B"
          }
        }

        // Title and Status text
        Column {
          id: headerTextCol
          Layout.fillWidth: true
          spacing: Style.space(2)

          RowLayout {
            spacing: Style.space(6)
            Text {
              textFormat: Text.PlainText
              text: root.serviceName
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              elide: Text.ElideRight
            }

            // Metric Badge Pill
            BorderSurface {
              visible: root.badgeText !== ""
              implicitWidth: badgeLabel.implicitWidth + Style.space(8)
              implicitHeight: badgeLabel.implicitHeight + Style.space(3)
              color: "transparent"
              borderSpec: Border.controlSpec("normal", root.serviceData && root.serviceData.badgeType === "warning" ? "#e5c07b" : (root.serviceData && root.serviceData.badgeType === "success" ? "#87c095" : Color.accent), Color.accent)
              radius: Style.cornerRadius

              Text {
                id: badgeLabel
                textFormat: Text.PlainText
                anchors.centerIn: parent
                text: root.badgeText
                color: root.serviceData && root.serviceData.badgeType === "warning" ? "#e5c07b" : (root.serviceData && root.serviceData.badgeType === "success" ? "#87c095" : Color.accent)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.statusText
            color: root.isOnline ? (root.serviceData && root.serviceData.badgeType === "warning" ? "#e5c07b" : root.dim) : (root.isEnabled ? "#e06c75" : root.subtle)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        // Actions: Open in Browser (󰌹) & Chevron
        Row {
          spacing: Style.space(4)

          PanelActionButton {
            iconText: "󰌹"
            tooltipText: "Open in Browser"
            foreground: Color.accent
            onClicked: {
              var t = Model.safeUrl(root.serviceUrl)
              if (t) root.launchRequested(t)
            }
          }

          PanelActionButton {
            iconText: root.expanded ? "󰅃" : "󰅀"
            tooltipText: root.expanded ? "Collapse details" : "Expand details"
            onClicked: root.expandToggled(root.serviceId)
          }
        }
      }
    }

    // ==========================================
    // EXPANDED WIDGETS SECTION
    // ==========================================
    Column {
      id: expandedContent
      visible: root.expanded
      width: parent.width
      spacing: Style.space(8)

      // Thin separator
      Rectangle {
        width: parent.width
        height: Style.spacing.hairline
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
      }

      // ----------------------------------------------------
      // 1. PROXMOX VE CLUSTER, RESOURCE GAUGES & VM/LXC LIST
      // ----------------------------------------------------
      Column {
        id: proxmoxWidgetCol
        visible: root.serviceType === "proxmox"
        width: parent.width
        spacing: Style.space(8)

        readonly property var pveData: root.widgetsData.proxmox || ({})

        Text {
          textFormat: Text.PlainText
          text: "CLUSTER RESOURCES & WORKLOADS"
          color: root.subtle
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 1
        }

        // Permission Missing Alert Banner (if PVEAuditor role is not yet assigned on /)
        BorderSurface {
          visible: Boolean(proxmoxWidgetCol.pveData.permissionWarning)
          width: parent.width
          implicitHeight: pveWarnCol.implicitHeight + Style.space(12)
          radius: Style.cornerRadius
          color: Qt.rgba(229/255, 192/255, 123/255, 0.08)
          borderSpec: Border.controlSpec("normal", "#e5c07b", Color.accent)

          Column {
            id: pveWarnCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(6)
            spacing: 2

            Text {
              textFormat: Text.PlainText
              text: "⚠ Proxmox Token Permission Notice"
              color: "#e5c07b"
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
            Text {
              textFormat: Text.PlainText
              width: parent.width
              wrapMode: Text.WordWrap
              text: "API Token authenticated, but needs 'PVEAuditor' role on path '/' to read CPU, RAM, and VM lists.\nIn Proxmox UI: Datacenter > Permissions > Add > API Token Permission (Path: /, Role: PVEAuditor)."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        // Three Resource Metric Cards (CPU, RAM, Storage)
        RowLayout {
          visible: !proxmoxWidgetCol.pveData.permissionWarning || proxmoxWidgetCol.pveData.hasMetrics
          width: parent.width
          spacing: Style.space(6)

          // CPU Usage
          BorderSurface {
            Layout.fillWidth: true
            implicitHeight: Style.space(52)
            radius: Style.cornerRadius
            color: "transparent"
            borderSpec: Border.controlSpec("normal", root.subtle, Color.accent)

            Column {
              anchors.fill: parent
              anchors.margins: Style.space(6)
              spacing: Style.space(3)

              RowLayout {
                width: parent.width
                Text { textFormat: Text.PlainText; text: "󰍛 CPU"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                Item { Layout.fillWidth: true }
                Text { textFormat: Text.PlainText; text: (proxmoxWidgetCol.pveData.avgCpuPercent || 0) + "%"; color: Color.accent; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
              }

              Rectangle {
                width: parent.width
                height: Style.space(4)
                radius: height / 2
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)

                Rectangle {
                  width: Math.round(parent.width * (Math.min(100, proxmoxWidgetCol.pveData.avgCpuPercent || 0) / 100.0))
                  height: parent.height
                  radius: parent.radius
                  color: (proxmoxWidgetCol.pveData.avgCpuPercent || 0) > 85 ? "#e06c75" : Color.accent
                }
              }
            }
          }

          // Memory Usage
          BorderSurface {
            Layout.fillWidth: true
            implicitHeight: Style.space(52)
            radius: Style.cornerRadius
            color: "transparent"
            borderSpec: Border.controlSpec("normal", root.subtle, Color.accent)

            Column {
              anchors.fill: parent
              anchors.margins: Style.space(6)
              spacing: Style.space(3)

              RowLayout {
                width: parent.width
                Text { textFormat: Text.PlainText; text: "󰘚 RAM"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                Item { Layout.fillWidth: true }
                Text { textFormat: Text.PlainText; text: (proxmoxWidgetCol.pveData.memUsedStr || "0") + " (" + (proxmoxWidgetCol.pveData.memPercent || 0) + "%)"; color: "#87c095"; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
              }

              Rectangle {
                width: parent.width
                height: Style.space(4)
                radius: height / 2
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)

                Rectangle {
                  width: Math.round(parent.width * (Math.min(100, proxmoxWidgetCol.pveData.memPercent || 0) / 100.0))
                  height: parent.height
                  radius: parent.radius
                  color: "#87c095"
                }
              }
            }
          }

          // Storage Usage
          BorderSurface {
            Layout.fillWidth: true
            implicitHeight: Style.space(52)
            radius: Style.cornerRadius
            color: "transparent"
            borderSpec: Border.controlSpec("normal", root.subtle, Color.accent)

            Column {
              anchors.fill: parent
              anchors.margins: Style.space(6)
              spacing: Style.space(3)

              RowLayout {
                width: parent.width
                Text { textFormat: Text.PlainText; text: "󰋊 Disk"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                Item { Layout.fillWidth: true }
                Text { textFormat: Text.PlainText; text: (proxmoxWidgetCol.pveData.diskUsedStr || "0") + " (" + (proxmoxWidgetCol.pveData.diskPercent || 0) + "%)"; color: "#6aa6b2"; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
              }

              Rectangle {
                width: parent.width
                height: Style.space(4)
                radius: height / 2
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)

                Rectangle {
                  width: Math.round(parent.width * (Math.min(100, proxmoxWidgetCol.pveData.diskPercent || 0) / 100.0))
                  height: parent.height
                  radius: parent.radius
                  color: "#6aa6b2"
                }
              }
            }
          }
        }

        // Summary Counts (VMs & LXCs)
        RowLayout {
          width: parent.width
          spacing: Style.space(8)

          BorderSurface {
            Layout.fillWidth: true
            implicitHeight: Style.space(32)
            radius: Style.cornerRadius
            color: "transparent"
            borderSpec: Border.controlSpec("normal", root.subtle, Color.accent)

            Row {
              anchors.centerIn: parent
              spacing: Style.space(6)
              Text { textFormat: Text.PlainText; text: "󰢹"; color: Color.accent; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
              Text { textFormat: Text.PlainText; text: "Virtual Machines:"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
              Text { textFormat: Text.PlainText; text: (proxmoxWidgetCol.pveData.vmsRunning || 0) + " running / " + (proxmoxWidgetCol.pveData.vmsTotal || 0) + " total"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
            }
          }

          BorderSurface {
            Layout.fillWidth: true
            implicitHeight: Style.space(32)
            radius: Style.cornerRadius
            color: "transparent"
            borderSpec: Border.controlSpec("normal", root.subtle, Color.accent)

            Row {
              anchors.centerIn: parent
              spacing: Style.space(6)
              Text { textFormat: Text.PlainText; text: "󰡨"; color: "#87c095"; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
              Text { textFormat: Text.PlainText; text: "LXC Containers:"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
              Text { textFormat: Text.PlainText; text: (proxmoxWidgetCol.pveData.lxcsRunning || 0) + " running / " + (proxmoxWidgetCol.pveData.lxcsTotal || 0) + " total"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
            }
          }
        }

        // Active VMs / LXC Items List (Combined)
        Repeater {
          model: (proxmoxWidgetCol.pveData.vms || []).concat(proxmoxWidgetCol.pveData.lxcs || []).slice(0, 8)

          BorderSurface {
            required property var modelData
            width: parent.width
            implicitHeight: Style.space(32)
            radius: Style.cornerRadius
            color: "transparent"
            borderSpec: Border.controlSpec("normal", root.subtle, Color.accent)

            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: Style.space(8)
              anchors.rightMargin: Style.space(8)
              spacing: Style.space(8)

              Rectangle {
                width: Style.space(7)
                height: width
                radius: width / 2
                color: modelData.running ? "#87c095" : root.subtle
              }

              Text {
                textFormat: Text.PlainText
                text: "[" + modelData.id + "]"
                color: root.subtle
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: modelData.name
                color: modelData.running ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: modelData.running
                elide: Text.ElideRight
              }

              Text {
                textFormat: Text.PlainText
                text: modelData.running ? ("CPU " + modelData.cpu + "% · " + modelData.memStr) : "Stopped"
                color: modelData.running ? Color.accent : root.subtle
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }
      }

      // ----------------------------------------------------
      // 2. N8N WORKFLOWS WIDGET (ALL RETRIEVED & SORTED ACTIVE FIRST)
      // ----------------------------------------------------
      Column {
        id: n8nWidgetCol
        visible: root.serviceType === "n8n"
        width: parent.width
        spacing: Style.space(6)

        readonly property var wfData: root.widgetsData.active_workflows || ({})
        readonly property var workflows: wfData.workflows || []

        RowLayout {
          width: parent.width
          Text {
            textFormat: Text.PlainText
            text: "WORKFLOWS"
            color: root.subtle
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1
          }
          Item { Layout.fillWidth: true }
          Text {
            textFormat: Text.PlainText
            text: (n8nWidgetCol.wfData.activeCount || 0) + " active / " + (n8nWidgetCol.wfData.totalCount || 0) + " total"
            color: "#87c095"
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: !n8nWidgetCol.workflows || n8nWidgetCol.workflows.length === 0
          text: "No workflows found on this n8n instance."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Repeater {
          model: n8nWidgetCol.workflows || []

          BorderSurface {
            required property var modelData
            width: parent.width
            implicitHeight: Style.space(36)
            radius: Style.cornerRadius
            color: "transparent"
            borderSpec: Border.controlSpec("normal", root.subtle, Color.accent)

            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: Style.space(8)
              anchors.rightMargin: Style.space(8)
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                text: modelData.active ? "󰒓" : "󰒑"
                color: modelData.active ? "#87c095" : root.subtle
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: modelData.name
                color: modelData.active ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: modelData.active
                elide: Text.ElideRight
              }

              BorderSurface {
                implicitWidth: Style.space(36)
                implicitHeight: Style.space(20)
                radius: Style.cornerRadius
                color: modelData.active ? Style.selectedFillFor(root.foreground, root.foreground) : "transparent"
                borderSpec: Border.controlSpec(modelData.active ? "selected" : "normal", modelData.active ? "#87c095" : root.subtle, Color.accent)

                Text {
                  textFormat: Text.PlainText
                  anchors.centerIn: parent
                  text: modelData.active ? "ON" : "OFF"
                  color: modelData.active ? "#87c095" : root.subtle
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.actionRequested(root.serviceId, "toggle_workflow", { workflowId: modelData.id, active: !modelData.active })
                }
              }
            }
          }
        }
      }

      // ----------------------------------------------------
      // 3. JELLYFIN WIDGET
      // ----------------------------------------------------
      Column {
        id: jellyfinWidgetCol
        visible: root.serviceType === "jellyfin"
        width: parent.width
        spacing: Style.space(6)

        readonly property var sessions: root.widgetsData.now_playing ? (root.widgetsData.now_playing.sessions || []) : []

        RowLayout {
          width: parent.width
          Text {
            textFormat: Text.PlainText
            text: "ACTIVE PLAYBACK SESSIONS"
            color: root.subtle
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1
          }
          Item { Layout.fillWidth: true }
          Text {
            textFormat: Text.PlainText
            text: (jellyfinWidgetCol.sessions ? jellyfinWidgetCol.sessions.length : 0) + " active"
            color: Color.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: !jellyfinWidgetCol.sessions || jellyfinWidgetCol.sessions.length === 0
          text: "No active playback streams right now."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Repeater {
          model: jellyfinWidgetCol.sessions || []

          BorderSurface {
            required property var modelData
            width: parent.width
            implicitHeight: Style.space(52)
            radius: Style.cornerRadius
            color: "transparent"
            borderSpec: Border.controlSpec("normal", root.subtle, Color.accent)

            Column {
              anchors.fill: parent
              anchors.margins: Style.space(8)
              spacing: Style.space(4)

              RowLayout {
                width: parent.width
                spacing: Style.space(6)

                Text {
                  textFormat: Text.PlainText
                  text: modelData.isPaused ? "󰏤" : "󰐊"
                  color: modelData.isPaused ? "#e5c07b" : "#87c095"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                Text {
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: modelData.mediaTitle
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  elide: Text.ElideRight
                }

                Text {
                  textFormat: Text.PlainText
                  text: modelData.userName + " (" + modelData.deviceName + ")"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              // Progress Bar
              Rectangle {
                width: parent.width
                height: Style.space(4)
                radius: height / 2
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)

                Rectangle {
                  width: Math.round(parent.width * (modelData.progressPercent / 100.0))
                  height: parent.height
                  radius: parent.radius
                  color: Color.accent
                }
              }
            }
          }
        }
      }

      // ----------------------------------------------------
      // 4. KASM WORKSPACES WIDGET
      // ----------------------------------------------------
      Column {
        id: kasmWidgetCol
        visible: root.serviceType === "kasm" || root.serviceType === "kasm-workspaces"
        width: parent.width
        spacing: Style.space(6)

        readonly property var kasmData: root.widgetsData.kasm_sessions || ({})

        RowLayout {
          width: parent.width
          Text {
            textFormat: Text.PlainText
            text: "WORKSPACE SESSIONS & STATUS"
            color: root.subtle
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1
          }
          Item { Layout.fillWidth: true }
          Text {
            textFormat: Text.PlainText
            text: (kasmWidgetCol.kasmData ? (kasmWidgetCol.kasmData.totalSessions || 0) : 0) + " container sessions"
            color: "#87c095"
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }

        BorderSurface {
          width: parent.width
          implicitHeight: Style.space(44)
          radius: Style.cornerRadius
          color: "transparent"
          borderSpec: Border.controlSpec("normal", root.subtle, Color.accent)

          RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Style.space(8)
            anchors.rightMargin: Style.space(8)
            spacing: Style.space(8)

            Text {
              textFormat: Text.PlainText
              text: "󰢹"
              color: "#87c095"
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Column {
              Layout.fillWidth: true
              spacing: 1

              Text {
                textFormat: Text.PlainText
                text: "KASM Operational Status: " + ((kasmWidgetCol.kasmData && kasmWidgetCol.kasmData.status) ? kasmWidgetCol.kasmData.status : "Ready")
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
              }
              Text {
                textFormat: Text.PlainText
                text: "Remote browser, desktop, and isolated container streaming active"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }
      }

      // ----------------------------------------------------
      // 5. OVERSEERR / SEERR WIDGET
      // ----------------------------------------------------
      Column {
        id: seerrWidgetCol
        visible: root.serviceType === "overseerr" || root.serviceType === "jellyseerr"
        width: parent.width
        spacing: Style.space(6)

        readonly property var reqList: root.widgetsData.pending_requests ? (root.widgetsData.pending_requests.requests || []) : []

        RowLayout {
          width: parent.width
          Text {
            textFormat: Text.PlainText
            text: "PENDING REQUESTS"
            color: root.subtle
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1
          }
          Item { Layout.fillWidth: true }
          Text {
            textFormat: Text.PlainText
            text: (seerrWidgetCol.reqList ? seerrWidgetCol.reqList.length : 0) + " pending"
            color: Color.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: !seerrWidgetCol.reqList || seerrWidgetCol.reqList.length === 0
          text: "All media requests are approved and processed."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Repeater {
          model: seerrWidgetCol.reqList || []

          BorderSurface {
            required property var modelData
            width: parent.width
            implicitHeight: Style.space(42)
            radius: Style.cornerRadius
            color: "transparent"
            borderSpec: Border.controlSpec("normal", root.subtle, Color.accent)

            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: Style.space(8)
              anchors.rightMargin: Style.space(8)
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                text: modelData.type === "movie" ? "󰎁" : "󰗃"
                color: Color.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              Column {
                Layout.fillWidth: true
                spacing: 1

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: modelData.title
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  elide: Text.ElideRight
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: "Requested by " + modelData.requestedBy
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }

              Row {
                spacing: Style.space(4)

                PanelActionButton {
                  iconText: "✓"
                  tooltipText: "Approve Request"
                  foreground: "#87c095"
                  onClicked: root.actionRequested(root.serviceId, "approve", { requestId: modelData.id })
                }

                PanelActionButton {
                  iconText: "✕"
                  tooltipText: "Decline Request"
                  foreground: "#e06c75"
                  onClicked: root.actionRequested(root.serviceId, "decline", { requestId: modelData.id })
                }
              }
            }
          }
        }
      }

      // ----------------------------------------------------
      // 6. SONARR / RADARR WIDGET
      // ----------------------------------------------------
      Column {
        id: arrWidgetCol
        visible: root.serviceType === "sonarr" || root.serviceType === "radarr" || root.serviceType === "prowlarr"
        width: parent.width
        spacing: Style.space(6)

        readonly property var queueItems: root.widgetsData.download_queue ? (root.widgetsData.download_queue.items || []) : []

        RowLayout {
          width: parent.width
          Text {
            textFormat: Text.PlainText
            text: "DOWNLOAD QUEUE"
            color: root.subtle
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1
          }
          Item { Layout.fillWidth: true }
          Text {
            textFormat: Text.PlainText
            text: (arrWidgetCol.queueItems ? arrWidgetCol.queueItems.length : 0) + " active"
            color: "#87c095"
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: !arrWidgetCol.queueItems || arrWidgetCol.queueItems.length === 0
          text: "Download queue is currently empty."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Repeater {
          model: arrWidgetCol.queueItems || []

          BorderSurface {
            required property var modelData
            width: parent.width
            implicitHeight: Style.space(48)
            radius: Style.cornerRadius
            color: "transparent"
            borderSpec: Border.controlSpec("normal", root.subtle, Color.accent)

            Column {
              anchors.fill: parent
              anchors.margins: Style.space(8)
              spacing: Style.space(4)

              RowLayout {
                width: parent.width
                spacing: Style.space(6)

                Text {
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: modelData.title
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  elide: Text.ElideRight
                }

                Text {
                  textFormat: Text.PlainText
                  text: modelData.progress + "% · " + modelData.eta
                  color: "#87c095"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }

              Rectangle {
                width: parent.width
                height: Style.space(3)
                radius: height / 2
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)

                Rectangle {
                  width: Math.round(parent.width * (modelData.progress / 100.0))
                  height: parent.height
                  radius: parent.radius
                  color: "#87c095"
                }
              }
            }
          }
        }
      }

      // ----------------------------------------------------
      // 7. DOKPLOY WIDGET
      // ----------------------------------------------------
      Column {
        id: dokployWidgetCol
        visible: root.serviceType === "dokploy"
        width: parent.width
        spacing: Style.space(6)

        readonly property var stacks: root.widgetsData.containers_status ? (root.widgetsData.containers_status.stacks || []) : []

        RowLayout {
          width: parent.width
          Text {
            textFormat: Text.PlainText
            text: "DEPLOYED STACKS & APPS"
            color: root.subtle
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1
          }
          Item { Layout.fillWidth: true }
          Text {
            textFormat: Text.PlainText
            text: (dokployWidgetCol.stacks ? dokployWidgetCol.stacks.length : 0) + " running"
            color: "#87c095"
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }

        Repeater {
          model: dokployWidgetCol.stacks || []

          BorderSurface {
            required property var modelData
            width: parent.width
            implicitHeight: Style.space(38)
            radius: Style.cornerRadius
            color: "transparent"
            borderSpec: Border.controlSpec("normal", root.subtle, Color.accent)

            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: Style.space(8)
              anchors.rightMargin: Style.space(8)
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                text: "󰡨"
                color: "#87c095"
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: modelData.name + " (" + modelData.version + ")"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                elide: Text.ElideRight
              }

              PanelActionButton {
                iconText: ""
                tooltipText: "Restart Stack"
                foreground: Color.accent
                onClicked: root.actionRequested(root.serviceId, "restart", {})
              }
            }
          }
        }
      }
    }
  }
}
