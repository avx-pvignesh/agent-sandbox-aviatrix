#!/usr/bin/env bash
# Host bootstrap for the agent-containment reference design (Ubuntu 24.04 on AWS).
# Run as root, during the SETUP phase (DCF rule 20 enabled). Idempotent-ish.
#
#   sudo KATA_VERSION=3.x.y KATA_SHA256=<digest> ./bootstrap.sh
#
set -euo pipefail

# Pin a 3.x release (Go runtime + Firecracker). Get the digest GitHub recorded for the asset:
#   curl -s https://api.github.com/repos/kata-containers/kata-containers/releases/tags/$V \
#     | jq -r '.assets[] | select(.name|test("amd64.tar")) | "\(.name) \(.digest)"'
KATA_VERSION="${KATA_VERSION:?set KATA_VERSION, e.g. 3.32.0}"
KATA_SHA256="${KATA_SHA256:?set KATA_SHA256 to the GitHub-recorded digest of kata-static-${KATA_VERSION}-amd64.tar.zst}"
THINPOOL_DEV="${THINPOOL_DEV:-auto}"          # e.g. /dev/nvme1n1
AGENTS_SUBNET="${AGENTS_SUBNET:-172.30.0.0/24}"
ARCH="$(uname -m)"; [[ "$ARCH" == "x86_64" ]] && KARCH=amd64 || KARCH=arm64

log(){ printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die(){ printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ----------------------------------------------------------------- 0. Preflight
log "Preflight: KVM"
[[ -e /dev/kvm ]] || die "/dev/kvm missing. Use a nested-virt (c8i/m8i/r8i) or *.metal instance."
grep -qE 'vmx|svm' /proc/cpuinfo || die "CPU does not expose virtualization extensions."
apt-get update -y && apt-get install -y cpu-checker >/dev/null
kvm-ok || die "kvm-ok failed"

log "Preflight: CPU vulnerability mitigations"
if grep -l . /sys/devices/system/cpu/vulnerabilities/* | xargs grep -H Vulnerable; then
  echo "WARNING: 'Vulnerable' lines present. Update kernel/microcode before relying on this host."
fi

# ----------------------------------------------------------------- 1. Host hardening basics
log "Disable swap"
swapoff -a || true
sed -i.bak '/\sswap\s/d' /etc/fstab

log "Kernel modules"
modprobe vhost_vsock
modprobe dm_thin_pool
cat >/etc/modules-load.d/kata.conf <<EOF
vhost_vsock
dm_thin_pool
EOF

log "/dev/kvm permissions (root:kvm 0660)"
groupadd -f kvm
cat >/etc/udev/rules.d/99-kvm.rules <<'EOF'
KERNEL=="kvm", GROUP="kvm", MODE="0660"
EOF
udevadm control --reload-rules && udevadm trigger --name-match=kvm || true
chown root:kvm /dev/kvm && chmod 0660 /dev/kvm

# ----------------------------------------------------------------- 2. Docker CE (Engine 25+) + containerd.io (2.x)
log "Install Docker CE + containerd from Docker's apt repo"
apt-get install -y ca-certificates curl gnupg lvm2 thin-provisioning-tools jq xz-utils zstd python3
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$KARCH signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin
systemctl stop docker docker.socket containerd || true

# client-only: the daemon is stopped at this point, so `docker version` would exit non-zero
DOCKER_VER="$(docker --version | sed -E 's/.*version ([0-9]+)\..*/\1/')"
CTR_VER="$(containerd --version | awk '{print $3}' | tr -d v | cut -d. -f1)"
[[ "$DOCKER_VER" -ge 25 ]] || die "Docker Engine $DOCKER_VER < 25"
[[ "$CTR_VER" -ge 2 ]]     || die "containerd $CTR_VER < 2.0"

# ----------------------------------------------------------------- 3. LVM thin pool for devmapper snapshotter
log "LVM thin pool"
if [[ "$THINPOOL_DEV" == "auto" ]]; then
  # largest unmounted disk with no partitions and not the root disk
  ROOTDISK="$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" | head -1)"
  THINPOOL_DEV="/dev/$(lsblk -dn -o NAME,TYPE,SIZE -b | awk -v r="$ROOTDISK" '$2=="disk" && $1!=r {print $3" "$1}' | sort -rn | head -1 | awk '{print $2}')"
fi
[[ -b "$THINPOOL_DEV" ]] || die "thin pool device $THINPOOL_DEV not found"
lsblk "$THINPOOL_DEV" | grep -q part && die "$THINPOOL_DEV has partitions; refusing"
echo "Using $THINPOOL_DEV for the thin pool"

if ! vgs containerd >/dev/null 2>&1; then
  pvcreate -ff -y "$THINPOOL_DEV"
  vgcreate containerd "$THINPOOL_DEV"
  lvcreate --wipesignatures y -y -n thinpool containerd -l 95%VG
  lvcreate --wipesignatures y -y -n thinpoolmeta containerd -l 1%VG
  lvconvert -y --zero n -c 512K --thinpool containerd/thinpool --poolmetadata containerd/thinpoolmeta
  cat >/etc/lvm/profile/containerd-thinpool.profile <<'EOF'
activation {
  thin_pool_autoextend_threshold=80
  thin_pool_autoextend_percent=20
}
EOF
  lvchange --metadataprofile containerd-thinpool containerd/thinpool
  lvchange --monitor y containerd/thinpool
fi
POOL_NAME="containerd-thinpool"
dmsetup status "$POOL_NAME" >/dev/null || die "thin pool $POOL_NAME not active"

# ----------------------------------------------------------------- 4. containerd config (v3) with devmapper
log "containerd config"
mkdir -p /etc/containerd /var/lib/containerd/devmapper
cat >/etc/containerd/config.toml <<EOF
version = 3

[plugins.'io.containerd.snapshotter.v1.devmapper']
  root_path = "/var/lib/containerd/devmapper"
  pool_name = "${POOL_NAME}"
  base_image_size = "20GB"
  discard_blocks = true
EOF
systemctl enable --now containerd
sleep 2
ctr plugins ls | grep -E 'devmapper.*ok' || die "devmapper snapshotter not ok (ctr plugins ls)"

# ----------------------------------------------------------------- 5. Kata Containers (pinned, digest-verified)
log "Kata ${KATA_VERSION}"
KATA_EXT="${KATA_EXT:-tar.zst}"   # 3.2x+ releases ship .tar.zst; older ones .tar.xz
TARBALL="kata-static-${KATA_VERSION}-${KARCH}.${KATA_EXT}"
URL="https://github.com/kata-containers/kata-containers/releases/download/${KATA_VERSION}/${TARBALL}"
WORK="$(mktemp -d)"
curl -fsSL -o "$WORK/$TARBALL" "$URL"
echo "${KATA_SHA256}  $WORK/$TARBALL" | sha256sum -c - || die "Kata tarball digest mismatch"

# clear immutable flags from a previous install before replacing files (resolve the symlinks)
for l in /opt/kata/share/kata-containers/vmlinux.container /opt/kata/share/kata-containers/kata-containers.img; do
  [[ -e "$l" ]] && chattr -i "$(readlink -f "$l")" || true
done
if [[ "$KATA_EXT" == tar.zst ]]; then tar -C / --zstd -xf "$WORK/$TARBALL"; else tar -C / -xJf "$WORK/$TARBALL"; fi
rm -rf "$WORK"

[[ -x /opt/kata/bin/firecracker ]] || die "firecracker binary missing from Kata tarball"
[[ -x /opt/kata/bin/jailer ]]      || die "jailer binary missing from Kata tarball"
[[ -f /opt/kata/share/defaults/kata-containers/configuration-fc.toml ]] || die "configuration-fc.toml missing"

# Shim name suffix "-fc" makes Kata load configuration-fc.toml
ln -sf /opt/kata/bin/containerd-shim-kata-v2 /usr/local/bin/containerd-shim-kata-fc-v2
ln -sf /opt/kata/bin/kata-runtime           /usr/local/bin/kata-runtime

log "Harden configuration-fc.toml"
mkdir -p /etc/kata-containers
python3 "$(dirname "$0")/kata-harden.py" \
  /opt/kata/share/defaults/kata-containers/configuration-fc.toml \
  /etc/kata-containers/configuration-fc.toml \
  /opt/kata/bin/jailer

# ownership/permissions BEFORE the immutable flag: chown on an immutable file is refused
chown -R root:root /opt/kata /etc/kata-containers
chmod -R o-w /opt/kata /etc/kata-containers

log "Immutable guest kernel + image"
KERNEL="$(readlink -f /opt/kata/share/kata-containers/vmlinux.container)"
IMAGE="$(readlink -f /opt/kata/share/kata-containers/kata-containers.img)"
chattr +i "$KERNEL" "$IMAGE"
lsattr "$KERNEL" "$IMAGE"

# ----------------------------------------------------------------- 6. Docker daemon: system containerd, devmapper store, kata-fc runtime
log "Docker daemon.json"
mkdir -p /etc/docker
cat >/etc/docker/daemon.json <<'EOF'
{
  "storage-driver": "devmapper",
  "features": { "containerd-snapshotter": true },
  "default-runtime": "runc",
  "runtimes": {
    "kata-fc": {
      "runtimeType": "io.containerd.kata-fc.v2",
      "options": { "ConfigPath": "/etc/kata-containers/configuration-fc.toml" }
    }
  },
  "no-new-privileges": true,
  "live-restore": false,
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "5" }
}
EOF
systemctl enable --now docker
sleep 3
docker info --format '{{.Driver}} | {{json .Runtimes}}' | tee /dev/stderr | grep -q kata-fc || die "kata-fc runtime not registered"

# ----------------------------------------------------------------- 7. Agents' internal network (no default route out)
log "Internal docker network 'agents' (${AGENTS_SUBNET})"
docker network inspect agents >/dev/null 2>&1 || docker network create --internal --subnet "$AGENTS_SUBNET" agents
docker network inspect agents --format '{{.Internal}}' | grep -q true || die "agents network is not internal"

# ----------------------------------------------------------------- 8. Smoke test: guest kernel differs from host
log "Smoke test: kata-fc guest kernel"
docker pull alpine:3.20 >/dev/null
HOSTK="$(uname -r)"
GUESTK="$(docker run --rm --runtime kata-fc alpine:3.20 uname -r)"
echo "host=$HOSTK guest=$GUESTK"
[[ "$HOSTK" != "$GUESTK" ]] || die "guest kernel equals host kernel: sandbox is NOT a microVM"

log "Bootstrap complete."
echo "Next: build proxies + agent image (scripts/build-images.sh), then flip DCF to attack phase."
