import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar widget + popup for the RME Fireface 800 stack. The bar icon is the
// at-a-glance state; the popup carries the on/off switch, the numbers worth
// watching while tracking (buffer, DSP load, xruns), and the three recovery
// actions the README calls for.
Panel {
  id: root
  moduleName: "spoitras.ff800"
  ipcTarget: "ff800"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string glyph: ff800.ffState === "failed" ? "󰀦" : "󰥛"  // nf-md-alert / nf-md-sine_wave
  readonly property bool hideWhenAbsent: String(setting("whenAbsent", "Show")) === "Hide"
  readonly property bool shown: !hideWhenAbsent || ff800.ffState !== "absent"

  // Cursor targets, top to bottom: the header switch, then the action rows.
  readonly property int actionCount: 3
  property int cursorIndex: 0
  property bool cursorActive: false

  readonly property string stateLabel: {
    if (ff800.busy) return ff800.pendingOn ? "Starting…" : "Stopping…"
    switch (ff800.ffState) {
      case "on":      return (ff800.rate / 1000) + " kHz · " + ff800.buffer + " frames"
      case "partial": return "Running, desktop not bridged"
      case "off":     return "Off"
      case "absent":  return "Not on the FireWire bus"
      case "failed":  return "jackd failed to start"
      default:        return "Checking…"
    }
  }

  readonly property string tooltip: {
    if (!ff800.known) return "Fireface 800"
    if (ff800.ffState === "on") return "Fireface 800 — " + ff800.rate + " Hz / " + ff800.buffer + " frames"
    return "Fireface 800 — " + stateLabel
  }

  function togglePower() {
    if (!ff800.busy) ff800.toggleRunning()
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    if (dy === 0) return
    cursorIndex = Math.max(0, Math.min(actionCount, cursorIndex + dy))
    scrollCursorIntoView()
  }

  function activateCursor() {
    if (cursorIndex === 0) togglePower()
    else if (cursorIndex === 1) ff800.reset()
    else if (cursorIndex === 2) ff800.openMixer()
    else if (cursorIndex === 3) ff800.restartShell()
  }

  function setCursor(index) {
    cursorActive = true
    cursorIndex = index
  }

  function scrollCursorIntoView() {
    if (!panelFlick) return
    if (cursorIndex === 0) panelFlick.contentY = 0
    else panelFlick.contentY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
  }

  visible: shown
  implicitWidth: shown ? button.implicitWidth : 0
  implicitHeight: shown ? button.implicitHeight : 0

  onOpenedChanged: if (opened) {
    cursorActive = false
    cursorIndex = 0
    if (panelFlick) panelFlick.contentY = 0
    ff800.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Service {
    id: ff800
    settings: root.settings
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function powerOn(): string { ff800.power(true); return "ok" }
    function powerOff(): string { ff800.power(false); return "ok" }
    function power(): string { ff800.toggleRunning(); return "ok" }
    function reset(): string { ff800.reset(); return "ok" }
    function refresh(): string { ff800.refresh(); return "ok" }
    function state(): string { return ff800.ffState }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyph
    tooltipText: root.tooltip
    // Urgent red for a failed start; dimmed for anything that is not fully up.
    active: ff800.ffState === "failed"
    dimmed: ff800.ffState !== "on"
    onPressed: function(buttonCode) {
      // Deliberately no power toggle on right-click: `ff800 on` restarts
      // PipeWire and takes ~15s, which is not something to trigger by accident.
      if (buttonCode === Qt.RightButton) ff800.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var k = String(t).toLowerCase()
        if (k === "r") ff800.refresh()
        else if (k === "p") root.togglePower()
        else if (k === "x") ff800.reset()
        else if (k === "m") ff800.openMixer()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight
            // The hero's `root` resolves to PanelHero, so its trailingControl
            // reaches panel state through `header` instead.
            readonly property bool ringVisible: root.cursorActive && root.cursorIndex === 0
            function focusHero() { root.setCursor(0) }

            PanelHero {
              id: hero
              width: parent.width
              title: "Fireface 800"
              meta: root.stateLabel
              detail: ff800.ffState === "on" && ff800.xruns > 0
                ? ff800.xruns + (ff800.xruns === 1 ? " xrun" : " xruns") : ""
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconOpacity: ff800.active ? 1.0 : 0.5
              iconComponent: Component {
                Text {
                  textFormat: Text.PlainText
                  text: root.glyph
                  color: ff800.ffState === "failed" ? root.urgent
                    : (ff800.active ? root.foreground : root.dim)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }
              }

              trailingControl: Component {
                ToggleSwitch {
                  id: powerSwitch
                  checked: ff800.active
                  busy: ff800.busy
                  hasCursor: header.ringVisible
                  foreground: hero.foreground
                  onHovered: function(isHovered) { if (isHovered) header.focusHero() }
                  onToggled: root.togglePower()

                  PanelToolTip {
                    visible: powerSwitch.containsMouse
                    text: ff800.active ? "Stop jackd and detach PipeWire"
                                       : "Start jackd and attach PipeWire"
                    fontFamily: hero.fontFamily
                  }
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: text !== ""
            width: parent.width
            text: ff800.lastError !== "" ? ff800.lastError : ff800.actionStatus
            color: ff800.lastError !== "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          PanelSeparator { foreground: root.foreground }

          Column {
            width: parent.width
            spacing: Style.spacing.labelGap

            InfoPair {
              label: "Device"
              value: ff800.device ? "present on bus" : "absent"
            }
            InfoPair {
              label: "jackd"
              value: ff800.jackd !== "" ? ff800.jackd : "—"
            }
            InfoPair {
              visible: ff800.rate > 0
              label: "Clock"
              value: ff800.rate + " Hz"
            }
            InfoPair {
              visible: ff800.buffer > 0
              label: "Buffer"
              value: ff800.buffer + " frames · " + ff800.periodMs.toFixed(1) + " ms"
            }
            InfoPair {
              visible: ff800.ports > 0
              label: "Ports"
              value: String(ff800.ports)
            }
            InfoPair {
              visible: ff800.isOn
              label: "DSP load"
              value: ff800.dsp.toFixed(1) + " %"
            }
            InfoPair {
              visible: ff800.isOn
              label: "Xruns"
              value: String(ff800.xruns)
              urgentValue: ff800.xruns > 0
            }
            InfoPair {
              label: "PipeWire bridge"
              value: ff800.bridge ? "enabled" : "disabled"
            }
            InfoPair {
              label: "PipeWire"
              value: ff800.pipewire !== "" ? ff800.pipewire : "—"
            }
          }

          PanelSeparator { foreground: root.foreground }

          Column {
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "ACTIONS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            ActionRow {
              rowIndex: 1
              glyph: "󰜉"
              title: "Reset device"
              subtitle: "For a red HOST light or a wedged stream"
              onTriggered: ff800.reset()
            }
            ActionRow {
              rowIndex: 2
              glyph: "󰙪"
              title: "Onboard mixer"
              subtitle: "Trims, hi-Z, zero-latency monitoring"
              onTriggered: ff800.openMixer()
            }
            ActionRow {
              rowIndex: 3
              glyph: "󰦛"
              title: "Restart shell"
              subtitle: "Restores the bar's audio icon"
              onTriggered: ff800.restartShell()
            }
          }
        }
      }
    }
  }

  component ActionRow: CursorSurface {
    id: actionRow
    property int rowIndex: 0
    property string glyph: ""
    property string title: ""
    property string subtitle: ""
    signal triggered()

    width: parent ? parent.width : 0
    hasCursor: root.cursorActive && root.cursorIndex === rowIndex
    foreground: root.foreground
    implicitHeight: actionLabels.implicitHeight + Style.spacing.rowPaddingX
    enabled: !ff800.busy
    opacity: enabled ? 1.0 : 0.5

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.setCursor(actionRow.rowIndex)
      onClicked: actionRow.triggered()
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(10)

      Text {
        textFormat: Text.PlainText
        text: actionRow.glyph
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        id: actionLabels
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: actionRow.title
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: actionRow.subtitle
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }

  component InfoPair: Row {
    id: infoPair
    property string label: ""
    property string value: ""
    property bool urgentValue: false

    width: parent ? parent.width : 0
    spacing: Style.space(8)

    Text {
      id: infoLabel
      textFormat: Text.PlainText
      text: infoPair.label
      color: root.foreground
      opacity: 0.6
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    // Pushes the value to the trailing edge without a Layout, so the row
    // stays a plain Row inside the Column.
    Item {
      width: Math.max(0, infoPair.width - infoLabel.implicitWidth - infoValue.implicitWidth - infoPair.spacing * 2)
      height: 1
    }

    Text {
      id: infoValue
      textFormat: Text.PlainText
      text: infoPair.value
      color: infoPair.urgentValue ? root.urgent : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }
  }
}
