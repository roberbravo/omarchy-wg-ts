"use strict"

const test = require("node:test")
const assert = require("node:assert/strict")
const Model = require("../Model.js")

test("splitTerse splits nmcli terse fields and unescapes colons and backslashes", () => {
  assert.deepEqual(Model.splitTerse("a:b:c"), ["a", "b", "c"])
  assert.deepEqual(Model.splitTerse("office\\:vpn:id:wireguard"), ["office:vpn", "id", "wireguard"])
  assert.deepEqual(Model.splitTerse("back\\\\slash:x"), ["back\\slash", "x"])
  assert.deepEqual(Model.splitTerse("a::c"), ["a", "", "c"])
})

test("parseNmConnections keeps only VPN-like connections", () => {
  const raw = [
    "Home Wi-Fi:11111111-1111-1111-1111-111111111111:802-11-wireless:wlan0:yes:activated",
    "office:22222222-2222-2222-2222-222222222222:wireguard:office:yes:activated",
    "lab\\:eu:33333333-3333-3333-3333-333333333333:vpn:::",
    "docker0:44444444-4444-4444-4444-444444444444:bridge:docker0:yes:activated",
    ""
  ].join("\n")
  const list = Model.parseNmConnections(raw)
  assert.deepEqual(list.map(c => c.name), ["lab:eu", "office"])
  const office = list.find(c => c.name === "office")
  assert.equal(office.id, "nm:22222222-2222-2222-2222-222222222222")
  assert.equal(office.uuid, "22222222-2222-2222-2222-222222222222")
  assert.equal(office.kind, "wireguard")
  assert.equal(office.active, true)
  assert.equal(office.pending, false)
  const lab = list.find(c => c.name === "lab:eu")
  assert.equal(lab.kind, "vpn")
  assert.equal(lab.active, false)
})

test("parseNmConnections marks transitional states as pending and ignores garbage", () => {
  const raw = "w:55555555-5555-5555-5555-555555555555:wireguard:w:yes:activating\nnot a line"
  const list = Model.parseNmConnections(raw)
  assert.equal(list.length, 1)
  assert.equal(list[0].active, false)
  assert.equal(list[0].pending, true)
  assert.deepEqual(Model.parseNmConnections(""), [])
  assert.deepEqual(Model.parseNmConnections(null), [])
})

test("parseNmConnections lists one entry per connection even if nmcli repeats it", () => {
  const line = "w:66666666-6666-6666-6666-666666666666:wireguard:w:yes:activated"
  assert.equal(Model.parseNmConnections(line + "\n" + line).length, 1)
})

test("othersToDisconnect returns every other active entry for exclusive mode", () => {
  const entries = [
    { id: "nm:a", active: true },
    { id: "nm:b", active: false },
    { id: "tailscale", active: true }
  ]
  assert.deepEqual(Model.othersToDisconnect(entries, "nm:b").map(e => e.id), ["nm:a", "tailscale"])
  assert.deepEqual(Model.othersToDisconnect(entries, "nm:a").map(e => e.id), ["tailscale"])
  assert.deepEqual(Model.othersToDisconnect([], "x"), [])
})

test("activeCount counts active entries", () => {
  assert.equal(Model.activeCount([{ active: true }, { active: false }, { active: true }]), 2)
  assert.equal(Model.activeCount(null), 0)
})

test("parseStatus reads Tailscale backend state without peers", () => {
  const running = Model.parseStatus(JSON.stringify({
    BackendState: "Running",
    Self: { HostName: "laptop", DNSName: "laptop.example.ts.net.", TailscaleIPs: ["100.64.0.1", "fd7a:115c:a1e0::1"] }
  }))
  assert.equal(running.ok, true)
  assert.equal(running.running, true)
  assert.equal(running.needsLogin, false)
  assert.equal(running.selfName, "laptop")
  assert.equal(running.selfIp, "100.64.0.1")

  const login = Model.parseStatus(JSON.stringify({ BackendState: "NeedsLogin", AuthURL: "https://login.example/a" }))
  assert.equal(login.needsLogin, true)
  assert.equal(login.authUrl, "https://login.example/a")

  assert.equal(Model.parseStatus("").unavailable, true)
  assert.equal(Model.parseStatus("{nope").ok, false)
})

test("parseAccounts finds the selected Tailscale account", () => {
  const parsed = Model.parseAccounts(JSON.stringify([
    { id: "a1", nickname: "work", selected: false },
    { id: "a2", tailnet: "home.example", selected: true }
  ]))
  assert.equal(parsed.accounts.length, 2)
  assert.equal(parsed.selectedAccountId, "a2")
  assert.equal(parsed.selectedAccountLabel, "home.example")
  assert.deepEqual(Model.parseAccounts("not json").accounts, [])
})

test("loginPlan opens a pending auth URL instead of running tailscale up", () => {
  assert.deepEqual(Model.loginPlan(true, "https://login.example/a"), { authUrl: "https://login.example/a", command: [] })
  assert.deepEqual(Model.loginPlan(false, "https://login.example/a"), { authUrl: "", command: ["tailscale", "up"] })
  assert.deepEqual(Model.loginPlan(true, "javascript:alert(1)"), { authUrl: "", command: ["tailscale", "up"] })
})

test("elide collapses whitespace and bounds length", () => {
  assert.equal(Model.elide("  a \n b  "), "a b")
  const long = Model.elide("x".repeat(500))
  assert.equal(long.length, 140)
  assert.ok(long.endsWith("…"))
})
