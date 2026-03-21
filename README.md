# alpine-image-builder-x86

Builds a bootable disk image with AlpineOS for x86_64 UEFI systems (e.g. LattePanda).
Based on the rootfs from
[alpine-os-rootfs](https://github.com/barthel/alpine-os-rootfs).

## What the image contains

- Alpine Linux base rootfs (x86_64)
- Kernel: `linux-lts`
- Bootloader: GRUB EFI (`grub-efi`, installed to `EFI/BOOT/BOOTX64.EFI` — removable media path)
- Docker CE with OpenRC service enabled
- cloud-init (NoCloud datasource, seeded from the ESP at `/boot/efi`)
- OpenRC init system

## Disk layout

| Partition | Filesystem | Size | Mount point | Contents |
|---|---|---|---|---|
| 1 (ESP) | FAT32 | 256 MiB | `/boot/efi` | GRUB EFI, grub.cfg, cloud-init seed files |
| 2 | ext4 | ~1.75 GiB | `/` | Alpine rootfs |

GPT partition table. The ESP carries the `esp` flag so any UEFI firmware finds it.
GRUB boots the kernel by `PARTUUID` — no dependency on partition numbering or disk labels.

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

### Push to Docker Hub

On `PUSH=true`, two images are pushed:

| Image | Platform | Use |
|---|---|---|
| `uwebarthel/alpine-image-builder-x86:<version>` | `linux/amd64`, `linux/arm64` | Builder image (CI) |
| `uwebarthel/alpineos-x86:<version>` | `linux/amd64` | Disk image distribution |

Extract the image zip from Docker Hub:
```bash
cid=$(docker create uwebarthel/alpineos-x86:latest)
docker cp "${cid}:/image/image.img.zip" .
docker rm "${cid}"
```

## Flashing

Write the image to a USB drive or SSD. On macOS:

```bash
unzip alpineos-x86-<version>.img.zip
sudo dd if=alpineos-x86-<version>.img of=/dev/rdiskN bs=4m status=progress
```

Or use [alpine-flash](https://github.com/barthel/alpine-flash) /
[cloud-init-server's `flash-sd-card.sh`](https://gitea.fritz.box/fritz.box/cloud-init-server)
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
    # ...
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
Dockerfile              Builder container (Debian bookworm + loop-device tools, no QEMU needed)
build.sh                Outer build: pulls rootfs-x86_64.tar.gz, runs builder container, optional push
versions.config         Pinned ALPINE_VERSION (set by build.sh into container env)
builder/
  build.sh              Creates disk image: GPT partition, ESP format, extract rootfs, chroot, GRUB install, grub.cfg
  chroot-script.sh      apk installs: linux-lts, grub-efi, docker, cloud-init; grub-install; seed symlinks
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
  config.yml            CI pipeline: shellcheck → build → GitHub Release
```
