ISO ?= out/gentoo-panther-lake-amd64.iso
OVMF ?= /usr/share/OVMF/OVMF_CODE.fd

.PHONY: build check boot-bios boot-uefi
build:
	sudo ./build.sh

check:
	test -s "$(ISO)"
	xorriso -indev "$(ISO)" -report_el_torito plain -report_system_area plain

boot-bios: check
	qemu-system-x86_64 -enable-kvm -m 2048 -cdrom "$(ISO)" -boot d

boot-uefi: check
	test -r "$(OVMF)"
	qemu-system-x86_64 -enable-kvm -m 2048 -bios "$(OVMF)" -cdrom "$(ISO)" -boot d
