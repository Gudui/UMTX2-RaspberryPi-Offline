#!/usr/bin/env bash
set -euo pipefail

# --- Config --- #
ALPINE_VERSION="3.21.0"
ARCH="armhf"
DEVICE="/dev/mmcblk0"   # ← verify this
BOOT_P="${DEVICE}p1"
ROOT_P="${DEVICE}p2"

MNT_BOOT="/mnt/boot"
MNT_ROOT="/mnt/root"
ROOTFS_TAR="alpine-minirootfs-${ALPINE_VERSION}-${ARCH}.tar.gz"
ROOTFS_URL="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/${ARCH}/${ROOTFS_TAR}"

BOOTFILES_REPO="https://github.com/raspberrypi/firmware.git"
UMTX2_REPO="https://github.com/idlesauce/umtx2"

STATIC_IP="192.168.2.5/24"
GATEWAY="192.168.2.1"
HOSTNAME="alpinepi"

# --- Check prerequisites --- #
for cmd in parted mkfs.vfat mkfs.ext4 wget git tar chroot; do
  command -v "$cmd" >/dev/null || { echo "Missing: $cmd"; exit 1; }
done

# --- Download rootfs --- #
echo "[1] Downloading Alpine minirootfs…"
wget -O "$ROOTFS_TAR" --continue "$ROOTFS_URL"

echo "[1a] Unmounting /dev/mmcblk0*…"
sudo umount -l ${DEVICE}p1 || true
sudo umount -l ${DEVICE}p2 || true
sudo udevadm settle
sudo partprobe "$DEVICE"

echo "[1b] Killing automounters (if any)…"
sudo fuser -km ${DEVICE} || true

echo "[1c] Ensuring device is unused…"
sudo udevadm settle
sleep 1

# Kill anything still using it
sudo fuser -vkm "$DEVICE" || true
sudo dmsetup remove_all || true

# Force reread of partition table
sudo blockdev --rereadpt "$DEVICE" || true
sudo partprobe "$DEVICE" || true

# --- Partition the SD card --- #
echo "[2] Partitioning $DEVICE…"
sudo parted --script "$DEVICE" \
  mklabel msdos \
  mkpart primary fat32 1MiB 100MiB \
  mkpart primary ext4 100MiB 100% \
  set 1 boot on

sudo mkfs.vfat -F32 "$BOOT_P"
sudo mkfs.ext4 "$ROOT_P"

# --- Mount filesystems --- #
echo "[3] Mounting…"
sudo mkdir -p "$MNT_BOOT" "$MNT_ROOT"
sudo mount "$ROOT_P" "$MNT_ROOT"
sudo mkdir -p "$MNT_ROOT/boot"
sudo mount "$BOOT_P" "$MNT_ROOT/boot"

# --- Extract Alpine rootfs --- #
echo "[4] Extracting rootfs…"
sudo tar -xzf "$ROOTFS_TAR" -C "$MNT_ROOT"

# --- Bootstrap essential files --- #
echo "[5] Configuring system files…"
echo "$HOSTNAME" | sudo tee "$MNT_ROOT/etc/hostname" >/dev/null

sudo tee "$MNT_ROOT/etc/fstab" >/dev/null <<EOF
/dev/mmcblk0p1  /boot   vfat    defaults        0 0
/dev/mmcblk0p2  /       ext4    defaults,noatime  0 1
EOF

sudo tee "$MNT_ROOT/etc/network/interfaces" >/dev/null <<EOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
    address ${STATIC_IP}
    gateway ${GATEWAY}
EOF

# --- Copy DNS config --- #
sudo cp /etc/resolv.conf "$MNT_ROOT/etc/"

# --- Enable essential services --- #
echo "[6] Installing and configuring in chroot…"
sudo chroot "$MNT_ROOT" /bin/sh <<'EOF'
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev

apk update
apk add openrc e2fsprogs util-linux linux-firmware-brcm \
        raspberrypi-bootloader linux-rpi python3 py3-pip git openssl

mkinitfs -c /etc/mkinitfs/mkinitfs.conf -b / -F -o /boot/initramfs-rpi

rc-update add devfs sysinit
rc-update add dmesg sysinit
rc-update add hwdrivers sysinit
rc-update add modules boot
rc-update add sysctl boot
rc-update add hostname boot
rc-update add bootmisc boot
rc-update add networking boot
# remove → rc-update add urandom boot
rc-update add killprocs shutdown
rc-update add mount-ro shutdown
rc-update add savecache shutdown

# Clone & patch uMTX2
rm -rf /opt/umtx2
git clone https://github.com/idlesauce/umtx2 /opt/umtx2
sed -i 's/443/80/' /opt/umtx2/host.py
sed -i '/if self.headers.get/,/else:/c\
        if self.path.startswith("/document/en/ps5"):\
            return self.serve_userguide()\
        return super().do_GET()' /opt/umtx2/host.py

# Create init.d directory if missing
mkdir -p /etc/init.d

# Create OpenRC service
cat >/etc/init.d/umtx2 <<EOL
#!/sbin/openrc-run
command="/usr/bin/python3"
command_args="/opt/umtx2/host.py --port 80"
pidfile="/run/umtx2.pid"
depend() {
  need network
}
EOL
chmod +x /etc/init.d/umtx2
rc-update add umtx2 default

umount /proc /sys /dev
EOF

# --- Install bootloader files --- #
echo "[7] Installing Raspberry Pi boot files…"
TMP_BOOT=$(mktemp -d)
git clone --depth 1 --branch stable "$BOOTFILES_REPO" "$TMP_BOOT"
sudo cp "$TMP_BOOT"/boot/{bootcode.bin,start.elf,fixup.dat} "$MNT_ROOT/boot/"
sudo tee "$MNT_ROOT/boot/config.txt" >/dev/null <<EOF
disable_overscan=1
enable_uart=1
kernel=vmlinuz-rpi
initramfs initramfs-rpi
EOF
sudo tee "$MNT_ROOT/boot/cmdline.txt" >/dev/null <<EOF
dwc_otg.lpm_enable=0 console=ttyAMA0,115200 root=/dev/mmcblk0p2 rw rootfstype=ext4 elevator=deadline fsck.repair=yes rootwait
EOF
sudo rm -rf "$TMP_BOOT"

# --- Done --- #
echo "[8] Unmounting and finalizing…"
sync
sudo umount "$MNT_ROOT/boot"
sudo umount "$MNT_ROOT"

echo -e "\n[✓] SD card ready.\nInsert into Raspberry Pi 1 and browse to:"
echo -e "    http://${STATIC_IP}/document/en/ps5/index.html\n"
