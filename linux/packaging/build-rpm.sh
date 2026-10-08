#!/bin/bash
# Builds the MD Lite RPM from this working tree into linux/dist/.
set -euo pipefail
cd "$(dirname "$0")/../.."
VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' linux/Cargo.toml | head -1)
NAME=md-lite
TOP=$(mktemp -d)
trap 'rm -rf "$TOP"' EXIT
mkdir -p "$TOP"/{SOURCES,SPECS,BUILD,RPMS,SRPMS}
# The tarball holds what the GTK build needs: the crate, its data, and the shared resources.
tar --transform "s,^,$NAME-$VERSION/," --exclude='linux/target' --exclude='linux/dist' \
    -czf "$TOP/SOURCES/$NAME-$VERSION.tar.gz" \
    LICENSE README.md CHANGELOG.md Resources/Mermaid linux
cp linux/packaging/md-lite.spec "$TOP/SPECS/"
# A rustup toolchain satisfies the build but not RPM's cargo/rust dependencies.
NODEPS=()
if ! rpm -q cargo >/dev/null 2>&1 && command -v cargo >/dev/null; then
    echo "Using $(cargo --version) from rustup; skipping RPM build dependency checks."
    NODEPS=(--nodeps)
fi
rpmbuild --define "_topdir $TOP" "${NODEPS[@]}" -ba "$TOP/SPECS/md-lite.spec"
mkdir -p linux/dist
cp "$TOP"/RPMS/*/*.rpm "$TOP"/SRPMS/*.rpm linux/dist/
ls -1 linux/dist/
