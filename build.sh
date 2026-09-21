#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
MIRROR=${MIRROR:-https://distfiles.gentoo.org}
OUTPUT=${OUTPUT:-$PWD/out/gentoo-panther-lake-amd64.iso}
WORKDIR=${WORKDIR:-$PWD/.work}
JOBS=${JOBS:-$(nproc)}
KEEP_WORK=${KEEP_WORK:-0}
KEYRING=${KEYRING:-$WORKDIR/gnupg}
readonly INDEX=latest-install-amd64-minimal.txt

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
log() { printf '\n==> %s\n' "$*"; }
need() { command -v "$1" >/dev/null || die "missing required command: $1"; }

mounts=()
cleanup() {
  local i
  for ((i=${#mounts[@]}-1; i>=0; i--)); do umount -R "${mounts[i]}" 2>/dev/null || true; done
  [[ $KEEP_WORK == 1 ]] || rm -rf "$WORKDIR/root" "$WORKDIR/iso-tree"
}
trap cleanup EXIT INT TERM

[[ $EUID == 0 ]] || die 'run as root (sudo ./build.sh)'
for c in curl gpg sha512sum xorriso unsquashfs mksquashfs mount chroot sort; do need "$c"; done
mkdir -p "$WORKDIR/download" "$WORKDIR/root" "$WORKDIR/iso-tree" "$(dirname "$OUTPUT")" "$KEYRING"
chmod 700 "$KEYRING"

base="$MIRROR/releases/amd64/autobuilds"
if [[ -z ${SOURCE_ISO:-} ]]; then
  log 'Resolving the latest official minimal ISO'
  curl --fail --location --retry 3 "$base/$INDEX" -o "$WORKDIR/$INDEX"
  rel=$(awk '!/^#/ && /install-amd64-minimal-[0-9]+T[0-9]+Z\.iso([[:space:]]|$)/ {print $1; exit}' "$WORKDIR/$INDEX")
  [[ -n $rel && $rel != /* && $rel != *..* ]] || die 'could not parse a safe ISO path from the Gentoo index'
  SOURCE_ISO="$WORKDIR/download/${rel##*/}"
  curl --fail --location --retry 3 "$base/$rel" -o "$SOURCE_ISO"
  curl --fail --location --retry 3 "$base/$rel.DIGESTS" -o "$SOURCE_ISO.DIGESTS"
else
  SOURCE_ISO=$(readlink -f "$SOURCE_ISO")
  [[ -f $SOURCE_ISO && -f $SOURCE_ISO.DIGESTS ]] || die 'SOURCE_ISO and its adjacent .DIGESTS are required'
fi

log 'Authenticating the source ISO'
if ! gpg --homedir "$KEYRING" --list-keys releng@gentoo.org >/dev/null 2>&1; then
  gpg --homedir "$KEYRING" --auto-key-locate clear,wkd --locate-keys releng@gentoo.org
fi
gpg --homedir "$KEYRING" --verify "$SOURCE_ISO.DIGESTS"
(cd "$(dirname "$SOURCE_ISO")" && awk '/^# SHA512 HASH/{on=1; next} /^#/{on=0} on && $2==name {print; found=1} END{exit !found}' name="$(basename "$SOURCE_ISO")" "$(basename "$SOURCE_ISO").DIGESTS" | sha512sum -c -)

log 'Extracting ISO and live root'
xorriso -osirrox on -indev "$SOURCE_ISO" -extract / "$WORKDIR/iso-tree"
[[ -f $WORKDIR/iso-tree/image.squashfs ]] || die 'source ISO has no /image.squashfs'
unsquashfs -d "$WORKDIR/root" "$WORKDIR/iso-tree/image.squashfs"
for setting in package.accept_keywords package.license; do
  target="$WORKDIR/root/etc/portage/$setting"
  if [[ -f $target ]]; then
    mv "$target" "$target.upstream"
    mkdir -p "$target"
    mv "$target.upstream" "$target/00-upstream"
  fi
  install -Dm644 "$SCRIPT_DIR/config/$setting" "$target/panther-lake"
done
printf 'MAKEOPTS="-j%s"\n' "$JOBS" >> "$WORKDIR/root/etc/portage/make.conf"
rm -f "$WORKDIR/root/etc/resolv.conf"
install -m644 /etc/resolv.conf "$WORKDIR/root/etc/resolv.conf"
mkdir -p "$WORKDIR/root/run"

for fs in dev proc sys; do
  mount --rbind "/$fs" "$WORKDIR/root/$fs"; mount --make-rslave "$WORKDIR/root/$fs"; mounts+=("$WORKDIR/root/$fs")
done
mount -t tmpfs tmpfs "$WORKDIR/root/run"; mounts+=("$WORKDIR/root/run")

log 'Installing the latest Panther Lake enablement packages'
chroot "$WORKDIR/root" /bin/bash -eux <<'CHROOT'
emerge --sync
emerge --update --newuse --deep --with-bdeps=y \
  sys-kernel/gentoo-kernel-bin sys-kernel/linux-firmware \
  sys-firmware/intel-microcode sys-firmware/sof-firmware
CHROOT

for ((i=${#mounts[@]}-1; i>=0; i--)); do umount -R "${mounts[i]}"; done
mounts=()

kernel=$(find "$WORKDIR/root/boot" -maxdepth 1 -type f -name 'vmlinuz-*' -printf '%f\n' | sort -V | tail -1)
initrd=$(find "$WORKDIR/root/boot" -maxdepth 1 -type f \( -name 'initramfs-*' -o -name 'initrd-*' \) -printf '%f\n' | sort -V | tail -1)
[[ -n $kernel && -n $initrd ]] || die 'gentoo-kernel-bin did not install both a kernel and initramfs'
install -m644 "$WORKDIR/root/boot/$kernel" "$WORKDIR/iso-tree/boot/gentoo"
install -m644 "$WORKDIR/root/boot/$initrd" "$WORKDIR/iso-tree/boot/gentoo.igz"

log 'Packing live root and replaying the official boot configuration'
rm -f "$WORKDIR/iso-tree/image.squashfs"
mksquashfs "$WORKDIR/root" "$WORKDIR/iso-tree/image.squashfs" -comp xz -b 1M -noappend -processors "$JOBS"
rm -f "$OUTPUT"
xorriso -indev "$SOURCE_ISO" -outdev "$OUTPUT" -update_r "$WORKDIR/iso-tree" / -boot_image any replay -commit
sha512sum "$OUTPUT" > "$OUTPUT.sha512"
log "Built $OUTPUT"
