#!/bin/bash
set -u
# Runs as root, after package/install.sh has succeeded. It does not change kexts, GPU
# bundles, firmware, kernel collections, EFI/OpenCore, or boot-args. A failure here
# leaves that install in place and does not delete it.
PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH
HERE=$(cd "$(dirname "$0")" && pwd)
FORK_VERSION=v2.4.2-v0.3
APP_NAME="GPU Control.app"
DEST_APP="/Applications/$APP_NAME"
SUPPORT="/Library/Application Support/GPU Control"
BINDIR="$SUPPORT/bin"
CTL_NAME=nvmtlctl
VERSION_FILE=/Library/NullMoth/fork-version
APP_STAGE=""; APP_PREV=""; CTL_TMP=""; CTL_PREV=""; CTL_REPLACED=0; HASH_TMP=""; HASH_PUBLISHED=0; VER_TMP=""; CHECK=""; APP_COPIED=0

die() {
  echo "   STOP: $*" >&2
  echo "   The upstream driver install was not changed." >&2
  echo "   Fix the problem and run this script again: sudo ./fork-install.sh" >&2
  echo "   To remove only the pieces this script adds: sudo ./fork-uninstall.sh" >&2
  exit 1
}
step() { echo; echo "== $*"; }; ok() { echo "   ok  $*"; }
restore_previous_app() {
  if [ -n "$APP_PREV" ] && [ -d "$APP_PREV/$APP_NAME" ] && [ ! -e "$DEST_APP" ]; then
    mv "$APP_PREV/$APP_NAME" "$DEST_APP" || echo "   STOP: the previous app is still at $APP_PREV/$APP_NAME; move it back to $DEST_APP by hand." >&2
  fi
}
cleanup_temps() {
  status=$?
  restore_previous_app
  if [ "$status" -ne 0 ] && [ "$CTL_REPLACED" = 1 ]; then
    if [ -n "$CTL_PREV" ]; then
      mv -f "$CTL_PREV" "$BINDIR/$CTL_NAME" || echo "   STOP: the previous nvmtlctl is still at $CTL_PREV; move it back to $BINDIR/$CTL_NAME by hand." >&2
      CTL_PREV=""
    else
      rm -f "$BINDIR/$CTL_NAME"
    fi
    if [ "$HASH_PUBLISHED" = 1 ]; then rm -f "$BINDIR/$CTL_NAME.sha256"; fi
  elif [ -n "$CTL_PREV" ]; then
    rm -f "$CTL_PREV"
  fi
  [ -z "$APP_STAGE" ] || rm -rf "$APP_STAGE"
  [ -z "$CTL_TMP" ] || rm -f "$CTL_TMP"
  [ -z "$HASH_TMP" ] || rm -f "$HASH_TMP"
  [ -z "$VER_TMP" ] || rm -f "$VER_TMP"
  [ -z "$CHECK" ] || rm -rf "$CHECK"
  if [ -n "$APP_PREV" ] && [ -d "$DEST_APP" ]; then rm -rf "$APP_PREV"; fi
}
trap cleanup_temps EXIT
trap 'echo "   STOP: fork installer interrupted" >&2; exit 1' HUP INT TERM

[ "$(id -u)" -eq 0 ] || die "run with sudo"
[ "$#" -eq 0 ] || die "expected no arguments"
step "1. checks"
[ -L /Library/NullMoth ] && die "/Library/NullMoth is a symlink; not writing a version there"
[ -d /Library/NullMoth ] || die "no /Library/NullMoth yet. Run sudo ./install.sh first and let it finish; nothing was written"
meta=$(stat -f '%u %Lp' /Library/NullMoth 2>/dev/null) || die "cannot inspect /Library/NullMoth"
case "$meta" in
  "0 "[0-7][0-7][0-7]|"0 "[0-7][0-7][0-7][0-7]) ;;
  *) die "/Library/NullMoth is not a root-owned directory";;
esac
perm=${meta#* }
[ $((8#$perm & 022)) -eq 0 ] || die "/Library/NullMoth is writable by another account or group"
[ -L /Applications ] && die "/Applications is a symlink"
[ -d /Applications ] || die "/Applications is not a directory"
[ -L "/Library/Application Support" ] && die "/Library/Application Support is a symlink"
[ -d "/Library/Application Support" ] || die "/Library/Application Support is missing"
meta=$(stat -f '%u %Lp' "/Library/Application Support" 2>/dev/null) || die "cannot inspect /Library/Application Support"
case "$meta" in
  "0 "[0-7][0-7][0-7]|"0 "[0-7][0-7][0-7][0-7]) ;;
  *) die "/Library/Application Support is not a root-owned directory";;
esac
perm=${meta#* }
[ $((8#$perm & 002)) -eq 0 ] || die "/Library/Application Support is writable by every account"
if [ -e "$SUPPORT" ]; then
  [ -L "$SUPPORT" ] && die "$SUPPORT is a symlink; remove it by hand and run this script again"
  [ -d "$SUPPORT" ] || die "$SUPPORT exists and is not a directory"
fi
if [ -e "$BINDIR" ]; then
  [ -L "$BINDIR" ] && die "$BINDIR is a symlink; remove it by hand and run this script again"
  [ -d "$BINDIR" ] || die "$BINDIR exists and is not a directory"
fi
if [ -e "$BINDIR/$CTL_NAME" ] || [ -L "$BINDIR/$CTL_NAME" ]; then
  [ -L "$BINDIR/$CTL_NAME" ] && die "$BINDIR/$CTL_NAME is a symlink; remove it by hand and run this script again"
  [ -f "$BINDIR/$CTL_NAME" ] || die "$BINDIR/$CTL_NAME exists and is not a regular file"
fi
if [ -e "$BINDIR/$CTL_NAME.sha256" ] || [ -L "$BINDIR/$CTL_NAME.sha256" ]; then
  [ -L "$BINDIR/$CTL_NAME.sha256" ] && die "$BINDIR/$CTL_NAME.sha256 is a symlink; remove it by hand and run this script again"
fi
if [ -e "$VERSION_FILE" ] || [ -L "$VERSION_FILE" ]; then
  [ -L "$VERSION_FILE" ] && die "$VERSION_FILE is a symlink; remove it by hand and run this script again"
  [ -f "$VERSION_FILE" ] || die "$VERSION_FILE exists and is not a regular file"
fi
if [ -e "$DEST_APP" ] || [ -L "$DEST_APP" ]; then
  [ -L "$DEST_APP" ] && die "$DEST_APP is a symlink; remove it by hand and run this script again"
  [ -d "$DEST_APP" ] || die "$DEST_APP exists and is not an app bundle"
fi

SRC_CTL=""
if [ -e "$HERE/$CTL_NAME" ] || [ -L "$HERE/$CTL_NAME" ]; then
  SRC_CTL="$HERE/$CTL_NAME"
elif [ -d "$HERE/$APP_NAME" ] && [ ! -L "$HERE/$APP_NAME" ]; then
  for rel in "Contents/Resources/$CTL_NAME" "Contents/MacOS/$CTL_NAME"; do
    if [ -e "$HERE/$APP_NAME/$rel" ] || [ -L "$HERE/$APP_NAME/$rel" ]; then SRC_CTL="$HERE/$APP_NAME/$rel"; break; fi
  done
fi
[ -n "$SRC_CTL" ] || die "no $CTL_NAME next to this script (or inside $APP_NAME). Place that binary beside fork-install.sh and run this script again"
[ -L "$SRC_CTL" ] && die "$SRC_CTL is a symlink; a root copy has to be a regular file"
[ -f "$SRC_CTL" ] || die "$SRC_CTL is not a regular file"
[ -s "$SRC_CTL" ] || die "$SRC_CTL is empty"
ok "fork version $FORK_VERSION; $CTL_NAME found; upstream driver files will not be modified"

step "2. GPU Control.app"
if [ ! -e "$HERE/$APP_NAME" ] && [ ! -L "$HERE/$APP_NAME" ]; then
  echo "   skip  $APP_NAME is not next to this script, so it was not copied to /Applications"
elif [ -L "$HERE/$APP_NAME" ]; then
  die "$HERE/$APP_NAME is a symlink; not copying it"
elif [ ! -d "$HERE/$APP_NAME" ]; then
  die "$HERE/$APP_NAME is not an app bundle"
elif [ ! -f "$HERE/$APP_NAME/Contents/Info.plist" ]; then
  die "$HERE/$APP_NAME has no Contents/Info.plist"
else
  while IFS= read -r -d '' link; do
    target=$(readlink "$link") || die "cannot read a link inside $APP_NAME"
    case "$target" in
      /*|..|../*|*/..|*/../*) die "the app holds a link that leaves the bundle: ${link#"$HERE/$APP_NAME/"}";;
    esac
  done < <(find "$HERE/$APP_NAME" -type l -print0)
  APP_STAGE=$(mktemp -d /var/tmp/gpu-control-app.XXXXXX) || die "cannot stage the app"
  ditto "$HERE/$APP_NAME" "$APP_STAGE/$APP_NAME" || die "cannot copy $APP_NAME into a private stage"
  if [ -d "$DEST_APP" ]; then
    APP_PREV=$(mktemp -d /var/tmp/gpu-control-prev.XXXXXX) || die "cannot hold the app already in /Applications"
    mv "$DEST_APP" "$APP_PREV/$APP_NAME" || die "cannot move the existing app aside; it is still at $DEST_APP"
  fi
  if ! mv "$APP_STAGE/$APP_NAME" "$DEST_APP"; then
    restore_previous_app
    die "cannot publish $DEST_APP"
  fi
  APP_COPIED=1
  ok "copied to $DEST_APP"
  echo "   note  $APP_NAME is unsigned. This script does not sign it, notarize it, or remove the quarantine flag."
  echo "   note  First open: right-click the app, choose Open, then Open. Or System Settings → Privacy & Security → Open Anyway."
fi

step "3. root-owned nvmtlctl"
own_dir() {
  [ -L "$1" ] && die "$1 is a symlink"
  if [ ! -e "$1" ]; then mkdir -m 755 "$1" || die "cannot create $1"; fi
  [ -d "$1" ] || die "$1 is not a directory"
  chown root:wheel "$1" && chmod 755 "$1" || die "cannot set root:wheel 755 on $1"
  meta=$(stat -f '%Su:%Sg %Lp' "$1" 2>/dev/null) || die "cannot verify $1"
  [ "$meta" = "root:wheel 755" ] || die "$1 is $meta, wanted root:wheel 755"
  entry=$(ls -lde "$1" 2>/dev/null | head -1 | awk '{print $1}')
  case "$entry" in *+*) die "$1 has access-control entries; review them by hand";; esac
}
own_dir "$SUPPORT"
own_dir "$BINDIR"
CTL_TMP=$(mktemp "$BINDIR/.nvmtlctl.XXXXXX") || die "cannot create a private copy of $CTL_NAME"
cp "$SRC_CTL" "$CTL_TMP" || die "cannot copy $CTL_NAME"
chown root:wheel "$CTL_TMP" && chmod 755 "$CTL_TMP" || die "cannot set root:wheel 755 on the $CTL_NAME copy"
sum=$(shasum -a 256 "$CTL_TMP") || die "cannot hash the $CTL_NAME copy"
sum=${sum%% *}
printf '%s\n' "$sum" | grep -Eq '^[0-9a-f]{64}$' || die "hash of $CTL_NAME is not a sha256"
CHECK=$(mktemp -d "$BINDIR/.nvmtlctl-check.XXXXXX") || die "cannot check the $CTL_NAME hash"
cp "$CTL_TMP" "$CHECK/$CTL_NAME" || die "cannot stage the hash check"
printf '%s  %s\n' "$sum" "$CTL_NAME" > "$CHECK/$CTL_NAME.sha256" || die "cannot write the staged hash"
(cd "$CHECK" && shasum -a 256 --strict -c "$CTL_NAME.sha256" --quiet) || die "the private $CTL_NAME copy failed its hash check"
rm -rf "$CHECK"; CHECK=""
if [ -f "$BINDIR/$CTL_NAME" ]; then
  have=$(shasum -a 256 "$BINDIR/$CTL_NAME") || die "cannot hash the installed $CTL_NAME"
  have=${have%% *}
  if [ "$have" = "$sum" ]; then
    rm -f "$CTL_TMP"; CTL_TMP=""
    chown root:wheel "$BINDIR/$CTL_NAME" && chmod 755 "$BINDIR/$CTL_NAME" || die "cannot set root:wheel 755 on $CTL_NAME"
  fi
fi
if [ -n "$CTL_TMP" ]; then
  if [ -f "$BINDIR/$CTL_NAME" ]; then
    CTL_PREV=$(mktemp "$BINDIR/.nvmtlctl.prev.XXXXXX") || die "cannot keep the previous $CTL_NAME"
    mv -f "$BINDIR/$CTL_NAME" "$CTL_PREV" || die "cannot move the installed $CTL_NAME aside"
  fi
  mv -f "$CTL_TMP" "$BINDIR/$CTL_NAME" || die "cannot publish $BINDIR/$CTL_NAME"
  CTL_TMP=""; CTL_REPLACED=1
fi
[ -L "$BINDIR/$CTL_NAME" ] && die "published $CTL_NAME is a symlink"
got=$(shasum -a 256 "$BINDIR/$CTL_NAME") || die "cannot re-hash the published $CTL_NAME"
got=${got%% *}
[ "$got" = "$sum" ] || die "published $CTL_NAME hash does not match the copy"
meta=$(stat -f '%Su:%Sg %Lp' "$BINDIR/$CTL_NAME" 2>/dev/null) || die "cannot verify $CTL_NAME"
[ "$meta" = "root:wheel 755" ] || die "$BINDIR/$CTL_NAME is $meta, wanted root:wheel 755"
HASH_TMP=$(mktemp "$BINDIR/.nvmtlctl.sha256.XXXXXX") || die "cannot record the $CTL_NAME hash"
printf '%s  %s\n' "$sum" "$CTL_NAME" > "$HASH_TMP" || die "cannot write the hash file"
chown root:wheel "$HASH_TMP" && chmod 644 "$HASH_TMP" || die "cannot set permissions on the hash file"
mv -f "$HASH_TMP" "$BINDIR/$CTL_NAME.sha256" || die "cannot publish the hash file"
HASH_TMP=""; HASH_PUBLISHED=1
(cd "$BINDIR" && shasum -a 256 --strict -c "$CTL_NAME.sha256" --quiet) || die "nvmtlctl.sha256 does not match the published binary"
if [ -n "$CTL_PREV" ]; then rm -f "$CTL_PREV"; CTL_PREV=""; fi
CTL_REPLACED=0
ok "$BINDIR/$CTL_NAME"
echo "   note  The app must run this copy only. A copy inside the app bundle or under a user-writable directory is not the one installed here."

step "4. fork version"
VER_TMP=$(mktemp /Library/NullMoth/.fork-version.XXXXXX) || die "cannot write $VERSION_FILE"
printf '%s\n' "$FORK_VERSION" > "$VER_TMP" || die "cannot record $FORK_VERSION"
chown root:wheel "$VER_TMP" && chmod 644 "$VER_TMP" || die "cannot set permissions on $VERSION_FILE"
mv -f "$VER_TMP" "$VERSION_FILE" || die "cannot publish $VERSION_FILE"
VER_TMP=""
read_back=$(head -n 1 "$VERSION_FILE") || die "cannot read $VERSION_FILE"
[ "$read_back" = "$FORK_VERSION" ] || die "$VERSION_FILE does not contain $FORK_VERSION"
ok "$VERSION_FILE contains $FORK_VERSION"

step "5. boot-check LaunchDaemon"
echo "   skip  no separate boot-check LaunchDaemon source is in this repo."
echo "   skip  upstream install.sh already writes com.nullmoth.lastgood and com.nullmoth.bootguard. This script does not add another."
ok "no fork daemon installed"

echo
echo "Done. Upstream's driver files were left as install.sh wrote them."
if [ "$APP_COPIED" = 1 ]; then
  echo "GPU Control is at $DEST_APP (unsigned; see the note above)."
else
  echo "GPU Control.app was not in this folder, so /Applications was not changed."
fi
echo "nvmtlctl is $BINDIR/$CTL_NAME"
echo "Undo these pieces only: sudo ./fork-uninstall.sh"
echo "The driver itself is still removed with: sudo ./uninstall.sh"
