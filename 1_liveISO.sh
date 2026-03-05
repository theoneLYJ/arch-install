#!/bin/bash

# Bash Strict Mode
set -euo pipefail
IFS=$'\n\t'

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
print_step() {
    echo -e "${GREEN}==>${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}==>${NC} $1"
}

print_error() {
    echo -e "${RED}==>${NC} $1"
}

print_info() {
    echo -e "${BLUE}-->${NC} $1"
}

confirm_action() {
    local prompt="$1"
    local response
    read -rp "$prompt [y/N] " response
    [[ $response =~ ^[Yy]$ ]]
}

# Force script PWD to be where the script is located up a directory
cd "${0%/*}/.." || exit 1

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    print_error "This script must be run as root"
    exit 1
fi

# Display recommended BIOS settings
cat << 'EOF'
RECOMMENDED BIOS SETTINGS:
================================
PURE UEFI: ENABLED
CSM: DISABLED
Secure Boot: DISABLED (can be enabled later)
TPM: ENABLED
BIOS PASSWORD: ENABLED
USB BOOT: ENABLED (DISABLE AFTER INSTALL)
================================

EOF

# Wait for internet connection
print_step "Testing network connection..."
until ping -c1 archlinux.org >/dev/null 2>&1; do
    print_warning "Waiting for network connection..."
    sleep 2
done
print_step "Network connection established"

# Get installation drive
while true; do
    read -rp 'Enter installation drive (e.g., /dev/sda or /dev/nvme0n1): ' INSTALL_DRIVE
    if [[ -b $INSTALL_DRIVE ]]; then
        break
    else
        print_error "Invalid drive: $INSTALL_DRIVE"
    fi
done

# Partitioning
cat << 'EOF'

Partitioning Guide (1TB SSD Example):
------------------------------------
Partition 1: EFI System Partition (1G) - /dev/sda1
Partition 2: BTRFS root partition (rest of drive) - /dev/sda2
------------------------------------
Note: BTRFS will handle swap via subvolumes or swapfile
EOF

if confirm_action "Open cfdisk to partition the drive?"; then
    cfdisk "$INSTALL_DRIVE"
fi

# Get partition information
clear
lsblk "$INSTALL_DRIVE"
echo

while true; do
    read -rp 'Enter EFI partition (e.g., /dev/sda1 or /dev/nvme0n1p1): ' EFI_PARTITION
    if [[ -b $EFI_PARTITION ]]; then
        break
    else
        print_error "Invalid partition: $EFI_PARTITION"
    fi
done

while true; do
    read -rp 'Enter BTRFS root partition (e.g., /dev/sda2 or /dev/nvme0n1p2): ' ROOT_PARTITION
    if [[ -b $ROOT_PARTITION ]]; then
        break
    else
        print_error "Invalid partition: $ROOT_PARTITION"
    fi
done

# Format EFI partition
clear
lsblk "$EFI_PARTITION"
echo

if confirm_action "Format $EFI_PARTITION as FAT32?"; then
    print_step "Formatting EFI partition..."
    mkfs.fat -F 32 -n EFI "$EFI_PARTITION"
else
    print_error "Installation cancelled"
    exit 1
fi

# Format and setup BTRFS
clear
lsblk "$ROOT_PARTITION"
echo

print_step "Creating BTRFS filesystem..."
mkfs.btrfs -f -L ARCH "$ROOT_PARTITION"

# Mount and create subvolumes
print_step "Creating BTRFS subvolumes..."
mount "$ROOT_PARTITION" /mnt

# Create subvolumes
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@var_log
btrfs subvolume create /mnt/@var_cache
btrfs subvolume create /mnt/@var_tmp
btrfs subvolume create /mnt/@swap

# Unmount and remount with subvolumes
umount /mnt

# Mount options for better performance
MOUNT_OPTIONS="defaults,noatime,compress=zstd:3,ssd,space_cache=v2,autodefrag"

# Mount root subvolume
mount -o "$MOUNT_OPTIONS",subvol=@ "$ROOT_PARTITION" /mnt

# Create mount points
mkdir -p /mnt/{boot,home,.snapshots,var/{log,cache,tmp},swap}

# Mount other subvolumes
mount -o "$MOUNT_OPTIONS",subvol=@home "$ROOT_PARTITION" /mnt/home
mount -o "$MOUNT_OPTIONS",subvol=@snapshots "$ROOT_PARTITION" /mnt/.snapshots
mount -o "$MOUNT_OPTIONS",subvol=@var_log "$ROOT_PARTITION" /mnt/var/log
mount -o "$MOUNT_OPTIONS",subvol=@var_cache "$ROOT_PARTITION" /mnt/var/cache
mount -o "$MOUNT_OPTIONS",subvol=@var_tmp "$ROOT_PARTITION" /mnt/var/tmp
mount -o "$MOUNT_OPTIONS",subvol=@swap "$ROOT_PARTITION" /mnt/swap

# Mount EFI partition to the correct location for systemd-boot
mount "$EFI_PARTITION" /mnt/boot

# Install base system
print_step "Installing base system..."
pacstrap /mnt base base-devel linux-firmware \
    btrfs-progs \
    mkinitcpio \
    systemd \
    systemd-boot \
    iptables-nft \
    networkmanager \
    git \
    nano \
    sudo \
    fish \
    man-db \
    man-pages \
    texinfo \
    intel-ucode \
    amd-ucode

# Kernel selection
print_step "Kernel Selection"
KERNELS=()
KERNEL_PRESETS=()

if confirm_action "Install linux-lts kernel? (NOTE: May have BTRFS performance impact)"; then
    KERNELS+=("linux-lts" "linux-lts-headers")
    KERNEL_PRESETS+=("linux-lts")
fi

if confirm_action "Install linux-zen kernel?"; then
    KERNELS+=("linux-zen" "linux-zen-headers")
    KERNEL_PRESETS+=("linux-zen")
fi

if confirm_action "Install linux-hardened kernel?"; then
    KERNELS+=("linux-hardened" "linux-hardened-headers")
    KERNEL_PRESETS+=("linux-hardened")
fi

if confirm_action "Install linux kernel?" || [[ ${#KERNELS[@]} -eq 0 ]]; then
    KERNELS+=("linux" "linux-headers")
    KERNEL_PRESETS+=("linux")
fi

pacstrap /mnt "${KERNELS[@]}"

# Optional packages
print_step "Optional Software Selection"

if confirm_action "Install doas (as sudo replacement)?"; then
    pacstrap /mnt opendoas
fi

if confirm_action "Install secure boot support (sbctl)?"; then
    pacstrap /mnt sbctl
fi

# Microcode
if confirm_action "Install AMD CPU microcode?"; then
    pacstrap /mnt amd-ucode
elif confirm_action "Install Intel CPU microcode?"; then
    pacstrap /mnt intel-ucode
fi

# 32-bit support
if confirm_action "Enable 32-bit support (for Steam, etc.)?"; then
    # Enable multilib in both live and target system
    sed -i 's/^#\[multilib\]/\[multilib\]/' /etc/pacman.conf
    sed -i '/^\[multilib\]/{n;s/^#//}' /etc/pacman.conf
    cp /etc/pacman.conf /mnt/etc/pacman.conf
    pacstrap /mnt lib32-glibc lib32-gcc-libs
fi

# Graphics drivers
print_step "Graphics Driver Installation"

GPU=""
while [[ ! $GPU =~ ^[AaNnIi]$ ]]; do
    read -rp "Select GPU [A]MD/[N]VIDIA/[I]ntel/[S]kip: " GPU
    GPU=${GPU^^}
done

case $GPU in
    A)
        pacstrap /mnt mesa vulkan-radeon libva-mesa-driver mesa-vdpau
        if confirm_action "Install X11 drivers?"; then
            pacstrap /mnt xf86-video-amdgpu
        fi
        if [[ -d /mnt/etc/pacman.d/ && -f /mnt/etc/pacman.conf ]]; then
            pacstrap /mnt lib32-mesa lib32-vulkan-radeon lib32-libva-mesa-driver lib32-mesa-vdpau
        fi
        ;;
    N)
        pacstrap /mnt nvidia-dkms nvidia-utils nvidia-settings
        if [[ -d /mnt/etc/pacman.d/ ]]; then
            pacstrap /mnt lib32-nvidia-utils
        fi
        print_warning "VA-API support requires nvidia-vaapi-driver from AUR"
        ;;
    I)
        pacstrap /mnt mesa vulkan-intel intel-media-driver libvdpau-va-gl intel-gpu-tools
        if confirm_action "Install X11 drivers?"; then
            pacstrap /mnt xf86-video-intel
        fi
        if [[ -d /mnt/etc/pacman.d/ ]]; then
            pacstrap /mnt lib32-mesa lib32-vulkan-intel
        fi
        ;;
esac

# Generate fstab
print_step "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

# Create swapfile (if desired)
if confirm_action "Create BTRFS swapfile (4GB)?"; then
    print_step "Creating swapfile..."
    truncate -s 0 /mnt/swap/swapfile
    chattr +C /mnt/swap/swapfile
    fallocate -l 4G /mnt/swap/swapfile
    chmod 600 /mnt/swap/swapfile
    mkswap /mnt/swap/swapfile
    echo "/swap/swapfile none swap defaults 0 0" >> /mnt/etc/fstab
fi

# Copy installation files
print_step "Copying installation files..."
mkdir -p /mnt/archBT
cp -r ./* /mnt/archBT/

# Export variables for chroot script
cat > /mnt/archBT/chroot_vars.sh << EOF
#!/bin/bash
export EFI_PARTITION="$EFI_PARTITION"
export ROOT_PARTITION="$ROOT_PARTITION"
export KERNELS=(${KERNELS[@]})
export KERNEL_PRESETS=(${KERNEL_PRESETS[@]})
export GPU="$GPU"
EOF
chmod +x /mnt/archBT/chroot_vars.sh

print_step "Base installation complete!"
print_step "Run the following command to continue:"
echo -e "${GREEN}arch-chroot /mnt /archBT/scripts/2_rootChroot.sh${NC}"
