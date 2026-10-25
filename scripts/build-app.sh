#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
configuration="debug"
configuration_was_set=0
universal=0

usage() {
    cat <<'EOF'
Usage: scripts/build-app.sh [--debug | --release] [--universal]

Builds dist/RunAnyways.app for the host architecture, or a universal
arm64+x86_64 app with --universal. Set CODE_SIGN_IDENTITY and DEVELOPMENT_TEAM
to sign with a team identity; otherwise the output is ad-hoc signed for local
development.
EOF
}

for argument in "$@"; do
    case "$argument" in
        --debug)
            if [ "$configuration_was_set" -ne 0 ]; then
                usage >&2
                exit 2
            fi
            configuration="debug"
            configuration_was_set=1
            ;;
        --release)
            if [ "$configuration_was_set" -ne 0 ]; then
                usage >&2
                exit 2
            fi
            configuration="release"
            configuration_was_set=1
            ;;
        --universal)
            universal=1
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$argument" >&2
            usage >&2
            exit 2
            ;;
    esac
done

signing_identity="${CODE_SIGN_IDENTITY:-}"
signing_team="${DEVELOPMENT_TEAM:-}"
if [ -n "$signing_identity" ]; then
    if [[ ! "$signing_team" =~ ^[A-Z0-9]{10}$ ]]; then
        printf 'Set DEVELOPMENT_TEAM to the 10-character signing team ID when CODE_SIGN_IDENTITY is set.\n' >&2
        exit 2
    fi
elif [ -n "$signing_team" ]; then
    printf 'DEVELOPMENT_TEAM requires CODE_SIGN_IDENTITY.\n' >&2
    exit 2
fi

if [ "$universal" -eq 1 ]; then
    architectures=(arm64 x86_64)
else
    host_architecture="$(uname -m)"
    case "$host_architecture" in
        arm64|aarch64) architectures=(arm64) ;;
        x86_64) architectures=(x86_64) ;;
        *)
            printf 'Unsupported host architecture: %s\n' "$host_architecture" >&2
            exit 2
            ;;
    esac
fi

dist_directory="$repo_root/dist"
mkdir -p "$dist_directory"
staging_app="$dist_directory/.RunAnyways.app.staging.$$"
output_app="$dist_directory/RunAnyways.app"
cleanup() {
    if [ -d "$staging_app" ] && [[ "$staging_app" == "$dist_directory/"* ]]; then
        rm -rf "$staging_app"
    fi
}
trap cleanup EXIT

mkdir -p "$staging_app/Contents/MacOS" \
    "$staging_app/Contents/Resources" \
    "$staging_app/Contents/Library/HelperTools" \
    "$staging_app/Contents/Library/LaunchDaemons"

declare -a app_binaries=()
declare -a helper_binaries=()
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
for architecture in "${architectures[@]}"; do
    scratch_path="$repo_root/.build/runanyways-app/$architecture-$configuration-native"
    # Swift 6.4's swiftbuild backend records the deployment target as the SDK
    # version. The native backend preserves the actual SDK and Package.swift's
    # macOS 13 deployment target, avoiding unintended compatibility behavior.
    build_arguments=(--build-system native --scratch-path "$scratch_path"
        --arch "$architecture" --sdk "$sdk_path" --configuration "$configuration")
    binary_directory="$(swift build "${build_arguments[@]}" --show-bin-path)"
    swift build "${build_arguments[@]}"
    app_binaries+=("$binary_directory/RunAnyways")
    helper_binaries+=("$binary_directory/RunAnywaysHelper")
done

if [ "$universal" -eq 1 ]; then
    lipo -create "${app_binaries[@]}" -output "$staging_app/Contents/MacOS/RunAnyways"
    lipo -create "${helper_binaries[@]}" -output "$staging_app/Contents/Library/HelperTools/RunAnywaysHelper"
else
    cp "${app_binaries[0]}" "$staging_app/Contents/MacOS/RunAnyways"
    cp "${helper_binaries[0]}" "$staging_app/Contents/Library/HelperTools/RunAnywaysHelper"
fi

if [ -n "$signing_team" ]; then
    sed "s/__RUNANYWAYS_SIGNING_TEAM_ID__/$signing_team/" \
        "$repo_root/Resources/Info.plist.template" > "$staging_app/Contents/Info.plist"
else
    sed 's/__RUNANYWAYS_SIGNING_TEAM_ID__//' \
        "$repo_root/Resources/Info.plist.template" > "$staging_app/Contents/Info.plist"
fi
cp "$repo_root/Resources/com.runanyways.RunAnywaysHelper.plist" \
    "$staging_app/Contents/Library/LaunchDaemons/com.runanyways.RunAnywaysHelper.plist"

if [ -n "$signing_identity" ]; then
    codesign --force --sign "$signing_identity" \
        --identifier com.runanyways.RunAnywaysHelper \
        --options runtime --timestamp \
        "$staging_app/Contents/Library/HelperTools/RunAnywaysHelper"
    codesign --force --sign "$signing_identity" \
        --identifier com.runanyways.RunAnyways \
        --options runtime --timestamp \
        "$staging_app"
    helper_team="$(codesign -dv --verbose=4 "$staging_app/Contents/Library/HelperTools/RunAnywaysHelper" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    app_team="$(codesign -dv --verbose=4 "$staging_app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    if [ "$helper_team" != "$signing_team" ] || [ "$app_team" != "$signing_team" ]; then
        printf 'The app and helper did not receive the configured signing team ID.\n' >&2
        exit 1
    fi
else
    codesign --force --sign - --identifier com.runanyways.RunAnywaysHelper \
        "$staging_app/Contents/Library/HelperTools/RunAnywaysHelper"
    codesign --force --sign - --identifier com.runanyways.RunAnyways "$staging_app"
fi

plutil -lint "$staging_app/Contents/Info.plist"
plutil -lint "$staging_app/Contents/Library/LaunchDaemons/com.runanyways.RunAnywaysHelper.plist"
codesign --verify --strict --deep "$staging_app"

if [ -e "$output_app" ] || [ -L "$output_app" ]; then
    if [ -L "$output_app" ] || [ ! -d "$output_app" ]; then
        printf 'Refusing to replace non-directory or symlink at %s\n' "$output_app" >&2
        exit 1
    fi
    existing_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$output_app/Contents/Info.plist" 2>/dev/null || true)"
    if [ "$existing_identifier" != "com.runanyways.RunAnyways" ]; then
        printf 'Refusing to replace an app bundle with an unexpected identifier at %s\n' "$output_app" >&2
        exit 1
    fi
    rm -rf "$output_app"
fi
mv "$staging_app" "$output_app"

if [ -n "$signing_identity" ]; then
    printf 'Built signed %s app: %s\n' "$configuration" "$output_app"
else
    printf 'Built ad-hoc signed %s development app: %s\n' "$configuration" "$output_app"
    printf 'Before enabling the privileged helper, run scripts/install-local.sh, then register the helper from the app.\n'
fi
