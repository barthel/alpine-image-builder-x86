ARG BASE_TAG=latest

### Stage 1: Debian for i386-efi GRUB modules
# Alpine's grub package ships x86_64-efi modules only; i386-efi (needed for
# 32-bit UEFI firmware on LattePanda v1 / Bay Trail / Cherry Trail) comes from Debian.
FROM debian:bookworm-slim AS grub-ia32
RUN apt-get update \
 && apt-get install -y --no-install-recommends grub-efi-ia32-bin \
 && rm -rf /var/lib/apt/lists/*

### Stage 2: Alpine-based builder
FROM uwebarthel/alpine-image-builder:${BASE_TAG}

# grub-efi and linux-lts are installed inside the target rootfs chroot;
# the build container itself only needs the partitioning/loop tools already
# provided by the base image.
# zerofree zeroes out free ext4 blocks before compression (better zip ratio).
RUN apk add --no-cache zerofree

# i386-efi GRUB modules — for 32-bit UEFI (LattePanda v1 / Bay Trail / Cherry Trail).
# Copied into the Alpine chroot by build.sh before running chroot-script.sh,
# so that grub-install --target=i386-efi works inside the chroot.
COPY --from=grub-ia32 /usr/lib/grub/i386-efi /usr/lib/grub/i386-efi

COPY builder /builder/

CMD ["/builder/build.sh"]
