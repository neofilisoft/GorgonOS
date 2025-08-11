#!/usr/bin/env bash
set -Eeuo pipefail

# =========================
# GorgonOS Live ISO Builder
# UEFI-only • Ubuntu 24.04
# =========================

# ---- Config ----
ISO_NAME="GorgonOS-1.0-amd64.iso"
WORKDIR="$(pwd)/work"
CHROOT_DIR="${WORKDIR}/chroot"
IMAGE_DIR="${WORKDIR}/image"
ARCH="amd64"
CODENAME="noble"                  # Ubuntu 24.04 LTS
MIRROR="http://archive.ubuntu.com/ubuntu"
LIVE_USER="gorgon"
HOSTNAME="gorgonos-live"
LOCALE="en_US.UTF-8"
TIMEZONE="Asia/Bangkok"
VOLID="GORGONOS_1_0"

# ---- Build deps check (host) ----
need_host_bins=(
  debootstrap mksquashfs xorriso grub-mkstandalone mtools dosfstools
  grub-efi-amd64-bin squashfs-tools
)
for b in "${need_host_bins[@]}"; do
  command -v "$b" >/dev/null 2>&1 || {
    echo "Missing host tool: $b"
    echo "Install: sudo apt update && sudo apt install -y debootstrap grub-efi-amd64-bin grub-pc-bin xorriso mtools dosfstools squashfs-tools"
    exit 1
  }
done

# ---- Prepare dirs ----
rm -rf "$WORKDIR"
mkdir -p "$CHROOT_DIR" "$IMAGE_DIR"/{EFI/boot,boot/grub,casper,isomod}

# ---- Stage 1: Bootstrap minimal system ----
sudo debootstrap --arch="$ARCH" "$CODENAME" "$CHROOT_DIR" "$MIRROR"

# ---- Stage 2: Seed basic config (chroot) ----
mount --bind /dev  "$CHROOT_DIR/dev"
mount --bind /dev/pts "$CHROOT_DIR/dev/pts"
mount -t proc /proc "$CHROOT_DIR/proc"
mount -t sysfs /sys  "$CHROOT_DIR/sys"
mount -t efivarfs efivarfs "$CHROOT_DIR/sys/firmware/efi/efivars" || true
mount -t tmpfs tmpfs "$CHROOT_DIR/run"

cat > "$CHROOT_DIR/host-setup.sh" <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive

# Base system + live components
apt-get update
apt-get install -y --no-install-recommends \
    systemd-sysv sudo locales tzdata software-properties-common \
    linux-image-generic linux-firmware \
    network-manager resolvconf \
    casper squashfs-tools \
    grub-efi-amd64 shim-signed \
    grub-common grub-efi-amd64-signed \
    plymouth plymouth-themes

# Desktop (Cinnamon) + DM
apt-get install -y --no-install-recommends \
    cinnamon-desktop-environment lightdm slick-greeter \
    gnome-terminal vlc \
    arc-theme papirus-icon-theme \
    zenity inxi nano xterm

# Gaming stack (baseline; keep snaps for first boot)
apt-get install -y --no-install-recommends \
    ubuntu-drivers-common mesa-utils vulkan-tools gamemode \
    steam-installer \
    wine64 wine32 libwine libwine:i386 fonts-wine winetricks \
    libsdl2-2.0-0 libopenal1

# Dev tools (optional but useful for demos)
apt-get install -y --no-install-recommends \
    build-essential cmake git llvm clang pkg-config \
    libglvnd-dev libsdl2-dev libvulkan-dev libopenal-dev unzip

# Locale/Timezone
sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8
ln -sf /usr/share/zoneinfo/Asia/Bangkok /etc/localtime

# Networking
systemctl enable NetworkManager

# Create live user with passwordless sudo
useradd -m -s /bin/bash gorgon
echo "gorgon:gorgon" | chpasswd
adduser gorgon sudo
echo "%sudo ALL=(ALL) NOPASSWD: ALL" >/etc/sudoers.d/00-sudo-nopasswd

# LightDM autologin
mkdir -p /etc/lightdm
cat > /etc/lightdm/lightdm.conf <<EOC
[Seat:*]
greeter-session=slick-greeter
user-session=cinnamon
autologin-user=gorgon
autologin-user-timeout=0
EOC

# Cinnamon sensible defaults
sudo -u gorgon mkdir -p /home/gorgon/.config/gtk-3.0 /home/gorgon/.config/gtk-4.0
cat > /home/gorgon/.config/gtk-3.0/settings.ini <<EOG
[Settings]
gtk-application-prefer-dark-theme=1
gtk-theme-name=Arc-Dark
gtk-icon-theme-name=Papirus-Dark
gtk-font-name=Sans 10
EOG
cp /home/gorgon/.config/gtk-3.0/settings.ini /home/gorgon/.config/gtk-4.0/settings.ini
chown -R gorgon:gorgon /home/gorgon/.config

# Plymouth theme
plymouth-set-default-theme -R spinner || true

# Hostname & minimal hosts
echo "gorgonos-live" > /etc/hostname
cat > /etc/hosts <<EOT
127.0.0.1   localhost
127.0.1.1   gorgonos-live
::1         localhost ip6-localhost ip6-loopback
EOT

# Make Installer entry (desktop icon)
mkdir -p /usr/local/bin /usr/share/applications /etc/skel/Desktop /home/gorgon/Desktop
install -m 0755 /root/GORGONOS_INSTALLER /usr/local/bin/gorgonos-installer

cat > /usr/share/applications/gorgonos-installer.desktop <<'EOD'
[Desktop Entry]
Type=Application
Name=Install GorgonOS
Comment=Run the disk installer
Exec=pkexec /usr/local/bin/gorgonos-installer
Icon=system-software-install
Terminal=true
Categories=System;Utility;
EOD

cp /usr/share/applications/gorgonos-installer.desktop /etc/skel/Desktop/
cp /usr/share/applications/gorgonos-installer.desktop /home/gorgon/Desktop/
chmod +x /home/gorgon/Desktop/gorgonos-installer.desktop
chown -R gorgon:gorgon /home/gorgon/Desktop

# Live session quality-of-life
systemctl enable lightdm
systemctl enable systemd-timesyncd
EOS
chmod +x "$CHROOT_DIR/host-setup.sh"

# ---- Stage 3: Provide installer script into chroot ----
# Put your disk installer script at ./files/GorgonOS_install.sh before running this builder.
if [[ ! -f "./files/GorgonOS_install.sh" ]]; then
  echo "ERROR: ./files/GorgonOS_install.sh not found."
  echo "Place your disk installer script here and re-run."
  exit 1
fi
install -D -m 0755 "./files/GorgonOS_install.sh" "$CHROOT_DIR/root/GORGONOS_INSTALLER"

# ---- Run chroot customization ----
chroot "$CHROOT_DIR" /bin/bash -c "/host-setup.sh"
rm -f "$CHROOT_DIR/host-setup.sh"

# ---- Clean up chroot for squashing ----
chroot "$CHROOT_DIR" apt-get clean
rm -rf "$CHROOT_DIR"/var/lib/apt/lists/*
rm -f  "$CHROOT_DIR"/etc/machine-id || true
: > "$CHROOT_DIR"/var/lib/dbus/machine-id || true

# ---- Extract kernel & initrd ----
KERNEL_IMG="$(ls -1 "$CHROOT_DIR"/boot/vmlinuz-* | sort | tail -n1)"
INITRD_IMG="$(ls -1 "$CHROOT_DIR"/boot/initrd.img-* | sort | tail -n1)"
cp "$KERNEL_IMG" "$IMAGE_DIR/casper/vmlinuz"
cp "$INITRD_IMG" "$IMAGE_DIR/casper/initrd"

# ---- Squash filesystem ----
mkdir -p "$IMAGE_DIR/casper"
mksquashfs "$CHROOT_DIR" "$IMAGE_DIR/casper/filesystem.squashfs" -comp xz -e boot

# Manifest (optional but useful)
chroot "$CHROOT_DIR" dpkg-query -W --showformat='${Package} ${Version}\n' \
    > "$IMAGE_DIR/casper/filesystem.manifest" || true

# ---- Create GRUB EFI bootloader (standalone) ----
# Embedded grub.cfg will load kernel/initrd from /casper
mkdir -p "$WORKDIR/grub-embed"
cat > "$WORKDIR/grub-embed/grub.cfg" <<'EOG'
set default="0"
set timeout=3

menuentry "GorgonOS Live (UEFI)" {
    linux /casper/vmlinuz boot=casper quiet splash ---
    initrd /casper/initrd
}
menuentry "GorgonOS Live (nomodeset)" {
    linux /casper/vmlinuz boot=casper quiet splash nomodeset ---
    initrd /casper/initrd
}
EOG

grub-mkstandalone \
  -O x86_64-efi \
  -o "$IMAGE_DIR/EFI/boot/bootx64.efi" \
  "boot/grub/grub.cfg=$WORKDIR/grub-embed/grub.cfg"

# Optional: add a small FAT image as ESP for compatibility (not strictly needed for standalone)
# Skipped to keep image minimal.

# ---- ISO metadata files ----
echo "$VOLID" > "$IMAGE_DIR/.disk/info"
mkdir -p "$IMAGE_DIR/.disk"
echo "GorgonOS 1.0" > "$IMAGE_DIR/.disk/casper-uuid"

# ---- Make ISO ----
xorriso -as mkisofs \
  -iso-level 3 \
  -full-iso9660-filenames \
  -volid "$VOLID" \
  -eltorito-alt-boot \
  -e EFI/boot/bootx64.efi \
  -no-emul-boot \
  -isohybrid-gpt-basdat \
  -output "$ISO_NAME" \
  "$IMAGE_DIR"

echo
echo "==============================="
echo " ISO BUILT: $ISO_NAME"
echo " Size: $(du -h "$ISO_NAME" | cut -f1)"
echo " Boot mode: UEFI"
echo "==============================="

# ---- Unmount cleanup ----
umount -lf "$CHROOT_DIR/dev/pts" || true
umount -lf "$CHROOT_DIR/dev" || true
umount -lf "$CHROOT_DIR/proc" || true
umount -lf "$CHROOT_DIR/sys/firmware/efi/efivars" || true
umount -lf "$CHROOT_DIR/sys" || true
umount -lf "$CHROOT_DIR/run" || true
