#!/bin/bash
# uninstall.sh — kde-cursor-sync uninstaller
set -euo pipefail

BIN_DIR="${HOME}/.local/bin"
SYSTEMD_DIR="${HOME}/.config/systemd/user"
PROFILE="${HOME}/.profile"

echo "=== kde-cursor-sync uninstaller ==="
echo ""

# --- 1. Stop and remove systemd units ----------------------------------------
echo "[1/4] Removing systemd units..."
systemctl --user disable --now sync-cursor.path 2>/dev/null || true
rm -f "${SYSTEMD_DIR}/sync-cursor.path" "${SYSTEMD_DIR}/sync-cursor.service"
systemctl --user daemon-reload
echo "  -> Done."

# --- 2. Remove script ---------------------------------------------------------
echo "[2/4] Removing sync-cursor.sh..."
rm -f "${BIN_DIR}/sync-cursor.sh"
echo "  -> Done."

# --- 3. Remove Distrobox env source -------------------------------------------
echo "[3/4] Cleaning up ${PROFILE}..."
if [ -f "$PROFILE" ]; then
    sed -i '/cursor-sync\/env/d' "$PROFILE"
    echo "  -> Removed env source line."
else
    echo "  -> No ${PROFILE} found, skipping."
fi

# Remove the env file
rm -rf "${HOME}/.config/cursor-sync"

# --- 4. Remove SDDM helper (if installed) ------------------------------------
echo "[4/4] Checking for SDDM helper..."
if [ -f /etc/sync-cursor/sddm-helper ]; then
    if sudo -n true 2>/dev/null; then
        echo "  -> SDDM helper found. Removing..."
        sudo rm -f /etc/sync-cursor/sddm-helper
        sudo rmdir /etc/sync-cursor 2>/dev/null || true
        sudo rm -f /etc/sudoers.d/sync-cursor-sddm
        sudo rm -f /etc/sddm.conf.d/zzz-sync-cursor.conf
        sudo rm -f /etc/sddm.conf.d/cursor.conf
        echo "  -> SDDM helper and sudoers rule removed."
    else
        echo "  -> SDDM helper found but sudo requires a password."
        echo "     Run 'sudo bash uninstall.sh' to remove SDDM components, or manually:"
        echo "       sudo rm -f /etc/sync-cursor/sddm-helper"
        echo "       sudo rm -rf /etc/sync-cursor"
        echo "       sudo rm -f /etc/sudoers.d/sync-cursor-sddm"
        echo "       sudo rm -f /etc/sddm.conf.d/zzz-sync-cursor.conf"
    fi
else
    echo "  -> No SDDM helper installed, skipping."
fi

# Remove state file
rm -f "${XDG_RUNTIME_DIR}/sync-cursor.state" 2>/dev/null || true
rm -f "${XDG_RUNTIME_DIR}/sync-cursor.lock" 2>/dev/null || true

echo ""
echo "=== Uninstall complete ==="
echo ""
echo "Note: cursor configs written to GTK settings.ini, .Xresources,"
echo "gsettings, Flatpak overrides, and index.theme files were left in"
echo "place — they contain your current cursor theme and are harmless."
echo "KDE will overwrite them next time you change your cursor."
