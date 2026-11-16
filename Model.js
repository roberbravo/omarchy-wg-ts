// Pure helpers shared by the backends and the panel. No QML here, so the
// file loads both as a QML JavaScript resource and as a Node module for tests.
//
// The Tailscale helpers are adapted from Omarchy's built-in Tailscale widget
// (MIT, Copyright (c) David Heinemeier Hansson).

var VPN_TYPES = { "wireguard": "wireguard", "vpn": "vpn" }

function translator(tr) {
  return typeof tr === "function" ? tr : function(key, english) { return english }
}

function elide(text) {
  var value = String(text || "").replace(/\s+/g, " ").trim()
  return value.length > 140 ? value.substring(0, 139) + "…" : value
}

// ---------------------------------------------------------------- NetworkManager

// Split one line of `nmcli -t` output. Terse mode escapes ':' and '\' inside
// values with a backslash.
function splitTerse(line) {
  var fields = []
  var current = ""
  var text = String(line || "")
  for (var i = 0; i < text.length; i++) {
    var ch = text.charAt(i)
    if (ch === "\\" && i + 1 < text.length) {
      current += text.charAt(i + 1)
      i++
    } else if (ch === ":") {
      fields.push(current)
      current = ""
    } else {
      current += ch
    }
  }
  fields.push(current)
  return fields
}

// Parse `nmcli -t -f NAME,UUID,TYPE,DEVICE,ACTIVE,STATE connection show`.
function parseNmConnections(raw) {
  var result = []
  var seen = {}
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].trim() === "") continue
    var f = splitTerse(lines[i])
    if (f.length < 6) continue
    var kind = VPN_TYPES[f[2]]
    var uuid = f[1]
    if (!kind || uuid === "" || seen[uuid]) continue
    seen[uuid] = true
    var state = f[5]
    result.push({
      id: "nm:" + uuid,
      uuid: uuid,
      name: f[0],
      kind: kind,
      device: f[3],
      active: state === "activated",
      pending: state === "activating" || state === "deactivating"
    })
  }
  result.sort(function(a, b) { return a.name.localeCompare(b.name) })
  return result
}

// ------------------------------------------------------------------- Switching

function othersToDisconnect(entries, targetId) {
  var result = []
  if (!entries) return result
  for (var i = 0; i < entries.length; i++) {
    if (entries[i].active === true && entries[i].id !== targetId) result.push(entries[i])
  }
  return result
}

function activeCount(entries) {
  var n = 0
  if (!entries) return n
  for (var i = 0; i < entries.length; i++) if (entries[i].active === true) n++
  return n
}

// -------------------------------------------------------------------- Tailscale

function filterIPv4(ips) {
  var result = []
  if (!ips || typeof ips.length !== "number") return result
  for (var i = 0; i < ips.length; i++) {
    var ip = String(ips[i] || "")
    if (/^100\./.test(ip)) result.push(ip)
  }
  return result
}

function cleanDnsName(name) {
  var value = String(name || "")
  return value.charAt(value.length - 1) === "." ? value.slice(0, -1) : value
}

function displayHostName(hostName, dnsName) {
  var host = String(hostName || "")
  if (host !== "" && host.toLowerCase() !== "localhost") return host
  var clean = cleanDnsName(dnsName)
  return (clean.split(".")[0] || clean) || host
}

function accountLabel(account, tr) {
  var t = translator(tr)
  if (!account) return t("tailscale.unknownAccount", "Unknown account")
  if (account.nickname) return String(account.nickname)
  if (account.tailnet) return String(account.tailnet)
  if (account.account) return String(account.account)
  return String(account.id || t("tailscale.unknownAccount", "Unknown account"))
}

function loginPlan(needsLogin, authUrl) {
  var url = String(authUrl || "").trim()
  if (needsLogin === true && /^https?:\/\//.test(url)) return { authUrl: url, command: [] }
  return { authUrl: "", command: ["tailscale", "up"] }
}

// Parse `tailscale status --json --peers=false`.
function parseStatus(raw) {
  var text = String(raw || "").trim()
  if (text === "") return { ok: true, unavailable: true }
  try {
    var data = JSON.parse(text)
    var backendState = String(data.BackendState || "Unknown")
    var self = data.Self || {}
    var selfIps = filterIPv4(self.TailscaleIPs || data.TailscaleIPs || [])
    return {
      ok: true,
      unavailable: false,
      backendState: backendState,
      running: backendState === "Running",
      needsLogin: backendState === "NeedsLogin",
      authUrl: String(data.AuthURL || ""),
      selfName: displayHostName(self.HostName, self.DNSName),
      selfIp: selfIps.length > 0 ? selfIps[0] : ""
    }
  } catch (e) {
    return { ok: false, unavailable: true }
  }
}

// Parse `tailscale switch --list --json`.
function parseAccounts(raw, tr) {
  var empty = { accounts: [], selectedAccountId: "", selectedAccountLabel: "" }
  var text = String(raw || "").trim()
  if (text === "") return empty
  try {
    var parsed = JSON.parse(text)
    var next = []
    var selected = null
    if (parsed && typeof parsed.length === "number") {
      for (var i = 0; i < parsed.length; i++) {
        var a = parsed[i] || {}
        var account = {
          id: String(a.id || a.ID || ""),
          nickname: String(a.nickname || a.Nickname || a.name || a.Name || ""),
          tailnet: String(a.tailnet || a.Tailnet || ""),
          account: String(a.account || a.Account || a.loginName || a.LoginName || a.user || a.User || ""),
          selected: a.selected === true || a.Selected === true
        }
        next.push(account)
        if (account.selected) selected = account
      }
    }
    return {
      accounts: next,
      selectedAccountId: selected ? selected.id : "",
      selectedAccountLabel: selected ? accountLabel(selected, tr) : ""
    }
  } catch (e) {
    return empty
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    elide: elide,
    splitTerse: splitTerse,
    parseNmConnections: parseNmConnections,
    othersToDisconnect: othersToDisconnect,
    activeCount: activeCount,
    filterIPv4: filterIPv4,
    cleanDnsName: cleanDnsName,
    displayHostName: displayHostName,
    accountLabel: accountLabel,
    loginPlan: loginPlan,
    parseStatus: parseStatus,
    parseAccounts: parseAccounts
  }
}
