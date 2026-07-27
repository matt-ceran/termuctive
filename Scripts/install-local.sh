#!/bin/zsh

set -euo pipefail

script_directory=${0:A:h}
repository_root=${script_directory:h}
install_directory=${TERMUCTIVE_INSTALL_DIRECTORY:-$HOME/Applications}
derived_data_path=${TERMUCTIVE_LOCAL_DERIVED_DATA_PATH:-$repository_root/.build/local-derived-data}
destination="$install_directory/Termuctive.app"
staging_root=
backup_root=
installed_new_bundle=false
installation_complete=false

fail() {
    print -u2 -- "$1"
    exit 1
}

cleanup() {
    if [[ $installation_complete == false && $installed_new_bundle == true && -e $destination ]]; then
        /bin/mv "$destination" "$staging_root/Termuctive.failed.app"
    fi
    if [[ $installation_complete == false && -n $backup_root && -e $backup_root/Termuctive.app ]]; then
        /bin/mv "$backup_root/Termuctive.app" "$destination"
    fi
    if [[ -n $staging_root && -d $staging_root ]]; then
        /bin/rm -rf "$staging_root"
    fi
    if [[ -n $backup_root && -d $backup_root ]]; then
        /bin/rm -rf "$backup_root"
    fi
}

trap cleanup EXIT INT TERM HUP

[[ $install_directory == /* ]] || fail 'TERMUCTIVE_INSTALL_DIRECTORY must be absolute.'

if [[ $install_directory == "$HOME/Applications" || $install_directory == /Applications ]]; then
    if /usr/bin/pgrep -x Termuctive >/dev/null; then
        fail 'Quit Termuctive before replacing the installed application.'
    fi
fi

TERMUCTIVE_LOCAL_DERIVED_DATA_PATH=$derived_data_path "$script_directory/build-local.sh"

source_application="$derived_data_path/Build/Products/Release/Termuctive.app"
[[ -d $source_application ]] || fail 'The local build output is missing.'

/bin/mkdir -p "$install_directory"
staging_root=$(/usr/bin/mktemp -d "$install_directory/.termuctive-install.XXXXXX")
/usr/bin/ditto "$source_application" "$staging_root/Termuctive.app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$staging_root/Termuctive.app"

if [[ -e $destination ]]; then
    backup_root=$(/usr/bin/mktemp -d "$install_directory/.termuctive-backup.XXXXXX")
    /bin/mv "$destination" "$backup_root/Termuctive.app"
fi

/bin/mv "$staging_root/Termuctive.app" "$destination"
installed_new_bundle=true
/usr/bin/codesign --verify --deep --strict --verbose=2 "$destination"
installation_complete=true

if [[ -n $backup_root && -d $backup_root ]]; then
    /bin/rm -rf "$backup_root"
    backup_root=
fi

launch_services_database=$(
    /usr/bin/find /System/Library/Frameworks/CoreServices.framework \
        -name lsregister -type f -print -quit
)
if [[ -n $launch_services_database ]]; then
    "$launch_services_database" -f "$destination"
fi

print -- "INSTALLED_APP=$destination"
