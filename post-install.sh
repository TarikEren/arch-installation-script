# Fail quick and loud
set -euo pipefail
install_complete=0
cleanup() {
    if [[ $install_complete -eq 1 ]]; then
        return
    fi
    printf "[WARN] Script interrupted or failed — cleaning up...\n"
    umount -R /mnt 2>/dev/null || true
    cryptsetup close root 2>/dev/null || true
}

trap cleanup EXIT

setup_yay() {
    if [[ -d "~/yay" ]]; then
        return 0
    else
        cd ~
        sudo pacman -S --noconfirm git
        git clone https://aur.archlinux.org/yay.git
        cd yay && makepkg -si --noconfirm
        cd ~
    fi
}

enable_trim() {
    mapfile -t disks < <(lsblk -d -n -o NAME,TYPE | awk '$2 == "disk" {print "/dev/"$1}')
    for disk in "${disks[@]}"; do
        read -r disc_gran disc_max < <(lsblk -d -n -o DISC-GRAN,DISC-MAX "$disk")
        if [[ "$disc_gran" != "0B" ]] && [[ "$disc_max" != "0B" ]]; then
            printf "[INFO] %s supports TRIM (GRAN: %s, MAX: %s)\n" "$disk" "$disc_gran" "$disc_max"
            systemctl enable --now fstrim.timer
        else
            printf "[INFO] %s does NOT support TRIM\n" "$disk"
        fi
    done
}

add_pacman_limine_hook() {
    mkdir -p /etc/pacman.d/hooks
    path=""
    [[ -d "/boot/EFI/BOOT" ]] && path="/boot/EFI/BOOT" || path="/boot/EFI/limine"
    cat > /etc/pacman.d/hooks/99-limine.hook <<EOF
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
    local GB_DENOM=$((1024 * 1024))
    local mem_size_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local mem_size_gb=$(($mem_size_kb / $GB_DENOM))
    sudo btrfs subvolume create /swap
    sudo btrfs filesystem mkswapfile --size "$mem_size_gb"g --uuid clear /swap/swapfile
    sudo swapon -p 0 /swap/swapfile
    sudo echo "/swap/swapfile none swap defaults,pri=0 0 0" >> /etc/fstab
    sudo mkinitcpio -P
}

configure_snapper() {
    sudo pacman -S --noconfirm snapper snap-pac
    yay -S limine-snapper-sync limine-mkinitcpio-hook
    sudo snapper -c root create-config /
    sudo snapper -c home create-config /home
    sudo sed -i 's/^TIMELINE_CREATE="yes"/TIMELINE_CREATE="no"/' /etc/snapper/configs/{root,home}
    sudo sed -i 's/^NUMBER_LIMIT="50"/NUMBER_LIMIT="5"/' /etc/snapper/configs/{root,home}
    sudo sed -i 's/^NUMBER_LIMIT_IMPORTANT="10"/NUMBER_LIMIT_IMPORTANT="5"/' /etc/snapper/configs/{root,home}
    sudo cp /etc/limine-entry-tool.conf /etc/default/limine
    sudo echo "ROOT_SNAPSHOTS_PATH=/@snapshots" >> /etc/default/limine

    [[ -d "/boot/EFI/BOOT" ]] && sudo rm "/boot/EFI/BOOT/limine.conf" || sudo rm "/boot/EFI/limine/limine.conf"
    if [[ -d "/boot/EFI/BOOT" ]]; then
        sudo limine-install --skip-uefi --fallback
    else
        sudo limine-install
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
