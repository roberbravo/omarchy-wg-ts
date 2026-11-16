import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Bar widget that lists every VPN on the machine — NetworkManager WireGuard
// and VPN-plugin connections plus Tailscale — with one switch each.
Panel {
  id: root
  moduleName: "roberbravo.vpn"
  ipcTarget: "roberbravo.vpn"
  manageIpc: false

  readonly property string vpnGlyph: "󰖂"
  readonly property bool exclusive: setting("exclusive", false) === true
  readonly property bool showTailscale: setting("showTailscale", true) !== false
  readonly property int refreshIntervalSec: {
    var n = parseInt(String(setting("refreshIntervalSec", 30)), 10)
    return isFinite(n) ? Math.max(5, Math.min(3600, n)) : 30
  }
  readonly property string lastConnection: String(setting("lastConnection", ""))

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Commons.Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Commons.Color.accent) : "transparent"

  readonly property bool tailscaleShown: showTailscale && tailscale.installed
  readonly property var entries: {
    var list = []
    for (var i = 0; i < nm.connections.length; i++) {
      var c = nm.connections[i]
      list.push({
        id: c.id,
        uuid: c.uuid,
        name: c.name,
        kind: c.kind,
        active: c.active,
        pending: c.pending || nm.pendingIds[c.uuid] === true,
        detail: c.kind === "wireguard" ? "WireGuard" : strings.t("kind.vpn", "VPN")
      })
    }
    if (tailscaleShown) {
      list.push({
        id: "tailscale",
        uuid: "",
        name: "Tailscale",
        kind: "tailscale",
        active: tailscale.active,
        pending: tailscale.busy,
        detail: tailscale.needsLogin ? strings.t("tailscale.needsLogin", "Needs login") : (tailscale.selectedAccountLabel || tailscale.selfName)
      })
    }
    return list
  }
  readonly property int activeCount: Model.activeCount(entries)
  readonly property bool anyActive: activeCount > 0
  readonly property bool showAccounts: tailscaleShown && tailscale.accounts.length > 1
  readonly property bool showAuth: tailscaleShown && tailscale.accountsAccessDenied
  readonly property string errorText: nm.lastError !== "" ? nm.lastError : (tailscaleShown ? tailscale.lastError : "")

  // Keyboard cursor over one flat list of focusable rows.
  readonly property var focusables: {
    var list = []
    for (var i = 0; i < entries.length; i++) list.push({ section: "vpn", index: i })
    if (showAuth) list.push({ section: "auth", index: 0 })
    if (showAccounts) for (var j = 0; j < tailscale.accounts.length; j++) list.push({ section: "account", index: j })
    return list
  }
  property int cursor: 0
  property bool cursorActive: false

  function hasCursor(section, index) {
    if (!cursorActive || focusables.length === 0) return false
    var f = focusables[Math.max(0, Math.min(cursor, focusables.length - 1))]
    return f.section === section && f.index === index
  }

  function setCursor(section, index) {
    for (var i = 0; i < focusables.length; i++) {
      if (focusables[i].section === section && focusables[i].index === index) {
        cursor = i
        cursorActive = true
        return
      }
    }
  }

  function moveCursor(dy) {
    if (focusables.length === 0) return
    cursorActive = true
    cursor = Math.max(0, Math.min(focusables.length - 1, cursor + dy))
  }

  function activateCursor() {
    if (focusables.length === 0) return
    var f = focusables[Math.max(0, Math.min(cursor, focusables.length - 1))]
    if (f.section === "vpn") toggleEntry(entries[f.index])
    else if (f.section === "auth") tailscale.authorizeOperator()
    else if (f.section === "account") tailscale.switchAccount(tailscale.accounts[f.index].id)
  }

  function findEntry(key) {
    var k = String(key || "")
    if (k === "") return null
    for (var i = 0; i < entries.length; i++) if (entries[i].id === k || entries[i].uuid === k) return entries[i]
    for (var j = 0; j < entries.length; j++) if (entries[j].name === k) return entries[j]
    var lower = k.toLowerCase()
    for (var n = 0; n < entries.length; n++) if (entries[n].name.toLowerCase() === lower) return entries[n]
    return null
  }

  function connectEntry(entry) {
    if (!entry || entry.active) return
    if (exclusive) {
      var others = Model.othersToDisconnect(entries, entry.id)
      for (var i = 0; i < others.length; i++) disconnectEntry(others[i])
    }
    if (entry.kind === "tailscale") tailscale.up()
    else nm.up(entry.uuid)
    rememberLast(entry.id)
  }

  function disconnectEntry(entry) {
    if (!entry || !entry.active) return
    if (entry.kind === "tailscale") tailscale.down()
    else nm.down(entry.uuid)
  }

  function toggleEntry(entry) {
    if (!entry || entry.pending) return
    if (entry.active) disconnectEntry(entry)
    else connectEntry(entry)
  }

  function disconnectAll() {
    for (var i = 0; i < entries.length; i++) disconnectEntry(entries[i])
  }

  // Right click on the bar icon: flip the last connection used, or the first.
  function quickToggle() {
    var entry = findEntry(lastConnection) || (entries.length > 0 ? entries[0] : null)
    toggleEntry(entry)
  }

  function rememberLast(id) {
    if (id === lastConnection) return
    if (!root.bar || !root.bar.shell || typeof root.bar.shell.updateEntryInline !== "function") return
    var entry = { id: root.moduleName }
    for (var key in settings) if (key !== "id") entry[key] = settings[key]
    entry.lastConnection = id
    root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function refreshAll() {
    nm.refresh()
    tailscale.refresh(true)
  }

  function statusLine() {
    var names = []
    for (var i = 0; i < entries.length; i++) if (entries[i].active) names.push(entries[i].name)
    return names.length > 0 ? names.join(", ") : "Disconnected"
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    cursor = 0
    refreshAll()
    Qt.callLater(function() { if (panel.loadedContent) panel.loadedContent.forceActiveFocus() })
  }
  onFocusablesChanged: if (cursor >= focusables.length) cursor = Math.max(0, focusables.length - 1)

  Commons.Translations {
    id: strings
    directory: Qt.resolvedUrl("i18n")
  }

  NetworkManagerBackend {
    id: nm
    strings: strings
    refreshIntervalSec: root.refreshIntervalSec
  }

  TailscaleBackend {
    id: tailscale
    strings: strings
    wanted: root.showTailscale
    refreshIntervalSec: root.refreshIntervalSec
  }

  // Answers stay English: they are for scripts and keybindings.
  ShellIpc {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refreshAll(); return "ok" }
    function status(): string { return root.statusLine() }
    function list(): string {
      var out = []
      for (var i = 0; i < root.entries.length; i++) {
        var e = root.entries[i]
        out.push({ id: e.id, name: e.name, kind: e.kind, active: e.active })
      }
      return JSON.stringify(out)
    }
    function up(name: string): string {
      var e = root.findEntry(name)
      if (!e) return "not found"
      root.connectEntry(e)
      return "ok"
    }
    function down(name: string): string {
      var e = root.findEntry(name)
      if (!e) return "not found"
      root.disconnectEntry(e)
      return "ok"
    }
    function toggleVpn(name: string): string {
      var e = root.findEntry(name)
      if (!e) return "not found"
      root.toggleEntry(e)
      return "ok"
    }
    function disconnectAll(): string { root.disconnectAll(); return "ok" }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Text {
        text: root.vpnGlyph
        color: root.anyActive ? root.barForeground : Qt.darker(root.barForeground, 1.55)
        font.family: root.fontFamily
        font.pixelSize: button.iconSize
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.quickToggle()
      else if (buttonCode === Qt.MiddleButton) root.refreshAll()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(520))

    content: PanelKeyCatcher {
      id: keyCatcher
      implicitHeight: column.implicitHeight
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      // No single-key shortcut may disconnect anything: the panel takes
      // keyboard focus when opened, so stray typing must stay harmless.
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refreshAll()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: strings.t("panel.title", "VPN")
            meta: root.anyActive
              ? strings.tn("panel.connected", root.activeCount, "%1 connected").arg(Commons.I18n.formatNumber(root.activeCount))
              : strings.t("panel.disconnected", "Disconnected")
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: root.anyActive ? 1.0 : 0.5
            iconComponent: Component {
              Text {
                text: root.vpnGlyph
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.errorText !== ""
            width: parent.width
            text: root.errorText
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          PanelSeparator { foreground: root.foreground }

          Column {
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: strings.t("panel.connections", "Connections")
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              textFormat: Text.PlainText
              visible: root.entries.length === 0
              width: parent.width
              text: nm.installed || tailscale.installed
                ? strings.t("panel.empty", "No VPN connections found. Import a WireGuard or VPN profile into NetworkManager, or install Tailscale.")
                : strings.t("panel.noBackends", "Neither nmcli nor tailscale is installed.")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            Repeater {
              model: root.entries
              VpnRow {
                required property var modelData
                required property int index
                width: parent.width
                entry: modelData
                rowIndex: index
              }
            }
          }

          AuthRow {
            visible: root.showAuth
            width: parent.width
          }

          PanelSeparator {
            visible: root.showAccounts
            foreground: root.foreground
          }

          Column {
            visible: root.showAccounts
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: strings.t("tailscale.accounts", "Tailscale accounts")
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.showAccounts ? tailscale.accounts : []
              AccountRow {
                required property var modelData
                required property int index
                width: parent.width
                account: modelData
                rowIndex: index
              }
            }
          }
        }
      }
    }
  }

  component VpnRow: CursorSurface {
    id: vpnRow
    property var entry: null
    property int rowIndex: 0

    hasCursor: root.hasCursor("vpn", rowIndex)
    current: entry && entry.active
    foreground: root.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: vpnInner.implicitHeight + Style.spacing.xl

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.setCursor("vpn", vpnRow.rowIndex)
      onClicked: root.toggleEntry(vpnRow.entry)
    }

    RowLayout {
      id: vpnInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(10)

      Item {
        Layout.preferredWidth: Style.space(22)
        Layout.preferredHeight: Style.space(22)
        Layout.alignment: Qt.AlignVCenter
        opacity: vpnRow.entry && vpnRow.entry.active ? 1.0 : 0.5

        TailscaleIcon {
          visible: vpnRow.entry && vpnRow.entry.kind === "tailscale"
          anchors.centerIn: parent
          iconSize: Style.font.heading
          color: root.foreground
          crossed: false
          warning: tailscale.needsLogin
        }

        Text {
          visible: !(vpnRow.entry && vpnRow.entry.kind === "tailscale")
          anchors.centerIn: parent
          text: root.vpnGlyph
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading
        }
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: vpnRow.entry ? vpnRow.entry.name : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: vpnRow.entry && vpnRow.entry.active
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          visible: text !== ""
          textFormat: Text.PlainText
          text: vpnRow.entry ? String(vpnRow.entry.detail || "") : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      ToggleSwitch {
        Layout.alignment: Qt.AlignVCenter
        checked: vpnRow.entry ? vpnRow.entry.active : false
        busy: vpnRow.entry ? vpnRow.entry.pending : false
        cursorRing: false
        foreground: root.foreground
        onHovered: function(on) { if (on) root.setCursor("vpn", vpnRow.rowIndex) }
        onToggled: root.toggleEntry(vpnRow.entry)
      }
    }
  }

  component AccountRow: CursorSurface {
    id: accountRow
    property var account: null
    property int rowIndex: 0
    readonly property bool selectedAccount: account && account.selected === true
    readonly property bool switching: account && tailscale.switchingAccountId === String(account.id || "")

    hasCursor: root.hasCursor("account", rowIndex)
    current: selectedAccount
    foreground: root.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: accountText.implicitHeight + Style.spacing.xl
    opacity: switching ? 0.6 : 1.0

    Text {
      id: accountText
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(12)
      textFormat: Text.PlainText
      text: accountRow.account ? Model.accountLabel(accountRow.account, strings.t) : ""
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: accountRow.selectedAccount
      elide: Text.ElideRight
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.setCursor("account", accountRow.rowIndex)
      onClicked: if (accountRow.account) tailscale.switchAccount(accountRow.account.id)
    }
  }

  component AuthRow: CursorSurface {
    id: authRow
    hasCursor: root.hasCursor("auth", 0)
    foreground: root.foreground
    implicitHeight: authColumn.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.setCursor("auth", 0)
      onClicked: tailscale.authorizeOperator()
    }

    ColumnLayout {
      id: authColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(12)
      spacing: Style.space(1)

      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        text: strings.t("tailscale.authorizeOperator", "Allow managing Tailscale")
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        text: strings.t("tailscale.authorizeHelp", "Makes your user the Tailscale operator (asks for your password once).")
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }
  }
}
