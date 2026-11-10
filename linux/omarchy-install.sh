#!/usr/bin/env bash
# Installs Limitty on Omarchy (Arch Linux + Hyprland + Waybar).
#
#   ./linux/omarchy-install.sh            # latest build from GitHub (needs the `gh` CLI, logged in)
#   ./linux/omarchy-install.sh --source   # build it here instead (needs nodejs + npm)
#
# What it does: installs the Limitty package (pacman), adds the Hyprland window
# rules + autostart (~/.config/hypr/limitty.conf or .lua), copies the Waybar
# module snippet, and starts Limitty. Nothing is removed; a backup of each file
# it edits is kept as *.limitty-backup.
set -euo pipefail

REPO="lavickasebastian16/Limitty"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
HYPR="${XDG_CONFIG_HOME:-$HOME/.config}/hypr"
WAYBAR="${XDG_CONFIG_HOME:-$HOME/.config}/waybar"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }

# 1. The app
if [[ "${1:-}" == "--source" ]]; then
  say "Building Limitty from source"
  command -v npm >/dev/null || sudo pacman -S --needed --noconfirm nodejs npm
  (cd "$ROOT" && npm ci && npm run dist:linux -- pacman)
  PKG="$(ls -t "$ROOT"/dist/*.pacman | head -1)"
else
  say "Downloading the latest Limitty build"
  if ! command -v gh >/dev/null; then
    echo "The repo is private, so downloads need the GitHub CLI:"
    echo "  sudo pacman -S github-cli && gh auth login"
    echo "or build locally with:  $0 --source"
    exit 1
  fi
  gh release download latest -R "$REPO" -p 'Limitty-*.pacman' -D "$TMP" --clobber
  PKG="$(ls "$TMP"/*.pacman | head -1)"
fi
say "Installing $(basename "$PKG")"
sudo pacman -U --noconfirm "$PKG"

# 2. Hyprland window rules + autostart
mkdir -p "$HYPR"
if [[ -f "$HYPR/hyprland.lua" ]]; then
  cp "$HERE/hypr/limitty.lua" "$HYPR/limitty.lua"
  if ! grep -q 'require("limitty")' "$HYPR/hyprland.lua"; then
    cp "$HYPR/hyprland.lua" "$HYPR/hyprland.lua.limitty-backup"
    printf '\n-- Limitty widget rules + autostart\nrequire("limitty")\n' >> "$HYPR/hyprland.lua"
  fi
  say "Added Hyprland rules (hyprland.lua)"
else
  cp "$HERE/hypr/limitty.conf" "$HYPR/limitty.conf"
  touch "$HYPR/hyprland.conf"
  if ! grep -q 'limitty.conf' "$HYPR/hyprland.conf"; then
    cp "$HYPR/hyprland.conf" "$HYPR/hyprland.conf.limitty-backup"
    printf '\n# Limitty widget rules + autostart\nsource = ~/.config/hypr/limitty.conf\n' >> "$HYPR/hyprland.conf"
  fi
  say "Added Hyprland rules (hyprland.conf)"
fi
hyprctl reload >/dev/null 2>&1 || true

# 3. Waybar module (added by you, so your bar layout stays yours)
mkdir -p "$WAYBAR"
cp "$HERE/waybar/limitty.jsonc" "$WAYBAR/limitty-module.jsonc"
cp "$HERE/waybar/limitty.css" "$WAYBAR/limitty-module.css"
say "Waybar: paste $WAYBAR/limitty-module.jsonc into config.jsonc, add \"custom/limitty\" to modules-right,"
say "        append limitty-module.css to style.css, then run: omarchy restart waybar"

# 4. Start it
pgrep -x limitty >/dev/null || (setsid limitty >/dev/null 2>&1 &)
say "Done. Limitty $(limitty --waybar >/dev/null 2>&1 && echo is running || echo installed)."
say "Agents → iPhone: Limitty menu (⋯) → Connect agents to iPhone…   Company: limitty --company"
