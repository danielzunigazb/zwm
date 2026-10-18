#!/bin/sh
# Build and register zwm as a login session (SDDM/GDM/LightDM list /usr/share/xsessions).
# Usage: ./install.sh            install
#        ./install.sh uninstall  remove
set -e
cd "$(dirname "$0")"

if [ "$1" = "uninstall" ]; then
    sudo rm -f /usr/local/bin/zwm /usr/local/bin/zwm-session /usr/share/xsessions/zwm.desktop
    echo "zwm removed."
    exit 0
fi

zig build -Drelease
sudo install -Dm755 zig-out/bin/wm /usr/local/bin/zwm
sudo install -Dm755 session/zwm-session /usr/local/bin/zwm-session
sudo install -Dm644 session/zwm.desktop /usr/share/xsessions/zwm.desktop
echo "zwm installed. Pick 'zwm' in your display manager's session menu."
