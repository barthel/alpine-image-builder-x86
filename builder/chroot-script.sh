#!/bin/sh
# Runs inside the Alpine chroot under busybox ash — POSIX sh only.
set -ex

ALPINE_MINOR="$(echo "${ALPINE_VERSION}" | cut -d. -f1,2)"

### Package repositories

cat > /etc/apk/repositories << EOF
https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_MINOR}/main
https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_MINOR}/community
EOF

apk update

### initramfs features (must be set before the kernel package generates initramfs)
# The base rootfs (alpine-os-rootfs) is container-focused and ships without a
# hardware-boot mkinitfs.conf. Set the features explicitly so that the initramfs
# includes ext4, USB storage, SCSI, NVMe and other hardware drivers needed to
# find and mount the root partition on real hardware.

mkdir -p /etc/mkinitfs
printf 'features="ata base cdrom ext4 keymap kms mmc nvme raid scsi usb virtio"\n' \
  > /etc/mkinitfs/mkinitfs.conf

### Kernel

apk add --no-cache linux-lts

### Regenerate initramfs with hardware-boot features
# apk's post-install trigger may run mkinitfs before our conf takes full effect
# (no /proc inside chroot). Calling mkinitfs explicitly ensures ext4, usb, scsi
# etc. are included regardless of trigger ordering.
KVER=$(find /lib/modules -mindepth 1 -maxdepth 1 -type d | head -n 1)
KVER="${KVER##*/}"
mkinitfs -c /etc/mkinitfs/mkinitfs.conf "${KVER}"

### GRUB EFI bootloader

apk add --no-cache grub grub-efi

### Docker CE

apk add --no-cache \
  docker \
  docker-cli-compose \
  docker-openrc

### cloud-init

apk add --no-cache \
  cloud-init \
  cloud-init-openrc \
  e2fsprogs \
  e2fsprogs-extra

### Enable OpenRC services

# sysfs, cgroups: added to runlevels by build.sh (from the build host, after
# the chroot exits) because rc-update detects the Docker build environment via
# /proc cgroup namespace and silently skips keyword -docker services.
rc-update add docker default

# cloud-init runs in four ordered stages
for svc in cloud-init-local cloud-init cloud-config cloud-final; do
  rc-update add "${svc}" default 2>/dev/null || true
done

### cloud-init: link seed files from ESP (/boot/efi on the running system)

mkdir -p /var/lib/cloud/seed/nocloud-net
ln -sf /boot/efi/user-data      /var/lib/cloud/seed/nocloud-net/user-data
ln -sf /boot/efi/meta-data      /var/lib/cloud/seed/nocloud-net/meta-data
ln -sf /boot/efi/network-config /var/lib/cloud/seed/nocloud-net/network-config

### GRUB EFI installation
#
# --target=x86_64-efi / i386-efi: EFI application for 64-bit and 32-bit UEFI firmware
# --efi-directory=/boot/efi: the mounted ESP
# --removable: write to EFI/BOOT/BOOTX64.EFI / BOOTIA32.EFI (removable media path)
# --no-nvram: skip UEFI NVRAM writes (not accessible from chroot)
# grub.cfg is written by builder/build.sh after the chroot exits (needs ROOT_PARTUUID).
#
# Both files share the same grub/grub.cfg on the ESP.
# BOOTX64.EFI: standard x86_64 UEFI (LattePanda Alpha/Delta, most PCs)
# BOOTIA32.EFI: 32-bit UEFI firmware (LattePanda v1 / Bay Trail / Cherry Trail)

grub-install \
  --target=x86_64-efi \
  --efi-directory=/boot/efi \
  --removable \
  --no-nvram

grub-install \
  --target=i386-efi \
  --efi-directory=/boot/efi \
  --removable \
  --no-nvram

### OS identification

printf 'ALPINE_DEVICE="LattePanda"\n' >> /etc/os-release
printf 'ALPINE_IMAGE_VERSION="%s"\n' "${VERSION}" >> /etc/os-release

### Clean up

rm -rf /var/cache/apk/*
