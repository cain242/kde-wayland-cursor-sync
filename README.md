# kde-cursor-sync

Automatic cursor theme sync for KDE Plasma 6 on Wayland.

Changes your cursor in KDE System Settings and it just works — everywhere. Flatpak apps, GTK apps, XWayland apps (Steam, Wine, Electron), the login screen, Distrobox containers. No manual config editing, no Flatseal tweaks, no wondering why Firefox has a different cursor than Dolphin.

## The problem

KDE Plasma 6 on Wayland dropped `XCURSOR_THEME` and `XCURSOR_SIZE` environment variables because they can't be simultaneously correct for Wayland and X11 apps. The result is that every toolkit and sandbox now has its own way of finding the cursor theme, and most of them get it wrong:

- **Flatpak apps** can't see your cursor theme because the sandbox blocks `~/.local/share/icons`
- **GTK apps** read from `settings.ini` and `gsettings`, which KDE may or may not have updated
- **XWayland apps** (Steam, Wine/Proton, Electron) rely on env vars that no longer exist
- **The login screen** (SDDM) runs as a different user who can't access your themes
- **Distrobox containers** don't share the host's systemd environment
- **Single-size cursor themes** (common with anime/art cursors ported from Windows) get force-scaled to whatever size the previous theme was using, looking blurry or pixelated

This script fixes all of it.

## How it works

A systemd path unit watches `~/.config/kcminputrc`. When you change your cursor theme or size in System Settings, the script runs automatically and writes the correct configuration to every target:

| # | Target | What it does |
|---|--------|-------------|
| 1 | **systemd environment** | Sets `XCURSOR_THEME`, `XCURSOR_SIZE`, `XCURSOR_PATH` for the live session via `environment.d` and `systemctl --user set-environment` |
| 2 | **Flatpak** | `flatpak --user override` with env vars and filesystem grants for icon directories |
| 3 | **XWayland / libXcursor** | Writes `~/.icons/default/index.theme` and `~/.local/share/icons/default/index.theme` with `Inherits=<your theme>` |
| 4 | **Xresources** | Merges `Xcursor.theme` and `Xcursor.size` into the live X resource database and `~/.Xresources` |
| 5 | **gsettings / dconf** | Sets `org.gnome.desktop.interface cursor-theme` and `cursor-size` for libadwaita/libhandy apps and AppImages |
| 6 | **GTK 3 & 4** | Updates `~/.config/gtk-3.0/settings.ini` and `~/.config/gtk-4.0/settings.ini` |
| 7 | **GTK 2** | Updates `~/.gtkrc-2.0` |
| 8 | **SDDM login screen** | Copies your theme to `/var/lib/sddm/.icons/` and writes `/etc/sddm.conf.d/zzz-sync-cursor.conf` (optional, requires one-time setup) |
| 9 | **Distrobox / Toolbox** | Writes a sourceable env file to `~/.config/cursor-sync/env` |

Additionally, the script **auto-corrects cursor sizes** — if you switch to a theme that only ships size 32 cursors but KDE still has size 36 saved from your previous theme, the script reads the XCursor binary, detects the available sizes, and snaps to the nearest one. No more blurry anime cursors.

## Requirements

- KDE Plasma 6.2+ on Wayland
- `kreadconfig6` (KDE Frameworks 6 — preinstalled on any KDE Plasma system)
- `xdg-desktop-portal-gtk` (required by KDE for Flatpak GTK cursor theming — [see KDE blog post](https://blogs.kde.org/2024/10/09/cursor-size-problems-in-wayland-explained/))
- `python3` (for XCursor size detection — preinstalled on Fedora/Bazzite/Arch)

Tested on Bazzite 43+, Fedora Kinoite/KDE, CachyOS, and EndeavourOS. Should work on any KDE Plasma 6 Wayland system using systemd.

## Installation

```bash
git clone https://github.com/YOURUSERNAME/kde-cursor-sync.git
cd kde-cursor-sync
bash install.sh
```

The installer:
- Copies `sync-cursor.sh` to `~/.local/bin/`
- Installs and enables the systemd path + service units
- Adds the Distrobox env source line to `~/.profile`
- Runs the script once with `--force` to sync everything immediately

### SDDM support (optional)

If you want the login screen to match your cursor theme:

```bash
sudo bash setup-sddm.sh
```

This installs a root-owned helper script and a narrow sudoers rule. If you skip it, everything else works fine — SDDM just keeps its default cursor. See [SDDM details](#sddm-details) below.

## Uninstalling

```bash
cd kde-cursor-sync
bash uninstall.sh
```

Cleanly removes the systemd units, scripts, sudoers rule, and SDDM helper.

## Usage

There is no manual usage. Change your cursor in **System Settings → Colors & Themes → Cursors** and everything syncs automatically within a second. You'll see a notification confirming it.

To force a re-sync (e.g. after first install or if something drifted):

```bash
sync-cursor.sh --force
```

## SDDM details

SDDM runs as the `sddm` user (home: `/var/lib/sddm`). It can't read cursor themes installed to your `~/.local/share/icons/`. The SDDM helper script:

1. Copies your user-installed theme to `/var/lib/sddm/.icons/` so the sddm user can find it
2. Writes `/etc/sddm.conf.d/zzz-sync-cursor.conf` — the `zzz-` prefix ensures it loads last and overrides any stale `CursorTheme` in `kde_settings.conf`
3. Updates `/var/lib/sddm/.icons/default/index.theme` as a fallback
4. Cleans up old themes from previous selections

The sudoers rule only grants NOPASSWD access to the single helper script at `/etc/sync-cursor/sddm-helper`, which validates all input independently.

**Note:** SDDM is being replaced by [Plasma Login Manager](https://blog.davidedmundson.co.uk/blog/a-roadmap-for-a-modern-plasma-login-manager/) (PLM) starting with Plasma 6.6 / Fedora 44. PLM uses Plasma's own theming infrastructure and may not need this workaround. The script will be updated for PLM once Bazzite adopts it.

## Limitations

- **XWayland apps require restart.** Steam, Wine/Proton, and Electron apps cache the cursor at launch. They won't pick up a theme change until you restart them. This is a fundamental Xlib limitation, not a script bug.
- **SDDM applies on next login.** The login screen loads its cursor when the greeter starts, so changes appear after you log out or reboot.
- **Distrobox containers need re-entry.** Already-running containers won't see env var changes until the next `distrobox enter`. Config files (GTK, index.theme) are visible immediately since `$HOME` is shared.
- **Fractional scaling + non-Breeze themes.** If you use fractional scaling (125%, 150%) with a third-party cursor theme that ships limited sizes, some apps will still render the cursor slightly wrong. This is a toolkit-level issue that only SVG cursors or the Wayland cursor-shape protocol can fully solve. The size auto-correction in this script minimizes the damage.

## How long will this be needed?

The Wayland [cursor-shape protocol](https://wayland.app/protocols/cursor-shape-v1) is the proper fix — apps tell the compositor which cursor to show, and the compositor draws it consistently. Qt and Electron already support it, GTK/Mutter added support recently, and adoption is growing. As more apps use it, fewer targets in this script matter.

Realistically, the non-login-manager targets (Flatpak overrides, XWayland env vars, GTK configs, Distrobox) will be needed for **2–4 more years** as the long tail of apps catch up. The script is designed to be harmless when its fixes become redundant — writing an env var that's already set or a config key that's already correct costs nothing.

## Credits

This script is heavily informed by Jin Liu's excellent blog post [Cursor Size Problems in Wayland, Explained](https://blogs.kde.org/2024/10/09/cursor-size-problems-in-wayland-explained/) and the [ArchWiki cursor themes page](https://wiki.archlinux.org/title/Cursor_themes).

## License

MIT
