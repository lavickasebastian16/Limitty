#!/usr/bin/env bash
# Installs Limitty on Omarchy (Arch Linux + Hyprland + Waybar).
#
#   ./linux/omarchy-install.sh            # latest build from GitHub
#   ./linux/omarchy-install.sh --source   # build it here instead (needs nodejs + npm)
#
# Or without cloning the repo:
#   curl -fsSL https://raw.githubusercontent.com/lavickasebastian16/Limitty/HEAD/linux/omarchy-install.sh | bash
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

# Run with `curl … | bash`: there's no repo folder, so fetch the config files.
if [[ ! -f "$HERE/hypr/limitty.conf" ]]; then
  if [[ "${1:-}" == "--source" ]]; then
    say "Getting the Limitty source"
    command -v git >/dev/null || sudo pacman -S --needed --noconfirm git
    git clone --depth 1 "https://github.com/$REPO.git" "$TMP/Limitty"
    ROOT="$TMP/Limitty"; HERE="$ROOT/linux"
  else
    HERE="$TMP/linux"
    for f in hypr/limitty.conf hypr/limitty.lua waybar/limitty.jsonc waybar/limitty.css; do
      mkdir -p "$HERE/$(dirname "$f")"
      curl -fsSL -o "$HERE/$f" "https://raw.githubusercontent.com/$REPO/HEAD/linux/$f"
    done
  fi
fi

# 1. The app
if [[ "${1:-}" == "--source" ]]; then
  say "Building Limitty from source"
  command -v npm >/dev/null || sudo pacman -S --needed --noconfirm nodejs npm
  (cd "$ROOT" && npm ci && npm run dist:linux -- pacman)
  PKG="$(ls -t "$ROOT"/dist/*.pacman | head -1)"
else
  say "Downloading the latest Limitty build"
  if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
    gh release download latest -R "$REPO" -p 'Limitty-*.pacman' -D "$TMP" --clobber
  else
    URL="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/tags/latest" \
      | grep -o '"browser_download_url": *"[^"]*\.pacman"' | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')"
    [[ -n "$URL" ]] || { echo "Couldn't find the Limitty package on GitHub. Try: $0 --source"; exit 1; }
    curl -fL --progress-bar -o "$TMP/$(basename "$URL")" "$URL"
  fi
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

# 4. Start it (the first time, it opens the setup window)
pgrep -x limitty >/dev/null || (setsid limitty >/dev/null 2>&1 &)
say "Done. Limitty is starting."
say "In the window that opens, press  Install agents  and sign in when asked. That's all."
say "Later: type tasks in the widget (or bind  limitty --prompt), Settings: limitty --settings"
