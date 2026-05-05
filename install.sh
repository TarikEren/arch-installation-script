# TODO: Add auto confirm on pacman package installs
install_complete=0
keymap="us"
disk=""
username=""
host_name=""
password=""
microcode=""
gpu_driver=""
root_disk=""
packages=(base linux linux-firmware base-devel btrfs-progs efibootmgr limine networkmanager iwd dhcpcd cryptsetup util-linux git bash-completion avahi acpi acpi_call acpid alsa-utils nvim pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber sof-firmware firewalld bluez bluez-utils cups openssh reflector man sudo rsync udisks2 ttf-jetbrains-mono-nerd)

# Fail quick and loud
set -euo pipefail

# Root check
if [ "`id -u`" -ne 0 ]
then
    printf "[ERROR] Run this script as root\n"
    exit -1
fi

cleanup() {
    if [[ $install_complete -eq 1 ]]; then
        return
    fi
    printf "[WARN] Script interrupted or failed — cleaning up...\n"
    umount -R /mnt 2>/dev/null || true
    cryptsetup close root 2>/dev/null || true
}

trap cleanup EXIT

connect_to_wifi() {
    while true; do
        printf "[INFO] Scanning for Wi-Fi networks...\n"

        mapfile -t networks < <(
          nmcli -t -f SSID,SIGNAL,SECURITY dev wifi list --rescan yes \
            | awk -F: 'NF >= 3 && $1 != "" { print }' \
            | sort -u
        )

    if (( ${#networks[@]} == 0 )); then
        printf "[ERROR] No Wi-Fi networks found.\n"
        return 1
    fi

        printf "[INFO] Available networks:\n"
    for i in "${!networks[@]}"; do
        IFS=: read -r ssid signal security <<< "${networks[$i]}"
        printf '%2d) %-32s  signal=%-3s  security=%s\n' \
        $((i + 1)) "$ssid" "$signal" "$security"
    done

    read -r -p "Select network number: " choice

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#networks[@]} )); then
        printf "[ERROR] Invalid selection.\n"
        continue
    fi

    IFS=: read -r ssid signal security <<< "${networks[$((choice - 1))]}"

    echo
    read -r -s -p "[PROMPT] Password for '$ssid' (leave blank for open network): " wifi_password
    echo

    printf "[INFO] Connecting to '$ssid'...\n"
    if [[ -n "$wifi_password" ]]; then
        if nmcli dev wifi connect "$ssid" password "$wifi_password"; then
            printf "[INFO] Connected to '$ssid'.\n"
            return 0
        fi
    else
        if nmcli dev wifi connect "$ssid"; then
            printf "[INFO] Connected to '$ssid'.\n"
            return 0
        fi
    fi

    printf "[ERROR] Failed to connect to '$ssid'. Returning to network list...\n"
    done
}

handle_connection() {
    printf "[INFO] Checking internet connectivity...\n"
    echo -e "GET http://google.com HTTP/1.0\n\n" | nc google.com 80 > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        printf "[INFO] Connected to internet\n"
    else
        if ! connect_to_wifi; then
            printf "[ERROR] Network connection failed. Solve network connection issues and re-run script.\n"
            exit 1
        fi
    fi
}

get_keyboard_layout() {
    while true; do
        read -p "[PROMPT] Enter keyboard layout. (Leave empty for 'us'): " usr_key_layout
        if localectl list-keymaps | grep -x "$usr_key_layout" > /dev/null; then
            printf "[INFO] Set '%s' as keyboard keymap\n" "$usr_key_layout"
            keymap=$usr_key_layout
            break
        elif [ -z "$usr_key_layout" ]; then
            printf "[INFO] Set 'us' as keyboard keymap\n"
            keymap="us"
            break
        else
            printf "[ERROR] Invalid layout\n"
        fi
    done
}

get_locale() {
    while true; do
        read -p "[PROMPT] Enter locale in the form of xx_XX. (Leave empty for en_US): " usr_locale
        if [[ "$usr_locale" == "" ]]; then
            locale="en_US"
            break
        elif [[ "$usr_locale" =~ ^[a-z]{2}_[A-Z]{2}$ ]]; then
            locale="$usr_locale"
            break
        else
            printf "[ERROR] Invalid locale format. Expected format: xx_XX (e.g. en_US)\n"
        fi
    done
    printf "[INFO] Using locale: %s\n" "$locale"
}

get_usr_info() {
    while [ -z "$host_name" ]; do
        read -p "[PROMPT] Enter host name: " host_name
    done

    while [ -z "$username" ]; do
        read -p "[PROMPT] Enter root user name: " username
    done

    while [ -z "$password" ]; do
        read -p "[PROMPT] Enter password (Root / Encryption / User): " password
    done
}

get_disk() {
    mapfile -t disks < <(
        lsblk -dn -o NAME,SIZE,TYPE | awk '$3 == "disk"'
    )

    if (( ${#disks[@]} == 0 )); then
        printf "[ERROR] No disks found\n"
        exit 1
    fi

    printf "Available disks:\n"
    for i in "${!disks[@]}"; do
        read -r name size type <<< "${disks[$i]}"
        printf '%2d- /dev/%-8s %-10s %s\n' "$((i + 1))" "$name" "$size" "$type"
    done

    while true; do
        read -r -p "[PROMPT] Select disk number: " disk
        if [[ "$disk" =~ ^[0-9]+$ ]] && (( disk >= 1 && disk <= ${#disks[@]} )); then
            printf "[PROMPT] The selected disk will be completely wiped. All partition data and files will be lost.\n"
            read -r -p "Do you want to continue (y/n): " cont_opt
            if [[ $cont_opt == [yY] ]]; then
                selected_disk="/dev/${disks[$((disk - 1))]%% *}"
                break
            else
                printf "[INFO] Exiting...\n"
                exit 1
            fi
        else
            printf "[ERROR] Invalid selection.\n"
        fi
    done

    printf "[INFO] Selected disk: %s\n" "$selected_disk"
    disk="$selected_disk"
}
handle_partitions() {
    printf "[INFO] Clearing disk and creating partitions\n"
    sgdisk -Zo "$disk" &> /dev/null
    parted --script "$disk" mklabel gpt mkpart ESP fat32 1MiB 2049MiB set 1 esp on mkpart Linux btrfs 2050MiB 100%
    local ESP="/dev/disk/by-partlabel/ESP"
    local LINUX="/dev/disk/by-partlabel/Linux"

    printf "[INFO] Notifying system about partitions\n"
    udevadm settle
    partprobe "$disk"

    printf "[INFO] Setting EFI partition\n"
    mkfs.fat -F 32 "$ESP" &>/dev/null

    printf "[INFO] Setting LUKS encryption\n"
    echo -n "$password" | cryptsetup luksFormat "$LINUX" -d - &>/dev/null
    echo -n "$password" | cryptsetup open "$LINUX" root -d - 
    root_disk="/dev/mapper/root"

    printf "[INFO] Setting root BTRFS partition\n"
    mkfs.btrfs "$root_disk" &>/dev/null

    printf "[INFO] Mounting disk and creating subvolumes\n"
    mount "$root_disk" /mnt
    btrfs subvolume create /mnt/@ /mnt/@home /mnt/@var_log /mnt/@var_cache
    umount /mnt

    printf "[INFO] Mounting partitions\n"
    MOUNT_ARGS="compress=zstd:1,noatime"
    mount -o "$MOUNT_ARGS",subvol=@ "$root_disk" /mnt
    mount --mkdir -o "$MOUNT_ARGS",subvol=@home "$root_disk" /mnt/home
    mount --mkdir -o "$MOUNT_ARGS",subvol=@var_log "$root_disk" /mnt/var/log
    mount --mkdir -o "$MOUNT_ARGS",subvol=@var_cache "$root_disk" /mnt/var/cache
    mount --mkdir "$ESP" /mnt/boot
}

get_cpu_and_gpu() {
    printf "[INFO] Checking CPU info\n"
    local cpu=$(grep vendor_id /proc/cpuinfo)
    if [[ "$cpu" == *"AuthenticAMD"* ]]; then
        packages+=(amd-ucode)
        printf "[INFO] AMD CPU detected\n"
    else
        packages+=(intel-ucode)
        printf "[INFO] Intel CPU detected\n"
    fi

    printf "[INFO] Checking GPU info\n"
    # TODO: Implement a more detailed gpu detection
    local gpu=$(lspci -vnn | grep -i VGA | grep -i NVIDIA)
    if [[ "$gpu" ]]; then
        packages+=(nvidia-open)
    fi
}

configure_limine() {
    local root_uuid=$(cryptsetup luksUUID /dev/disk/by-partlabel/Linux)
    local conf_path=""
    local efi_bin_path=""
    local efi_str_bin_path=""
    printf "[INFO] Setting up limine bootloader\n"
    if dmidecode -s baseboard-manufacturer | grep -qi micro-star; then
        printf "[INFO] MSI motherboard detected, using fallback path\n"
        conf_path="/boot/EFI/BOOT/limine.conf"
        efi_bin_path="/boot/EFI/BOOT/"
        efi_str_bin_path="\\EFI\\BOOT\\BOOTX64.EFI"
    else
        printf "[INFO] Using default limine configuration\n"
        conf_path="/boot/EFI/limine/limine.conf"
        efi_bin_path="/boot/EFI/limine/"
        efi_str_bin_path="\\EFI\\limine\\BOOTX64.EFI"
    fi

    printf "[INFO] Creating paths and boot entry\n"
    arch-chroot /mnt /bin/bash <<EOF
        mkdir -p $efi_bin_path
        cp /usr/share/limine/BOOTX64.EFI $efi_bin_path
        efibootmgr --create --disk $disk --part 1 --label "Arch Linux Limine Bootloader" --loader '$efi_str_bin_path' --unicode &> /dev/null
EOF

    printf "[INFO] Generating Limine configuration\n"
    cat > /mnt/"$conf_path" <<EOF
timeout: 3

/Arch Linux
    protocol: linux
    path: boot():/vmlinuz-linux
    cmdline: cryptdevice=UUID=$root_uuid:root root=/dev/mapper/root rw rootflags=subvol=@ rootfstype=btrfs
    module_path: boot():/initramfs-linux.img

/Arch Linux (fallback)
    protocol: linux
    path: boot():/vmlinuz-linux
    cmdline: cryptdevice=UUID=$root_uuid:root root=/dev/mapper/root rw rootflags=subvol=@ rootfstype=btrfs
    module_path: boot():/initramfs-linux-fallback.img
EOF
}

configure_system_details() {
    printf "[INFO] Detecting timezone...\n"
    local timezone=$(curl -s --max-time 5 https://ipapi.co/timezone)

    # Validate: must look like Region/City
    if [[ ! "$timezone" =~ ^[A-Za-z_]+/[A-Za-z_/]+$ ]]; then
        printf "[WARN] Could not detect timezone automatically.\n"
        read -p "[PROMPT] Enter timezone (e.g. Europe/Istanbul): " timezone
    fi
    printf "[INFO] Setting local time and language...\n"
    printf "%s\nen_US.UTF-8 UTF-8\n" "$locale" > /mnt/etc/locale.gen
    echo LANG="en_US.UTF-8" > /mnt/etc/locale.conf
    echo KEYMAP="$keymap" >> /mnt/etc/vconsole.conf
    arch-chroot /mnt /bin/bash <<EOF
        ln -sf /usr/share/zoneinfo/$timezone /etc/localtime &>/dev/null
        locale-gen &> /dev/null
        hwclock --systohc
EOF

    printf "[INFO] Setting up user...\n"
    echo "root:$password" | arch-chroot /mnt chpasswd
    echo "%wheel ALL=(ALL:ALL) ALL" > /mnt/etc/sudoers.d/wheel
    echo "$username" > /mnt/etc/hostname
    arch-chroot /mnt useradd -m -G wheel -s /bin/bash "$username"
    echo "$username:$password" | arch-chroot /mnt chpasswd
}

# Get network connection
handle_connection

# Handle keyboard layout
get_keyboard_layout

# Get locale
get_locale

# Handle host name, user name and password
get_usr_info

# List disk names and prompt
get_disk

# Present config to the user
printf "########## SYSTEM CONFIGURATION ##########\n"
printf "Username: %s\nPassword: %s\nKeyboard Layout: %s\nDisk Name: %s\n" "$username" "$password" "$keymap" "$disk"
read -r -p "[PROMPT] Would you like to proceed (y/n): " confirm
if ! [[ $confirm == [yY] ]]; then
    printf "[INFO] Exiting...\n"
    exit 1
fi

# Handle partitions
handle_partitions

# Get CPU and GPU model
get_cpu_and_gpu

printf "[INFO] Refreshing package database with keyring and installing packages...\n"
pacman -Syy --noconfirm archlinux-keyring
pacman-key --init
pacman-key --populate archlinux
pacstrap -K /mnt --noconfirm "${packages[@]}"

printf "[INFO] Generating fstab...\n"
genfstab -U /mnt >> /mnt/etc/fstab &> /dev/null

printf "[INFO] Generating mkinitcpio.conf...\n"
cat > /mnt/etc/mkinitcpio.conf <<EOF
MODULES=(btrfs)
BINARIES=(/usr/bin/btrfs)
FILES=()
HOOKS=(base udev autodetect microcode modconf kms keyboard keymap block encrypt filesystems resume fsck)
EOF

printf "[INFO] Generating system images...\n"
arch-chroot /mnt /bin/bash <<EOF
    mkinitcpio -P &> /dev/null
EOF

configure_system_details

configure_limine

printf "[INFO] Finalizing system installation...\n"
printf "[INFO] Starting services pre-reboot...\n"
arch-chroot /mnt /bin/bash <<EOF
    systemctl enable NetworkManager dhcpcd iwd systemd-networkd systemd-resolved bluetooth cups avahi-daemon firewalld acpid reflector.timer
EOF

install_complete=1
printf "[INFO] Installation completed. You may now reboot.\n"
