#!/bin/zsh

set -euo pipefail

disk_image=${1:-}
temporary_root=
mounted=false

fail() {
    print -u2 -- "$1"
    exit 1
}

cleanup() {
    if [[ $mounted == true ]]; then
        /usr/bin/hdiutil detach "$temporary_root/mount" -quiet || true
    fi
    if [[ -n $temporary_root && -d $temporary_root ]]; then
        /bin/rm -rf "$temporary_root"
    fi
}

trap cleanup EXIT INT TERM HUP

[[ -n $disk_image ]] || fail 'Usage: Scripts/verify-distribution.sh <Termuctive.dmg>'
[[ -f $disk_image ]] || fail "Disk image not found: $disk_image"

disk_image_directory=${disk_image:h}
disk_image_name=${disk_image:t}
disk_image="$(cd "$disk_image_directory" && pwd)/$disk_image_name"

DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer} \
    /usr/bin/xcrun stapler validate "$disk_image"
/usr/sbin/spctl --assess --type open --context context:primary-signature \
    --verbose=4 "$disk_image"

temporary_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/termuctive-verify.XXXXXX")
/bin/mkdir "$temporary_root/mount"
/usr/bin/hdiutil attach -readonly -nobrowse -mountpoint "$temporary_root/mount" \
    "$disk_image" -quiet
mounted=true

application="$temporary_root/mount/Termuctive.app"
executable="$application/Contents/MacOS/Termuctive"

[[ -d $application ]] || fail 'The disk image does not contain Termuctive.app.'
[[ -f $application/Contents/Resources/LICENSE ]] \
    || fail 'The application is missing the Termuctive license.'
[[ -f $application/Contents/Resources/THIRD_PARTY_NOTICES.md ]] \
    || fail 'The application is missing third-party license notices.'
/usr/bin/codesign --verify --deep --strict --verbose=2 "$application"
/usr/bin/lipo "$executable" -verify_arch arm64 x86_64

signature_details=$(/usr/bin/codesign -d --verbose=4 "$application" 2>&1)
[[ $signature_details == *'Authority=Developer ID Application:'* ]] \
    || fail 'The application is not signed with Developer ID Application.'
[[ $signature_details == *'runtime'* ]] \
    || fail 'The application is missing the hardened runtime signature flag.'
[[ $signature_details == *'Timestamp='* ]] \
    || fail 'The application signature is missing a secure timestamp.'

minimum_version_count=$(
    /usr/bin/otool -l "$executable" \
        | /usr/bin/awk '$1 == "minos" && $2 == "14.0" { count += 1 } END { print count + 0 }'
)
[[ $minimum_version_count == 2 ]] \
    || fail 'Both executable slices must target macOS 14.0.'

DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer} \
    /usr/bin/xcrun stapler validate "$application"
/usr/sbin/spctl --assess --type execute --verbose=4 "$application"

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$application/Contents/Info.plist")
bundle_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$application/Contents/Info.plist")
[[ $bundle_identifier == com.mattceran.termuctive ]] \
    || fail "Unexpected bundle identifier: $bundle_identifier"

print -- "VERIFIED_VERSION=$version"
print -- 'VERIFIED_ARCHITECTURES=arm64 x86_64'
print -- 'VERIFIED_MINIMUM_MACOS=14.0'
