import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

BarWidget {
  id: root
  moduleName: "kiryuuki.oma-lab"

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function refresh() {
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh()
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.open) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item && panelLoader.item.closeForPopoutSwitch) panelLoader.item.closeForPopoutSwitch()
  }

  function getStatusColor(panelItem) {
    if (root.opened) return Color.accent
    if (panelItem && panelItem.homelabState && panelItem.homelabState.summary) {
      var s = panelItem.homelabState.summary
      if (s.alerts > 0) return "#EF4444"
      if (s.online > 0) return "#10B981"
    }
    return root.bar ? root.bar.barForeground : Color.foreground
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "kiryuuki.oma-lab"

    function refresh(): void { root.refresh() }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.togglePanel() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰒋"
    foreground: root.getStatusColor(panelLoader.item)
    slotSize: Style.bar.statusSlot
    tooltipText: {
      var item = panelLoader.item
      if (!item || !item.homelabState || !item.homelabState.summary) return "Homelab: Monitor & Launcher"
      var s = item.homelabState.summary
      return "Homelab: " + s.online + "/" + s.enabled + " Online" + (s.alerts > 0 ? " (" + s.alerts + " Alert)" : "")
    }

    onPressed: function(b) {
      console.log("HOMELAB TEST pressed btn=" + b)
      if (!root.bar) return
      if (b === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }
  }
}
