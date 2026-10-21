#!/bin/bash
set -u
# Removes only what package/fork-install.sh adds. It does not touch /Library/Extensions,
# /Library/GPUBundles, kernel collections, firmware, EFI/OpenCore, nvram, or boot-args,
# and it does not remove the LaunchDaemons upstream's install.sh writes.
PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH
APP_NAME="GPU Control.app"
DEST_APP="/Applications/$APP_NAME"
SUPPORT="/Library/Application Support/GPU Control"
BINDIR="$SUPPORT/bin"
VERSION_FILE=/Library/NullMoth/fork-version
FAIL=0

die() { echo "STOP: $*" >&2; exit 1; }
step() { echo; echo "== $*"; }; ok() { echo "   ok  $*"; }
mark() { echo "   STOP: $*" >&2; FAIL=1; }

[ "$(id -u)" -eq 0 ] || die "run with sudo"
[ "$#" -eq 0 ] || die "expected no arguments"

step "1. GPU Control.app"
if [ -L "$DEST_APP" ]; then
  mark "$DEST_APP is a symlink; left in place. Remove that link by hand if it should go."
elif [ -d "$DEST_APP" ]; then
  rm -rf "$DEST_APP" || mark "could not remove $DEST_APP"
  [ -e "$DEST_APP" ] || ok "removed $DEST_APP"
elif [ -e "$DEST_APP" ]; then
  mark "$DEST_APP is not an app bundle; left in place"
else
  ok "no $DEST_APP"
fi

step "2. root bin directory"
if [ -L "$BINDIR" ]; then
  mark "$BINDIR is a symlink; left in place. Remove it by hand if it is leftover."
elif [ -d "$BINDIR" ]; then
  for base in nvmtlctl nvmtlctl.sha256; do
    path="$BINDIR/$base"
    if [ -L "$path" ]; then
      mark "$path is a symlink; left in place. Remove that link by hand."
    elif [ -e "$path" ]; then
      rm -f "$path" || mark "could not remove $path"
    fi
  done
  for path in "$BINDIR"/.nvmtlctl.* "$BINDIR"/.nvmtlctl-check.*; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    if [ -L "$path" ]; then mark "$path is a symlink; left in place."; continue; fi
    if [ -d "$path" ]; then rm -rf "$path" || mark "could not remove $path"
    else rm -f "$path" || mark "could not remove $path"
    fi
  done
  leftover=$(find "$BINDIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true)
  if [ ! -e "$BINDIR/nvmtlctl" ] && [ ! -e "$BINDIR/nvmtlctl.sha256" ]; then
    if [ -z "$leftover" ]; then
      rmdir "$BINDIR" || mark "could not remove empty $BINDIR"
      [ -e "$BINDIR" ] || ok "removed $BINDIR"
    else
      echo "   note  $BINDIR still holds other files, so the directory was kept"
      ok "removed nvmtlctl and nvmtlctl.sha256"
    fi
  fi
else
  ok "no $BINDIR"
fi
if [ -d "$SUPPORT" ] && [ ! -L "$SUPPORT" ]; then
  leftover=$(find "$SUPPORT" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true)
  if [ -z "$leftover" ]; then
    rmdir "$SUPPORT" || mark "could not remove empty $SUPPORT"
    [ -e "$SUPPORT" ] || ok "removed empty $SUPPORT"
  fi
fi

step "3. fork version"
for path in /Library/NullMoth/.fork-version.*; do
  [ -e "$path" ] || [ -L "$path" ] || continue
  if [ -L "$path" ]; then mark "$path is a symlink; left in place."; continue; fi
  [ -f "$path" ] && { rm -f "$path" || mark "could not remove $path"; }
done
if [ -L "$VERSION_FILE" ]; then
  mark "$VERSION_FILE is a symlink; left in place. Remove it by hand."
elif [ -f "$VERSION_FILE" ]; then
  rm -f "$VERSION_FILE" || mark "could not remove $VERSION_FILE"
  [ -e "$VERSION_FILE" ] || ok "removed $VERSION_FILE"
elif [ -e "$VERSION_FILE" ]; then
  mark "$VERSION_FILE is not a regular file; left in place"
else
  ok "no $VERSION_FILE"
fi

step "4. fork LaunchDaemon"
echo "   skip  fork-install.sh does not install a boot-check daemon."
echo "   skip  com.nullmoth.lastgood and com.nullmoth.bootguard belong to upstream's installer and were left in place."
ok "no fork daemon to remove"

echo
if [ "$FAIL" -ne 0 ]; then
  echo "STOP: some fork pieces are still installed. Nothing under /Library/Extensions, /Library/GPUBundles, EFI, or boot-args was changed." >&2
  echo "Fix the error above and run: sudo ./fork-uninstall.sh" >&2
  exit 1
fi
echo "Fork pieces removed. The NVIDIA driver is still installed."
echo "To remove the driver, run upstream's uninstaller from this folder:"
echo "  sudo ./uninstall.sh"
echo "  sudo shutdown -r now"
echo "This script did not change /Library/Extensions, /Library/GPUBundles, EFI/OpenCore, or boot-args."
