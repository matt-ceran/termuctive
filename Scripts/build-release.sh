#!/bin/zsh

set -euo pipefail

script_directory=${0:A:h}
repository_root=${script_directory:h}
developer_directory=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
derived_data_path=${TERMUCTIVE_DERIVED_DATA_PATH:-$repository_root/.build/release-derived-data}
signing_identity=${TERMUCTIVE_CODE_SIGN_IDENTITY:-}

if [[ -z $signing_identity ]]; then
    signing_identity=$(
        /usr/bin/security find-identity -v -p codesigning \
            | /usr/bin/awk '/^[[:space:]]*[0-9]+\)/ { print $2; exit }'
    )
fi

if [[ -z $signing_identity ]]; then
    print -u2 'Termuctive Release builds require a stable code-signing identity.'
    print -u2 'Install an Apple Development or Developer ID certificate, or set TERMUCTIVE_CODE_SIGN_IDENTITY.'
    exit 1
fi

DEVELOPER_DIR=$developer_directory /usr/bin/xcodebuild build -quiet \
    -project "$repository_root/Termuctive.xcodeproj" \
    -scheme Termuctive \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived_data_path" \
    ARCHS='arm64 x86_64' \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO

application="$derived_data_path/Build/Products/Release/Termuctive.app"
executable="$application/Contents/MacOS/Termuctive"

[[ -d $application ]]
/usr/bin/lipo "$executable" -verify_arch arm64 x86_64
/usr/bin/codesign --force --sign "$signing_identity" --timestamp=none "$application"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$application"

designated_requirement=$(/usr/bin/codesign -d -r- "$application" 2>&1)
if [[ $designated_requirement == *'cdhash '* ]]; then
    print -u2 'The Release application still has a hash-only designated requirement.'
    print -u2 'Refusing to produce an identity that would repeatedly invalidate macOS privacy consent.'
    exit 1
fi

print -- "$designated_requirement"
print -- "SIGNED_APP=$application"
