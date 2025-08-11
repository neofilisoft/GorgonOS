#!/usr/bin/env bash
set -Eeuo pipefail

# ======= CONFIG =======
TARGET_DISK="/dev/sda"           # e.g. /dev/nvme0n1
HOSTNAME="gorgonos"
USERNAME="gorgonuser"
SWAP_SIZE_GIB=8                  # integer GiB
UBUNTU_CODENAME="noble"          # 24.04 LTS
CRYPT_NAME_ROOT="gorgon_crypt"
CRYPT_NAME_SWAP="cryptswap"
# ======================

echo "[WARNING] This will ERASE ALL DATA on ${TARGET_DISK}!"
read -r -p "Confirm disk (Type YES to continue): " CONFIRM
[[ "${CONFIRM}" != "YES" ]] && { echo "Aborted."; exit 1; }

# Require root
[[ $EUID -ne 0 ]] && { echo "Run as root."; exit 1; }

# UEFI-only for reliability
if [[ ! -d /sys/firmware/efi ]]; then
  echo "UEFI firmware not detected. This installer targets UEFI-only."
  exit 1
fi

# Check required tools
for bin in debootstrap cryptsetup parted mkfs.vfat mkfs.btrfs btrfs grub-install grub-mkconfig; do
  command -v "$bin" >/dev/null 2>&1 || { echo "Missing: $bin"; exit 1; }
done

# Ask for LUKS passphrase (no keyfile persisted)
read -rs -p "Set LUKS passphrase: " LUKS_PW1; echo
read -rs -p "Confirm LUKS passphrase: " LUKS_PW2; echo
[[ "$LUKS_PW1" != "$LUKS_PW2" ]] && { echo "Passphrase mismatch."; exit 1; }

echo "[INFO] Partitioning ${TARGET_DISK} (GPT: EFI + SWAP + ROOT)..."
parted --script "${TARGET_DISK}" \
  mklabel gpt \
  mkpart ESP fat32 1MiB 513MiB \
  set 1 esp on

# Compute swap end (start 513MiB, size SWAP_SIZE_GIB)
SWAP_END_MIB=$(( 513 + SWAP_SIZE_GIB * 1024 ))
parted --script "${TARGET_DISK}" \
  mkpart primary linux-swap 513MiB "${SWAP_END_MIB}MiB" \
  mkpart primary "${SWAP_END_MIB}MiB" 100%

EFI_PART="${TARGET_DISK}1"
SWAP_PART="${TARGET_DISK}2"
ROOT_PART="${TARGET_DISK}3"

echo "[INFO] Formatting EFI..."
mkfs.vfat -F32 -n EFI "${EFI_PART}"

echo "[INFO] Setting up encrypted SWAP (LUKS)..."
printf "%s" "$LUKS_PW1" | cryptsetup luksFormat --type luks2 --batch-mode "${SWAP_PART}" -
printf "%s" "$LUKS_PW1" | cryptsetup open "${SWAP_PART}" "${CRYPT_NAME_SWAP}" -
mkswap -L GORGONSWAP "/dev/mapper/${CRYPT_NAME_SWAP}"
swapon "/dev/mapper/${CRYPT_NAME_SWAP}"

echo "[INFO] Setting up encrypted ROOT (LUKS + BTRFS)..."
printf "%s" "$LUKS_PW1" | cryptsetup luksFormat --type luks2 --batch-mode "${ROOT_PART}" -
printf "%s" "$LUKS_PW1" | cryptsetup open "${ROOT_PART}" "${CRYPT_NAME_ROOT}" -
mkfs.btrfs -f -L GORGONROOT "/dev/mapper/${CRYPT_NAME_ROOT}"

echo "[INFO] Mounting..."
mount -o compress=zstd "/dev/mapper/${CRYPT_NAME_ROOT}" /mnt
mkdir -p /mnt/boot/efi
mount "${EFI_PART}" /mnt/boot/efi

echo "[INFO] Bootstrapping Ubuntu ${UBUNTU_CODENAME}..."
debootstrap "${UBUNTU_CODENAME}" /mnt http://archive.ubuntu.com/ubuntu

echo "[INFO] System basics..."
echo "${HOSTNAME}" > /mnt/etc/hostname
cat > /mnt/etc/hosts <<EOF
127.0.0.1   localhost
127.0.1.1   ${HOSTNAME}
::1         localhost ip6-localhost ip6-loopback
EOF

# Proper sources.list (incl. restricted/universe/multiverse + updates/security)
cat > /mnt/etc/apt/sources.list <<EOF
deb http://archive.ubuntu.com/ubuntu ${UBUNTU_CODENAME} main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu ${UBUNTU_CODENAME}-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu ${UBUNTU_CODENAME}-security main restricted universe multiverse
EOF

# crypttab (root + swap) - using passphrase at boot (no keyfile path)
ROOT_UUID=$(blkid -s UUID -o value "${ROOT_PART}")
SWAP_UUID=$(blkid -s UUID -o value "${SWAP_PART}")
cat > /mnt/etc/crypttab <<EOF
${CRYPT_NAME_ROOT} UUID=${ROOT_UUID} none luks,discard
${CRYPT_NAME_SWAP} UUID=${SWAP_UUID} none luks,discard
EOF

# fstab
BTRFS_UUID=$(blkid -s UUID -o value "/dev/mapper/${CRYPT_NAME_ROOT}")
EFI_UUID=$(blkid -s UUID -o value "${EFI_PART}")
SWAP_MAPPED_UUID=$(blkid -s UUID -o value "/dev/mapper/${CRYPT_NAME_SWAP}" || true)
cat > /mnt/etc/fstab <<EOF
UUID=${BTRFS_UUID}  /           btrfs  compress=zstd,ssd,space_cache=v2  0 1
UUID=${EFI_UUID}    /boot/efi   vfat   umask=0077                        0 1
/dev/mapper/${CRYPT_NAME_SWAP} none     swap   sw                        0 0
EOF

# Enable resume to encrypted swap by device mapper path (more reliable than UUID for swap)
mkdir -p /mnt/etc/initramfs-tools/conf.d
echo "RESUME=/dev/mapper/${CRYPT_NAME_SWAP}" > /mnt/etc/initramfs-tools/conf.d/resume

echo "[INFO] Bind-mounting chroot essentials..."
for d in /dev /dev/pts /proc /sys /run; do
  mount --bind "$d" "/mnt$d"
done
mount -t efivarfs efivarfs /mnt/sys/firmware/efi/efivars

# Helper to run commands in chroot via bash -c
chr() { chroot /mnt /bin/bash -c "$*"; }

echo "[INFO] Base packages..."
chr "apt-get update"
chr "apt-get install -y --no-install-recommends linux-image-generic linux-firmware initramfs-tools \
     grub-efi-amd64 cryptsetup-initramfs sudo locales tzdata \
     network-manager policykit-1"

# Locale/Timezone
chr "sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && locale-gen"
chr "update-locale LANG=en_US.UTF-8"
chr "ln -sf /usr/share/zoneinfo/Asia/Bangkok /etc/localtime"

# User + sudo
chr "useradd -m -s /bin/bash ${USERNAME}"
echo "Set password for ${USERNAME}:"
chroot /mnt passwd "${USERNAME}"
echo "Set root password:"
chroot /mnt passwd root
chr "usermod -aG sudo ${USERNAME}"

# Graphics & gaming stack (avoid snap in chroot)
chr "apt-get install -y ubuntu-drivers-common mesa-utils vulkan-tools gamemode steam-installer"
# 32-bit for wine/steam
chr "dpkg --add-architecture i386 && apt-get update"
chr "apt-get install -y wine64 wine32 libwine libwine:i386 fonts-wine winetricks"

# Dev toolchain & common libs
chr "apt-get install -y build-essential cmake git llvm clang pkg-config \
     libglvnd-dev libsdl2-dev libvulkan-dev libopenal-dev unzip \
     linux-tools-generic cpufrequtils zenity inxi"

# (Optional) NVIDIA drivers auto-detect; safe to run, may be no-op on AMD/Intel
chr "ubuntu-drivers autoinstall || true"

# Desktop (Cinnamon + LightDM; avoid snap-based apps here)
chr "apt-get install -y cinnamon-desktop-environment lightdm slick-greeter \
     synaptic gnome-software vlc gnome-terminal arc-theme papirus-icon-theme"

# Display manager
mkdir -p /mnt/etc/lightdm
cat > /mnt/etc/lightdm/lightdm.conf <<EOF
[Seat:*]
greeter-session=slick-greeter
user-session=cinnamon
EOF
chr "systemctl enable lightdm"
chr "systemctl enable NetworkManager"
chr "systemctl enable systemd-timesyncd"

# Power/perf services
chr "apt-get install -y irqbalance tuned"
chr "systemctl enable irqbalance"
chr "systemctl enable tuned"

# Kernel sysctl
cat >> /mnt/etc/sysctl.conf <<EOF
vm.swappiness=10
vm.vfs_cache_pressure=50
net.core.rmem_max=16777216
net.core.wmem_max=16777216
EOF

# I/O scheduler rules (NVMe: none; SATA SSD/HDD: mq-deadline)
mkdir -p /mnt/etc/udev/rules.d
cat > /mnt/etc/udev/rules.d/60-ioscheduler.rules <<'EOF'
ACTION=="add|change", KERNEL=="nvme*n*", ATTR{queue/scheduler}="none"
ACTION=="add|change", KERNEL=="sd*[!0-9]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
ACTION=="add|change", KERNEL=="sd*[!0-9]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="mq-deadline"
EOF

# Simple control center (uses zenity, inxi)
cat > /mnt/usr/bin/gorgon-control-center <<'EOF'
#!/usr/bin/env bash
while true; do
    status=$(systemctl is-active gamemoded.service 2>/dev/null || echo inactive)
    if [ "$status" = "active" ]; then
        game_status="Disable Gaming Mode"
        game_desc="Turn off performance optimizations to avoid anti-cheat issues"
    else
        game_status="Enable Gaming Mode"
        game_desc="Optimize system for gaming (may trigger anti-cheat systems)"
    fi
    choice=$(zenity --list --title="GorgonOS Control Center" --width=640 --height=420 \
        --column="Option" --column="Description" \
        "System Info" "Display system information" \
        "Driver Manager" "Manage hardware drivers" \
        "Update System" "Update packages (apt)" \
        "Theme: Dark" "Switch to Arc-Dark + Papirus-Dark" \
        "Theme: Light" "Switch to Arc + Papirus" \
        "$game_status" "$game_desc" \
        "Exit" "Close Control Center")
    case "$choice" in
        "System Info") inxi -Fxxxz | zenity --text-info --width=900 --height=600 ;;
        "Driver Manager") software-properties-gtk --open-tab=4 >/dev/null 2>&1 & ;;
        "Update System") x-terminal-emulator -e "sudo apt update && sudo apt -y upgrade" & ;;
        "Theme: Dark")
            gsettings set org.cinnamon.desktop.interface gtk-theme 'Arc-Dark'
            gsettings set org.cinnamon.desktop.interface icon-theme 'Papirus-Dark'
        ;;
        "Theme: Light")
            gsettings set org.cinnamon.desktop.interface gtk-theme 'Arc'
            gsettings set org.cinnamon.desktop.interface icon-theme 'Papirus'
        ;;
        "Enable Gaming Mode")
            pkexec systemctl enable --now gamemoded.service
            zenity --info --text="Gaming mode activated."
        ;;
        "Disable Gaming Mode")
            pkexec systemctl disable --now gamemoded.service
            zenity --info --text="Gaming mode deactivated."
        ;;
        *) exit 0 ;;
    esac
done
EOF
chmod +x /mnt/usr/bin/gorgon-control-center

# Autostart a tiny first-setup wrapper (placeholder)
mkdir -p "/mnt/home/${USERNAME}/.config/autostart"
cat > "/mnt/home/${USERNAME}/.config/autostart/FirstSetup.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Gorgon Control Center
Exec=/usr/bin/gorgon-control-center
X-GNOME-Autostart-enabled=true
EOF

# Themes defaults
mkdir -p "/mnt/home/${USERNAME}/.config/gtk-3.0" "/mnt/home/${USERNAME}/.config/gtk-4.0"
cat > "/mnt/home/${USERNAME}/.config/gtk-3.0/settings.ini" <<'EOF'
[Settings]
gtk-application-prefer-dark-theme=1
gtk-theme-name=Arc-Dark
gtk-icon-theme-name=Papirus-Dark
gtk-font-name=Sans 10
EOF
cp "/mnt/home/${USERNAME}/.config/gtk-3.0/settings.ini" "/mnt/home/${USERNAME}/.config/gtk-4.0/settings.ini"

# Ensure ownership
chroot /mnt chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}"

# Optional: Build RyzenAdj from source
chr "git clone https://github.com/FlyGoat/RyzenAdj.git /tmp/RyzenAdj && cd /tmp/RyzenAdj && \
     mkdir -p build && cd build && cmake -DCMAKE_BUILD_TYPE=Release .. && make -j\$(nproc) && make install" || true

# Plymouth (theme kept minimal)
chr "apt-get install -y plymouth plymouth-themes"
chr "plymouth-set-default-theme -R spinner || true"

# GRUB configuration for encrypted root
cat > /mnt/etc/default/grub <<'EOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=2
GRUB_DISTRIBUTOR=GorgonOS
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
# Enable LUKS in GRUB so it can unlock root
GRUB_ENABLE_CRYPTODISK=y
EOF

echo "[INFO] Update initramfs and GRUB..."
chr "update-initramfs -u -k all"
chr "grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GorgonOS"
chr "grub-mkconfig -o /boot/grub/grub.cfg"

echo "[INFO] Cleanup and unmount..."
swapoff "/dev/mapper/${CRYPT_NAME_SWAP}" || true
umount -R /mnt/boot/efi || true
for d in /run /sys/firmware/efi/efivars /sys /proc /dev/pts /dev; do
  mountpoint -q "/mnt${d}" && umount -R "/mnt${d}" || true
done
umount -R /mnt || true
cryptsetup close "${CRYPT_NAME_SWAP}" || true
cryptsetup close "${CRYPT_NAME_ROOT}" || true

echo "[SUCCESS] GorgonOS base installed. Reboot, then install snap apps (e.g., Firefox) on first boot."
