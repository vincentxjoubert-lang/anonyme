#!/usr/bin/env bash
# Debian 13.6 "trixie" - poste Openbox stable et sécurisé
# Exécution : sudo ./debian13-openbox-stable.sh --user NOM

set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export LC_ALL=C.UTF-8

readonly SCRIPT_NAME="${0##*/}"
readonly LOG_FILE="/var/log/debian13-openbox-stable.log"
readonly AUDIT_FILE="/var/log/debian13-openbox-audit.log"

MODE="install"
TARGET_USER="${SUDO_USER:-}"

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$LOG_FILE"; }
die() { printf 'ERREUR: %s\n' "$*" >&2; exit 1; }
trap 'printf "ERREUR ligne %s. Voir %s\n" "$LINENO" "$LOG_FILE" >&2' ERR

while (( $# )); do
    case "$1" in
        --user)
            [[ $# -ge 2 ]] || die "--user exige un nom."
            TARGET_USER="$2"
            shift 2
            ;;
        --audit-only)
            MODE="audit"
            shift
            ;;
        -h|--help)
            printf 'Usage: sudo %s --user NOM [--audit-only]\n' "$SCRIPT_NAME"
            exit 0
            ;;
        *) die "Option inconnue: $1" ;;
    esac
done

[[ $EUID -eq 0 ]] || die "Lancer avec sudo."
[[ -r /etc/os-release ]] || die "/etc/os-release absent."
# shellcheck disable=SC1091
source /etc/os-release
[[ ${ID:-} == "debian" && ${VERSION_CODENAME:-} == "trixie" ]] || \
    die "Ce script exige Debian 13 trixie."
[[ $(dpkg --print-architecture) == "amd64" ]] || die "Architecture amd64 exigée."

[[ -n $TARGET_USER && $TARGET_USER != "root" ]] || \
    die "Préciser l'utilisateur: sudo ./$SCRIPT_NAME --user NOM"
id "$TARGET_USER" >/dev/null 2>&1 || die "Utilisateur introuvable: $TARGET_USER"

TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
TARGET_GROUP="$(id -gn "$TARGET_USER")"
[[ -d $TARGET_HOME ]] || die "Dossier personnel introuvable: $TARGET_HOME"

write_root_file() {
    local mode="$1" path="$2"
    install -D -m "$mode" /dev/stdin "$path"
}

write_user_file() {
    local mode="$1" path="$2"
    install -D -m "$mode" -o "$TARGET_USER" -g "$TARGET_GROUP" /dev/stdin "$path"
}

as_user() {
    runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" USER="$TARGET_USER" \
        LOGNAME="$TARGET_USER" XDG_CONFIG_HOME="$TARGET_HOME/.config" \
        XDG_DATA_HOME="$TARGET_HOME/.local/share" "$@"
}

package_installed() {
    dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null | grep -qx installed
}

package_available() {
    local candidate
    candidate="$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"
    [[ -n $candidate && $candidate != "(none)" ]]
}

require_packages() {
    local missing=() package
    for package in "$@"; do
        package_available "$package" || missing+=("$package")
    done
    ((${#missing[@]} == 0)) || die "Paquets absents des dépôts: ${missing[*]}"
}

install_packages() {
    require_packages "$@"
    apt-get -y -qq install --no-install-suggests "$@"
}

unit_exists() {
    systemctl list-unit-files "$1" --no-legend 2>/dev/null | grep -q .
}

disable_unit() {
    local unit="$1"
    unit_exists "$unit" || return 0
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
    systemctl mask "$unit" >/dev/null
}

user_dir() {
    install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_GROUP" "$1"
}

audit_system() {
    local failures=0 warnings=0 dpkg_audit exec_count helper helpers_ok=1 owner
    : >"$AUDIT_FILE"

    audit_ok() { printf 'OK   %s\n' "$*" >>"$AUDIT_FILE"; }
    audit_warn() { printf 'WARN %s\n' "$*" >>"$AUDIT_FILE"; warnings=$((warnings + 1)); }
    audit_fail() { printf 'FAIL %s\n' "$*" >>"$AUDIT_FILE"; failures=$((failures + 1)); }
    audit_cmd() {
        local label="$1"
        shift
        if "$@" >>"$AUDIT_FILE" 2>&1; then audit_ok "$label"; else audit_fail "$label"; fi
    }

    printf 'Audit Debian/Openbox - %s\n\n' "$(date --iso-8601=seconds)" >>"$AUDIT_FILE"

    if [[ ${VERSION_CODENAME:-} == "trixie" ]]; then audit_ok "Debian trixie"; else audit_fail "Version Debian"; fi
    if dpkg_audit="$(dpkg --audit 2>&1)" && [[ -z $dpkg_audit ]]; then
        audit_ok "dpkg cohérent"
    else
        printf '%s\n' "$dpkg_audit" >>"$AUDIT_FILE"
        audit_fail "dpkg incohérent"
    fi
    audit_cmd "Dépendances APT" apt-get -qq check
    audit_cmd "XML menu Openbox" xmllint --noout "$TARGET_HOME/.config/openbox/menu.xml"
    audit_cmd "XML configuration Openbox" xmllint --noout "$TARGET_HOME/.config/openbox/rc.xml"
    audit_cmd "Menu personnalisé sélectionné" grep -Fq \
        "<file>$TARGET_HOME/.config/openbox/menu.xml</file>" \
        "$TARGET_HOME/.config/openbox/rc.xml"
    audit_cmd "Thème Openbox sombre" grep -Fq '<name>Nightmare-02</name>' \
        "$TARGET_HOME/.config/openbox/rc.xml"
    audit_cmd "Police Openbox Inter" grep -Fq '<name>Inter</name>' \
        "$TARGET_HOME/.config/openbox/rc.xml"
    if grep -Fq '<file>/var/lib/openbox/debian-menu.xml</file>' \
        "$TARGET_HOME/.config/openbox/rc.xml"; then
        audit_fail "Menu Debian encore prioritaire"
    else
        audit_ok "Menu Debian retiré"
    fi
    audit_cmd "Lanceur Openbox" dash -n "$TARGET_HOME/.local/bin/openbox-startup"
    audit_cmd "Autostart Openbox" dash -n "$TARGET_HOME/.config/openbox/autostart"
    audit_cmd "Autostart XDG" desktop-file-validate \
        "$TARGET_HOME/.config/autostart/openbox-components.desktop"
    exec_count="$(grep -c '^execp = new$' "$TARGET_HOME/.config/tint2/tint2rc" 2>/dev/null || true)"
    if grep -Fqx 'panel_items = LTEEEESC' "$TARGET_HOME/.config/tint2/tint2rc" 2>/dev/null && \
        grep -Fqx 'panel_position = top center horizontal' "$TARGET_HOME/.config/tint2/tint2rc" 2>/dev/null && \
        grep -Fqx 'panel_dock = 1' "$TARGET_HOME/.config/tint2/tint2rc" 2>/dev/null && \
        [[ $exec_count == 4 ]]; then
        audit_ok "Configuration barre Tint2"
    else
        audit_fail "Configuration barre Tint2"
    fi
    for helper in panel-cpu panel-ram panel-gpu panel-net; do
        [[ -x $TARGET_HOME/.local/bin/$helper ]] || helpers_ok=0
    done
    if (( helpers_ok )); then audit_ok "Widgets Tint2 exécutables"; else audit_fail "Widgets Tint2 incomplets"; fi
    audit_cmd "Service Wi-Fi" systemd-analyze verify /etc/systemd/system/disable-wifi.service

    if xkbcli compile-keymap --rules evdev --model pc105 --layout fr_numlock \
        --variant basic >/dev/null 2>>"$AUDIT_FILE"; then
        audit_ok "Clavier XKB français/chiffres Caps Lock"
    else
        audit_fail "Compilation XKB français/chiffres Caps Lock"
    fi

    if systemctl is-enabled lightdm.service >/dev/null 2>&1; then audit_ok "LightDM activé"; else audit_fail "LightDM non activé"; fi
    if systemctl is-active apparmor.service >/dev/null 2>&1; then audit_ok "AppArmor actif"; else audit_fail "AppArmor inactif"; fi
    if systemctl is-active systemd-resolved.service >/dev/null 2>&1; then audit_ok "DNS systemd-resolved actif"; else audit_fail "DNS inactif"; fi
    if systemctl is-active NetworkManager.service >/dev/null 2>&1; then audit_ok "NetworkManager actif"; else audit_fail "NetworkManager inactif"; fi
    if systemctl is-active bluetooth.service >/dev/null 2>&1; then audit_ok "Bluetooth actif"; else audit_warn "Bluetooth inactif"; fi
    if systemctl is-enabled fstrim.timer >/dev/null 2>&1; then audit_ok "TRIM SSD programmé"; else audit_fail "TRIM SSD non programmé"; fi
    if systemctl is-enabled unattended-upgrades.service >/dev/null 2>&1; then audit_ok "Mises à jour automatiques"; else audit_fail "Mises à jour automatiques"; fi
    if ufw status 2>/dev/null | grep -q '^Status: active'; then audit_ok "UFW actif"; else audit_fail "UFW inactif"; fi
    if ufw status verbose 2>/dev/null | grep -q 'Default: deny (incoming), allow (outgoing), deny (routed)'; then
        audit_ok "Politique UFW DROP entrant/routé"
    else
        audit_fail "Politique UFW incorrecte"
    fi
    if aa-enabled >/dev/null 2>&1; then audit_ok "AppArmor noyau"; else audit_fail "AppArmor noyau"; fi

    if [[ $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) == "bbr" ]]; then audit_ok "TCP BBR"; else audit_warn "BBR non chargé"; fi
    if [[ $(sysctl -n net.core.default_qdisc 2>/dev/null) == "fq" ]]; then audit_ok "Ordonnanceur réseau fq"; else audit_warn "qdisc fq non actif"; fi

    if resolvectl status 2>/dev/null | grep -q '9\.9\.9\.9'; then audit_ok "Quad9 configuré"; else audit_fail "Quad9 absent"; fi
    if resolvectl status 2>/dev/null | grep -Eq 'DNS over TLS setting: yes|\+DNSOverTLS'; then
        audit_ok "DNS-over-TLS strict"
    else
        audit_warn "DNS-over-TLS non confirmé par resolvectl status"
    fi
    if resolvectl query --type=TXT proto.on.quad9.net 2>>"$AUDIT_FILE" | grep -q 'dot\.'; then
        audit_ok "Quad9 confirme le protocole DoT"
    else
        audit_warn "Quad9 ne confirme pas encore le protocole DoT"
    fi

    for package in brave-browser code virtualbox-7.2 steam-installer qalculate-qt \
        firmware-amd-graphics amd64-microcode fonts-inter fonts-jetbrains-mono; do
        if package_installed "$package"; then
            audit_ok "Paquet $package"
        else
            audit_fail "Paquet $package absent"
        fi
    done

    audit_cmd "Commande Brave" test -x /usr/bin/brave-browser
    audit_cmd "Commande VS Code" test -x /usr/bin/code
    audit_cmd "Lanceur Brave" test -r /usr/share/applications/brave-browser.desktop
    audit_cmd "Lanceur VS Code" test -r /usr/share/applications/code.desktop
    if flatpak info --system com.discordapp.Discord >/dev/null 2>&1; then audit_ok "Discord Flatpak"; else audit_fail "Discord absent"; fi
    if flatpak info --system org.vinegarhq.Sober >/dev/null 2>&1; then audit_ok "Sober Flatpak"; else audit_fail "Sober absent"; fi
    audit_cmd "Lanceur Discord" test -r \
        /var/lib/flatpak/exports/share/applications/com.discordapp.Discord.desktop
    audit_cmd "Applications Flatpak visibles dans Openbox" grep -Fq \
        '/var/lib/flatpak/exports/share' "$TARGET_HOME/.config/openbox/environment"

    owner="$(stat -c '%U' "$TARGET_HOME/.config/mimeapps.list" 2>/dev/null || true)"
    if [[ $owner == "$TARGET_USER" ]]; then audit_ok "Propriétaire mimeapps.list"; else audit_fail "Propriétaire mimeapps.list"; fi
    audit_cmd "Navigateur par défaut" grep -Fq \
        'x-scheme-handler/https=brave-browser.desktop;' "$TARGET_HOME/.config/mimeapps.list"
    audit_cmd "XML Fontconfig" xmllint --noout "$TARGET_HOME/.config/fontconfig/fonts.conf"
    if as_user fc-match sans-serif 2>/dev/null | grep -qi 'Inter'; then
        audit_ok "Police Inter active"
    else
        audit_fail "Police Inter inactive"
    fi

    if pgrep -u "$TARGET_USER" -x openbox >/dev/null 2>&1; then
        if pgrep -u "$TARGET_USER" -x tint2 >/dev/null 2>&1; then
            audit_ok "Barre Tint2 active"
        elif [[ $MODE == "audit" ]]; then
            audit_fail "Session Openbox active mais Tint2 absent"
        else
            audit_warn "Tint2 sera vérifié après le redémarrage"
        fi
    else
        audit_warn "Session Openbox inactive; processus Tint2 non vérifiable"
    fi

    printf '\nRésultat: %d échec(s), %d avertissement(s).\n' "$failures" "$warnings" >>"$AUDIT_FILE"
    log "Audit: $failures échec(s), $warnings avertissement(s) — $AUDIT_FILE"
    grep -E '^(FAIL|WARN)' "$AUDIT_FILE" >&2 || true
    (( failures == 0 ))
}

if [[ $MODE == "audit" ]]; then
    audit_system
    exit $?
fi

log "Démarrage pour $TARGET_USER"

# 1. Dépôts Debian 13 signés
rm -f /etc/apt/sources.list
write_root_file 0644 /etc/apt/sources.list.d/debian.sources <<'EOF'
Types: deb
URIs: https://deb.debian.org/debian
Suites: trixie trixie-updates
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: https://security.debian.org/debian-security
Suites: trixie-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF

dpkg --add-architecture i386
apt-get -qq update

# 2. Paquets Debian stables
BASE_PACKAGES=(
    ca-certificates curl gnupg debian-archive-keyring procps python3-xdg
    unattended-upgrades apt-listchanges needrestart
    linux-image-amd64 linux-headers-amd64 amd64-microcode
    firmware-amd-graphics firmware-realtek firmware-mediatek fwupd
    xserver-xorg xserver-xorg-video-amdgpu xserver-xorg-input-libinput
    xinit x11-xserver-utils x11-xkb-utils openbox obconf lightdm lightdm-gtk-greeter
    thunar tumbler thunar-archive-plugin gvfs-backends gvfs-fuse qimgv
    xarchiver zip unzip 7zip unrar zstd tar featherpad
    lxpolkit nitrogen rofi picom dunst lxappearance xsettingsd tint2
    network-manager network-manager-applet nm-connection-editor systemd-resolved
    pipewire pipewire-pulse pipewire-alsa wireplumber pavucontrol libspa-0.2-bluetooth
    qalculate-qt lxterminal btop vlc gammastep qbittorrent flameshot
    flatpak xdg-desktop-portal xdg-desktop-portal-gtk
    ufw gufw apparmor apparmor-utils
    bluez blueman rfkill
    mesa-utils mesa-vulkan-drivers mesa-va-drivers libva2 vainfo vulkan-tools
    mesa-vulkan-drivers:i386 libgl1-mesa-dri:i386 libglx-mesa0:i386 libvulkan1:i386
    steam-installer steam-devices
    zram-tools
    libxml2-utils libxkbcommon-tools dbus-x11 libnotify-bin xdg-utils desktop-file-utils
    fontconfig fonts-inter fonts-jetbrains-mono fonts-noto-core fonts-noto-color-emoji
    arc-theme papirus-icon-theme
    adwaita-qt adwaita-qt6
)

require_packages "${BASE_PACKAGES[@]}"
apt-get -y -qq full-upgrade
echo 'lightdm shared/default-x-display-manager select lightdm' | debconf-set-selections
apt-get -y -qq install --no-install-suggests "${BASE_PACKAGES[@]}"

# 3. Dépôts éditeurs officiels et signés
curl -fsSLo /usr/share/keyrings/brave-browser-archive-keyring.gpg \
    https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg
curl -fsSLo /etc/apt/sources.list.d/brave-browser-release.sources \
    https://brave-browser-apt-release.s3.brave.com/brave-browser.sources
chmod 0644 /usr/share/keyrings/brave-browser-archive-keyring.gpg \
    /etc/apt/sources.list.d/brave-browser-release.sources

curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | \
    gpg --dearmor --yes -o /usr/share/keyrings/microsoft.gpg
chmod 0644 /usr/share/keyrings/microsoft.gpg
write_root_file 0644 /etc/apt/sources.list.d/vscode.sources <<'EOF'
Types: deb
URIs: https://packages.microsoft.com/repos/code
Suites: stable
Components: main
Architectures: amd64
Signed-By: /usr/share/keyrings/microsoft.gpg
EOF

curl -fsSL https://download.virtualbox.org/virtualbox/debian/oracle_vbox_2016.asc | \
    gpg --dearmor --yes -o /usr/share/keyrings/oracle-virtualbox-2016.gpg
chmod 0644 /usr/share/keyrings/oracle-virtualbox-2016.gpg
write_root_file 0644 /etc/apt/sources.list.d/virtualbox.sources <<'EOF'
Types: deb
URIs: https://download.virtualbox.org/virtualbox/debian
Suites: trixie
Components: contrib
Architectures: amd64
Signed-By: /usr/share/keyrings/oracle-virtualbox-2016.gpg
EOF

apt-get -qq update
install_packages brave-browser code virtualbox-7.2
for package in brave-browser code virtualbox-7.2; do
    package_installed "$package" || die "Installation incomplète: $package"
done
[[ -x /usr/bin/brave-browser && -x /usr/bin/code ]] || \
    die "Brave ou VS Code installé sans exécutable."
log "Brave, VS Code et VirtualBox installés."

for group in video render bluetooth vboxusers; do
    getent group "$group" >/dev/null && usermod -aG "$group" "$TARGET_USER"
done

# 4. Flatpak
flatpak remote-add --system --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install --system -y --noninteractive flathub com.discordapp.Discord org.vinegarhq.Sober
flatpak info --system com.discordapp.Discord >/dev/null || die "Installation Discord incomplète."
flatpak info --system org.vinegarhq.Sober >/dev/null || die "Installation Sober incomplète."
log "Discord et Sober installés via Flathub."

# 5. Mises à jour de sécurité automatiques
write_root_file 0644 /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "14";
EOF

write_root_file 0644 /etc/apt/apt.conf.d/52unattended-upgrades-local <<'EOF'
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "false";
EOF

systemctl enable --now unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer >/dev/null

# 6. Quad9 en DNS-over-TLS strict
write_root_file 0644 /etc/systemd/resolved.conf.d/quad9.conf <<'EOF'
[Resolve]
DNS=9.9.9.9#dns.quad9.net 149.112.112.112#dns.quad9.net 2620:fe::fe#dns.quad9.net 2620:fe::9#dns.quad9.net
FallbackDNS=
Domains=~.
DNSSEC=no
DNSOverTLS=yes
MulticastDNS=no
LLMNR=no
Cache=yes
DNSStubListener=yes
EOF

write_root_file 0644 /etc/NetworkManager/conf.d/99-quad9.conf <<'EOF'
[main]
dns=none
systemd-resolved=false
rc-manager=unmanaged

[connectivity]
enabled=false
EOF

ln -sfn /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
systemctl enable --now systemd-resolved.service NetworkManager.service >/dev/null
systemctl restart systemd-resolved.service NetworkManager.service

# 7. Pare-feu et AppArmor
sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw default deny routed >/dev/null
ufw logging low >/dev/null
ufw --force enable >/dev/null
systemctl enable --now apparmor.service >/dev/null

# 8. Durcissement et performances prudentes
write_root_file 0644 /etc/modules-load.d/20-bbr.conf <<'EOF'
tcp_bbr
EOF
modprobe tcp_bbr

write_root_file 0644 /etc/sysctl.d/99-desktop-stable.conf <<'EOF'
# Sécurité noyau sans casser les navigateurs, jeux, VM ou serveurs locaux
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.yama.ptrace_scope = 1
kernel.unprivileged_bpf_disabled = 1
fs.suid_dumpable = 0
fs.protected_fifos = 2
fs.protected_regular = 2
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
vm.mmap_min_addr = 65536

# Réseau : sécurité compatible VPN, jeux et hébergement
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# Ethernet 2,5 Gbit/s : autotuning TCP conservé, plafonds relevés
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 131072 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.core.netdev_max_backlog = 4096
net.core.somaxconn = 4096

# 32 Go de RAM, jeux et VS Code
vm.swappiness = 20
vm.max_map_count = 1048576
fs.inotify.max_user_watches = 1048576
fs.inotify.max_user_instances = 1024
EOF
sysctl --system >>"$LOG_FILE"

write_root_file 0644 /etc/default/zramswap <<'EOF'
ALGO=lz4
PERCENT=25
PRIORITY=100
EOF
systemctl enable --now zramswap.service fstrim.timer >/dev/null

# 9. Bluetooth fiable, Wi-Fi et services inutiles désactivés
write_root_file 0644 /etc/modprobe.d/20-bluetooth-reliability.conf <<'EOF'
options btusb enable_autosuspend=0
EOF

write_root_file 0644 /etc/bluetooth/main.conf <<'EOF'
[General]
ControllerMode = dual
FastConnectable = true
AutoEnable = true
EOF
systemctl enable --now bluetooth.service >/dev/null

write_root_file 0644 /etc/systemd/system/disable-wifi.service <<'EOF'
[Unit]
Description=Disable Wi-Fi while keeping Bluetooth available
After=NetworkManager.service
Wants=NetworkManager.service

[Service]
Type=oneshot
ExecStart=/usr/bin/nmcli radio wifi off
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now disable-wifi.service >/dev/null

for unit in ssh.service sshd.service ssh.socket cups.service cups.socket cups.path \
    cups-browsed.service ipp-usb.service xrdp.service cockpit.socket \
    gnome-remote-desktop.service; do
    disable_unit "$unit"
done

systemctl --global mask tracker-miner-fs-3.service tracker-extract-3.service \
    baloo-file.service gnome-remote-desktop.service >/dev/null 2>&1 || true

REMOVE_PACKAGES=(popularity-contest openssh-server xrdp)
for package in "${REMOVE_PACKAGES[@]}"; do
    if dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null | grep -qx installed; then
        apt-get -y -qq purge "$package"
    fi
done

# 10. Écran AMD, LightDM et session Openbox
write_root_file 0644 /etc/X11/xorg.conf.d/20-amdgpu.conf <<'EOF'
Section "OutputClass"
    Identifier "AMD Radeon"
    MatchDriver "amdgpu"
    Driver "amdgpu"
    Option "VariableRefresh" "true"
EndSection
EOF

write_root_file 0644 /etc/lightdm/lightdm.conf.d/20-openbox.conf <<'EOF'
[Seat:*]
greeter-session=lightdm-gtk-greeter
user-session=openbox
EOF
systemctl set-default graphical.target >/dev/null
systemctl enable lightdm.service >/dev/null

# 11. Clavier français : Caps Lock verrouille lettres/chiffres, sans modifier Shift
write_root_file 0644 /usr/share/X11/xkb/symbols/fr_numlock <<'EOF'
default partial alphanumeric_keys
xkb_symbols "basic" {
    include "fr(basic)"
    name[Group1] = "French (Caps Lock digits)";

    key <AE01> { type[Group1]="FOUR_LEVEL_ALPHABETIC", [ ampersand, 1, onesuperior, exclamdown ] };
    key <AE02> { type[Group1]="FOUR_LEVEL_ALPHABETIC", [ eacute, 2, asciitilde, oneeighth ] };
    key <AE03> { type[Group1]="FOUR_LEVEL_ALPHABETIC", [ quotedbl, 3, numbersign, sterling ] };
    key <AE04> { type[Group1]="FOUR_LEVEL_ALPHABETIC", [ apostrophe, 4, braceleft, dollar ] };
    key <AE05> { type[Group1]="FOUR_LEVEL_ALPHABETIC", [ parenleft, 5, bracketleft, threeeighths ] };
    key <AE06> { type[Group1]="FOUR_LEVEL_ALPHABETIC", [ minus, 6, bar, fiveeighths ] };
    key <AE07> { type[Group1]="FOUR_LEVEL_ALPHABETIC", [ egrave, 7, grave, seveneighths ] };
    key <AE08> { type[Group1]="FOUR_LEVEL_ALPHABETIC", [ underscore, 8, backslash, trademark ] };
    key <AE09> { type[Group1]="FOUR_LEVEL_ALPHABETIC", [ ccedilla, 9, asciicircum, plusminus ] };
    key <AE10> { type[Group1]="FOUR_LEVEL_ALPHABETIC", [ agrave, 0, at, degree ] };
};
EOF

write_root_file 0644 /etc/default/keyboard <<'EOF'
XKBMODEL="pc105"
XKBLAYOUT="fr_numlock"
XKBVARIANT="basic"
XKBOPTIONS=""
BACKSPACE="guess"
EOF

# 12. Fichiers utilisateur
for directory in \
    "$TARGET_HOME/.config/openbox" \
    "$TARGET_HOME/.config/autostart" \
    "$TARGET_HOME/.config/tint2" \
    "$TARGET_HOME/.config/picom" \
    "$TARGET_HOME/.config/dunst" \
    "$TARGET_HOME/.config/rofi" \
    "$TARGET_HOME/.config/gammastep" \
    "$TARGET_HOME/.config/xsettingsd" \
    "$TARGET_HOME/.config/fontconfig" \
    "$TARGET_HOME/.config/gtk-3.0" \
    "$TARGET_HOME/.config/gtk-4.0" \
    "$TARGET_HOME/.cache" \
    "$TARGET_HOME/.local/bin" \
    "$TARGET_HOME/.local/share/applications"; do
    user_dir "$directory"
done

write_user_file 0644 "$TARGET_HOME/.Xresources" <<'EOF'
Xft.dpi: 120
Xft.antialias: true
Xft.hinting: true
Xft.hintstyle: hintslight
Xft.rgba: rgb
Xft.lcdfilter: lcddefault
Xft.autohint: false
EOF

write_user_file 0644 "$TARGET_HOME/.config/fontconfig/fonts.conf" <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <match target="font">
    <edit name="antialias" mode="assign"><bool>true</bool></edit>
    <edit name="hinting" mode="assign"><bool>true</bool></edit>
    <edit name="hintstyle" mode="assign"><const>hintslight</const></edit>
    <edit name="rgba" mode="assign"><const>rgb</const></edit>
    <edit name="lcdfilter" mode="assign"><const>lcddefault</const></edit>
    <edit name="autohint" mode="assign"><bool>false</bool></edit>
  </match>
  <alias>
    <family>sans-serif</family>
    <prefer><family>Inter</family><family>Noto Sans</family></prefer>
  </alias>
  <alias>
    <family>monospace</family>
    <prefer><family>JetBrains Mono</family><family>Noto Sans Mono</family></prefer>
  </alias>
</fontconfig>
EOF

write_user_file 0644 "$TARGET_HOME/.config/xsettingsd/xsettingsd.conf" <<'EOF'
Net/ThemeName "Adwaita-dark"
Net/IconThemeName "Papirus-Dark"
Gtk/FontName "Inter 10"
Gtk/CursorThemeName "Adwaita"
Xft/DPI 122880
Xft/Antialias 1
Xft/Hinting 1
Xft/HintStyle "hintslight"
Xft/RGBA "rgb"
Xft/Lcdfilter "lcddefault"
EOF

write_user_file 0644 "$TARGET_HOME/.gtkrc-2.0" <<'EOF'
gtk-theme-name="Adwaita-dark"
gtk-icon-theme-name="Papirus-Dark"
gtk-font-name="Inter 10"
EOF

write_user_file 0644 "$TARGET_HOME/.config/gtk-3.0/settings.ini" <<'EOF'
[Settings]
gtk-theme-name=Adwaita-dark
gtk-icon-theme-name=Papirus-Dark
gtk-font-name=Inter 10
gtk-application-prefer-dark-theme=1
EOF
cp "$TARGET_HOME/.config/gtk-3.0/settings.ini" "$TARGET_HOME/.config/gtk-4.0/settings.ini"
chown "$TARGET_USER:$TARGET_GROUP" "$TARGET_HOME/.config/gtk-4.0/settings.ini"

write_user_file 0644 "$TARGET_HOME/.config/openbox/environment" <<'EOF'
export GTK_THEME=Adwaita:dark
export QT_STYLE_OVERRIDE=Adwaita-Dark
export XCURSOR_SIZE=24
export XDG_DATA_DIRS="$HOME/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:/usr/local/share:/usr/share"
EOF

write_user_file 0755 "$TARGET_HOME/.local/bin/display-setup" <<'EOF'
#!/bin/sh
output="$(xrandr --query | awk '/ connected/{print $1; exit}')"
[ -n "$output" ] || exit 0

rate="$(xrandr --query | awk '
    $1 == "2560x1440" {
        for (i=2; i<=NF; i++) {
            gsub(/[+*]/, "", $i)
            if (($i + 0) > best) best=$i + 0
        }
    }
    END { if (best >= 179) print best }
')"

if [ -n "$rate" ] && xrandr --output "$output" --primary --mode 2560x1440 --rate "$rate"; then
    exit 0
fi

if xrandr --output "$output" --primary --mode 2560x1440; then
    notify-send -u normal "Écran" "180 Hz indisponible : utiliser DisplayPort 1.4."
else
    notify-send -u normal "Écran" "2560×1440 indisponible sur cette sortie."
fi
EOF

write_user_file 0755 "$TARGET_HOME/.local/bin/panel-cpu" <<'EOF'
#!/bin/sh
state="${XDG_RUNTIME_DIR:-/tmp}/panel-cpu-$(id -u)"
read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
total=$((user + nice + system + idle + iowait + irq + softirq + steal))
idle_all=$((idle + iowait))
if [ -r "$state" ]; then
    read -r old_total old_idle < "$state"
    delta=$((total - old_total))
    idle_delta=$((idle_all - old_idle))
    [ "$delta" -gt 0 ] && usage=$((100 * (delta - idle_delta) / delta)) || usage=0
else
    usage=0
fi
printf '%s %s\n' "$total" "$idle_all" > "$state"
printf 'CPU %s%%\n' "$usage"
EOF

write_user_file 0755 "$TARGET_HOME/.local/bin/panel-ram" <<'EOF'
#!/bin/sh
free -m | awk '/^Mem:/ {printf "RAM %.1fG/%.0fG\n", $3/1024, $2/1024}'
EOF

write_user_file 0755 "$TARGET_HOME/.local/bin/panel-gpu" <<'EOF'
#!/bin/sh
best_file=""
best_vram=0
for file in /sys/class/drm/card*/device/gpu_busy_percent; do
    [ -r "$file" ] || continue
    device=${file%/gpu_busy_percent}
    vram=0
    [ -r "$device/mem_info_vram_total" ] && read -r vram < "$device/mem_info_vram_total"
    if [ "$vram" -ge "$best_vram" ]; then
        best_vram=$vram
        best_file=$file
    fi
done
[ -n "$best_file" ] || { printf 'GPU --\n'; exit 0; }
read -r usage < "$best_file"
printf 'GPU %s%%\n' "$usage"
EOF

write_user_file 0755 "$TARGET_HOME/.local/bin/panel-net" <<'EOF'
#!/bin/sh
interface=""
for path in /sys/class/net/*; do
    name=${path##*/}
    [ "$name" = lo ] && continue
    [ -d "$path/wireless" ] && continue
    [ "$(cat "$path/carrier" 2>/dev/null)" = 1 ] || continue
    interface=$name
    break
done
[ -n "$interface" ] || { printf 'NET --\n'; exit 0; }

read -r rx < "/sys/class/net/$interface/statistics/rx_bytes"
read -r tx < "/sys/class/net/$interface/statistics/tx_bytes"
now=$(date +%s)
state="${XDG_RUNTIME_DIR:-/tmp}/panel-net-$(id -u)"

if [ -r "$state" ]; then
    read -r old_rx old_tx old_time < "$state"
    seconds=$((now - old_time))
    [ "$seconds" -gt 0 ] || seconds=1
    down=$(((rx - old_rx) / seconds))
    up=$(((tx - old_tx) / seconds))
else
    down=0
    up=0
fi
printf '%s %s %s\n' "$rx" "$tx" "$now" > "$state"
awk -v d="$down" -v u="$up" 'BEGIN {printf "NET ↓%.1f ↑%.1f MB/s\n", d/1048576, u/1048576}'
EOF

write_user_file 0755 "$TARGET_HOME/.local/bin/openbox-startup" <<'EOF'
#!/bin/sh
runtime="${XDG_RUNTIME_DIR:-/tmp}"
lock="$runtime/openbox-startup-$(id -u).lock"
mkdir "$lock" 2>/dev/null || exit 0
trap 'rmdir "$lock"' EXIT HUP INT TERM

log="$HOME/.cache/openbox-startup.log"
mkdir -p "$HOME/.cache"
exec >>"$log" 2>&1
printf '\n[%s] Démarrage Openbox\n' "$(date --iso-8601=seconds)"

start_once() {
    process="$1"
    shift
    if ! pgrep -u "$(id -u)" -x "$process" >/dev/null 2>&1; then
        "$@" &
    fi
}

xrdb -merge "$HOME/.Xresources"
setxkbmap -rules evdev -model pc105 -layout fr_numlock -variant basic -option ''
xsetroot -solid '#10131a'
"$HOME/.local/bin/display-setup" &

start_once xsettingsd xsettingsd --config "$HOME/.config/xsettingsd/xsettingsd.conf"
start_once lxpolkit lxpolkit
start_once nm-applet nm-applet
start_once blueman-applet blueman-applet
start_once dunst dunst -config "$HOME/.config/dunst/dunstrc"
start_once picom picom --config "$HOME/.config/picom/picom.conf"
start_once tint2 tint2 -c "$HOME/.config/tint2/tint2rc"
start_once gammastep gammastep -c "$HOME/.config/gammastep/config.ini"
start_once flameshot flameshot

gsettings set org.gnome.desktop.interface color-scheme "'prefer-dark'" >/dev/null 2>&1 || true
gsettings set org.gnome.desktop.interface gtk-theme "'Adwaita-dark'" >/dev/null 2>&1 || true
gsettings set org.gnome.desktop.interface font-name "'Inter 10'" >/dev/null 2>&1 || true
gsettings set org.gnome.desktop.interface monospace-font-name "'JetBrains Mono 10'" >/dev/null 2>&1 || true

sleep 2
if pgrep -u "$(id -u)" -x tint2 >/dev/null 2>&1; then
    printf 'OK: Tint2 actif.\n'
else
    printf 'ERREUR: Tint2 ne reste pas actif.\n'
    notify-send -u critical "Openbox" "Tint2 n'a pas démarré. Voir ~/.cache/openbox-startup.log" || true
fi
EOF

write_user_file 0644 "$TARGET_HOME/.config/autostart/openbox-components.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Composants Openbox
Comment=Barre, notifications et composants de session
Exec=$TARGET_HOME/.local/bin/openbox-startup
TryExec=$TARGET_HOME/.local/bin/openbox-startup
NoDisplay=true
Terminal=false
EOF

write_user_file 0644 "$TARGET_HOME/.config/picom/picom.conf" <<'EOF'
backend = "glx";
vsync = true;
use-damage = true;
unredir-if-possible = true;
detect-rounded-corners = true;
detect-client-opacity = true;
shadow = true;
shadow-radius = 10;
shadow-opacity = 0.28;
shadow-offset-x = -7;
shadow-offset-y = -7;
fading = false;
corner-radius = 8;
wintypes:
{
    tooltip = { fade = false; shadow = true; opacity = 0.96; };
    dock = { shadow = false; };
    dnd = { shadow = false; };
};
EOF

write_user_file 0644 "$TARGET_HOME/.config/dunst/dunstrc" <<'EOF'
[global]
    monitor = 0
    follow = mouse
    origin = top-right
    offset = 12x48
    width = 380
    height = 180
    notification_limit = 5
    progress_bar = true
    transparency = 8
    separator_height = 2
    padding = 12
    horizontal_padding = 12
    frame_width = 1
    frame_color = "#64748b"
    separator_color = frame
    font = Inter 10
    markup = full
    format = "<b>%s</b>\n%b"
    corner_radius = 10
    icon_position = left
    max_icon_size = 42

[urgency_low]
    background = "#161a22"
    foreground = "#cbd5e1"
    timeout = 4

[urgency_normal]
    background = "#161a22"
    foreground = "#f8fafc"
    timeout = 7

[urgency_critical]
    background = "#3f1d2e"
    foreground = "#ffffff"
    frame_color = "#fb7185"
    timeout = 0
EOF

write_user_file 0644 "$TARGET_HOME/.config/rofi/config.rasi" <<'EOF'
configuration {
    modi: "drun,run,window";
    show-icons: true;
    display-drun: "Applications";
    font: "Inter 11";
    drun-display-format: "{name}";
}
@theme "Arc-Dark"
EOF

write_user_file 0644 "$TARGET_HOME/.config/gammastep/config.ini" <<'EOF'
[general]
temp-day=6000
temp-night=1900
dawn-time=06:00
dusk-time=22:30
fade=1
adjustment-method=randr
EOF

write_user_file 0644 "$TARGET_HOME/.local/share/applications/openbox-apps.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Applications
Comment=Toutes les applications
Icon=start-here
Exec=rofi -show drun
Terminal=false
Categories=System;
EOF

write_user_file 0644 "$TARGET_HOME/.config/tint2/tint2rc" <<EOF
# Barre supérieure légère pour Openbox
rounded = 10
border_width = 1
border_sides = TBLR
background_color = #161a22 88
border_color = #64748b 35
background_color_hover = #222936 92
border_color_hover = #94a3b8 50
background_color_pressed = #334155 95
border_color_pressed = #cbd5e1 60

rounded = 7
border_width = 0
background_color = #334155 55
border_color = #000000 0

panel_items = LTEEEESC
panel_size = 99% 38
panel_margin = 0 5
panel_padding = 8 4 7
panel_background_id = 1
panel_position = top center horizontal
panel_layer = normal
panel_monitor = all
panel_shrink = 0
panel_dock = 1
wm_menu = 1
strut_policy = follow_size
mouse_effects = 1
font_shadow = 0

launcher_padding = 7 5 7
launcher_background_id = 0
launcher_icon_size = 22
launcher_item_app = $TARGET_HOME/.local/share/applications/openbox-apps.desktop

taskbar_mode = multi_desktop
taskbar_padding = 3 0 4
taskbar_background_id = 0
taskbar_hide_if_empty = 0
taskbar_distribute_size = 1

task_text = 1
task_icon = 1
task_centered = 1
task_maximum_size = 180 30
task_padding = 6 3 6
task_font = Inter 9
task_font_color = #cbd5e1 100
task_active_font_color = #ffffff 100
task_background_id = 0
task_active_background_id = 2
task_iconified_icon_asb = 70 0 0

systray_padding = 6 3 5
systray_background_id = 0
systray_sort = ascending
systray_icon_size = 20

time1_format = %H:%M
time2_format = %a %d %b
time1_font = Inter Bold 10
time2_font = Inter 8
clock_font_color = #f8fafc 100
clock_padding = 8 2
clock_background_id = 0
clock_tooltip = %A %d %B %Y

execp = new
execp_command = $TARGET_HOME/.local/bin/panel-cpu
execp_interval = 2
execp_font = Inter 9
execp_font_color = #93c5fd 100
execp_padding = 7 0
execp_background_id = 0

execp = new
execp_command = $TARGET_HOME/.local/bin/panel-ram
execp_interval = 2
execp_font = Inter 9
execp_font_color = #a7f3d0 100
execp_padding = 7 0
execp_background_id = 0

execp = new
execp_command = $TARGET_HOME/.local/bin/panel-gpu
execp_interval = 2
execp_font = Inter 9
execp_font_color = #f9a8d4 100
execp_padding = 7 0
execp_background_id = 0

execp = new
execp_command = $TARGET_HOME/.local/bin/panel-net
execp_interval = 2
execp_font = Inter 9
execp_font_color = #fde68a 100
execp_padding = 7 0
execp_background_id = 0

tooltip_show_timeout = 0.3
tooltip_hide_timeout = 0.1
tooltip_padding = 8 5
tooltip_background_id = 1
tooltip_font = Inter 9
tooltip_font_color = #f8fafc 100
EOF

write_user_file 0644 "$TARGET_HOME/.config/openbox/menu.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_menu xmlns="http://openbox.org/3.4/menu">
  <menu id="root-menu" label="Menu">
    <item label="🌐  Navigateur — Brave">
      <action name="Execute"><command>brave-browser</command></action>
    </item>
    <item label="⌨  Terminal — LXTerminal">
      <action name="Execute"><command>lxterminal</command></action>
    </item>
    <item label="📝  Notepad — FeatherPad">
      <action name="Execute"><command>featherpad</command></action>
    </item>
    <item label="🧮  Calculatrice — Qalculate!">
      <action name="Execute"><command>qalculate-qt</command></action>
    </item>
    <item label="📁  Fichiers — Thunar">
      <action name="Execute"><command>thunar</command></action>
    </item>
    <item label="📊  Gestionnaire de tâches — Btop">
      <action name="Execute"><command>lxterminal -e btop</command></action>
    </item>
    <item label="🔊  Mélangeur de volume">
      <action name="Execute"><command>pavucontrol</command></action>
    </item>
    <separator/>
    <menu id="start-menu" label="☰  Menu démarrer">
      <item label="▦  Toutes les applications">
        <action name="Execute"><command>rofi -show drun</command></action>
      </item>
      <separator/>
      <item label="↻  Redémarrer">
        <action name="Execute"><command>systemctl reboot</command></action>
      </item>
      <item label="⏻  Arrêter">
        <action name="Execute"><command>systemctl poweroff</command></action>
      </item>
    </menu>
  </menu>
</openbox_menu>
EOF

install -m 0644 -o "$TARGET_USER" -g "$TARGET_GROUP" \
    /etc/xdg/openbox/rc.xml "$TARGET_HOME/.config/openbox/rc.xml"
sed -i \
    -e '\#<file>/var/lib/openbox/debian-menu.xml</file>#d' \
    -e "s#<file>menu.xml</file>#<file>$TARGET_HOME/.config/openbox/menu.xml</file>#" \
    -e 's#<name>Clearlooks</name>#<name>Nightmare-02</name>#' \
    -e 's#<name>sans</name>#<name>Inter</name>#g' \
    -e '/<!-- Take a screenshot of the current window with scrot when Alt+Print are pressed -->/,+3d' \
    -e '/<!-- Launch scrot when Print is pressed -->/,+3d' \
    "$TARGET_HOME/.config/openbox/rc.xml"
sed -i '/<\/keyboard>/i\
    <!-- Raccourcis gérés par debian13-openbox-stable -->\
    <!-- Super+Espace est le secours fiable si Fn n est pas exposé par le firmware -->\
    <keybind key="W-space">\
      <action name="NextDesktop"><wrap>yes</wrap></action>\
    </keybind>\
    <keybind key="XF86Fn">\
      <keybind key="space">\
        <action name="NextDesktop"><wrap>yes</wrap></action>\
      </keybind>\
      <keybind key="Insert">\
        <action name="Execute"><command>flameshot gui</command></action>\
      </keybind>\
    </keybind>\
    <!-- Le firmware du G413 TKL peut convertir Fn+Insert directement en Print -->\
    <keybind key="Print">\
      <action name="Execute"><command>flameshot gui</command></action>\
    </keybind>' "$TARGET_HOME/.config/openbox/rc.xml"
chown "$TARGET_USER:$TARGET_GROUP" "$TARGET_HOME/.config/openbox/rc.xml"

write_user_file 0755 "$TARGET_HOME/.config/openbox/autostart" <<'EOF'
#!/bin/sh
exec "$HOME/.local/bin/openbox-startup"
EOF

# Associations par défaut, écrites directement avec le bon propriétaire
write_user_file 0644 "$TARGET_HOME/.config/mimeapps.list" <<'EOF'
[Default Applications]
x-scheme-handler/http=brave-browser.desktop;
x-scheme-handler/https=brave-browser.desktop;
text/html=brave-browser.desktop;
image/jpeg=qimgv.desktop;
image/png=qimgv.desktop;
image/gif=qimgv.desktop;
image/webp=qimgv.desktop;
image/bmp=qimgv.desktop;
text/plain=featherpad.desktop;
EOF

# 13. Mise à jour finale et contrôles
apt-get -qq update
apt-get -y -qq full-upgrade
update-initramfs -u >>"$LOG_FILE"
systemctl daemon-reload

log "Installation terminée. Redémarrage requis."
audit_system
