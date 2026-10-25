#!/bin/bash
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source_app="${1:-$repo_root/dist/RunAnyways.app}"
destination=/Applications/RunAnyways.app
label=com.runanyways.RunAnywaysHelper
journal=/private/var/db/RunAnyways/sleep-override.json
fail() { printf '%s\n' "$*" >&2; exit 1; }
[ "$#" -le 1 ] || fail 'Usage: scripts/install-local.sh [APP_PATH]'
[ "$(id -u)" -ne 0 ] || fail 'Run this installer as your normal user; it requests sudo only for fixed installation steps.'
[ -d "$source_app" ] && [ ! -L "$source_app" ] || fail 'Source must be a real app-bundle directory.'
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$source_app/Contents/Info.plist")" = com.runanyways.RunAnyways ] || fail 'The source app has an unexpected identifier.'
backend="$(/usr/libexec/PlistBuddy -c 'Print :RunAnywaysHelperInstallationMode' "$source_app/Contents/Info.plist")"
case "$backend" in localDaemon|serviceManagement) ;; *) fail 'Rebuild the app with an explicit supported helper installation mode.' ;; esac
[ -z "$(find "$source_app" \( -type l -o \! -type d -a \! -type f \) -print -quit)" ] || fail 'The source app contains a symlink or special file.'
codesign --verify --strict --deep "$source_app"
if pgrep -x RunAnyways >/dev/null 2>&1; then fail 'Quit RunAnyways before installing or upgrading the app.'; fi

# A never-started failed job is repairable. A live helper must first finish its
# session and be disabled from the owning app; never replace its pinned app code.
job_description="$(mktemp -t RunAnyways.install-job.XXXXXXXX)"
trap 'rm -f "$job_description"' EXIT
if launchctl print "system/$label" >"$job_description" 2>&1; then
    if grep -Eq '^[[:space:]]*pid = [1-9][0-9]*' "$job_description"; then
        fail 'A helper process is running. Stop its session and disable the helper in RunAnyways before upgrading.'
    fi
else
    result=$?
    [ "$result" -eq 113 ] && grep -q 'Could not find service' "$job_description" || fail 'Could not inspect the current system job safely.'
fi
sudo -v
if sudo test -e "$journal" || sudo test -L "$journal"; then
    fail 'A recovery journal exists. Restore normal sleep with the installed helper before replacing the app.'
fi

temporary_root="$(sudo mktemp -d /Applications/.RunAnyways.install.XXXXXXXX)"
temporary_app="$temporary_root/RunAnyways.app"
backup_root=""
backup_app=""
copy_installed=0
moved_existing=0
cleanup() {
    rm -f "$job_description"
    if [ "$copy_installed" -eq 0 ] && [ "$moved_existing" -eq 1 ] && [ ! -e "$destination" ] && [ -e "$backup_app" ]; then
        sudo mv "$backup_app" "$destination"
    fi
    if [ -n "$temporary_root" ] && [ -d "$temporary_root" ]; then sudo rm -rf "$temporary_root"; fi
    if [ "$copy_installed" -eq 0 ] && [ -n "$backup_root" ] && [ -d "$backup_root" ]; then sudo rmdir "$backup_root" 2>/dev/null || true; fi
}
trap cleanup EXIT
sudo chmod 700 "$temporary_root"
sudo ditto --rsrc --extattr "$source_app" "$temporary_app"
[ -z "$(sudo find "$temporary_app" \( -type l -o \! -type d -a \! -type f \) -print -quit)" ] || fail 'The copied app contains a symlink or special file.'
sudo chmod -RN "$temporary_app"
sudo chown -R root:wheel "$temporary_app"
sudo find "$temporary_app" -exec chmod ug-s,go-w {} +
sudo codesign --verify --strict --deep "$temporary_app"

if [ -e "$destination" ] || [ -L "$destination" ]; then
    [ -d "$destination" ] && [ ! -L "$destination" ] || fail 'Refusing to replace a non-directory or symlink at the destination.'
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist")" = com.runanyways.RunAnyways ] || fail 'The existing app belongs to another product.'
    codesign --verify --strict --deep "$destination"
    backup_root="$(sudo mktemp -d /Applications/.RunAnyways.previous.XXXXXXXX)"
    backup_app="$backup_root/RunAnyways.app"
    sudo chmod 700 "$backup_root"
    sudo mv "$destination" "$backup_app"
    moved_existing=1
fi
sudo mv "$temporary_app" "$destination"
copy_installed=1

if [ "$backend" = localDaemon ]; then
    # Service Management registration belongs to the user's installed app
    # context. Do not unregister through sudo or invoke the app from a build tree.
    "$destination/Contents/MacOS/RunAnyways" --unregister-managed-helper || fail 'The app is installed, but managed-helper migration failed. The previous app backup was retained.'
    # Pin the protected script inode inside the elevated shell before executing
    # it; a renamed /Applications bundle must never redirect root execution.
    sudo /bin/bash -c '        exec 3< /Applications/RunAnyways.app/Contents/Resources/manage-helper.sh
        [ "$(/usr/bin/stat -L -f %u /dev/fd/3)" = 0 ] || exit 1
        [ "$(/usr/bin/stat -L -f %HT /dev/fd/3)" = "Regular File" ] || exit 1
        script_mode=$(/usr/bin/stat -L -f %Lp /dev/fd/3)
        [ "$((8#$script_mode & 0022))" -eq 0 ] || exit 1
        exec /bin/bash /dev/fd/3 install
    ' || fail 'The app is installed, but local daemon setup failed. Keep the app and any recovery journal intact; inspect --helper-status.'
    "$destination/Contents/MacOS/RunAnyways" --probe-helper || fail 'The daemon was installed but authenticated IPC failed. Run the installed app --helper-status and inspect its diagnostic output.'
    printf 'Installed app and local daemon. Authenticated helper status succeeded.\n'
else
    printf 'Installed signed app. Open RunAnyways to enable its managed helper and approve it in System Settings.\n'
fi
if [ -n "$backup_app" ]; then printf 'Previous app backup: %s\n' "$backup_app"; fi
