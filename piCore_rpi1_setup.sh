#!/usr/bin/env bash
set -euo pipefail

# --- Config --- #
ALPINE_VERSION="3.22.0"
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
SPOOF_IP="${STATIC_IP%/*}"
IP4=${STATIC_IP%%/*}               # → 192.168.2.5 (used later for FakeDNS patch)


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

# --- Enable essential services --- #
echo "[6] Installing and configuring in chroot…"
sudo chroot "$MNT_ROOT" /bin/sh <<EOF
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev

apk update
apk add openrc e2fsprogs util-linux linux-firmware-brcm \
        raspberrypi-bootloader linux-rpi python3 py3-pip git openssl
apk add --no-cache ifupdown-ng ifupdown-ng-openrc   # provides /etc/init.d/ifupdown-ng
apk add chrony
apk add curl
apk add nano
apk add iproute2
apk add lsof
apk add py3-flask
#mkinitfs -c /etc/mkinitfs/mkinitfs.conf -b / -F -o /boot/initramfs-rpi
mkinitfs -b / -k rpi -o /boot/initramfs-rpi


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
 rc-update add chronyd default
 rc-update add networking boot
 

passwd -d root

mkdir -p /etc/init.d /var/log/umtx2 /run


# — net‑provide: export virtual facility “net”


cat >/etc/init.d/net-provide <<'NET'
#!/sbin/openrc-run
description="Marks the network stack as ready (provides virtual facility net)"

depend() {
    need networking        # wait until /etc/init.d/networking is running
    provide net            # then satisfy every ‘need net’
}

start() {                  # one-shot, stays ‘started’ as soon as it returns 0
    ebegin "Providing virtual facility net"
    eend 0
}
NET
chmod +x /etc/init.d/net-provide
rc-update add net-provide boot


# — uMTX2 clone —
rm -rf /opt/umtx2
git clone "$UMTX2_REPO" /opt/umtx2

# switch HTTPS → HTTP port
sed -i 's/:443/:80/g' /opt/umtx2/host.py
sed -i 's/ssl_context=.*/# ssl disabled by build script/' /opt/umtx2/host.py
# ── insert 302 redirect for “/” → /document/en/ps5/index.html ───────────────
# overwrite do_GET so root URL issues HTTP-302
apply_redirect() {
  python - "$@" <<'PY'
import pathlib, textwrap, re, sys
p = pathlib.Path('/opt/umtx2/host.py')
src = p.read_text().splitlines()
out = []
skip = False
for line in src:
    if line.startswith('    def do_GET('):
        skip = True          # drop the old version
        # new implementation
        out.append('    def do_GET(self):')
        out.append('        self.replace_locale()')
        out.append("        if self.path in (\"/\", \"\"):")
        out.append('            self.send_response(302)')
        out.append('            self.send_header("Location", "/document/en/ps5/index.html")')
        out.append('            self.end_headers()')
        out.append('            return')
        out.append('        return super().do_GET()')
        continue
    if skip and re.match(r'^\s*def ', line):
        skip = False         # reached next method
    if not skip:
        out.append(line)
p.write_text('\n'.join(out) + '\n')
PY
}
apply_redirect
# patch FakeDNS: replace gethostbyname().local with static IP
sed -i "s/socket.gethostbyname(socket.gethostname()+\".local\")/'$IP4'/g" \
       /opt/umtx2/fakedns.py
# Variant with single quotes
sed -i "s/socket.gethostbyname(socket.gethostname()+'.local')/'$IP4'/g" \
       /opt/umtx2/fakedns.py

# ----------------  umtx2-http -----------------
cat > /etc/init.d/umtx2-http <<'HTTP'
#!/sbin/openrc-run
description="uMTX2 HTTP server"
command="/usr/bin/python3"
command_args="/opt/umtx2/host.py"
directory="/opt/umtx2"
supervisor="supervise-daemon"
pidfile="/run/umtx2-http.pid"
output_log="/var/log/umtx2/http.log"
error_log="/var/log/umtx2/http.err"
depend() { need net; }
start_pre() { checkpath --directory --mode 0755 /var/log/umtx2; }
HTTP
chmod +x /etc/init.d/umtx2-http
rc-update add umtx2-http default


# ----------------  umtx2-dns ------------------
cat > /etc/init.d/umtx2-dns <<'DNS'
#!/sbin/openrc-run
description="uMTX2 FakeDNS"
command="/usr/bin/python3"
command_args="/opt/umtx2/fakedns.py -i 0.0.0.0 -p 53"
directory="/opt/umtx2"
supervisor="supervise-daemon"
pidfile="/run/umtx2-dns.pid"
output_log="/var/log/umtx2/dns.log"
error_log="/var/log/umtx2/dns.err"
depend() { need net; }
start_pre() { checkpath --directory --mode 0755 /var/log/umtx2; }
DNS
chmod +x /etc/init.d/umtx2-dns
rc-update add umtx2-dns default
# ------------------------------------------------------------------
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
