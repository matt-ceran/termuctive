#!/bin/zsh

set -euo pipefail

script_directory=${0:A:h}
repository_root=${script_directory:h}
developer_directory=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
output_directory=${TERMUCTIVE_RELEASE_OUTPUT_DIRECTORY:-$repository_root/dist}
derived_data_path=${TERMUCTIVE_DERIVED_DATA_PATH:-$repository_root/.build/release-derived-data}
signing_identity=${TERMUCTIVE_CODE_SIGN_IDENTITY:-}
notary_profile=${TERMUCTIVE_NOTARY_KEYCHAIN_PROFILE:-}
notary_key=${TERMUCTIVE_NOTARY_KEY:-}
notary_key_id=${TERMUCTIVE_NOTARY_KEY_ID:-}
notary_issuer_id=${TERMUCTIVE_NOTARY_ISSUER_ID:-}
release_tag=${TERMUCTIVE_RELEASE_TAG:-}
temporary_root=

fail() {
    print -u2 -- "$1"
    exit 1
}

cleanup() {
    if [[ -n $temporary_root && -d $temporary_root ]]; then
        /bin/rm -rf "$temporary_root"
    fi
}

trap cleanup EXIT INT TERM HUP

version=$(
    /usr/bin/awk '$1 == "MARKETING_VERSION:" { gsub(/"/, "", $2); print $2; exit }' \
        "$repository_root/project.yml"
)
[[ -n $version ]] || fail 'Could not read MARKETING_VERSION from project.yml.'

if [[ -n $release_tag && $release_tag != "v$version" ]]; then
    fail "Release tag $release_tag does not match MARKETING_VERSION $version."
fi

[[ -n $signing_identity ]] \
    || fail 'TERMUCTIVE_CODE_SIGN_IDENTITY must name a Developer ID Application identity.'

typeset -a notary_arguments
if [[ -n $notary_profile ]]; then
    notary_arguments=(--keychain-profile "$notary_profile")
else
    [[ -f $notary_key ]] || fail 'TERMUCTIVE_NOTARY_KEY must name an App Store Connect API key.'
    [[ -n $notary_key_id ]] || fail 'TERMUCTIVE_NOTARY_KEY_ID is required.'
    notary_arguments=(--key "$notary_key" --key-id "$notary_key_id")
    if [[ -n $notary_issuer_id ]]; then
        notary_arguments+=(--issuer "$notary_issuer_id")
    fi
fi

notarize() {
    local item=$1
    local result
    local status
    local submission_id

    result=$(
        DEVELOPER_DIR=$developer_directory /usr/bin/xcrun notarytool submit "$item" \
            --wait --output-format json "${notary_arguments[@]}"
    )
    print -- "$result"

    status=$(print -r -- "$result" | /usr/bin/plutil -extract status raw -o - -)
    if [[ $status != Accepted ]]; then
        submission_id=$(print -r -- "$result" | /usr/bin/plutil -extract id raw -o - -)
        DEVELOPER_DIR=$developer_directory /usr/bin/xcrun notarytool log "$submission_id" \
            "${notary_arguments[@]}" || true
        fail "Apple notarization returned status: $status"
    fi
}

TERMUCTIVE_SIGNING_MODE=distribution \
    TERMUCTIVE_CODE_SIGN_IDENTITY=$signing_identity \
    TERMUCTIVE_DERIVED_DATA_PATH=$derived_data_path \
    DEVELOPER_DIR=$developer_directory \
    "$script_directory/build-release.sh"

application="$derived_data_path/Build/Products/Release/Termuctive.app"
[[ -d $application ]] || fail 'The signed Release application is missing.'

bundle_version=$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
        "$application/Contents/Info.plist"
)
[[ $bundle_version == $version ]] \
    || fail "Bundle version $bundle_version does not match MARKETING_VERSION $version."

temporary_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/termuctive-release.XXXXXX")
submission_archive="$temporary_root/Termuctive-$version.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$application" "$submission_archive"
notarize "$submission_archive"

DEVELOPER_DIR=$developer_directory /usr/bin/xcrun stapler staple "$application"
DEVELOPER_DIR=$developer_directory /usr/bin/xcrun stapler validate "$application"

disk_image_root="$temporary_root/disk-image"
/bin/mkdir "$disk_image_root"
/usr/bin/ditto "$application" "$disk_image_root/Termuctive.app"
/bin/cp "$repository_root/LICENSE" "$disk_image_root/LICENSE"
/bin/cp "$repository_root/THIRD_PARTY_NOTICES.md" "$disk_image_root/THIRD_PARTY_NOTICES.md"
/bin/ln -s /Applications "$disk_image_root/Applications"

disk_image="$temporary_root/Termuctive-$version-universal.dmg"
/usr/bin/hdiutil create -quiet -ov -format UDZO -fs HFS+ \
    -volname "Termuctive $version" -srcfolder "$disk_image_root" "$disk_image"

/usr/bin/codesign --force --sign "$signing_identity" --timestamp "$disk_image"
/usr/bin/codesign --verify --verbose=2 "$disk_image"
notarize "$disk_image"

DEVELOPER_DIR=$developer_directory /usr/bin/xcrun stapler staple "$disk_image"
DEVELOPER_DIR=$developer_directory /usr/bin/xcrun stapler validate "$disk_image"

/bin/mkdir -p "$output_directory"
final_disk_image="$output_directory/${disk_image:t}"
/usr/bin/ditto "$disk_image" "$final_disk_image"
"$script_directory/verify-distribution.sh" "$final_disk_image"

(
    cd "$output_directory"
    /usr/bin/shasum -a 256 "${final_disk_image:t}" > "${final_disk_image:t}.sha256"
)

print -- "RELEASE_DMG=$final_disk_image"
print -- "RELEASE_CHECKSUM=$final_disk_image.sha256"
