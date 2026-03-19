#!/bin/bash
# =============================================================================
# setup-sddm-cursor-sync.sh — One-time setup for sync-cursor.sh SDDM support
#
# Run once as root:   sudo bash setup-sddm-cursor-sync.sh
#
# Installs:
#   /etc/sync-cursor/sddm-helper          — privileged helper (root:root, 0755)
#   /etc/sudoers.d/sync-cursor-sddm       — NOPASSWD rule for wheel group
#   /etc/sddm.conf.d/                     — directory for SDDM config drop-ins
#   /var/lib/sddm/.icons/                 — writable icon dir for sddm user
# =============================================================================

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: this script must be run as root (sudo bash $0)" >&2
    exit 1
fi

HELPER_DIR="/etc/sync-cursor"
HELPER_PATH="${HELPER_DIR}/sddm-helper"
SUDOERS_FILE="/etc/sudoers.d/sync-cursor-sddm"

echo "=== sync-cursor SDDM setup ==="

# --- 1. Install the helper script -------------------------------------------
echo "[1/4] Installing helper to ${HELPER_PATH}..."
mkdir -p "$HELPER_DIR"

# Copy from the same directory as this setup script, or look in common locations.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_HELPER=""
for candidate in \
    "${SCRIPT_DIR}/sddm-helper" \
    "${SCRIPT_DIR}/sync-cursor-sddm-helper" \
    "./sddm-helper"; do
    if [ -f "$candidate" ]; then
        SOURCE_HELPER="$candidate"
        break
    fi
done

if [ -z "$SOURCE_HELPER" ]; then
    echo "Error: cannot find sddm-helper in ${SCRIPT_DIR}/ or current directory." >&2
    echo "Make sure sddm-helper is in the same directory as this setup script." >&2
    exit 1
fi

install -o root -g root -m 0755 "$SOURCE_HELPER" "$HELPER_PATH"
echo "  -> Installed ${HELPER_PATH} (root:root, 0755)"

# --- 2. Create sudoers drop-in ----------------------------------------------
echo "[2/4] Writing sudoers rule to ${SUDOERS_FILE}..."
cat > "${SUDOERS_FILE}.tmp" <<EOF
# Allow sync-cursor.sh to update SDDM cursor config via the helper script.
# The helper validates all input and only touches:
#   /etc/sddm.conf.d/cursor.conf
#   /var/lib/sddm/.icons/<theme>/
%wheel ALL=(ALL) NOPASSWD: ${HELPER_PATH} *
EOF

# Validate syntax before installing — a broken sudoers file locks you out.
if visudo -cf "${SUDOERS_FILE}.tmp" >/dev/null 2>&1; then
    chmod 0440 "${SUDOERS_FILE}.tmp"
    mv -f "${SUDOERS_FILE}.tmp" "$SUDOERS_FILE"
    echo "  -> Sudoers rule installed and validated."
else
    echo "Error: sudoers syntax check failed! Not installing." >&2
    rm -f "${SUDOERS_FILE}.tmp"
    exit 1
fi

# --- 3. Create directories ---------------------------------------------------
echo "[3/4] Creating directories..."
mkdir -p /etc/sddm.conf.d
mkdir -p /var/lib/sddm/.icons
# Ensure the sddm user can read its own .icons dir (it should already, but be safe).
chown sddm:sddm /var/lib/sddm/.icons 2>/dev/null || true
echo "  -> /etc/sddm.conf.d/ and /var/lib/sddm/.icons/ ready."

# --- 4. Verify ---------------------------------------------------------------
echo "[4/4] Verifying..."
if [ -x "$HELPER_PATH" ] && [ -f "$SUDOERS_FILE" ]; then
    echo ""
    echo "=== Setup complete ==="
    echo ""
    echo "sync-cursor.sh will now automatically sync your cursor theme to SDDM."
    echo "The change takes effect on next login screen appearance (reboot / logout)."
    echo ""
    echo "To test immediately:  sync-cursor.sh --force"
    echo "To undo this setup:   sudo rm ${HELPER_PATH} ${SUDOERS_FILE}"
    echo "                      sudo rm -rf ${HELPER_DIR}"
else
    echo "Error: verification failed. Please check the output above." >&2
    exit 1
fi
