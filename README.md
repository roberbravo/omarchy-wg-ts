# VPN switcher for Omarchy

An [Omarchy](https://omarchy.org) bar widget that lists every VPN on your machine and turns each one on or off with a switch:

- **WireGuard** and **VPN-plugin connections** (OpenVPN, etc.) managed by NetworkManager, through `nmcli`.
- **Tailscale**, through the `tailscale` CLI, including switching between Tailscale accounts.

New NetworkManager VPN profiles show up on their own; there is nothing to configure per connection.

## Install

```sh
omarchy plugin add https://github.com/roberbravo/omarchy-vpn.git --enable
```

Move it on the bar if you like:

```sh
omarchy bar move roberbravo.vpn --section right
```

## Usage

| Action | Result |
| --- | --- |
| Left click | Open the panel |
| Right click | Toggle the last VPN you turned on (or the first one listed) |
| Middle click | Refresh |

Inside the panel: `j`/`k` or arrows move, `enter`/`space` toggles the selected row, `r` refreshes, `esc` closes. No single key ever disconnects a VPN by itself.

## Settings

Set them from the bar widget settings, or in the plugin's entry in `~/.config/omarchy/shell.json`:

| Key | Default | Meaning |
| --- | --- | --- |
| `exclusive` | `false` | One VPN at a time: turning one on turns the others off. |
| `showTailscale` | `true` | List Tailscale when the `tailscale` CLI is installed. |
| `refreshIntervalSec` | `30` | Fallback poll interval. NetworkManager changes are picked up instantly through `nmcli monitor`. |

## Scripting

The widget answers on the `roberbravo.vpn` IPC target. `<name>` is a connection name, NetworkManager UUID, or `tailscale`:

```sh
omarchy-shell roberbravo.vpn status          # names of active VPNs, or "Disconnected"
omarchy-shell roberbravo.vpn list            # JSON: id, name, kind, active
omarchy-shell roberbravo.vpn up <name>
omarchy-shell roberbravo.vpn down <name>
omarchy-shell roberbravo.vpn toggleVpn <name>
omarchy-shell roberbravo.vpn disconnectAll
```

Example Hyprland binding in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + ALT + V", "Toggle office VPN", "omarchy-shell roberbravo.vpn toggleVpn office")
```

## Requirements and permissions

- **NetworkManager** (`nmcli`). Import a WireGuard config with `nmcli connection import type wireguard file /path/to/wg0.conf`. Activating connections is authorized by polkit; a normal desktop session user needs no `sudo`.
- **Tailscale** (optional). `tailscale up`/`down`/`switch` require your user to be the daemon operator. When it is not, the panel offers a one-time **Allow managing Tailscale** row that runs `pkexec tailscale set --operator=$USER`.

The plugin never reads, stores, or prints keys or configuration files. It only runs `nmcli` and `tailscale` commands and shows connection names.

## Update and remove

```sh
omarchy plugin update roberbravo.vpn
omarchy plugin remove roberbravo.vpn
```

## Troubleshooting

- **A VPN is missing.** Only NetworkManager connections of type `wireguard` or `vpn` are listed. Check with `nmcli -t -f NAME,TYPE connection show`. Profiles started with `wg-quick` are not managed by NetworkManager; import them instead.
- **Tailscale says access denied.** Use the **Allow managing Tailscale** row, or run `sudo tailscale set --operator=$USER`.
- **Changes do not show up.** Reload plugins with `omarchy-shell shell rescanPlugins`. This is required after editing a symlinked checkout.
- **Errors.** The shell log is at `/run/user/$UID/quickshell/by-id/*/log.log`; search it for `roberbravo.vpn`.

## Development

```sh
node --test tests/*.test.js
omarchy plugin validate .
```

To try a checkout live, link it into your plugins folder:

```sh
ln -s "$PWD" ~/.config/omarchy/plugins/roberbravo.vpn
omarchy plugin enable roberbravo.vpn
```

To release a version, bump `version` in `manifest.json`, run the tests and `omarchy plugin validate .`, then tag and push:

```sh
git tag v0.1.0 && git push origin main --tags
```

## License

MIT. The Tailscale backend and icon are adapted from Omarchy's built-in Tailscale widget (MIT, Copyright (c) David Heinemeier Hansson). See [LICENSE](LICENSE).
