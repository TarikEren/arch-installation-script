# Fail quick and loud
set -euo pipefail
install_complete=0
cleanup() {
    if [[ $install_complete -eq 1 ]]; then
        return
    fi
    printf "[WARN] Script interrupted or failed\n"
}

trap cleanup EXIT

setup_yay() {
    cd ~
    if [[ -d "./yay" ]]; then
        return 0
    else
        git clone https://aur.archlinux.org/yay.git
        cd yay && makepkg -si --noconfirm
        cd ~
    fi
}

enable_trim() {
    if systemctl list-unit-files | grep "fstrim.timer"; then
        printf "[INFO] Enabling fstrim.timer\n"
        systemctl enable --now fstrim.timer
    else
        printf "[INFO] No support for fstrim detected\n"
    fi
}

add_pacman_limine_hook() {
    sudo mkdir -p /etc/pacman.d/hooks
    path=""
    [[ -d "/boot/EFI/BOOT" ]] && path="/boot/EFI/BOOT" || path="/boot/EFI/limine"
    if [[ -f "/etc/pacman.d/hooks/99-limine.hook" ]]; then
        printf "[WARN] Pacman limine hook already exists\n"
        read -p "[PROMPT] Overwrite hook? (y/n): " hook_opt
        if [[ "$hook_opt" != [yY] ]]; then
            return 0
        fi
    fi
    sudo tee /etc/pacman.d/hooks/99-limine.hook <<EOF
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = limine

[Action]
Description = Deploying Limine after upgrade...
When = PostTransaction
Exec = /usr/bin/cp /usr/share/limine/BOOTX64.EFI $path
EOF
}

add_swap() {
    local mem_total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local disk_total_kb=$(($(lsblk -bno SIZE | head -n1) / 1024))

    if [[ "$mem_total_kb" -ge "$disk_total_kb" ]]; then
        mem_total_kb=$(($mem_total_kb / 2))
    fi

    local swap_size_gb=$((mem_total_kb / 1024 / 1024))

    [[ "$swap_size_gb" -le 0 ]] && swap_size_gb=1

    if sudo btrfs subvolume list / | grep -i "swap"; then
        printf "[WARN] Swap subvolume exists\n"
        return 0
    fi
    sudo btrfs subvolume create /swap
    if cat /proc/swaps | grep -i "swapfile"; then
        printf "[WARN] Swapfile exists\n"
    else
        sudo btrfs filesystem mkswapfile --size "$swap_size_gb"g --uuid clear /swap/swapfile
        sudo swapon -p 0 /swap/swapfile
    fi
    if ! cat /etc/fstab | grep -i "swapfile"; then
        echo "/swap/swapfile none swap defaults,pri=0 0 0" | sudo tee -a /etc/fstab >/dev/null
        sudo mkinitcpio -P
    fi
}

configure_snapper() {
    local root_snapper_conf="/etc/snapper/configs/root"
    local home_snapper_conf="/etc/snapper/configs/home"
    local limine_conf=""
    if [[ -f '/boot/EFI/BOOT/limine.conf' ]]; then
        limine_conf="/boot/EFI/BOOT/limine.conf"
    elif [[ -f '/boot/EFI/limine/limine.conf' ]]; then
        limine_conf="/boot/EFI/limine/limine.conf"
    else
        printf "[WARN] No limine.conf found"
        return 1
    fi
    if [[ -f "$root_snapper_conf" ]]; then
        printf "[WARN] Pre-existing snapper config file found at '%s'. Aborting configuration creation\n" "$root_snapper_conf"
        return 0
    fi
    if [[ -f "$home_snapper_conf" ]]; then
        printf "[WARN] Pre-existing snapper config file found at '%s'. Aborting configuration creation\n" "$home_snapper_conf"
        return 0
    fi

    sudo pacman -S --needed --noconfirm snapper snap-pac jdk-openjdk
    yay -S --needed --noconfirm --answerdiff None --answerclean None limine-snapper-sync limine-mkinitcpio-hook

    sudo snapper -c root create-config /
    sudo snapper -c home create-config /home
    sudo cp /etc/limine-entry-tool.conf /etc/default/limine

    local btrfs_dev=$(findmnt -n -o SOURCE /)
    btrfs_dev="${btrfs_dev%%\[*}"
    if ! grep -q "/.snapshots" /etc/fstab; then
        echo "$btrfs_dev /.snapshots btrfs subvol=@snapshots,compress=zstd,noatime 0 0" | sudo tee -a /etc/fstab >/dev/null
    fi

    sudo mount "$btrfs_dev" /mnt -o subvolid=5
    if [[ ! -d "/mnt/@snapshots" ]]; then
        sudo btrfs subvolume create /mnt/@snapshots
    fi
    sudo umount /mnt

    sudo mount /.snapshots
    sudo chmod 750 /.snapshots

    sudo sed -i 's/^TIMELINE_CREATE="yes"/TIMELINE_CREATE="no"/' /etc/snapper/configs/{root,home}
    sudo sed -i 's/^NUMBER_LIMIT="50"/NUMBER_LIMIT="5"/' /etc/snapper/configs/{root,home}
    sudo sed -i 's/^NUMBER_LIMIT_IMPORTANT="10"/NUMBER_LIMIT_IMPORTANT="5"/' /etc/snapper/configs/{root,home}
    echo "ROOT_SNAPSHOTS_PATH=/@snapshots" | sudo tee -a /etc/default/limine >/dev/null

    if [[ -d "/boot/EFI/BOOT" ]]; then
        sudo rm -f "/boot/EFI/BOOT/limine.conf"
        sudo limine-install --skip-uefi --fallback
    else
        sudo rm -f "/boot/EFI/limine/limine.conf"
        sudo limine-install
    fi

    if [[ -f "/boot/limine.conf" ]]; then
        if ! grep -q "//Snapshots" "$limine_conf"; then
            printf "[INFO] Injecting Snapshots marker into %s\n" "$limine_conf"
            # Inserts //Snapshots after the cmdline in the //linux entry
            sudo sed -i '/\/\/linux/I,/cmdline/ s/cmdline.*/&\n  \/\/Snapshots/' "$limine_conf"
        fi
    fi

    sudo limine-snapper-sync
    sudo systemctl enable --now limine-snapper-sync.service
}

add_automatic_firmware_updates() {
    sudo pacman -Syu --noconfirm fwupd
    fwupdmgr get-devices || true
    fwupdmgr refresh || true
    fwupdmgr get-updates || true
    fwupdmgr update || true
    sudo systemctl enable --now fwupd-refresh.timer
}

printf "[INFO] Setting up yay\n"
setup_yay

printf "[INFO] Checking and enabling trim if available\n"
enable_trim

printf "[INFO] Adding pacman limine hook\n"
add_pacman_limine_hook

printf "[INFO] Creating swapfile\n"
add_swap

printf "[INFO] Configuring snapper\n"
configure_snapper

printf "[INFO] Adding automatic firmware updates\n"
add_automatic_firmware_updates

install_complete=1
printf "[INFO] Installation complete\n"
