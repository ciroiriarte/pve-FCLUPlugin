#!/usr/bin/env bash
#
# make-obs-source.sh - Build a Debian "3.0 (native)" source package from git HEAD
#                      without requiring dpkg-dev on the build host.
#
# Produces, under build/obs/ :
#   <pkg>_<version>.tar.xz    the full source tree at HEAD (including debian/)
#   <pkg>_<version>.dsc       Debian source control (with checksums)
#
# These two files are what OBS (obs.opensuse.org) consumes to build the .debs.
# The version is taken from debian/changelog (authoritative for Debian). This repo
# is a single NATIVE source package (pve-fclu) producing multiple binaries
# (pve-fclu-core, pve-fclu-hitachi, pve-fclu) — see ARCHITECTURE.md §11.
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
OUT="$ROOT/build/obs"

# The tarball comes from `git archive HEAD`, but versions/fields are read from the
# working tree; a dirty debian/ or version.mk would desync the .dsc from what is
# archived (OBS would then reject the mismatched source).
if ! git diff --quiet HEAD -- debian version.mk; then
  echo "error: uncommitted changes to debian/ or version.mk; commit first" >&2
  exit 1
fi

# --- identifiers from debian/changelog + control ---------------------------
PKG="$(sed -n '1s/^\([a-z0-9.+-]*\) .*/\1/p' debian/changelog)"
VERSION="$(sed -n '1s/^[^(]*(\([^)]*\)).*/\1/p' debian/changelog)"   # native: no -rev
case "$VERSION" in
  *-*) echo "error: version '$VERSION' has a Debian revision; this repo is 3.0 (native)" >&2; exit 1 ;;
esac

MAINT="$(sed -n 's/^Maintainer: //p' debian/control)"
STDVER="$(sed -n 's/^Standards-Version: //p' debian/control)"
# All binary package names (the Package: lines), comma-joined for the .dsc Binary field.
BINS="$(sed -n 's/^Package: //p' debian/control | paste -sd',' - | sed 's/,/, /g')"
# Build-Depends may span indented continuation lines; fold to one.
BDEPS="$(awk '
  /^Build-Depends:/    { g=1; sub(/^Build-Depends:[ \t]*/,""); printf "%s",$0; next }
  g && /^[ \t]+[^ \t]/ { sub(/^[ \t]+/,""); printf " %s",$0; next }
  g                    { exit }
' debian/control | sed -e 's/[[:space:]]\+/ /g' -e 's/ *, */, /g' -e 's/^ //; s/ $//')"

echo ">> $PKG  native version=$VERSION  binaries: $BINS"
rm -rf "$OUT"; mkdir -p "$OUT"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# --- 1. native tarball: the whole tracked tree at HEAD (incl. debian/) ------
# Deterministic (sorted, fixed owner, mtime from the HEAD commit) so identical
# source produces byte-identical tarballs.
MTIME="$(git show -s --format=%cI HEAD)"
git archive --format=tar --prefix="$PKG-$VERSION/" HEAD | tar -x -C "$WORK"
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="$MTIME" \
    -C "$WORK" -cJf "$OUT/${PKG}_${VERSION}.tar.xz" "$PKG-$VERSION"

# --- 2. the .dsc -----------------------------------------------------------
TARBALL="${PKG}_${VERSION}.tar.xz"
DSC="$OUT/${PKG}_${VERSION}.dsc"

field() { # algo file -> " <sum> <size> <name>"
  local sum
  case "$1" in
    md5)    sum=$(md5sum    "$OUT/$2" | cut -d' ' -f1) ;;
    sha1)   sum=$(sha1sum   "$OUT/$2" | cut -d' ' -f1) ;;
    sha256) sum=$(sha256sum "$OUT/$2" | cut -d' ' -f1) ;;
  esac
  printf ' %s %s %s\n' "$sum" "$(stat -c%s "$OUT/$2")" "$2"
}

{
  echo "Format: 3.0 (native)"
  echo "Source: $PKG"
  echo "Binary: $BINS"
  echo "Architecture: all"
  echo "Version: $VERSION"
  echo "Maintainer: $MAINT"
  echo "Standards-Version: $STDVER"
  echo "Build-Depends: $BDEPS"
  echo "Package-List:"
  sed -n 's/^Package: \(.*\)/ \1 deb admin optional arch=all/p' debian/control
  echo "Checksums-Sha1:";   field sha1   "$TARBALL"
  echo "Checksums-Sha256:"; field sha256 "$TARBALL"
  echo "Files:";            field md5    "$TARBALL"
} > "$DSC"

echo ">> wrote:"; ls -l "$OUT"
