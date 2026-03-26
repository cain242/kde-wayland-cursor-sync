#!/bin/bash
# =============================================================================
# sync-cursor.sh — KDE Plasma 6 Cursor Theme Sync
# Target: Bazzite (43.20260303+) / Wayland / KDE Plasma 6.6+
# Tested: Plasma 6.6.2, Flatpak 1.x, Qt 6.10, Mesa 26.0
# Triggered by: systemd path unit watching ~/.config/kcminputrc
#
# Battery notes:
#   - Early-exit cache: if theme+size haven't changed, exits in <1 ms with
#     zero disk I/O (state file lives on tmpfs via XDG_RUNTIME_DIR).
#   - Flatpak override is skipped entirely if flatpak isn't installed.
#   - gsettings calls are skipped if the binary isn't available.
#   - Pass --force to bypass the cache (e.g., first install, repair).
#
# Prerequisites:
#   - kreadconfig6             (KDE Frameworks 6)
#   - xdg-desktop-portal-gtk   (required by KDE for Flatpak GTK apps to
#                               receive cursor theme/size via XDG Settings Portal;
#                               see https://blogs.kde.org/2024/10/09/cursor-size-problems-in-wayland-explained/)
#
# One-time setup (SDDM):
#   SDDM writes require root. Run the provided setup-sddm.sh
#   script once to install a root-owned helper and sudoers rule:
#
#     sudo bash setup-sddm.sh
#
#   This creates:
#     /etc/sync-cursor/sddm-helper   — root-owned script that validates
#                                       input and writes SDDM config + copies themes
#     /etc/sudoers.d/sync-cursor-sddm — NOPASSWD rule for just that helper
#
#   If you skip this, SDDM sync silently no-ops (sudo -n fails gracefully).
#
# One-time setup (Distrobox):
#   Add this line to your ~/.profile (or ~/.zprofile for zsh):
#
#     [ -r "${HOME}/.config/cursor-sync/env" ] && . "${HOME}/.config/cursor-sync/env"
#
#   Distrobox 1.4.0+ runs login shells by default, so this is sourced
#   on every `distrobox enter` and by exported apps. It's harmless on the
#   host (the values match what systemctl --user set-environment already set).
#
# Limitations:
#   - XWayland apps (Steam, Wine/Proton, Electron) cache cursor themes at
#     startup and do NOT hot-reload. They must be restarted after a change.
#     This is a known Xlib/XWayland limitation, not a script bug.
#   - SDDM: user-installed cursor themes (in ~/.local/share/icons) are
#     copied to /var/lib/sddm/.icons/ so the sddm user can read them.
#     If the theme files change (e.g., update via KDE Store), re-run with
#     --force to re-copy.
#   - SDDM picks up CursorTheme on next greeter launch (reboot / logout),
#     not hot-reloaded.
#   - Distrobox: already-running containers won't see env var changes until
#     the next `distrobox enter`. Config files (GTK, index.theme) are
#     visible immediately since $HOME is shared.
# =============================================================================

# --- 0. PATH ----------------------------------------------------------------
# systemd user services inherit a minimal environment; ensure standard bins
# are always reachable.
export PATH="/usr/bin:/usr/local/bin:/bin:$PATH"
if [ -z "$XDG_RUNTIME_DIR" ]; then
    XDG_RUNTIME_DIR="/tmp/runtime-$(id -u)"
    mkdir -p "$XDG_RUNTIME_DIR"
fi

# --- 0b. ENVIRONMENT DETECTION ----------------------------------------------
# Not on KDE → exit immediately with a notification. The script reads KDE-
# specific config (kcminputrc via kreadconfig6) and is useless without it.
if ! command -v kreadconfig6 &>/dev/null; then
    notify-send \
        --app-name="Cursor Sync" \
        --icon=dialog-error \
        "Cursor Sync: Not a KDE Plasma session" \
        "kreadconfig6 not found. This script requires KDE Plasma 6." \
        2>/dev/null
    echo "sync-cursor: error: kreadconfig6 not found — not a KDE Plasma 6 session." >&2
    exit 1
fi

# Not on Wayland → warn but continue. Most targets still work under X11, but
# XWayland-specific logic (DISPLAY detection, xrdb merge) may behave
# differently and the script was never tested there.
if [ "${XDG_SESSION_TYPE:-}" != "wayland" ]; then
    echo "sync-cursor: warning: session type is '${XDG_SESSION_TYPE:-unset}', not 'wayland'. This script is designed for Wayland sessions." >&2
fi

# --- 1. LOCK ----------------------------------------------------------------
# Prevent concurrent runs if systemd fires multiple times quickly.
LOCK_FILE="${XDG_RUNTIME_DIR}/sync-cursor.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "sync-cursor: already running, exiting duplicate instance." >&2
    exit 0
fi
# NOTE: FD 9 holds the flock. We must NOT close it globally (exec 9>&-
# would release the lock). Instead, every external command that could
# potentially hang gets 9>&- so children don't inherit the lock FD.

# --- 2. DBUS ----------------------------------------------------------------
# Only set if absent — never overwrite a live session address.
if [ -z "$DBUS_SESSION_BUS_ADDRESS" ]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
fi

# --- 3. READ CURSOR CONFIG --------------------------------------------------
# Read once. If kreadconfig6 returns empty, KDE has reverted to defaults or
# hasn't written the key yet — either way, fall back immediately.
#
# Note: Plasma 6.6 introduced KConfig stream parsing (config files are now
# parsed as a stream rather than loaded entirely into memory). kreadconfig6
# remains the stable public API and is unaffected by this internal change.
THEME=$(kreadconfig6 --file kcminputrc --group Mouse --key cursorTheme 2>/dev/null)
SIZE=$( kreadconfig6 --file kcminputrc --group Mouse --key cursorSize  2>/dev/null)

THEME=${THEME:-breeze_cursors}
SIZE=${SIZE:-24}

# Validate: prevent injecting garbage into config files.
[[ "$SIZE" =~ ^[0-9]+$ ]] || SIZE=24
THEME=$(printf '%s' "$THEME" | tr -cd '[:alnum:]_.-')
[ -z "$THEME" ] && THEME=breeze_cursors

# --- 3b. SIZE AUTO-CORRECTION -----------------------------------------------
# Many third-party cursor themes (especially anime/art themes ported from
# Windows) ship only a single size (commonly 32). KDE stores cursor size
# independently from theme — so switching from Breeze at 36 to a single-size
# theme keeps SIZE=36. Apps then ask libXcursor for size 36, can't find it,
# and either scale badly (blurry/pixelated) or fall back to 24 (wrong).
#
# Fix: read the XCursor binary of a representative cursor in the theme,
# extract the available nominal sizes, and if the requested size isn't
# available, snap to the nearest one. If the theme ships only one size,
# force it unconditionally.
#
# This uses python3 (always present on Fedora/Bazzite) to parse the XCursor
# header. The XCursor format stores a Table of Contents where each image
# entry (type 0xfffd0002) records its nominal size as the subtype field.
get_cursor_sizes() {
    local cursor_file="$1"
    python3 -c "
import struct, sys
try:
    with open(sys.argv[1], 'rb') as f:
        magic, hdr_size, version, ntoc = struct.unpack('<IIII', f.read(16))
        if magic != 0x72756358:
            sys.exit(1)
        sizes = set()
        for _ in range(ntoc):
            type_, subtype, pos = struct.unpack('<III', f.read(12))
            # Image type is 0xfffd0002 in the spec
            if type_ == 0xfffd0002:
                sizes.add(subtype)
        print(' '.join(str(s) for s in sorted(sizes)))
except Exception:
    pass
" "$cursor_file" 2>/dev/null
}

# Find the theme directory.
THEME_DIR=""
for candidate in \
    "${HOME}/.local/share/icons/${THEME}" \
    "${HOME}/.icons/${THEME}" \
    "/usr/share/icons/${THEME}"; do
    if [ -d "${candidate}/cursors" ]; then
        THEME_DIR="$candidate"
        break
    fi
done

if [ -n "$THEME_DIR" ]; then
    # Pick a representative cursor file (try common names).
    SAMPLE_CURSOR=""
    for name in default left_ptr arrow; do
        if [ -f "${THEME_DIR}/cursors/${name}" ]; then
            SAMPLE_CURSOR="${THEME_DIR}/cursors/${name}"
            break
        fi
    done

    # Fallback: just pick the first regular file in cursors/ that isn't a symlink.
    if [ -z "$SAMPLE_CURSOR" ]; then
    SAMPLE_CURSOR=$(find "${THEME_DIR}/cursors" -maxdepth 1 \( -type f -o -type l \) -print -quit 2>/dev/null)
    fi

    if [ -n "$SAMPLE_CURSOR" ]; then
        AVAILABLE_SIZES=$(get_cursor_sizes "$SAMPLE_CURSOR")

        if [ -n "$AVAILABLE_SIZES" ]; then
            # Check if the requested size is available.
            SIZE_FOUND=false
            for s in $AVAILABLE_SIZES; do
                [ "$s" -eq "$SIZE" ] 2>/dev/null && SIZE_FOUND=true && break
            done

            if ! $SIZE_FOUND; then
                # Snap to the nearest available size.
                BEST_SIZE=""
                BEST_DIFF=999999
                for s in $AVAILABLE_SIZES; do
                    DIFF=$(( SIZE > s ? SIZE - s : s - SIZE ))
                    if [ "$DIFF" -lt "$BEST_DIFF" ]; then
                        BEST_DIFF=$DIFF
                        BEST_SIZE=$s
                    fi
                done

                if [ -n "$BEST_SIZE" ]; then
                    echo "sync-cursor: theme '${THEME}' doesn't have size ${SIZE}, snapping to nearest: ${BEST_SIZE} (available: ${AVAILABLE_SIZES})" >&2
                    SIZE=$BEST_SIZE
                fi
            fi
        fi
    fi
fi

# --- 4. EARLY EXIT: Skip all work if nothing changed ------------------------
# kcminputrc is the *input* config — KDE writes to it when ANY input setting
# changes (keyboard repeat, touchpad scroll speed, mouse acceleration, etc.),
# not only cursor theme/size. Without this check, every unrelated tweak in
# System Settings → Input Devices triggers ~10 process forks, 7+ file writes,
# multiple D-Bus roundtrips, and a flatpak override rewrite — all for nothing.
#
# The state file lives on tmpfs (XDG_RUNTIME_DIR), so reading it costs zero
# disk I/O and doesn't touch the SSD/NVMe at all. It is cleared on reboot,
# which means the first trigger after every boot always does a full sync —
# acting as a self-healing mechanism if any target file drifted.
STATE_FILE="${XDG_RUNTIME_DIR}/sync-cursor.state"
CURRENT_STATE="${THEME}:${SIZE}"

if [ "${1}" != "--force" ] && [ -f "$STATE_FILE" ]; then
    PREV_STATE=$(cat "$STATE_FILE" 2>/dev/null)
    if [ "$PREV_STATE" = "$CURRENT_STATE" ]; then
        echo "sync-cursor: no change (${CURRENT_STATE}), skipping." >&2
        exit 0
    fi
fi

# =============================================================================
# HELPERS
# =============================================================================

# Atomic write: write to a sibling temp file then mv. A concurrent reader
# always sees a complete file, never a partial one.
atomic_write() {
    local dest="$1" content="$2" tmp
    mkdir -p "$(dirname "$dest")"
    tmp=$(mktemp "${dest}.XXXXXX") || return 1
    printf '%s' "$content" > "$tmp" && mv -f "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
}

# GTK 3/4 ini updater (settings.ini format).
# Strategy: strip old cursor keys, ensure [Settings] exists, then inject new
# keys immediately after the header. Handles missing files, missing sections,
# and missing trailing newlines in one pass.
update_gtk_ini() {
    local file="$1"
    mkdir -p "$(dirname "$file")"

    # Bootstrap: create with [Settings] if missing or empty.
    if [ ! -s "$file" ]; then
        printf '[Settings]\ngtk-cursor-theme-name=%s\ngtk-cursor-theme-size=%s\n' \
            "$THEME" "$SIZE" > "$file"
        return
    fi

    # Ensure trailing newline so awk doesn't silently lose the last line.
    [ "$(tail -c1 "$file" 2>/dev/null | wc -l)" -eq 0 ] && printf '\n' >> "$file"

    # If no [Settings] section, append one with cursor keys and return.
    if ! grep -q '^\[Settings\]' "$file"; then
        printf '\n[Settings]\ngtk-cursor-theme-name=%s\ngtk-cursor-theme-size=%s\n' \
            "$THEME" "$SIZE" >> "$file"
        return
    fi

    local tmp
    tmp=$(mktemp "${file}.XXXXXX") || return 1

    # Single awk pass: strip old cursor keys only within [Settings], inject
    # new ones immediately after the header. Keys under other sections are
    # left untouched.
    awk -v theme="$THEME" -v size="$SIZE" '
        /^\[/           { in_settings = /^\[Settings\]/ }
        in_settings && /^gtk-cursor-theme-name=/ { next }
        in_settings && /^gtk-cursor-theme-size=/ { next }
        { print }
        /^\[Settings\]/ {
            print "gtk-cursor-theme-name=" theme
            print "gtk-cursor-theme-size=" size
        }
    ' "$file" > "$tmp" && mv -f "$tmp" "$file" || rm -f "$tmp"
}

# GTK 2 rc updater (key="value" / key=value format).
update_gtkrc2() {
    local file="$1"
    mkdir -p "$(dirname "$file")"
    touch "$file"

    [ "$(tail -c1 "$file" 2>/dev/null | wc -l)" -eq 0 ] && [ -s "$file" ] \
        && printf '\n' >> "$file"

    local tmp
    tmp=$(mktemp "${file}.XXXXXX") || return 1

    awk -v theme="$THEME" -v size="$SIZE" '
        /^gtk-cursor-theme-name/ { print "gtk-cursor-theme-name=\"" theme "\""; wrote_name=1; next }
        /^gtk-cursor-theme-size/ { print "gtk-cursor-theme-size=" size; wrote_size=1; next }
        { print }
        END {
            if (!wrote_name) print "gtk-cursor-theme-name=\"" theme "\""
            if (!wrote_size) print "gtk-cursor-theme-size=" size
        }
    ' "$file" > "$tmp" && mv -f "$tmp" "$file" || rm -f "$tmp"
}

# =============================================================================
# TARGET 1 — SYSTEMD USER SESSION ENVIRONMENT (environment.d)
# =============================================================================
# Export XCURSOR_THEME so every process spawned via systemd (krunner,
# .desktop files, etc.) inherits the correct theme across reboots.
#
# XCURSOR_PATH is required because libXcursor's built-in search path is only
# ~/.icons:/usr/share/icons:/usr/share/pixmaps — it does NOT include
# ~/.local/share/icons, which is where KDE System Settings installs user
# cursor themes. Without this, XWayland apps like Steam (layered on Bazzite,
# not Flatpak) can't find themes installed via KDE's UI.
#
# XCURSOR_SIZE is intentionally omitted from the *persistent* file.
# Plasma 6 stopped setting it because the env var can't be simultaneously
# correct for Wayland (logical px) and XWayland (physical px). KWin handles
# cursor scaling dynamically for native Wayland clients.
# See: https://blogs.kde.org/2024/10/09/cursor-size-problems-in-wayland-explained/
XCURSOR_PATH_VALUE="${HOME}/.icons:${HOME}/.local/share/icons:/usr/share/icons:/usr/share/pixmaps"

mkdir -p "${HOME}/.config/environment.d"
atomic_write "${HOME}/.config/environment.d/cursor.conf" \
"XCURSOR_THEME=${THEME}
XCURSOR_PATH=${XCURSOR_PATH_VALUE}
"
# Push XCURSOR_THEME, XCURSOR_SIZE, and XCURSOR_PATH into the *live* session.
# The persistent file above omits SIZE, but XWayland apps like Steam read all
# three vars from the environment at startup. Without XCURSOR_SIZE, Steam's
# CEF/Chromium falls back to the theme's default size. Without XCURSOR_PATH,
# libXcursor can't find themes in ~/.local/share/icons/ at all.
# The live SIZE push is ephemeral — it doesn't survive reboot, so it won't
# cause the Wayland/X11 scaling conflict that the persistent file avoids.
systemctl --user set-environment \
    XCURSOR_THEME="$THEME" \
    XCURSOR_SIZE="$SIZE" \
    XCURSOR_PATH="$XCURSOR_PATH_VALUE" \
    9>&- 2>/dev/null

# =============================================================================
# TARGET 2 — FLATPAKS (single consolidated command, skipped if not installed)
# =============================================================================
# Flatpak always unsets XCURSOR_PATH inside sandboxes (confirmed in
# flatpak-run(1)), so we MUST set it explicitly for apps to find cursors.
# Paths use sandbox-internal /run/host/ mounts where applicable:
#   /run/host/share/icons       ← host /usr/share/icons  (auto-mounted)
#   /run/host/user-share/icons  ← host ~/.local/share/icons (auto-mounted)
# ~/.icons and ~/.local/share/icons need explicit --filesystem grants.
#
# XCURSOR_SIZE is set here because Flatpak apps (especially XWayland ones
# running inside the sandbox) have no other way to discover the cursor size.
#
# NOTE: Flatpak *GTK* apps also need xdg-desktop-portal-gtk installed on the
# host to receive cursor theme/size via the XDG Settings Portal. This script
# handles the env var / filesystem side; the portal handles GTK's own config
# channel. Both are needed for full coverage.
#
# Battery: `flatpak --user override` does a full read-modify-write of
# ~/.local/share/flatpak/overrides/global on every call, even if the values
# are identical. Skip the entire operation if flatpak isn't installed.
if command -v flatpak &>/dev/null; then
    flatpak --user override \
        --env=XCURSOR_THEME="$THEME" \
        --env=XCURSOR_SIZE="$SIZE" \
        --env=XCURSOR_PATH="${HOME}/.icons:${HOME}/.local/share/icons:/run/host/user-share/icons:/run/host/share/icons" \
        --filesystem="${HOME}/.icons:ro" \
        --filesystem="${HOME}/.local/share/icons:ro" \
        9>&- 2>/dev/null
fi

# =============================================================================
# TARGET 3 — XWAYLAND / LEGACY X11 (index.theme fallback)
# =============================================================================
# Write the cursor inheritance to both legacy and XDG-compliant icon paths.
# Hidden=true conforms to the FreeDesktop Icon Theme Specification (§4, Table 1)
# and prevents KDE System Settings from showing "default" as a selectable
# cursor theme, while still allowing XWayland/libXcursor to read it.
INDEX_CONTENT="[Icon Theme]
Name=Default
Comment=Cursor fallback (auto-generated by sync-cursor)
Hidden=true
Inherits=${THEME}
"
# Legacy path — read by older apps, Wine/Proton, and some XWayland clients.
atomic_write "${HOME}/.icons/default/index.theme" "$INDEX_CONTENT"

# XDG path — read by Steam and modern apps that respect $XDG_DATA_HOME/icons.
atomic_write "${HOME}/.local/share/icons/default/index.theme" "$INDEX_CONTENT"

# =============================================================================
# TARGET 4 — XRDB + ~/.Xresources
# =============================================================================
# Merge into the live X resource database if XWayland is running.
# Also write to ~/.Xresources as a persistent fallback so the config is
# picked up when XWayland eventually starts (e.g., on first X11 app launch).
XRESOURCES_CONTENT=$(printf 'Xcursor.theme: %s\nXcursor.size: %s\n' "$THEME" "$SIZE")

# Persistent file — survives reboots and lazy XWayland start.
XRESOURCES_FILE="${HOME}/.Xresources"
if [ -f "$XRESOURCES_FILE" ]; then
    # Strip old Xcursor entries, then append fresh ones.
    tmp=$(mktemp "${XRESOURCES_FILE}.XXXXXX") || true
    if [ -n "$tmp" ]; then
        grep -v '^Xcursor\.\(theme\|size\):' "$XRESOURCES_FILE" > "$tmp" || true
        # Guard against missing trailing newline (same fix as the GTK functions).
        [ "$(tail -c1 "$tmp" 2>/dev/null | wc -l)" -eq 0 ] && [ -s "$tmp" ] \
            && printf '\n' >> "$tmp"
        printf '%s\n' "$XRESOURCES_CONTENT" >> "$tmp"
        mv -f "$tmp" "$XRESOURCES_FILE"
    fi
else
    printf '%s\n' "$XRESOURCES_CONTENT" > "$XRESOURCES_FILE"
fi

# Live merge — only possible if DISPLAY is set (XWayland is awake).
if command -v xrdb &>/dev/null; then
    if [ -z "$DISPLAY" ]; then
        DISPLAY=$(systemctl --user show-environment 2>/dev/null \
            | grep '^DISPLAY=' | cut -d= -f2)
    fi
    if [ -n "$DISPLAY" ]; then
        export DISPLAY
        printf '%s\n' "$XRESOURCES_CONTENT" | xrdb -merge - 9>&- 2>/dev/null
    fi
fi

# =============================================================================
# TARGET 5 — GTK NATIVE / MODERN APPIMAGES (gsettings / dconf)
# =============================================================================
# Effective for libhandy/libadwaita apps and AppImages shipping their own GTK.
#
# Battery: each gsettings call is a D-Bus roundtrip that can wake
# dconf-service. Skip if gsettings isn't available.
if command -v gsettings &>/dev/null; then
    gsettings set org.gnome.desktop.interface cursor-theme "$THEME" 9>&- 2>/dev/null
    gsettings set org.gnome.desktop.interface cursor-size  "$SIZE"  9>&- 2>/dev/null
fi

# =============================================================================
# TARGET 6 — GTK 3 & GTK 4 STATIC CONFIG FILES
# =============================================================================
update_gtk_ini "${HOME}/.config/gtk-3.0/settings.ini"
update_gtk_ini "${HOME}/.config/gtk-4.0/settings.ini"

# =============================================================================
# TARGET 7 — GTK 2 LEGACY
# =============================================================================
update_gtkrc2 "${HOME}/.gtkrc-2.0"

# =============================================================================
# TARGET 8 — SDDM LOGIN SCREEN
# =============================================================================
# SDDM reads CursorTheme from its own config, not from the user session.
# We write a drop-in to /etc/sddm.conf.d/ so the greeter shows the correct
# cursor on the login screen.
#
# Requires one-time sudoers setup (see header). If not configured, sudo -n
# fails silently and SDDM keeps its current cursor — no harm done.
#
# Caveat: SDDM runs as the `sddm` user, whose home is /var/lib/sddm.
# It can find cursor themes in /usr/share/icons (system-wide, immutable on
# Bazzite) and /var/lib/sddm/.icons (the sddm user's own icon dir, writable).
# If the user installed a theme via KDE System Settings, it lives in
# ~/.local/share/icons — invisible to the sddm user. We detect this and
# rsync the theme into /var/lib/sddm/.icons/ so SDDM can find it.
#
# SDDM's config has no CursorSize key — it relies on the theme's default or
# XCURSOR_SIZE in the greeter environment. The Xsetup script (which runs
# before the greeter) could export it, but that requires overriding
# DisplayCommand in sddm.conf, which is invasive. For the login screen,
# the theme's built-in default size is typically fine.
if [ -x /etc/sync-cursor/sddm-helper ]; then
    # The helper validates its arguments independently (defense in depth)
    # and handles: config write, theme detection, and theme copy.
    sudo -n /etc/sync-cursor/sddm-helper "$THEME" "$SIZE" 9>&- 2>/dev/null
fi

# =============================================================================
# TARGET 9 — DISTROBOX / TOOLBOX CONTAINERS
# =============================================================================
# Distrobox shares $HOME, so Targets 3–7 (index.theme, GTK configs,
# .Xresources, gsettings/dconf) are already visible inside containers.
#
# What's missing: environment variables. The container doesn't participate
# in the host's systemd user session, so `systemctl --user set-environment`
# (Target 1) doesn't reach it.
#
# Solution: write a POSIX-shell-compatible env file that the user sources
# from their login profile (see one-time setup in the header). Distrobox
# 1.4.0+ runs a login shell on entry, so ~/.profile (bash/sh) or
# ~/.zprofile (zsh) is sourced on every `distrobox enter` and by apps
# exported with `distrobox-export`.
#
# The file is also safe to source on the host (values are identical to what
# Target 1 already set), so no CONTAINER_ID guard is needed.
CURSOR_ENV_DIR="${HOME}/.config/cursor-sync"
CURSOR_ENV_FILE="${CURSOR_ENV_DIR}/env"
mkdir -p "$CURSOR_ENV_DIR"

atomic_write "$CURSOR_ENV_FILE" "\
export XCURSOR_THEME='${THEME}'
export XCURSOR_SIZE='${SIZE}'
export XCURSOR_PATH='${XCURSOR_PATH_VALUE}'
"

# =============================================================================
# DONE — persist state so subsequent no-op triggers exit in <1 ms
# =============================================================================
atomic_write "$STATE_FILE" "$CURRENT_STATE"

# Notify the user. This only fires when the cursor theme/size actually changed
# (the early-exit cache prevents it on no-op triggers), so it's rare enough
# that suppressing it on battery would just leave the user wondering if it ran.
# Note: XWayland apps (Steam, Wine, Electron) cache cursors at startup and
# won't pick up the new theme until they're restarted.
notify-send \
    --app-name="Cursor Sync" \
    --icon=input-mouse \
    "Cursor Synced" \
    "Theme: <b>${THEME}</b>  |  Size: <b>${SIZE}</b>  |  Restart XWayland apps to apply." \
    9>&- 2>/dev/null

echo "sync-cursor: complete. XCURSOR_THEME=${THEME} XCURSOR_SIZE=${SIZE}" >&2
