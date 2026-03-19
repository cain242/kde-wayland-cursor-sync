#!/bin/bash
# install.sh — kde-cursor-sync installer
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="${HOME}/.local/bin"
SYSTEMD_DIR="${HOME}/.config/systemd/user"
PROFILE="${HOME}/.profile"

echo "=== kde-cursor-sync installer ==="
echo ""

# --- 1. Install script -------------------------------------------------------
echo "[1/4] Installing sync-cursor.sh to ${BIN_DIR}..."
mkdir -p "$BIN_DIR"
install -m 0755 "${SCRIPT_DIR}/sync-cursor.sh" "${BIN_DIR}/sync-cursor.sh"
if ! echo "$PATH" | tr ':' '\n' | grep -qx "${BIN_DIR}"; then
    echo ""
    echo "  ⚠ WARNING: ${BIN_DIR} is not in your PATH."
    echo "  The systemd service will work fine, but to run 'sync-cursor.sh --force'"
    echo "  from your terminal, add this to your ~/.bashrc:"
    echo ""
    echo "    export PATH=\"\${HOME}/.local/bin:\${PATH}\""
    echo ""
fi

# --- 2. Install systemd units ------------------------------------------------
echo "[2/4] Installing systemd units..."
mkdir -p "$SYSTEMD_DIR"

cat > "${SYSTEMD_DIR}/sync-cursor.path" <<EOF
[Unit]
Description=Watch for KDE Cursor Changes

[Path]
PathChanged=%h/.config/kcminputrc

[Install]
WantedBy=default.target
EOF

cat > "${SYSTEMD_DIR}/sync-cursor.service" <<EOF
[Unit]
Description=Sync KDE Cursor to Flatpak, GTK, and XWayland

[Service]
Type=oneshot
ExecStart=%h/.local/bin/sync-cursor.sh
EOF

systemctl --user daemon-reload
systemctl --user enable --now sync-cursor.path
echo "  -> systemd path unit enabled and watching ~/.config/kcminputrc"

# --- 3. Distrobox env source -------------------------------------------------
echo "[3/4] Setting up Distrobox support..."
PROFILE_LINE='[ -r "${HOME}/.config/cursor-sync/env" ] && . "${HOME}/.config/cursor-sync/env"'

if [ -f "$PROFILE" ] && grep -qF 'cursor-sync/env' "$PROFILE" 2>/dev/null; then
    echo "  -> Already present in ${PROFILE}, skipping."
else
    echo "$PROFILE_LINE" >> "$PROFILE"
    echo "  -> Added env source line to ${PROFILE}"
fi

# --- 4. Initial sync ---------------------------------------------------------
echo "[4/4] Running initial sync..."
"${BIN_DIR}/sync-cursor.sh" --force

echo ""
echo "=== Installation complete ==="
echo ""
echo "Your cursor theme is now synced everywhere. Future changes in"
echo "System Settings will be picked up automatically."
echo ""
echo "Optional: run 'sudo bash setup-sddm.sh' for login screen sync."
echo "To uninstall: bash uninstall.sh"
