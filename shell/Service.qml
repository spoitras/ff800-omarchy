import QtQuick
import Quickshell
import Quickshell.Io

// Thin QML front end for the `ff800` shell script. All of the real logic --
// clock-mode coercion, service ordering, bus resets -- stays in the script, so
// the bar widget and the terminal never disagree about what "on" means.
//
// `ff800 status --json` is the only thing polled. It costs ~45ms and opens a
// short-lived JACK client, which is safe against a live server; the script's
// own `timeout` guards the case where jackd is wedged in the FFADO device open
// and never answers.
Item {
  id: root

  property var settings: ({})

  // ---------------------------------------------------------------- status
  // Named ffState, not `state`: Item already owns `state`.
  property string ffState: "unknown"   // on | partial | off | absent | failed | unknown
  property bool device: false
  property string jackd: ""
  property string pipewire: ""
  property bool bridge: false
  property int rate: 0
  property int buffer: 0
  property int ports: 0
  property real dsp: 0
  property int xruns: 0

  property bool refreshing: false
  property string actionStatus: ""
  property string lastError: ""

  // Optimistic on/off so the switch throws the instant it is clicked: `ff800
  // on` takes ~15s end to end (clock check, jackd start, PipeWire restart) and
  // a switch that sits still for that long reads as broken. -1 means "follow
  // whatever the last poll said".
  property int _desired: -1
  readonly property bool isOn: ffState === "on" || ffState === "partial"
  readonly property bool active: _desired === -1 ? isOn : (_desired === 1)
  readonly property bool busy: controlProcess.running
  readonly property bool known: ffState !== "unknown"
  // Which direction the in-flight command is heading, for the "Starting…" /
  // "Stopping…" label. Meaningless unless `busy`.
  readonly property bool pendingOn: _desired === 1

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 15, 2, 300)
  readonly property string command: String(setting("command", "ff800"))

  // Period, not round-trip latency: one jackd cycle at the running buffer size.
  readonly property real periodMs: rate > 0 ? (buffer * 1000 / rate) : 0

  property string _controlOut: ""
  property string _controlErr: ""

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  // ~/.local/bin is where the README installs `ff800`, and it is not
  // guaranteed to be on the shell process's PATH -- Hyprland's autostart
  // inherits the session environment, not an interactive shell's profile.
  function argv(args) {
    return ["bash", "-c", 'PATH="$HOME/.local/bin:$PATH"; exec "$0" "$@"', root.command].concat(args)
  }

  function refresh() {
    if (statusProcess.running) return
    refreshing = true
    statusProcess.command = argv(["status", "--json"])
    statusProcess.running = true
  }

  function applyStatus(raw) {
    var json
    try {
      json = JSON.parse(String(raw || ""))
    } catch (e) {
      lastError = "Could not parse ff800 status"
      return
    }
    ffState = String(json.state || "unknown")
    device = json.device === true
    jackd = String(json.jackd || "")
    pipewire = String(json.pipewire || "")
    bridge = json.bridge === true
    rate = Number(json.rate || 0)
    buffer = Number(json.buffer || 0)
    ports = Number(json.ports || 0)
    dsp = Number(json.dsp || 0)
    xruns = Number(json.xruns || 0)
    // Reality caught up with a pending on/off -- stop overriding it.
    if (_desired !== -1 && isOn === (_desired === 1)) _desired = -1
    lastError = ""
  }

  function elide(text) {
    var value = String(text || "").replace(/\s+/g, " ").trim()
    return value.length > 200 ? value.substring(0, 197) + "…" : value
  }

  // ------------------------------------------------------------ commands

  function power(on) {
    if (controlProcess.running) return
    if (on && !device) {
      lastError = "The interface is not on the FireWire bus -- power it on first."
      return
    }
    _desired = on ? 1 : 0
    lastError = ""
    actionStatus = on ? "Starting jackd, attaching PipeWire…"
                      : "Detaching PipeWire, stopping jackd…"
    runControl(argv([on ? "on" : "off"]))
  }

  function toggleRunning() { power(!active) }

  // Recovers a device wedged by an unclean exit: red HOST light, "stream
  // enabled" errors, jackd segfaulting on start.
  function reset() {
    if (controlProcess.running) return
    lastError = ""
    actionStatus = "Resetting the FireWire bus…"
    runControl(argv(["reset"]))
  }

  function runControl(command) {
    _controlOut = ""
    _controlErr = ""
    controlProcess.command = command
    controlProcess.running = true
  }

  function openMixer() {
    // Mixer access goes through ffado-dbus-server, which is a separate
    // channel from streaming -- safe to open while jackd holds the device.
    Quickshell.execDetached(["uwsm-app", "--", "ffado-mixer"])
    actionStatus = "Opening ffado-mixer…"
    actionStatusTimer.restart()
  }

  // `ff800 on/off` restarts PipeWire, and the bar's audio widget does not
  // always survive losing its connection. This is the documented way back.
  function restartShell() {
    Quickshell.execDetached(["omarchy-restart-shell"])
  }

  // ------------------------------------------------------------- polling

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // jackd and PipeWire both take a few seconds to settle after on/off, and the
  // periodic poll is far too slow to show that. Chase the new state instead.
  Timer {
    id: settleTimer
    property int ticks: 0
    interval: 1500
    repeat: true
    running: false
    onTriggered: {
      ticks += 1
      root.refresh()
      if (ticks >= 5) {
        ticks = 0
        running = false
        root._desired = -1
      }
    }
  }

  Timer {
    id: actionStatusTimer
    interval: 3000
    onTriggered: root.actionStatus = ""
  }

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    stderr: StdioCollector { id: statusErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.refreshing = false
      if (exitCode === 0) root.applyStatus(statusOut.text)
      else root.lastError = root.elide(statusErr.text || statusOut.text
        || "`" + root.command + "` is not on PATH")
    }
  }

  Process {
    id: controlProcess
    running: false
    command: []
    stdout: StdioCollector { id: controlOut; waitForEnd: true }
    stderr: StdioCollector { id: controlErr; waitForEnd: true }
    onExited: function(exitCode) {
      var out = String(controlOut.text || "")
      var err = String(controlErr.text || "")
      if (exitCode !== 0) {
        root._desired = -1
        root.lastError = root.elide(err || out || "ff800 failed")
        root.actionStatus = ""
      } else {
        root.lastError = ""
        // First line only: the success path also echoes wpctl's JACK nodes.
        root.actionStatus = root.elide(out.split("\n")[0])
        actionStatusTimer.restart()
      }
      settleTimer.ticks = 0
      settleTimer.restart()
    }
  }
}
