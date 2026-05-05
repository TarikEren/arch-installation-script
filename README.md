# arch-installation-script

Installs Arch Linux with LUKS encrypted BTRFS and Limine Bootloader.
- Handles non-UEFI compliant motherboard issues with Limine.

## Installation
Run:
```bash
curl -OJ https://raw.githubusercontent.com/TarikEren/arch-installation-script/refs/heads/main/install.sh
```
to download the script.

## Usage
- This program is designed to be ran on new installations using arch iso.
  - Any misuse (Not running on arch live boot, not reading prompts etc.) might cause irreparable damage to your system. Handle with caution.

Run:
```bash
chmod +x install.sh
./install.sh
```
and follow the prompts.
