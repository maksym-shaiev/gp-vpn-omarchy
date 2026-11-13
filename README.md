# gp-vpn-omarchy

GlobalProtect (openconnect-based) VPN bar widget and popup panel for [Omarchy](https://omarchy.ai).

Requires [smc-gp-vpn](https://github.com/maksym-shaiev/smc-gp-vpn) (or any openconnect-based GlobalProtect portal) to be installed first — the widget reads `PORTAL`, `CONN_NAME`, and `BROWSER` from `~/.config/smc-gp-vpn/config`, which `smc-gp-vpn/install.sh` writes.

The widget is **vendor-agnostic**: it works with any GlobalProtect portal, not just SMC/Stagwell.

## What it shows

- **Bar icon** — locked when connected, unlocked when disconnected, spinning indicator during actions.
- **Popup** — hero with toggle switch, endpoint selector (when multiple endpoints are configured), connection details (status, portal, device, tunnel IP, gateway, DNS, connected since), public IP / country / city (fetched from ipinfo.io), and Refresh cookie / Reconnect buttons.

## Endpoints

When `~/.config/smc-gp-vpn/config` defines multiple endpoints (`ENDPOINTS` /
`ENDPOINT_<ID>_*` keys — written by recent `smc-gp-vpn` installers), the popup
shows an **endpoint selector**: one pill per endpoint (e.g. `UK`, `US`). The
selected pill is filled; clicking another endpoint switches tunnels (brings
the current connection down, brings the new one up). Each endpoint keeps its
own NM profile and portal cookie, so switching does not require a re-login.

- Popup hotkey `e` cycles to the next endpoint.
- The selection is persisted to `~/.config/gp-vpn-omarchy/widget.conf`
  (`ENDPOINT=<id>`); `gp-vpn-status --select <id>` does the same from a terminal.
- With a legacy single-endpoint config the widget behaves exactly as before.

## Hotkeys

| Scope | Key | Action |
|-------|-----|--------|
| Global | `Super + Alt + V` | Open/close popup (auto-added by `install.sh`) |
| Popup | `t` / `T` | Toggle VPN |
| Popup | `e` / `E` | Cycle endpoint |
| Popup | `r` | Refresh cookie (no reconnect) |
| Popup | `R` | Reconnect (refresh + connect) |
| Popup | `Esc` | Close popup |

## Installation

### Option A — from the smc-gp-vpn installer (Omarchy only)

If you're on Omarchy, `smc-gp-vpn/install.sh` offers to install the widget automatically:

```bash
git clone https://github.com/maksym-shaiev/smc-gp-vpn.git
cd smc-gp-vpn
bash install.sh
```

### Option B — standalone git clone

```bash
git clone https://github.com/maksym-shaiev/gp-vpn-omarchy.git
cd gp-vpn-omarchy
bash install.sh
```

### Option C — omarchy plugin add

```bash
omarchy plugin add https://github.com/maksym-shaiev/gp-vpn-omarchy.git --enable
```

## Configuration

The widget reads `CONN_NAME` and `PORTAL` from `~/.config/smc-gp-vpn/config` (written by `smc-gp-vpn/install.sh`). Multi-endpoint configs (`ENDPOINTS` / `ENDPOINT_<ID>_*`) are supported — see [Endpoints](#endpoints).

If that file is missing, the widget auto-detects the active VPN connection and shows a **Confirm / Skip** banner in the popup. **Confirm** persists the connection name to `~/.config/gp-vpn-omarchy/widget.conf` so future runs use it.

## Files installed

| Path | Purpose |
|------|---------|
| `~/.config/omarchy/plugins/gp-vpn/manifest.json` | Plugin manifest |
| `~/.config/omarchy/plugins/gp-vpn/Panel.qml` | Widget QML |
| `~/.config/omarchy/plugins/gp-vpn/gp-vpn-status` | Status helper (Python) |
| `~/.config/smc-gp-vpn/config` | Config (created by install.sh if missing) |
| `~/.config/gp-vpn-omarchy/widget.conf` | Pinned connection (created by Confirm) |

## Uninstall

### Option A — using the uninstall script

```bash
bash uninstall.sh
```

Or from a fresh clone:

```bash
bash <(curl -sL https://raw.githubusercontent.com/maksym-shaiev/gp-vpn-omarchy/main/uninstall.sh)
```

### Option B — using omarchy plugin remove

```bash
omarchy plugin remove gp-vpn
```

Both options remove:
- Plugin files from `~/.config/omarchy/plugins/gp-vpn/`
- Pinned connection config from `~/.config/gp-vpn-omarchy/`
- Bar layout entry from `~/.config/omarchy/shell.json`
- Global hotkey from `~/.config/hypr/bindings.lua`

**Note:** This does NOT remove `~/.config/smc-gp-vpn/config` or the VPN binaries — those belong to [smc-gp-vpn](https://github.com/maksym-shaiev/smc-gp-vpn).

## License

Same as [smc-gp-vpn](https://github.com/maksym-shaiev/smc-gp-vpn) — no LICENSE file.
