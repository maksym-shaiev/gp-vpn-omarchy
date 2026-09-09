#!/usr/bin/env bash
# uninstall.sh — gp-vpn-omarchy uninstaller
#
# Removes the GlobalProtect Omarchy bar widget and its configuration.
#
# What this script removes:
#   1. Plugin files from ~/.config/omarchy/plugins/gp-vpn/
#   2. Pinned connection config from ~/.config/gp-vpn-omarchy/
#   3. Bar layout entry from ~/.config/omarchy/shell.json
#   4. Plugins array entry from ~/.config/omarchy/shell.json
#   5. Global hotkey from ~/.config/hypr/bindings.lua
#
# What this script does NOT remove:
#   - ~/.config/smc-gp-vpn/config (belongs to smc-gp-vpn)
#   - ~/.local/bin/smc-vpn-refresh, gpclient-smc, gpauth-smc (belongs to smc-gp-vpn)
#   - NM VPN profile (out of scope — see smc-gp-vpn README for manual cleanup)
#
# Usage:
#   bash uninstall.sh

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${GREEN}[+]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[!]${RESET} $*"; }
error()   { echo -e "${RED}[✗]${RESET} $*" >&2; }
die()     { error "$*"; exit 1; }
section() { echo -e "\n${BOLD}── $* ──${RESET}"; }

# ── 0. detect Omarchy ────────────────────────────────────────────────────────
if ! command -v omarchy-shell &>/dev/null; then
    die "This uninstaller is for Omarchy only (omarchy-shell not found on PATH)."
fi

# ── 1. confirmation ──────────────────────────────────────────────────────────
section "Uninstall GlobalProtect VPN widget"

read -rp "  Are you sure you want to uninstall the gp-vpn widget? [y/N]: " confirm
confirm="${confirm:-N}"
if [[ ! "$confirm" =~ ^[Yy] ]]; then
    info "Aborted"
    exit 0
fi

# ── 2. remove plugin files ───────────────────────────────────────────────────
section "Removing plugin files"

PLUGIN_DIR="$HOME/.config/omarchy/plugins/gp-vpn"
if [[ -d "$PLUGIN_DIR" ]]; then
    rm -rf "$PLUGIN_DIR"
    info "Removed $PLUGIN_DIR"
else
    warn "$PLUGIN_DIR does not exist — skipping"
fi

# ── 3. remove pinned connection config ───────────────────────────────────────
section "Removing pinned connection config"

WIDGET_CONFIG_DIR="$HOME/.config/gp-vpn-omarchy"
if [[ -d "$WIDGET_CONFIG_DIR" ]]; then
    rm -rf "$WIDGET_CONFIG_DIR"
    info "Removed $WIDGET_CONFIG_DIR"
else
    warn "$WIDGET_CONFIG_DIR does not exist — skipping"
fi

# ── 4. edit shell.json ───────────────────────────────────────────────────────
section "Editing shell.json"

SHELL_JSON="$HOME/.config/omarchy/shell.json"
if [[ -f "$SHELL_JSON" ]]; then
    # Remove from plugins array
    if jq -e '.plugins[] | select(. == "gp-vpn")' "$SHELL_JSON" >/dev/null 2>&1; then
        tmp=$(mktemp)
        jq 'del(.plugins[] | select(. == "gp-vpn"))' "$SHELL_JSON" > "$tmp" && mv "$tmp" "$SHELL_JSON"
        info "Removed gp-vpn from plugins array"
    else
        warn "gp-vpn not found in plugins array — skipping"
    fi

    # Remove from bar.layout (any section)
    if jq -e '.bar.layout | to_entries[] | select(.value | any(.id == "gp-vpn"))' "$SHELL_JSON" >/dev/null 2>&1; then
        tmp=$(mktemp)
        jq '(.bar.layout | to_entries[] | select(.value | any(.id == "gp-vpn"))) as $match |
            if $match then .bar.layout[$match.key] |= map(select(.id != "gp-vpn")) else . end' "$SHELL_JSON" > "$tmp" && mv "$tmp" "$SHELL_JSON"
        info "Removed gp-vpn from bar layout"
    else
        warn "gp-vpn not found in bar layout — skipping"
    fi
else
    warn "$SHELL_JSON does not exist — skipping"
fi

# ── 5. edit bindings.lua ─────────────────────────────────────────────────────
section "Editing bindings.lua"

BINDINGS_LUA="$HOME/.config/hypr/bindings.lua"
if [[ -f "$BINDINGS_LUA" ]]; then
    if grep -q "shell toggle gp-vpn" "$BINDINGS_LUA"; then
        tmp=$(mktemp)
        sed -i '/^# Toggle GlobalProtect VPN popup by plugin id$/,/^o\.bind("SUPER + ALT + V".*gp-vpn")$/d' "$BINDINGS_LUA" > "$tmp" && mv "$tmp" "$BINDINGS_LUA"
        info "Removed gp-vpn hotkey from bindings.lua"
    else
        warn "gp-vpn hotkey not found in bindings.lua — skipping"
    fi
else
    warn "$BINDINGS_LUA does not exist — skipping"
fi

# ── 6. reload ────────────────────────────────────────────────────────────────
section "Reloading"

if command -v omarchy-shell &>/dev/null; then
    omarchy-shell shell rescanPlugins >/dev/null
    info "Rescanned plugins"
fi

if command -v hyprctl &>/dev/null; then
    hyprctl reload
    info "Reloaded Hyprland"
fi

# ── 7. done ──────────────────────────────────────────────────────────────────
section "Uninstall complete"

echo -e ""
echo -e "${BOLD}The gp-vpn widget has been removed.${RESET}"
echo -e ""
echo -e "To reinstall later:"
echo -e ""
echo -e "    ${GREEN}omarchy plugin add https://github.com/maksym-shaiev/gp-vpn-omarchy.git --enable${RESET}"
echo -e ""
