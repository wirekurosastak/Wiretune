#!/bin/sh
# Installs this Wiretune build: the player, its menu entry and its icon. For the current user by default (into
# ~/.local); for everyone with  sudo PREFIX=/usr/local ./install.sh . The same command with --uninstall removes it.
#
# The desktop file is named after the application ID (com.wiretune.player), which is how Wayland desktops match the
# window to its icon.
set -eu

prefix=${PREFIX:-"$HOME/.local"}
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
app="$prefix/lib/wiretune"
desktop="$prefix/share/applications/com.wiretune.player.desktop"
icon="$prefix/share/icons/hicolor/256x256/apps/com.wiretune.player.png"

refresh() {
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q "$prefix/share/applications" || true
  command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -t "$prefix/share/icons/hicolor" || true
}

if [ "${1:-}" = "--uninstall" ]; then
  rm -rf "$app"
  rm -f "$prefix/bin/wiretune" "$desktop" "$icon"
  refresh
  echo "Wiretune removed from $prefix."
  exit 0
fi
if [ $# -gt 0 ]; then
  echo "Usage: [PREFIX=<folder>] $0 [--uninstall]" >&2
  exit 64
fi

if [ "$here" != "$app" ]; then
  rm -rf "$app"
  mkdir -p "$app"
  cp -R "$here/wiretune" "$here/lib" "$here/data" "$app/"
fi
mkdir -p "$prefix/bin" "$(dirname "$desktop")" "$(dirname "$icon")"
ln -sf "$app/wiretune" "$prefix/bin/wiretune"
sed "s|@EXEC@|$app/wiretune|" "$here/com.wiretune.player.desktop" > "$desktop"
cp "$here/com.wiretune.player.png" "$icon"
refresh

echo "Wiretune installed in $app."
if ! { ldconfig -p 2>/dev/null || /sbin/ldconfig -p 2>/dev/null; } | grep -q 'libmpv\.so'; then
  echo "It needs libmpv, which this system lacks: mpv-libs on Fedora, libmpv2 on Debian and Ubuntu, mpv on Arch."
fi
