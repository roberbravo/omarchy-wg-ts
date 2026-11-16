import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Tailscale state and actions through the `tailscale` CLI. Adapted from
// Omarchy's built-in Tailscale widget (MIT, Copyright (c) David Heinemeier
// Hansson), trimmed to what a VPN switcher needs: on/off, login, account
// switching, and operator authorization.
Item {
  id: root

  property var strings: null
  property int refreshIntervalSec: 30
  property bool wanted: true

  property bool installed: false
  property bool running: false
  property bool needsLogin: false
  property string authUrl: ""
  property string selfName: ""
  property string selfIp: ""
  property var accounts: []
  property string selectedAccountId: ""
  property string selectedAccountLabel: ""
  property string switchingAccountId: ""
  property bool accountsAccessDenied: false
  property string lastError: ""

  // Optimistic state so the switch reacts on click: -1 follows reality,
  // 0/1 holds the requested state until a status poll confirms it.
  property int _desired: -1
  readonly property bool active: _desired === -1 ? running : _desired === 1
  readonly property bool busy: actionProcess.running || loginProcess.running || switchProcess.running || operatorProcess.running
  readonly property string userName: Quickshell.env("USER") || Quickshell.env("LOGNAME") || ""
  property bool _loginUrlOpened: false
  property double _lastAccountsRefreshMs: 0

  function t(key, fallback) {
    return strings ? strings.t(key, fallback) : fallback
  }

  function refresh(forceAccounts) {
    if (!wanted) return
    if (!installed) {
      if (!whichProcess.running) whichProcess.running = true
      return
    }
    var launched = false
    if (!statusProcess.running) {
      statusProcess.running = true
      launched = true
    }
    var now = Date.now()
    if ((forceAccounts === true || accounts.length === 0 || now - _lastAccountsRefreshMs > 60000) && !accountsProcess.running) {
      _lastAccountsRefreshMs = now
      accountsProcess.running = true
      launched = true
    }
    if (launched && !watchdog.running) watchdog.start()
  }

  function resetUnavailable() {
    running = false
    needsLogin = false
    _desired = -1
    authUrl = ""
    selfName = ""
    selfIp = ""
    accounts = []
    selectedAccountId = ""
    selectedAccountLabel = ""
  }

  function applyStatus(raw) {
    var s = Model.parseStatus(raw)
    if (!s.ok || s.unavailable) {
      resetUnavailable()
      return
    }
    running = s.running
    if (_desired !== -1 && running === (_desired === 1)) _desired = -1
    needsLogin = s.needsLogin
    authUrl = s.authUrl
    selfName = s.selfName
    selfIp = s.selfIp
    if (running) _loginUrlOpened = false
  }

  function applyAccounts(raw) {
    var parsed = Model.parseAccounts(raw, t)
    accounts = parsed.accounts
    selectedAccountId = parsed.selectedAccountId
    selectedAccountLabel = parsed.selectedAccountLabel
  }

  function toggle() {
    if (active) down()
    else up()
  }

  function down() {
    if (!installed || actionProcess.running) return
    _desired = 0
    actionProcess.command = ["tailscale", "down"]
    actionProcess.running = true
  }

  function up() {
    if (!installed || loginProcess.running) return
    var plan = Model.loginPlan(needsLogin, authUrl)
    if (plan.authUrl !== "") {
      openAuthUrl(plan.authUrl)
      return
    }
    _desired = needsLogin ? -1 : 1
    _loginUrlOpened = false
    loginOut.buffer = ""
    loginProcess.command = plan.command
    loginProcess.running = true
  }

  function switchAccount(id) {
    var accountId = String(id || "")
    if (!installed || accountId === "" || accountId === selectedAccountId || switchProcess.running) return
    switchingAccountId = accountId
    switchProcess.command = ["tailscale", "switch", accountId]
    switchProcess.running = true
  }

  // `tailscale up/down/switch` need the user to be the daemon's operator.
  function authorizeOperator() {
    if (!installed || operatorProcess.running || userName === "") return
    operatorProcess.command = ["pkexec", "tailscale", "set", "--operator=" + userName]
    operatorProcess.running = true
  }

  function openAuthUrl(text) {
    if (_loginUrlOpened) return true
    var match = String(text || "").match(/https:\/\/\S+/)
    if (!match) return false
    _desired = -1
    _loginUrlOpened = true
    Quickshell.execDetached(["xdg-open", match[0]])
    return true
  }

  function fail(stderr, fallbackKey, fallback) {
    _desired = -1
    lastError = Model.elide(stderr || t(fallbackKey, fallback))
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: root.wanted
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Right after boot tailscaled often is not up yet; poll quickly for ~30s.
  Timer {
    id: startupRamp
    property int ticks: 0
    interval: 2000
    repeat: true
    running: root.wanted
    onTriggered: {
      ticks += 1
      if (root.running || ticks >= 15) startupRamp.running = false
      else root.refresh()
    }
  }

  Timer {
    id: delayedRefresh
    interval: 600
    onTriggered: root.refresh(true)
  }

  // A hung CLI call would otherwise block every later poll.
  Timer {
    id: watchdog
    interval: 15000
    onTriggered: {
      if (statusProcess.running) statusProcess.running = false
      if (accountsProcess.running) accountsProcess.running = false
    }
  }

  Process {
    id: whichProcess
    command: ["sh", "-c", "command -v tailscale"]
    onExited: function(exitCode) {
      root.installed = exitCode === 0
      if (root.installed) root.refresh(true)
      else root.resetUnavailable()
    }
  }

  Process {
    id: statusProcess
    command: ["tailscale", "status", "--json", "--peers=false"]
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) root.applyStatus(statusOut.text)
      else root.resetUnavailable()
    }
  }

  Process {
    id: accountsProcess
    command: ["tailscale", "switch", "--list", "--json"]
    stdout: StdioCollector { id: accountsOut; waitForEnd: true }
    stderr: StdioCollector { id: accountsErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.accountsAccessDenied = false
        root.applyAccounts(accountsOut.text)
      } else {
        root.applyAccounts("")
        root.accountsAccessDenied = /access denied/i.test(String(accountsErr.text || ""))
      }
    }
  }

  Process {
    id: actionProcess
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.fail(actionErr.text, "error.commandFailed", "Command failed")
      else root.lastError = ""
      delayedRefresh.restart()
    }
  }

  Process {
    id: loginProcess
    // `tailscale up` prints the login URL and keeps waiting; open it as soon
    // as it shows up.
    stdout: SplitParser { onRead: function(line) { loginOut.buffer += line + "\n"; root.openAuthUrl(line) } }
    stderr: SplitParser { onRead: function(line) { loginOut.buffer += line + "\n"; root.openAuthUrl(line) } }
    onExited: function(exitCode) {
      if (exitCode !== 0 && !root._loginUrlOpened) root.fail(loginOut.buffer, "error.upFailed", "Could not start Tailscale")
      else root.lastError = ""
      delayedRefresh.restart()
    }
  }

  QtObject {
    id: loginOut
    property string buffer: ""
  }

  Process {
    id: switchProcess
    stderr: StdioCollector { id: switchErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.fail(switchErr.text, "error.switchFailed", "Could not switch account")
      else {
        root.lastError = ""
        root._lastAccountsRefreshMs = 0
      }
      root.switchingAccountId = ""
      delayedRefresh.restart()
    }
  }

  Process {
    id: operatorProcess
    stderr: StdioCollector { id: operatorErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.fail(operatorErr.text, "error.authorizationFailed", "Authorization failed")
      else {
        root.lastError = ""
        root.accountsAccessDenied = false
      }
      delayedRefresh.restart()
    }
  }
}
