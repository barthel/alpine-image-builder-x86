#!/bin/bash
set -ex

# This script must run inside a container only.
if [ ! -f /.dockerenv ] && [ ! -f /.containerenv ] && [ ! -f /run/.containerenv ]; then
  echo "ERROR: script works in Docker/Podman only!"
  exit 1
fi

# shellcheck disable=SC1091
source /workspace/versions.config

### Variables

# /workspace is a bind-mount from the host (virtiofs on macOS/Podman).
# Loop-device ioctls do NOT work on virtiofs-backed files, so all image
# operations happen in /work (container-local tmpfs).  Only the rootfs
# tarball is read from /workspace; the final zip is written back there.
BUILD_RESULT_PATH="/workspace"
WORK_PATH="/work"
BUILD_PATH="/build"

VERSION=${VERSION:-${CIRCLE_TAG:-latest}}
IMAGE_NAME="alpineos-x86-${VERSION}.img"
export VERSION

# Rootfs tarball is pre-fetched from Docker Hub (uwebarthel/alpine-os-rootfs:<version>)
# by build.sh before this container is started.
ROOTFS_TAR="rootfs-x86_64.tar.gz"
ROOTFS_TAR_PATH="${BUILD_RESULT_PATH}/${ROOTFS_TAR}"

echo "CIRCLE_TAG=${CIRCLE_TAG:-}"
echo "Building image: ${IMAGE_NAME}"

### Verify rootfs tarball is present

if [ ! -f "${ROOTFS_TAR_PATH}" ]; then
  echo "ERROR: rootfs tarball not found at ${ROOTFS_TAR_PATH}" >&2
  echo "       Run build.sh to pull it from Docker Hub first." >&2
  exit 1
fi

### Create blank disk image (container-local — virtiofs does not support losetup)

mkdir -p "${WORK_PATH}"
IMAGE_PATH="${WORK_PATH}/${IMAGE_NAME}"
rm -f "${IMAGE_PATH}"
# 1.75 GiB image: 256 MiB ESP + ~1.5 GiB root.
# cloud-init growpart+resizefs expands the root partition to fill the disk on first boot.
fallocate -l 1792M "${IMAGE_PATH}"

# Partition: GPT, ESP=FAT32 (256 MiB), root=ext4 (rest)
parted -s "${IMAGE_PATH}" \
  mklabel gpt \
  mkpart ESP fat32 4MiB 260MiB \
  mkpart root ext4  260MiB 100% \
  set 1 esp on

# Attach loop device and create partition devices
LOOP_DEV=$(losetup -f --show "${IMAGE_PATH}")
kpartx -as "${LOOP_DEV}"
LOOP_NAME=$(basename "${LOOP_DEV}")
BOOT_PART="/dev/mapper/${LOOP_NAME}p1"
ROOT_PART="/dev/mapper/${LOOP_NAME}p2"

# Retrieve per-partition PARTUUIDs (GPT uses per-partition GUIDs)
ESP_PARTUUID=$(blkid -s PARTUUID -o value "${BOOT_PART}")
ROOT_PARTUUID=$(blkid -s PARTUUID -o value "${ROOT_PART}")
export ESP_PARTUUID ROOT_PARTUUID

### Format partitions

mkfs.vfat -F 32 -n BOOT "${BOOT_PART}"
mkfs.ext4 -L root "${ROOT_PART}"

### Extract Alpine rootfs into root partition

mkdir -p "${BUILD_PATH}"
mount "${ROOT_PART}" "${BUILD_PATH}"
tar xf "${ROOTFS_TAR_PATH}" -C "${BUILD_PATH}"

# Mount ESP so that grub-install (run inside chroot) can write to it
mkdir -p "${BUILD_PATH}/boot/efi"
mount "${BOOT_PART}" "${BUILD_PATH}/boot/efi"

### Prepare chroot

# Ensure DNS resolves inside chroot
cp /etc/resolv.conf "${BUILD_PATH}/etc/resolv.conf"

# Copy builder file overlays
cp -R /builder/files/etc "${BUILD_PATH}/"

# Copy i386-efi GRUB modules into chroot.
# Alpine's grub package provides only x86_64-efi; i386-efi modules come from Debian
# via the multi-stage Dockerfile. chroot-script.sh calls grub-install for both targets.
mkdir -p "${BUILD_PATH}/usr/lib/grub"
cp -r /usr/lib/grub/i386-efi "${BUILD_PATH}/usr/lib/grub/"

# Mount pseudo filesystems
mkdir -p "${BUILD_PATH}"/{proc,sys,dev/pts}
mount -o bind /dev     "${BUILD_PATH}/dev"
mount -o bind /dev/pts "${BUILD_PATH}/dev/pts"
mount -t proc  none    "${BUILD_PATH}/proc"
mount -t sysfs none    "${BUILD_PATH}/sys"

### Run chroot script

chroot "${BUILD_PATH}" \
  /usr/bin/env \
  VERSION="${VERSION}" \
  ESP_PARTUUID="${ESP_PARTUUID}" \
  ROOT_PARTUUID="${ROOT_PARTUUID}" \
  ALPINE_VERSION="${ALPINE_VERSION}" \
  /bin/sh < /builder/chroot-script.sh

### Unmount pseudo filesystems

umount -lqn "${BUILD_PATH}/dev/pts" || true
umount -lqn "${BUILD_PATH}/dev"     || true
umount -lqn "${BUILD_PATH}/proc"    || true
umount -lqn "${BUILD_PATH}/sys"     || true

### Ensure Docker runlevel symlinks
# rc-update inside the chroot detects Docker and silently skips keyword -docker
# services. Create the symlinks directly from the build host.
mkdir -p "${BUILD_PATH}/etc/runlevels/sysinit"
ln -sf /etc/init.d/sysfs   "${BUILD_PATH}/etc/runlevels/sysinit/sysfs"
ln -sf /etc/init.d/cgroups "${BUILD_PATH}/etc/runlevels/sysinit/cgroups"

### Write GRUB config (needs ROOT_PARTUUID resolved here on build host)
# grub-install (without --boot-directory) places modules and config in
# /boot/grub/ on the ROOT partition — that is what GRUB actually reads at
# boot.  The EFI stub only bootstraps; it searches for /boot/grub/grub.cfg
# to find its real config.  Writing only to the ESP (/boot/efi/grub/grub.cfg)
# was ineffective: GRUB never consulted that file.
mkdir -p "${BUILD_PATH}/boot/grub"
cat > "${BUILD_PATH}/boot/grub/grub.cfg" << EOF
insmod gzio
insmod part_gpt
insmod ext2
insmod all_video

set gfxmode=640x480
set gfxpayload=keep

search --no-floppy --label --set=root root
linux /boot/vmlinuz-lts root=LABEL=root rootfstype=ext4 modules=ext4 fsck.repair=yes rootwait nomodeset net.ifnames=0 biosdevname=0
initrd /boot/initramfs-lts
boot
EOF

### Copy cloud-init seed files to ESP (readable on Mac/Linux via FAT32)

cp /builder/files/boot/user-data      "${BUILD_PATH}/boot/efi/"
cp /builder/files/boot/meta-data      "${BUILD_PATH}/boot/efi/"
cp /builder/files/boot/network-config "${BUILD_PATH}/boot/efi/"

### Unmount ESP

umount "${BUILD_PATH}/boot/efi"

### Write fstab (after ESP unmount, using PARTUUIDs)

cat >> "${BUILD_PATH}/etc/fstab" << EOF
PARTUUID=${ESP_PARTUUID}  /boot/efi  vfat  umask=0077,nofail  0 0
PARTUUID=${ROOT_PARTUUID} /          ext4  defaults,noatime   0 1
EOF

### Unmount root partition and release loop device

umount "${BUILD_PATH}"

# Zero out free ext4 blocks so that zip compression is effective.
# Must run after umount (filesystem must be unmounted).
zerofree "${ROOT_PART}"

kpartx -d "${LOOP_DEV}"
losetup -d "${LOOP_DEV}"

### Compress and checksum (still in /work — then copy to /workspace)

umask 0000
cd "${WORK_PATH}"
zip -9 "${IMAGE_NAME}.zip" "${IMAGE_NAME}"
sha256sum "${IMAGE_NAME}.zip" > "${IMAGE_NAME}.zip.sha256"
rm "${IMAGE_NAME}"
cp "${IMAGE_NAME}.zip"        "${BUILD_RESULT_PATH}/"
cp "${IMAGE_NAME}.zip.sha256" "${BUILD_RESULT_PATH}/"

### Run tests (from /workspace where the zip was copied)

cd "${BUILD_RESULT_PATH}"
VERSION="${VERSION}" rspec --format documentation --color /builder/test
