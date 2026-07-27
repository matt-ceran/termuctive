#!/bin/zsh

set -euo pipefail

script_directory=${0:A:h}
repository_root=${script_directory:h}
developer_directory=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
derived_data_path=${TERMUCTIVE_LOCAL_DERIVED_DATA_PATH:-$repository_root/.build/local-derived-data}
architecture=$(/usr/bin/uname -m)
system_version=$(/usr/bin/sw_vers -productVersion)
system_major_version=${system_version%%.*}

fail() {
    print -u2 -- "$1"
    exit 1
}

case $architecture in
    arm64 | x86_64) ;;
    *) fail "Unsupported Mac architecture: $architecture" ;;
esac

(( system_major_version >= 14 )) \
    || fail "Termuctive requires macOS 14 or newer. This Mac runs $system_version."

[[ -x $developer_directory/usr/bin/xcodebuild ]] \
    || fail "Full Xcode is required. Developer directory not found: $developer_directory"

DEVELOPER_DIR=$developer_directory /usr/bin/xcodebuild build -quiet \
    -project "$repository_root/Termuctive.xcodeproj" \
    -scheme Termuctive \
    -configuration Release \
    -destination "platform=macOS,arch=$architecture" \
    -derivedDataPath "$derived_data_path" \
    ARCHS="$architecture" \
    ONLY_ACTIVE_ARCH=YES \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO

application="$derived_data_path/Build/Products/Release/Termuctive.app"
executable="$application/Contents/MacOS/Termuctive"

[[ -d $application ]] || fail 'The local build did not produce Termuctive.app.'
/usr/bin/lipo "$executable" -verify_arch "$architecture"
/usr/bin/codesign --force --sign - --options runtime "$application"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$application"

print -- "LOCAL_ARCHITECTURE=$architecture"
print -- "LOCAL_APP=$application"
