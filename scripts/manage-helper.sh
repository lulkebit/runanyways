#!/bin/bash
# Sealed inside the signed app bundle. Deliberately accepts only two fixed actions.
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

app=/Applications/RunAnyways.app
script="$app/Contents/Resources/manage-helper.sh"
embedded_helper="$app/Contents/Library/HelperTools/RunAnywaysHelper"
helper=/Library/PrivilegedHelperTools/com.runanyways.RunAnywaysHelper
helper_directory=/Library/PrivilegedHelperTools
source_plist="$app/Contents/Library/LaunchDaemons/com.runanyways.RunAnywaysHelper.local.plist"
installed_plist=/Library/LaunchDaemons/com.runanyways.RunAnywaysHelper.plist
label=com.runanyways.RunAnywaysHelper
journal=/private/var/db/RunAnyways/sleep-override.json

fail() { printf '%s\n' "$*" >&2; exit 1; }
[ "$#" -eq 1 ] || fail 'Choose the fixed install or remove action.'
case "$1" in install|remove) action="$1" ;; *) fail 'Unknown helper management action.' ;; esac
[ "$(id -u)" -eq 0 ] || fail 'Administrator authorization is required.'
[ "${BASH_SOURCE[0]}" = /dev/fd/3 ] || fail 'Run only through the fixed descriptor-validated administrator launcher.'
[ -d "$app" ] && [ ! -L "$app" ] || fail 'The installed app is missing or is a symlink.'
unsafe="$(find "$app" \( -type l -o \! -type d -a \! -type f -o \! -user root -o -perm -0020 -o -perm -0002 \) -print -quit)"
[ -z "$unsafe" ] || fail 'The installed app contains an unprotected file or symlink.'
[ -d /Library/LaunchDaemons ] && [ ! -L /Library/LaunchDaemons ] || fail 'The LaunchDaemons directory is not a real directory.'
[ "$(stat -f %u /Library/LaunchDaemons)" = 0 ] || fail 'The LaunchDaemons directory is not root-owned.'
[ -z "$(find /Library/LaunchDaemons -prune \( -perm -0020 -o -perm -0002 \) -print)" ] || fail 'The LaunchDaemons directory is writable by an unprivileged user.'
codesign --verify --strict --deep "$app"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" = com.runanyways.RunAnyways ] || fail 'Unexpected app identifier.'
[ "$(/usr/libexec/PlistBuddy -c 'Print :RunAnywaysHelperInstallationMode' "$app/Contents/Info.plist")" = localDaemon ] || fail 'This build does not use the local daemon backend.'
[ -z "$(/usr/libexec/PlistBuddy -c 'Print :RunAnywaysSigningTeamID' "$app/Contents/Info.plist")" ] || fail 'Unexpected local-build signing configuration.'
helper_identity="$(codesign -dv "$embedded_helper" 2>&1 | sed -n 's/^Identifier=//p')"
[ "$helper_identity" = "$label" ] || fail 'Unexpected helper code signature identifier.'
plutil -lint "$source_plist" >/dev/null
[ "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$source_plist")" = "$label" ] || fail 'Unexpected daemon label.'
[ "$(/usr/libexec/PlistBuddy -c 'Print :UserName' "$source_plist")" = root ] || fail 'The daemon must run as root.'
[ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$source_plist")" = "$helper" ] || fail 'Unexpected helper executable path.'
if /usr/libexec/PlistBuddy -c 'Print :ProgramArguments:1' "$source_plist" >/dev/null 2>&1; then fail 'Unexpected helper arguments.'; fi
for forbidden in BundleProgram Program SpawnConstraint EnvironmentVariables; do
    if /usr/libexec/PlistBuddy -c "Print :$forbidden" "$source_plist" >/dev/null 2>&1; then fail 'Unexpected launch configuration.'; fi
done
[ "$(/usr/libexec/PlistBuddy -c "Print :MachServices:$label" "$source_plist")" = true ] || fail 'Unexpected Mach service.'
if [ -e "$installed_plist" ] || [ -L "$installed_plist" ]; then
    [ -f "$installed_plist" ] && [ ! -L "$installed_plist" ] || fail 'The installed daemon plist is not a regular file.'
    [ "$(stat -f %u "$installed_plist")" = 0 ] || fail 'The installed daemon plist is not root-owned.'
    [ -z "$(find "$installed_plist" -prune \( -perm -0020 -o -perm -0002 \) -print)" ] || fail 'The daemon plist is writable by an unprivileged user.'
    [ "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$installed_plist")" = "$label" ] || fail 'The existing daemon plist belongs to another service.'
fi

# The executable must not live under /Applications: its admin-writable parent
# allows app-directory replacement. Only this root-owned directory is executable
# launchd authority for the conventional local daemon.
if [ ! -e "$helper_directory" ] && [ ! -L "$helper_directory" ]; then
    mkdir -m 755 "$helper_directory"
    chown root:wheel "$helper_directory"
fi
[ -d "$helper_directory" ] && [ ! -L "$helper_directory" ] || fail 'PrivilegedHelperTools is not a real directory.'
[ "$(stat -f %u "$helper_directory")" = 0 ] || fail 'PrivilegedHelperTools is not root-owned.'
[ -z "$(find "$helper_directory" -prune \( -perm -0020 -o -perm -0002 \) -print)" ] || fail 'PrivilegedHelperTools is writable by an unprivileged user.'
if [ -e "$helper" ] || [ -L "$helper" ]; then
    [ -f "$helper" ] && [ ! -L "$helper" ] || fail 'The installed helper is not a regular file.'
    [ "$(stat -f %u "$helper")" = 0 ] || fail 'The installed helper is not root-owned.'
    [ -z "$(find "$helper" -prune \( -perm -0020 -o -perm -0002 \) -print)" ] || fail 'The installed helper is writable by an unprivileged user.'
    codesign --verify --strict --all-architectures "$helper"
    [ "$(codesign -dv "$helper" 2>&1 | sed -n 's/^Identifier=//p')" = "$label" ] || fail 'The installed helper belongs to another product.'
fi

work="$(mktemp -d "$helper_directory/.RunAnyways.manage.XXXXXXXX")"
chmod 700 "$work"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT
# Pin an opened, root-owned source inode before copying. App-directory renames
# cannot redirect this descriptor to a user-owned replacement during staging.
if [ "$action" = install ]; then
    exec 3< "$embedded_helper"
    [ "$(stat -L -f %u /dev/fd/3)" = 0 ] || fail 'The opened helper source is not root-owned.'
    [ "$(stat -L -f %HT /dev/fd/3)" = 'Regular File' ] || fail 'The opened helper source is not a regular file.'
    source_mode="$(stat -L -f %Lp /dev/fd/3)"
    [ "$((8#$source_mode & 0022))" -eq 0 ] || fail 'The opened helper source is writable by an unprivileged user.'
    expected_hash="$(codesign -dv --verbose=4 "$embedded_helper" 2>&1 | sed -n 's/^CDHash=//p')"
    [[ "$expected_hash" =~ ^[0-9a-fA-F]{40,64}$ ]] || fail 'The source helper has no valid code hash.'
    cat <&3 >"$work/new.helper"
    exec 3<&-
    chown root:wheel "$work/new.helper"
    chmod 755 "$work/new.helper"
    codesign --verify --strict --all-architectures "$work/new.helper"
    staged_hash="$(codesign -dv --verbose=4 "$work/new.helper" 2>&1 | sed -n 's/^CDHash=//p')"
    [ "$staged_hash" = "$expected_hash" ] || fail 'The staged helper does not match the captured source code hash.'
    [ "$(codesign -dv "$work/new.helper" 2>&1 | sed -n 's/^Identifier=//p')" = "$label" ] || fail 'The staged helper has an unexpected identifier.'
    # The privileged launch definition is literal, so an app-directory rename
    # cannot replace it between source validation and installation.
    cat >"$work/new.plist" <<'RUNANYWAYS_LOCAL_PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>ProgramArguments</key>
	<array>
		<string>/Library/PrivilegedHelperTools/com.runanyways.RunAnywaysHelper</string>
	</array>
	<key>ExitTimeOut</key>
	<integer>15</integer>
	<key>KeepAlive</key>
	<true/>
	<key>Label</key>
	<string>com.runanyways.RunAnywaysHelper</string>
	<key>MachServices</key>
	<dict>
		<key>com.runanyways.RunAnywaysHelper</key>
		<true/>
	</dict>
	<key>ProcessType</key>
	<string>Background</string>
	<key>RunAtLoad</key>
	<true/>
	<key>UserName</key>
	<string>root</string>
</dict>
</plist>
RUNANYWAYS_LOCAL_PLIST
    chown root:wheel "$work/new.plist"
    chmod 644 "$work/new.plist"
fi
loaded=0
if launchctl print "system/$label" >"$work/job" 2>&1; then loaded=1
else
    code=$?
    [ "$code" -eq 113 ] && grep -q 'Could not find service' "$work/job" || fail 'Could not inspect the existing system job safely.'
fi
# The journal is the durable ownership evidence. Never unload it merely because
# XPC is unavailable. A failed never-started job has no journal and can be repaired.
[ ! -e "$journal" ] && [ ! -L "$journal" ] || fail 'Sleep restoration is pending. Keep the helper installed and restore normal sleep before changing it.'
if [ "$loaded" -eq 1 ] && grep -Eq '^[[:space:]]*pid = [1-9][0-9]*' "$work/job"; then
    # App directories can be renamed by an administrator account. Never execute
    # an app-path binary as root, even after checking its current ownership.
    probe_uid="${SUDO_UID:-$(stat -f %u /dev/console)}"
    [[ "$probe_uid" =~ ^[0-9]+$ ]] && [ "$probe_uid" -gt 0 ] || fail 'No unprivileged user context is available to probe the running helper.'
    sudo -n -u "#$probe_uid" -- "$app/Contents/MacOS/RunAnyways" --probe-helper >"$work/probe.json" || fail 'The running helper could not acknowledge safe removal. Stop its session first.'
    [ "$(plutil -extract safeToUnload raw -o - "$work/probe.json" 2>/dev/null)" = true ] || fail 'The helper has an active session or pending restoration.'
fi
if [ "$loaded" -eq 1 ] && grep -q 'managed_by = com.apple.xpc.ServiceManagement' "$work/job"; then
    fail 'Unregister the old managed helper from the installed app before installing the local daemon.'
fi
[ ! -e "$journal" ] && [ ! -L "$journal" ] || fail 'A session acquired sleep ownership during installation; stop it first.'
if [ "$loaded" -eq 1 ]; then
    launchctl bootout "system/$label"
    for _ in {1..40}; do
        if ! launchctl print "system/$label" >/dev/null 2>&1; then break; fi
        sleep 0.1
    done
    if launchctl print "system/$label" >/dev/null 2>&1; then fail 'The old helper job did not unload.'; fi
fi
[ ! -e "$journal" ] && [ ! -L "$journal" ] || fail 'The helper retained a recovery journal while exiting. Keep the app installed and recover sleep before removing its files.'
if [ "$action" = remove ]; then
    rm -f "$installed_plist"
    rm -f "$helper"
    printf 'Removed the RunAnyways local daemon. The app and recovery directory were preserved.\n'
    exit 0
fi

# Both new files were validated and staged before the old job was unloaded.
# Their destination directories are on the same root-protected /Library volume.
if [ -f "$installed_plist" ]; then cp -p "$installed_plist" "$work/previous.plist"; fi
if [ -f "$helper" ]; then cp -p "$helper" "$work/previous.helper"; fi
mv -f "$work/new.helper" "$helper"
mv -f "$work/new.plist" "$installed_plist"
if ! launchctl enable "system/$label" || ! launchctl bootstrap system "$installed_plist"; then
    if [ ! -e "$journal" ] && [ ! -L "$journal" ]; then
        if [ -f "$work/previous.helper" ]; then mv -f "$work/previous.helper" "$helper"; else rm -f "$helper"; fi
        if [ -f "$work/previous.plist" ]; then mv -f "$work/previous.plist" "$installed_plist"; else rm -f "$installed_plist"; fi
    fi
    fail 'The daemon bootstrap failed; prior files were restored when no sleep-recovery ownership existed. Run --helper-status for diagnostics.'
fi
printf 'Installed the RunAnyways local daemon. Verify with the installed app --probe-helper.\n'
