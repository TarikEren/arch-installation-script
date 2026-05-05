# arch-installation-script  (WIP)

Installs Arch Linux with LUKS encrypted BTRFS and Limine Bootloader.
- Handles non-UEFI compliant motherboard issues with Limine.

## Installation

### Main Installation Script
Run:
```bash
curl -OJ https://raw.githubusercontent.com/TarikEren/arch-installation-script/refs/heads/main/install.sh
```
to download the script.

### Post Installation Script
```bash
curl -OJ https://raw.githubusercontent.com/TarikEren/arch-installation-script/refs/heads/main/post-install.sh
```

## Usage
- This program is designed to be ran on new installations using arch iso.
  - Any misuse (Not running on arch live boot, not reading prompts etc.) might cause irreparable damage to your system. Handle with caution.

### Main Installation Script
Run:
```bash
chmod +x install.sh
./install.sh
```
and follow the prompts.

### Post Installation Script
Run:
```bash
chmod +x post_install.sh
./post_install.sh
```
and follow the prompts.
