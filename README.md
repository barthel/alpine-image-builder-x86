# alpine-image-builder-x86

Builds a bootable disk image with AlpineOS for x86_64 UEFI systems (e.g. LattePanda).
Based on the rootfs from
[alpine-os-rootfs](https://github.com/barthel/alpine-os-rootfs).

## What the image contains

- Alpine Linux base rootfs (x86_64)
- Kernel: `linux-lts`
- Bootloader: GRUB EFI — both `EFI/BOOT/BOOTX64.EFI` (64-bit UEFI) and
  `EFI/BOOT/BOOTIA32.EFI` (32-bit UEFI, LattePanda v1 / Bay Trail / Cherry Trail)
- Docker CE with OpenRC service enabled
- cloud-init (NoCloud datasource, seeded from the ESP at `/boot/efi`)
- OpenRC init system

## Disk layout

| Partition | Filesystem | Size | Mount point | Contents |
|---|---|---|---|---|
| 1 (ESP) | FAT32 | 256 MiB | `/boot/efi` | GRUB EFI binaries, cloud-init seed files |
| 2 | ext4 | ~1.5 GiB | `/` | Alpine rootfs, kernel, initramfs, GRUB modules + config |

GPT partition table. The root partition is labeled `root`; the kernel is booted via
`root=LABEL=root`.

### GRUB config location

`grub-install` (without `--boot-directory`) places GRUB modules and reads its config from
`/boot/grub/grub.cfg` on the **root ext4 partition** — not from the ESP. The EFI binaries
on the ESP only bootstrap the loader; they then search for a partition containing
`/boot/grub/grub.cfg` and load the config from there.

### Kernel cmdline

```
root=LABEL=root rootfstype=ext4 modules=ext4 fsck.repair=yes rootwait nomodeset
```

- `modules=ext4` — Alpine's initramfs init only auto-loads storage drivers (usb, scsi,
  nvme, ata), not filesystem modules. `ext4` is a loadable module in `linux-lts`
  (not built-in), so it must be explicitly requested before the root mount.
- `nomodeset` — prevents the Intel i915 KMS driver from resetting the EFI framebuffer
  resolution during boot. Required to keep a readable console on small displays.

### 32-bit UEFI (LattePanda v1 / Bay Trail / Cherry Trail)

The LattePanda v1 (Atom Z8350) has a 32-bit UEFI firmware despite its 64-bit CPU.
It loads `EFI/BOOT/BOOTIA32.EFI` and ignores `BOOTX64.EFI`. Both files share the same
`/boot/grub/grub.cfg`.

Alpine's `grub` package only ships `x86_64-efi` modules. The `i386-efi` modules
required for `grub-install --target=i386-efi` come from Debian (`grub-efi-ia32-bin`),
pulled in via a dedicated stage in the multi-stage Dockerfile:

```dockerfile
FROM --platform=linux/amd64 debian:bookworm-slim AS grub-ia32
RUN apt-get install -y --no-install-recommends grub-efi-ia32-bin
```

The `--platform=linux/amd64` flag is required because `grub-efi-ia32-bin` is not
available for arm64 Debian (used by Apple Silicon CI runners).

### initramfs

The base `alpine-os-rootfs` image is container-focused and ships without hardware-boot
mkinitfs features. `chroot-script.sh` writes `/etc/mkinitfs/mkinitfs.conf` with
hardware features **before** installing `linux-lts`, then calls mkinitfs explicitly
afterwards with `-o /boot/initramfs-lts` to overwrite the file GRUB loads:

```sh
mkinitfs -c /etc/mkinitfs/mkinitfs.conf -o /boot/initramfs-lts "${KVER}"
```

Without `-o /boot/initramfs-lts`, mkinitfs writes to `/boot/initramfs-<fullversion>`
(e.g. `/boot/initramfs-6.6.79-0-lts`) which GRUB never reads.

## Prerequisites

- Docker

## Build

```bash
# Local build (dirty tag)
./build.sh

# Versioned build
VERSION=3.21.0 ./build.sh

# Versioned build + push to Docker Hub
VERSION=3.21.0 PUSH=true ./build.sh
```

Output: `alpineos-x86-<version>.img.zip` + `.sha256` in the project root.
Tests run automatically at the end of each build.

### Versioning

Versions follow the Alpine version: `MAJOR.MINOR.BUILD`.
`BUILD` starts at 0 and increments with each change while on the same Alpine minor.

## Flashing

Write the image to a USB drive or SD card. On macOS:

```bash
unzip alpineos-x86-<version>.img.zip
sudo dd if=alpineos-x86-<version>.img of=/dev/rdiskN bs=4m status=progress
```

Or use [cloud-init-server's `flash-sd-card.sh`](https://gitea.fritz.box/fritz.box/cloud-init-server)
which downloads the image automatically based on the board type in `boards.yaml`.

## First boot

### Default credentials

| Setting | Value |
|---|---|
| Default hostname | `black-pearl` |
| Default user | `admin` |
| Password | *none set* — SSH key required, or add `plain_text_passwd:` to user-data |
| SSH password auth | enabled (`ssh_pwauth: true`) |
| sudo | passwordless |

Add your SSH public key to `builder/files/boot/user-data` before building:

```yaml
users:
  - name: admin
    ssh_authorized_keys:
      - ssh-ed25519 AAAA...
```

Or mount the ESP and edit `/boot/efi/user-data` after writing the image.

### Network

DHCP is configured automatically on `eth0`. The image boots without any configuration.
For WiFi or static IP, edit `builder/files/boot/network-config`.

## cloud-init

Seed files on the ESP are linked to the NoCloud datasource:

| File | Mount path | Purpose |
|---|---|---|
| `/boot/efi/user-data` | ESP | cloud-config: hostname, users, write_files, runcmd |
| `/boot/efi/meta-data` | ESP | instance-id |
| `/boot/efi/network-config` | ESP | network configuration |

The ESP is FAT32 and accessible from macOS/Linux without mounting the ext4 root.
Edit these files on the disk to customise the first boot.

## CI / Release

CircleCI builds and tests the image on every push and every tag.
On a tag push, the image zip is published as a GitHub Release:

- `alpineos-x86.img.zip` — stable name (for `/latest/download/` support)
- `alpineos-x86.img.zip.sha256`

The pipeline uses contexts `github` (for `GITHUB_USER`) and `Docker Hub`
(for `DOCKER_USER` / `DOCKER_PASS`).

## Repository structure

```
Dockerfile              Multi-stage: Debian (i386-efi modules) + Alpine builder
build.sh                Outer build: pulls rootfs tarball, runs builder container, optional push
versions.config         Pinned ALPINE_VERSION
builder/
  build.sh              Disk image: GPT, ESP format, rootfs extract, chroot, grub.cfg
  chroot-script.sh      apk: linux-lts, grub-efi, docker, cloud-init; mkinitfs; grub-install
  files/
    boot/
      user-data         Default cloud-init user-data
      meta-data         cloud-init instance-id
      network-config    cloud-init network config (eth0 DHCP)
    etc/
      cloud/
        cloud.cfg       cloud-init config (distro: alpine, NoCloud datasource)
  test/
    spec_helper.rb      Test helper
    image_spec.rb       Verifies image zip exists
    os-release_spec.rb  Verifies image archive contents
.circleci/
  config.yml            CI: shellcheck → build (incl. initramfs ext4.ko check) → GitHub Release
.pre-commit-config.yaml shellcheck pre-commit hook
```
