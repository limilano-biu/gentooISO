# Gentoo Panther Lake live CD builder

This repository remasters Gentoo's **official amd64 minimal installation ISO** and
updates its live environment with Gentoo's newest binary kernel, Linux firmware,
Intel microcode, and Sound Open Firmware.  It deliberately keeps the upstream
ISO's BIOS/UEFI boot layout instead of inventing a new installer.

## Requirements

Run on an x86-64 Linux host with at least 12 GiB free.  The builder needs root,
network access, and these host tools:

* `bash`, `curl`, `gpg`, `sha512sum`, and `mount`
* `xorriso` and `unsquashfs`/`mksquashfs` (package `squashfs-tools`)

The downloaded ISO is checked against Gentoo's OpenPGP-signed DIGESTS file. The
signing key is fetched into a repository-local keyring from Gentoo's WKD; an
already-populated keyring can instead be supplied for an offline/restricted host.

## Build

```sh
sudo ./build.sh
```

The result is `out/gentoo-panther-lake-amd64.iso`.  Useful overrides are:

```sh
sudo MIRROR=https://your.gentoo.mirror/gentoo \
  OUTPUT=/var/tmp/gentoo-ptl.iso \
  JOBS=8 ./build.sh
```

`SOURCE_ISO=/path/to/install-amd64-minimal.iso` skips the ISO download. In this
case put its matching `*.DIGESTS` beside it; verification is never silently
disabled. `KEEP_WORK=1` retains the work directory for debugging.

The live root is updated using a temporary Portage sync and `~amd64` only for the
hardware-enablement packages in `config/package.accept_keywords`. This provides
the newest Gentoo-packaged kernel/firmware without globally converting the live
environment to testing. The new kernel and initramfs installed by
`gentoo-kernel-bin` replace the ISO boot payload, while xorriso replays the
official image's El Torito boot configuration.

## Test

Check the image metadata and both boot paths (QEMU packages are optional):

```sh
make check ISO=out/gentoo-panther-lake-amd64.iso
make boot-bios ISO=out/gentoo-panther-lake-amd64.iso
make boot-uefi ISO=out/gentoo-panther-lake-amd64.iso OVMF=/usr/share/OVMF/OVMF_CODE.fd
```

The QEMU targets are interactive. On Panther Lake hardware, additionally confirm
that `dmesg` has no missing-firmware messages and inspect `lscpu`, `lsmod`, and
`/lib/firmware` before installing.

## Security and scope

The script must run as root because it mounts pseudo-filesystems for the chroot.
Its cleanup trap unmounts them even after a failed build. Secure Boot is not
added: the resulting kernel is distributed by Gentoo but the remastered ISO is
not signed with Microsoft's UEFI trust chain. Intel microcode is loaded by Linux
from the installed firmware; systems may still need a vendor BIOS update for
platform initialization.
