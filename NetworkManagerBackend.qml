import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// WireGuard and VPN-plugin connections managed by NetworkManager. Toggling a
// connection goes through nmcli, which NetworkManager authorizes through
// polkit, so no sudo is needed for connections the session user may manage.
Item {
  id: root

  property var strings: null
  property int refreshIntervalSec: 30

  property bool installed: false
  property var connections: []
  property string lastError: ""

  // uuid -> true while an action for it is queued or running, so the row can
  // show progress and ignore double clicks.
  property var pendingIds: ({})
  readonly property bool busy: actionProcess.running || _queue.length > 0

  property var _queue: []
  property string _connectionsSig: "[]"

  function t(key, fallback) {
    return strings ? strings.t(key, fallback) : fallback
  }

  function refresh() {
    if (!installed) {
      if (!whichProcess.running) whichProcess.running = true
      return
    }
    if (!listProcess.running) listProcess.running = true
  }

  function publish(next) {
    var sig = JSON.stringify(next)
    if (sig === _connectionsSig) return
    _connectionsSig = sig
    connections = next
  }

  function find(uuid) {
    for (var i = 0; i < connections.length; i++) if (connections[i].uuid === uuid) return connections[i]
    return null
  }

  function setPending(uuid, on) {
    var next = {}
    for (var key in pendingIds) if (key !== uuid) next[key] = true
    if (on) next[uuid] = true
    pendingIds = next
  }

  function up(uuid) { enqueue(uuid, "up") }
  function down(uuid) { enqueue(uuid, "down") }

  function toggle(uuid) {
    var c = find(uuid)
    if (!c) return
    if (c.active) down(uuid)
    else up(uuid)
  }

  function enqueue(uuid, verb) {
    var id = String(uuid || "")
    if (!installed || id === "" || pendingIds[id] === true) return
    setPending(id, true)
    _queue = _queue.concat([{ uuid: id, verb: verb }])
    runNext()
  }

  function runNext() {
    if (actionProcess.running || _queue.length === 0) return
    var job = _queue[0]
    _queue = _queue.slice(1)
    actionProcess.job = job
    actionProcess.command = ["nmcli", "--wait", "20", "connection", job.verb, "uuid", job.uuid]
    actionProcess.running = true
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // `nmcli monitor` prints a line on every connection change; collapse bursts
  // into one refresh.
  Timer {
    id: debounce
    interval: 400
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    id: monitorRestart
    interval: 5000
    repeat: false
    onTriggered: if (root.installed) monitorProcess.running = true
  }

  Process {
    id: whichProcess
    command: ["sh", "-c", "command -v nmcli"]
    onExited: function(exitCode) {
      root.installed = exitCode === 0
      if (root.installed) {
        root.refresh()
        monitorProcess.running = true
      } else {
        root.publish([])
      }
    }
  }

  Process {
    id: listProcess
    command: ["nmcli", "-t", "-f", "NAME,UUID,TYPE,DEVICE,ACTIVE,STATE", "connection", "show"]
    stdout: StdioCollector { id: listOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) root.publish(Model.parseNmConnections(listOut.text))
    }
  }

  Process {
    id: monitorProcess
    command: ["nmcli", "monitor"]
    stdout: SplitParser { onRead: function(line) { debounce.restart() } }
    onExited: monitorRestart.restart()
  }

  Process {
    id: actionProcess
    property var job: null
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function(exitCode) {
      var job = actionProcess.job
      if (exitCode !== 0) {
        var name = job && root.find(job.uuid) ? root.find(job.uuid).name : ""
        root.lastError = Model.elide((name !== "" ? name + ": " : "") + (actionErr.text || root.t("error.commandFailed", "Command failed")))
      } else {
        root.lastError = ""
      }
      if (job) root.setPending(job.uuid, false)
      actionProcess.job = null
      root.refresh()
      root.runNext()
    }
  }
}
