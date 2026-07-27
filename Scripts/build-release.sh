#!/bin/zsh

set -euo pipefail

script_directory=${0:A:h}
repository_root=${script_directory:h}
developer_directory=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
derived_data_path=${TERMUCTIVE_DERIVED_DATA_PATH:-$repository_root/.build/release-derived-data}
signing_identity=${TERMUCTIVE_CODE_SIGN_IDENTITY:-}
signing_mode=${TERMUCTIVE_SIGNING_MODE:-development}

fail() {
    print -u2 -- "$1"
    exit 1
}

case $signing_mode in
    development | distribution) ;;
    *) fail "Unknown Termuctive signing mode: $signing_mode" ;;
esac

if [[ -z $signing_identity ]]; then
    if [[ $signing_mode == distribution ]]; then
        signing_identity=$(
            /usr/bin/security find-identity -v -p codesigning \
                | /usr/bin/awk -F '"' '/Developer ID Application:/ { print $2; exit }'
        )
    else
        signing_identity=$(
            /usr/bin/security find-identity -v -p codesigning \
                | /usr/bin/awk '/^[[:space:]]*[0-9]+\)/ { print $2; exit }'
        )
    fi
fi

if [[ -z $signing_identity ]]; then
    if [[ $signing_mode == distribution ]]; then
        fail 'Termuctive distribution builds require a Developer ID Application certificate.'
    fi
    fail 'Termuctive Release builds require a stable code-signing identity.'
fi

DEVELOPER_DIR=$developer_directory /usr/bin/xcodebuild build -quiet \
    -project "$repository_root/Termuctive.xcodeproj" \
    -scheme Termuctive \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived_data_path" \
    ARCHS='arm64 x86_64' \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO

application="$derived_data_path/Build/Products/Release/Termuctive.app"
executable="$application/Contents/MacOS/Termuctive"

[[ -d $application ]]
/usr/bin/lipo "$executable" -verify_arch arm64 x86_64

typeset -a signing_arguments
signing_arguments=(--force --sign "$signing_identity" --options runtime)
if [[ $signing_mode == distribution ]]; then
    signing_arguments+=(--timestamp)
else
    signing_arguments+=(--timestamp=none)
fi

/usr/bin/codesign "${signing_arguments[@]}" "$application"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$application"

signature_details=$(/usr/bin/codesign -d --verbose=4 "$application" 2>&1)
if [[ $signature_details != *'runtime'* ]]; then
    fail 'The Release application is missing the hardened runtime signature flag.'
fi
if [[ $signing_mode == distribution && $signature_details != *'Authority=Developer ID Application:'* ]]; then
    fail 'The distribution application is not signed with Developer ID Application.'
fi

designated_requirement=$(/usr/bin/codesign -d -r- "$application" 2>&1)
if [[ $designated_requirement == *'cdhash '* ]]; then
    fail 'The Release application still has a hash-only designated requirement.'
fi

print -- "$designated_requirement"
print -- "SIGNING_MODE=$signing_mode"
print -- "SIGNED_APP=$application"
