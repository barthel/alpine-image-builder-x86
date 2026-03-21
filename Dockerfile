ARG BASE_TAG=latest
FROM uwebarthel/alpine-image-builder:${BASE_TAG}

# grub-efi and linux-lts are installed inside the target rootfs chroot;
# the build container itself only needs the partitioning/loop tools already
# provided by the base image.
# zerofree zeroes out free ext4 blocks before compression (better zip ratio).
RUN apk add --no-cache zerofree

COPY builder /builder/

CMD ["/builder/build.sh"]
