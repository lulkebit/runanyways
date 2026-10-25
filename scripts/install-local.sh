#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source_app="${1:-$repo_root/dist/RunAnyways.app}"
destination="/Applications/RunAnyways.app"

if [ "$#" -gt 1 ]; then
    printf 'Usage: scripts/install-local.sh [APP_PATH]\n' >&2
    exit 2
fi
if [ ! -d "$source_app" ] || [ -L "$source_app" ]; then
    printf 'Source must be a real app-bundle directory: %s\n' "$source_app" >&2
    exit 1
fi
source_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$source_app/Contents/Info.plist" 2>/dev/null || true)"
if [ "$source_identifier" != "com.runanyways.RunAnyways" ]; then
    printf 'Source app has an unexpected bundle identifier: %s\n' "$source_identifier" >&2
    exit 1
fi
unsafe_source_item="$(find "$source_app" \( -type l -o \! -type d -a \! -type f \) -print -quit)"
if [ -n "$unsafe_source_item" ]; then
    printf 'Source app contains a symlink or special file: %s\n' "$unsafe_source_item" >&2
    exit 1
fi
codesign --verify --strict --deep "$source_app"

if pgrep -x RunAnyways >/dev/null 2>&1; then
    printf 'Quit RunAnyways before installing or upgrading the app.\n' >&2
    exit 1
fi
if sudo launchctl print system/com.runanyways.RunAnywaysHelper >/dev/null 2>&1; then
    printf 'Disable/unregister the RunAnyways helper from the app UI before installing or upgrading.\n' >&2
    exit 1
fi
printf 'This installs the app bundle only. Open it and register the helper from the app UI.\n'

temporary_root="$(sudo mktemp -d /Applications/.RunAnyways.install.XXXXXXXX)"
temporary_app="$temporary_root/RunAnyways.app"
backup_root=""
backup_app=""
moved_existing=0
install_complete=0
cleanup() {
    if [ "$install_complete" -ne 1 ] && [ "$moved_existing" -eq 1 ] && [ ! -e "$destination" ] && [ -e "$backup_app" ]; then
        sudo mv "$backup_app" "$destination"
    fi
    if [ -n "$temporary_root" ] && [ -d "$temporary_root" ]; then
        sudo rm -rf "$temporary_root"
    fi
    if [ "$install_complete" -ne 1 ] && [ -n "$backup_root" ] && [ -d "$backup_root" ]; then
        sudo rmdir "$backup_root" 2>/dev/null || true
    fi
}
trap cleanup EXIT

sudo chmod 700 "$temporary_root"
sudo ditto --rsrc --extattr "$source_app" "$temporary_app"
unsafe_copied_item="$(sudo find "$temporary_app" \( -type l -o \! -type d -a \! -type f \) -print -quit)"
if [ -n "$unsafe_copied_item" ]; then
    printf 'Copied app contains a symlink or special file; refusing privileged ownership changes.\n' >&2
    exit 1
fi
sudo chown -R root:wheel "$temporary_app"
sudo find "$temporary_app" -exec chmod ug-s,go-w {} +
sudo codesign --verify --strict --deep "$temporary_app"

if [ -e "$destination" ] || [ -L "$destination" ]; then
    if [ -L "$destination" ] || [ ! -d "$destination" ]; then
        printf 'Refusing to replace a non-directory or symlink at %s\n' "$destination" >&2
        exit 1
    fi
    existing_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist" 2>/dev/null || true)"
    if [ "$existing_identifier" != "com.runanyways.RunAnyways" ]; then
        printf 'Refusing to replace an app with an unexpected bundle identifier.\n' >&2
        exit 1
    fi
    codesign --verify --strict --deep "$destination"
    backup_root="$(sudo mktemp -d /Applications/.RunAnyways.previous.XXXXXXXX)"
    backup_app="$backup_root/RunAnyways.app"
    sudo chmod 700 "$backup_root"
    sudo mv "$destination" "$backup_app"
    moved_existing=1
fi

sudo mv "$temporary_app" "$destination"
install_complete=1

printf 'Installed to %s. Open the app and approve/register its helper in the app UI.\n' "$destination"
printf 'Before replacing an existing install, quit RunAnyways and unregister its helper from the app UI.\n'
if [ -n "$backup_app" ]; then
    printf 'The previous app was preserved at %s. Remove it after confirming the new helper works.\n' "$backup_app"
fi
