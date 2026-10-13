#!/bin/sh
# Installs this Termuctive server toolkit into /opt/termuctive and, unless
# --install-only is given, runs server setup with the remaining arguments.
# Must run as root (Termuctive invokes it through sudo).
set -eu

if [ "$(id -u)" -ne 0 ]; then
    echo "bootstrap.sh must run as root." >&2
    exit 1
fi

source_directory=$(cd "$(dirname "$0")" && pwd)
version=$(cat "$source_directory/VERSION")
case "$version" in
    *[!0-9.]* | "") echo "Invalid toolkit version: $version" >&2; exit 1 ;;
esac

if ! command -v python3 >/dev/null 2>&1; then
    echo "==> Installing Python"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3
fi

install_root=/opt/termuctive
destination="$install_root/versions/$version"
mkdir -p "$install_root/versions" "$install_root/bin"
rm -rf "$destination.tmp"
cp -R "$source_directory" "$destination.tmp"
rm -rf "$destination"
mv "$destination.tmp" "$destination"

cat > "$install_root/bin/tmc.tmp" <<'EOF'
#!/bin/sh
exec /opt/termuctive/current/bin/tmc "$@"
EOF
mv "$install_root/bin/tmc.tmp" "$install_root/bin/tmc"
ln -sfn "versions/$version" "$install_root/current.tmp"
mv -T "$install_root/current.tmp" "$install_root/current"
ln -sfn "$install_root/bin/tmc" /usr/local/bin/tmc

chown -R root:root "$install_root"
chmod -R u=rwX,go=rX "$install_root"
chmod 0755 "$install_root/bin/tmc" "$destination/bin/tmc"

echo "==> Termuctive toolkit $version installed"

if [ "${1:-}" = "--install-only" ]; then
    exit 0
fi
exec "$install_root/bin/tmc" setup "$@"
