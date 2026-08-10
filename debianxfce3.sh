#!/usr/bin/env bash
set -Eeuo pipefail
umask 022
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none

readonly LOG_FILE="/var/log/debian13-amd-xfce-setup.log"
BACKUP_STAMP="$(date +%Y%m%d-%H%M%S)" || exit 1
readonly BACKUP_STAMP

msg() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERREUR: %s\n' "$*" >&2; exit 1; }
apt_install() { apt-get -y -o Dpkg::Use-Pty=0 install "$@"; }
apt_update() { apt-get --error-on=any "$@" update; }

download_atomic() {
    local url="$1" destination="$2" temporary
    temporary="$(mktemp "${destination}.tmp.XXXXXX")" || return 1
    if ! curl --proto '=https' --tlsv1.2 \
            --connect-timeout 20 --max-time 300 --retry 3 --retry-delay 2 \
            -fsSL -o "$temporary" "$url"; then
        rm -f "$temporary"
        return 1
    fi
    if ! install -m 0644 "$temporary" "$destination"; then
        rm -f "$temporary"
        return 1
    fi
    rm -f "$temporary"
}

install_binary_key() {
    local url="$1" destination="$2" temporary
    temporary="$(mktemp "${destination}.tmp.XXXXXX")" || return 1
    if ! curl --proto '=https' --tlsv1.2 \
            --connect-timeout 20 --max-time 300 --retry 3 --retry-delay 2 \
            -fsSL -o "$temporary" "$url" \
        || ! gpg --batch --show-keys "$temporary" >/dev/null 2>&1 \
        || ! install -m 0644 "$temporary" "$destination"; then
        rm -f "$temporary"
        return 1
    fi
    rm -f "$temporary"
}

install_armored_key() {
    local url="$1" destination="$2" armored keyring
    armored="$(mktemp)" || return 1
    keyring="$(mktemp)" || { rm -f "$armored"; return 1; }
    if ! curl --proto '=https' --tlsv1.2 \
            --connect-timeout 20 --max-time 300 --retry 3 --retry-delay 2 \
            -fsSL -o "$armored" "$url" \
        || ! gpg --batch --yes --dearmor -o "$keyring" "$armored" \
        || ! gpg --batch --show-keys "$keyring" >/dev/null 2>&1 \
        || ! install -m 0644 "$keyring" "$destination"; then
        rm -f "$armored" "$keyring"
        return 1
    fi
    rm -f "$armored" "$keyring"
}

optional() {
    local name="$1"; shift
    if ! "$@"; then
        printf 'AVERTISSEMENT: installation optionnelle échouée: %s\n' "$name" >&2
        return 0
    fi
}

verify_quad9_doh() {
    local attempt
    nm-online --quiet --timeout=60 || return 1
    for ((attempt = 1; attempt <= 6; attempt++)); do
        if timeout 10s resolvectl query --type=TXT proto.on.quad9.net \
                2>/dev/null | grep -Fq '"doh."'; then
            return 0
        fi
        sleep 2
    done
    printf 'Diagnostic DNS Quad9 DoH:\n' >&2
    resolvectl status >&2 || true
    journalctl --quiet --no-pager -u dnscrypt-proxy.service -n 30 >&2 || true
    journalctl --quiet --no-pager -u systemd-resolved.service -n 30 >&2 || true
    return 1
}

[[ $EUID -eq 0 ]] || { echo "Exécuter avec sudo/root." >&2; exit 1; }
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "debian" && "${VERSION_CODENAME:-}" == "trixie" ]] || {
    echo "Ce script cible uniquement Debian 13 (Trixie)." >&2
    exit 1
}
[[ "$(dpkg --print-architecture)" == "amd64" ]] || {
    echo "Architecture amd64 requise." >&2
    exit 1
}
[[ -r /usr/share/keyrings/debian-archive-keyring.gpg ]] \
    || die "Trousseau debian-archive-keyring.gpg introuvable."

TARGET_USER="${SUDO_USER:-}"
if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
    TARGET_USER="$(getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 && $7 !~ /(nologin|false)$/ {print $1; exit}')"
fi
[[ -n "$TARGET_USER" ]] || { echo "Utilisateur desktop introuvable." >&2; exit 1; }
TARGET_UID="$(id -u "$TARGET_USER" 2>/dev/null)" \
    || die "Utilisateur desktop invalide: $TARGET_USER"
[[ "$TARGET_UID" -ge 1000 && "$TARGET_UID" -lt 60000 ]] \
    || die "UID desktop invalide: $TARGET_UID"
readonly TARGET_USER TARGET_UID

BACKUP_DIR="$(mktemp -d "/root/debian13-setup-backup-${BACKUP_STAMP}-XXXXXXXX")" \
    || die "Impossible de créer le répertoire de sauvegarde."
readonly BACKUP_DIR
[[ ! -L "$LOG_FILE" ]] || die "$LOG_FILE ne doit pas être un lien symbolique."
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1
trap 'printf "ERREUR: ligne %s (commande: %s)\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

msg "Sauvegarde des configurations"
for path in \
    /etc/apt/sources.list \
    /etc/apt/sources.list.d \
    /etc/apt/apt.conf.d/20auto-upgrades \
    /etc/apt/apt.conf.d/99-local-unattended-upgrades \
    /etc/nftables.conf \
    /etc/resolv.conf \
    /etc/dnscrypt-proxy \
    /etc/systemd/resolved.conf \
    /etc/systemd/resolved.conf.d \
    /etc/NetworkManager/NetworkManager.conf \
    /etc/NetworkManager/conf.d \
    /etc/sysctl.d/99-local-hardening-performance.conf \
    /etc/gamemode.ini \
    /etc/default/keyboard \
    /usr/local/bin/apply-display-180hz \
    /etc/xdg/autostart/display-180hz.desktop \
    /usr/share/X11/xkb/symbols/fr_windows_caps \
    /usr/local/bin/apply-fr-windows-caps \
    /etc/xdg/autostart/fr-windows-caps.desktop \
    /usr/share/keyrings/brave-browser-archive-keyring.gpg \
    /usr/share/keyrings/vscodium-archive-keyring.gpg \
    /usr/share/keyrings/oracle-virtualbox-2016.gpg; do
    [[ -e "$path" || -L "$path" ]] && cp -a --parents "$path" "$BACKUP_DIR/"
done

if [[ -e /etc/systemd/resolved.conf.d/90-quad9.conf \
        || -e /etc/NetworkManager/conf.d/90-quad9-dot.conf \
        || -e /etc/NetworkManager/conf.d/90-quad9-doh.conf ]]; then
    msg "Rétablissement DNS préalable"
    rm -f \
        /etc/systemd/resolved.conf.d/90-quad9.conf \
        /etc/NetworkManager/conf.d/90-quad9-dot.conf \
        /etc/NetworkManager/conf.d/90-quad9-doh.conf
    systemctl restart systemd-resolved.service
    systemctl restart NetworkManager.service
    nm-online --quiet --timeout=60 \
        || die "Le réseau ne s'est pas rétabli après retrait de l'ancienne configuration DNS."
    DNS_RECOVERED=0
    for ((recovery_attempt = 1; recovery_attempt <= 10; recovery_attempt++)); do
        if timeout 10s resolvectl query deb.debian.org >/dev/null 2>&1; then
            DNS_RECOVERED=1
            break
        fi
        sleep 2
    done
    [[ "$DNS_RECOVERED" -eq 1 ]] \
        || die "Le DNS temporaire n'a pas été rétabli."
    unset DNS_RECOVERED recovery_attempt
fi

msg "Dépôts Debian 13 officiels"
install -d -m 0755 /etc/apt/sources.list.d
find /etc/apt/sources.list.d -maxdepth 1 -type f \
    \( -name '*.list' -o -name '*.sources' \) -delete
find /etc/apt/sources.list.d -maxdepth 1 -type l \
    \( -name '*.list' -o -name '*.sources' \) -delete
rm -f /etc/apt/sources.list
cat > /etc/apt/sources.list <<'EOF'
# Les dépôts Debian sont définis dans /etc/apt/sources.list.d/debian.sources
EOF
cat > /etc/apt/sources.list.d/debian.sources <<'EOF'
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

msg "Mise à jour complète"
apt_update
apt-get -y -o Dpkg::Use-Pty=0 full-upgrade

msg "Base sécurité, réseau et stabilité"
apt_install \
    ca-certificates curl gnupg debian-archive-keyring \
    unattended-upgrades apt-listchanges \
    nftables apparmor apparmor-utils \
    dnscrypt-proxy systemd-resolved network-manager \
    flatpak xdg-desktop-portal xdg-desktop-portal-gtk \
    xfconf xfce4-settings x11-xkb-utils x11-xserver-utils \
    linux-image-amd64 linux-headers-amd64 \
    amd64-microcode firmware-amd-graphics firmware-realtek firmware-mediatek \
    xserver-xorg-video-amdgpu \
    libgl1-mesa-dri mesa-vulkan-drivers mesa-va-drivers mesa-vdpau-drivers \
    libvulkan1 vulkan-tools \
    pciutils usbutils nvme-cli smartmontools dkms build-essential

msg "Mises à jour automatiques de sécurité"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Enable "1";
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
cat > /etc/apt/apt.conf.d/99-local-unattended-upgrades <<'EOF'
#clear Unattended-Upgrade::Allowed-Origins;
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=${distro_codename},label=Debian-Security";
    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "false";
EOF
systemctl enable --now apt-daily.timer apt-daily-upgrade.timer

msg "Télémétrie et sondes réseau Debian"
if dpkg-query -W -f='${db:Status-Abbrev}' popularity-contest 2>/dev/null | grep -q '^ii'; then
    apt-get -y -o Dpkg::Use-Pty=0 purge popularity-contest
fi
install -d -m 0755 /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/10-privacy.conf <<'EOF'
[connectivity]
enabled=false
EOF

msg "Quad9 Secure - DNS over HTTPS strict"
install -d -m 0755 /etc/dnscrypt-proxy
cat > /etc/dnscrypt-proxy/dnscrypt-proxy.toml <<'EOF'
listen_addresses = []
server_names = ['quad9-doh-ip4-port443-filter-pri']
max_clients = 250

ipv4_servers = true
ipv6_servers = false
dnscrypt_servers = false
doh_servers = true
odoh_servers = false
require_dnssec = true
require_nolog = true
require_nofilter = false

force_tcp = false
http3 = false
timeout = 5000
keepalive = 30
bootstrap_resolvers = ['9.9.9.11:53', '149.112.112.11:53']
ignore_system_dns = true
netprobe_timeout = 60
netprobe_address = '9.9.9.9:443'

block_ipv6 = false
block_unqualified = true
block_undelegated = true

cache = true
cache_size = 4096
cache_min_ttl = 60
cache_max_ttl = 86400
cache_neg_min_ttl = 60
cache_neg_max_ttl = 600

[sources]
  [sources.public-resolvers]
  urls = ['https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md', 'https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md']
  cache_file = '/var/cache/dnscrypt-proxy/public-resolvers.md'
  minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
  refresh_delay = 73
  prefix = ''
EOF
chmod 0644 /etc/dnscrypt-proxy/dnscrypt-proxy.toml

install -d -m 0755 /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/90-quad9.conf <<'EOF'
[Resolve]
DNS=
DNS=127.0.2.1
FallbackDNS=
Domains=~.
DNSOverTLS=no
DNSSEC=no
LLMNR=no
MulticastDNS=no
Cache=no
DNSStubListener=yes
EOF
chmod 0644 /etc/systemd/resolved.conf.d/90-quad9.conf
rm -f /etc/NetworkManager/conf.d/90-quad9-dot.conf
cat > /etc/NetworkManager/conf.d/90-quad9-doh.conf <<'EOF'
[main]
dns=none
rc-manager=unmanaged
systemd-resolved=false
EOF
chmod 0644 /etc/NetworkManager/conf.d/90-quad9-doh.conf
systemctl enable --now dnscrypt-proxy.socket
systemctl restart dnscrypt-proxy.service
systemctl is-active --quiet dnscrypt-proxy.service
systemctl enable --now systemd-resolved
ln -sfn /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
systemctl restart NetworkManager
systemctl restart systemd-resolved
verify_quad9_doh \
    || die "Quad9 DoH non confirmé; voir le diagnostic ci-dessus."

msg "Pare-feu nftables - DROP entrant et routage"
cat > /etc/nftables.conf <<'EOF'
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
    chain input {
        type filter hook input priority filter; policy drop;

        ct state invalid drop
        ct state established,related accept
        iifname "lo" accept

        ip protocol icmp accept
        meta l4proto ipv6-icmp accept

        udp sport 67 udp dport 68 accept
        udp sport 547 udp dport 546 accept
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
EOF
nft -c -f /etc/nftables.conf
systemctl enable --now nftables
nft -f /etc/nftables.conf

msg "AppArmor"
systemctl enable --now apparmor.service
systemctl restart apparmor.service

msg "Durcissement noyau et réglages desktop/réseau"
cat > /etc/sysctl.d/99-local-hardening-performance.conf <<'EOF'
# Sécurité noyau
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.yama.ptrace_scope = 1
kernel.perf_event_paranoid = 3
kernel.unprivileged_bpf_disabled = 1
kernel.randomize_va_space = 2
fs.suid_dumpable = 0
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2

# Réseau - durcissement sans casser VPN, IPv6 ou desktop
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.*.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.*.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.*.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.*.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.*.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv6.conf.*.accept_source_route = 0
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.*.rp_filter = 2
net.ipv4.tcp_syncookies = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Débit 2,5 Gb/s : plafonds d'auto-tuning, sans forcer BBR ni MTU
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 131072 67108864
net.ipv4.tcp_wmem = 4096 16384 67108864

# Desktop 32 Gio : retarder le swap sans le désactiver
vm.swappiness = 10
EOF
systemctl restart systemd-sysctl.service

msg "SSD/NVMe"
systemctl enable --now fstrim.timer

msg "Steam, GameMode et compatibilité 32 bits"
dpkg --add-architecture i386
apt_update
apt_install \
    steam-installer steam-devices gamemode \
    libgamemode0:i386 libgamemodeauto0:i386 \
    libgl1-mesa-dri:i386 mesa-vulkan-drivers:i386 libvulkan1:i386

cat > /etc/gamemode.ini <<'EOF'
[general]
reaper_freq=5
desiredgov=performance
igpu_power_threshold=-1
softrealtime=off
renice=0
ioprio=0
inhibit_screensaver=1
disable_splitlock=0

[gpu]
apply_gpu_optimisations=0

[cpu]
park_cores=no
pin_cores=no
EOF

msg "Applications Debian natives"
apt_install qbittorrent vlc filezilla

msg "Flathub et Discord"
optional "Flathub" flatpak remote-add --system --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
optional "Discord" flatpak install --system -y flathub com.discordapp.Discord

install_brave() {
    local source=/etc/apt/sources.list.d/brave-browser-release.sources
    local keyring=/usr/share/keyrings/brave-browser-archive-keyring.gpg
    if ! install_binary_key \
            https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg \
            "$keyring" \
        || ! download_atomic \
            https://brave-browser-apt-release.s3.brave.com/brave-browser.sources \
            "$source" \
        || ! apt_update \
        || ! apt_install brave-browser; then
        rm -f "$source" "$keyring"
        apt_update -qq || true
        return 1
    fi
}

install_vscodium() {
    local source=/etc/apt/sources.list.d/vscodium.sources
    local keyring=/usr/share/keyrings/vscodium-archive-keyring.gpg
    install_armored_key \
        https://gitlab.com/paulcarroty/vscodium-deb-rpm-repo/raw/master/pub.gpg \
        "$keyring" || return 1
    if ! cat > "$source" <<'EOF'
Types: deb
URIs: https://download.vscodium.com/debs
Suites: vscodium
Components: main
Architectures: amd64
Signed-By: /usr/share/keyrings/vscodium-archive-keyring.gpg
EOF
    then
        rm -f "$source" "$keyring"
        return 1
    fi
    if ! apt_update || ! apt_install codium; then
        rm -f "$source" "$keyring"
        apt_update -qq || true
        return 1
    fi
}

install_virtualbox() {
    local source=/etc/apt/sources.list.d/virtualbox.sources
    local keyring=/usr/share/keyrings/oracle-virtualbox-2016.gpg
    install_armored_key \
        https://www.virtualbox.org/download/oracle_vbox_2016.asc \
        "$keyring" || return 1
    if ! cat > "$source" <<'EOF'
Types: deb
URIs: https://download.virtualbox.org/virtualbox/debian
Suites: trixie
Components: contrib
Architectures: amd64
Signed-By: /usr/share/keyrings/oracle-virtualbox-2016.gpg
EOF
    then
        rm -f "$source" "$keyring"
        return 1
    fi
    if ! apt_update || ! apt_install virtualbox-7.2; then
        rm -f "$source" "$keyring"
        apt_update -qq || true
        return 1
    fi
    usermod -aG vboxusers "$TARGET_USER" || return 1
}

msg "Brave"
optional "Brave" install_brave

msg "VSCodium"
optional "VSCodium" install_vscodium

msg "VirtualBox 7.2"
optional "VirtualBox" install_virtualbox

msg "Écran MSI MAG 275QF - 2560x1440, 180 Hz, DPI 125 % net"
cat > /usr/local/bin/apply-display-180hz <<'EOF'
#!/bin/sh
set -u
PATH=/usr/bin:/bin
export PATH

[ "${XDG_SESSION_TYPE:-x11}" = "x11" ] || exit 0
[ -n "${DISPLAY:-}" ] || exit 0

sleep 2
state="$(xrandr --query 2>/dev/null)" || exit 0
[ -n "$state" ] || exit 0

xfconf_ok=1
set_xfconf() {
    xfconf-query -c xsettings -p "$1" -n -t "$2" -s "$3" >/dev/null 2>&1 \
        || xfconf_ok=0
}

set_xfconf /Xft/DPI int 120
set_xfconf /Xfce/LastCustomDPI int 120
set_xfconf /Gdk/WindowScalingFactor int 1
set_xfconf /Xft/Antialias int 1
set_xfconf /Xft/Hinting int 1
set_xfconf /Xft/HintStyle string hintslight
set_xfconf /Xft/RGBA string rgb
set_xfconf /Xft/Lcdfilter string lcddefault
[ "$xfconf_ok" -eq 1 ] \
    || logger -t display-180hz "Impossible d'appliquer tous les réglages DPI XFCE."

selection="$(printf '%s\n' "$state" | awk '
    $2 == "connected" { output=$1; next }
    $2 == "disconnected" { output=""; next }
    output != "" && $1 == "2560x1440" {
        for (i=2; i<=NF; i++) {
            rate=$i
            gsub(/[+*]/, "", rate)
            if (rate + 0 >= 179 && rate + 0 <= 181) {
                print output, rate
                exit
            }
        }
    }
')"

if [ -z "$selection" ]; then
    logger -t display-180hz \
        "Mode 2560x1440 à 180 Hz indisponible; utiliser le câble DisplayPort 1.4."
    exit 0
fi

output="${selection%% *}"
rate="${selection#* }"
if ! xrandr --output "$output" --mode 2560x1440 --rate "$rate" \
        --primary --scale 1x1 --dpi 120; then
    logger -t display-180hz "Échec d'application du mode 2560x1440 à 180 Hz."
fi
EOF
chmod 0755 /usr/local/bin/apply-display-180hz

install -d -m 0755 /etc/xdg/autostart
cat > /etc/xdg/autostart/display-180hz.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=MSI MAG 275QF - 1440p 180 Hz and 125% DPI
Exec=/usr/local/bin/apply-display-180hz
TryExec=/usr/local/bin/apply-display-180hz
OnlyShowIn=XFCE;
NoDisplay=true
StartupNotify=false
X-GNOME-Autostart-enabled=true
EOF

msg "Clavier Français AZERTY - Caps Lock chiffres sans faux Shift"
cat > /etc/default/keyboard <<'EOF'
XKBMODEL="pc105"
XKBLAYOUT="fr"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF

cat > /usr/share/X11/xkb/symbols/fr_windows_caps <<'EOF'
partial alphanumeric_keys
xkb_symbols "digits" {
    key <AE01> { type[Group1] = "FOUR_LEVEL_ALPHABETIC" };
    key <AE02> { type[Group1] = "FOUR_LEVEL_ALPHABETIC" };
    key <AE03> { type[Group1] = "FOUR_LEVEL_ALPHABETIC" };
    key <AE04> { type[Group1] = "FOUR_LEVEL_ALPHABETIC" };
    key <AE05> { type[Group1] = "FOUR_LEVEL_ALPHABETIC" };
    key <AE06> { type[Group1] = "FOUR_LEVEL_ALPHABETIC" };
    key <AE07> { type[Group1] = "FOUR_LEVEL_ALPHABETIC" };
    key <AE08> { type[Group1] = "FOUR_LEVEL_ALPHABETIC" };
    key <AE09> { type[Group1] = "FOUR_LEVEL_ALPHABETIC" };
    key <AE10> { type[Group1] = "FOUR_LEVEL_ALPHABETIC" };
};
EOF

cat > /usr/local/bin/apply-fr-windows-caps <<'EOF'
#!/bin/sh
[ "${XDG_SESSION_TYPE:-x11}" = "x11" ] || exit 0
[ -n "${DISPLAY:-}" ] || exit 0
exec setxkbmap \
    -model pc105 \
    -layout fr \
    -option '' \
    -symbols 'pc+fr+inet(evdev)+fr_windows_caps(digits)'
EOF
chmod 0755 /usr/local/bin/apply-fr-windows-caps

install -d -m 0755 /etc/xdg/autostart
cat > /etc/xdg/autostart/fr-windows-caps.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=French AZERTY Windows-style CapsLock digits
Exec=/usr/local/bin/apply-fr-windows-caps
OnlyShowIn=XFCE;
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF

msg "Finalisation"
update-initramfs -u -k all
apt-get clean
systemctl daemon-reload

# Audits non destructifs
apt_update -qq
apt-get check
DPKG_AUDIT_OUTPUT="$(dpkg --audit)" || die "Impossible d'auditer l'état de dpkg."
[[ -z "$DPKG_AUDIT_OUTPUT" ]] || die "État dpkg incohérent: $DPKG_AUDIT_OUTPUT"
apt-config dump >/dev/null
unattended-upgrade --dry-run >/dev/null
NM_CONFIG_OUTPUT="$(NetworkManager --print-config)" \
    || die "Configuration NetworkManager invalide."
grep -Fxq 'dns=none' <<< "$NM_CONFIG_OUTPUT"
grep -Fxq 'rc-manager=unmanaged' <<< "$NM_CONFIG_OUTPUT"
grep -Fxq 'systemd-resolved=false' <<< "$NM_CONFIG_OUTPUT"
unset NM_CONFIG_OUTPUT
[[ "$(readlink -f /etc/resolv.conf)" == "/run/systemd/resolve/stub-resolv.conf" ]]
[[ -x /usr/games/gamemoderun ]]
[[ -r /etc/gamemode.ini ]]
[[ -e /usr/lib/i386-linux-gnu/libgamemode.so.0 ]]
[[ -e /usr/lib/i386-linux-gnu/libgamemodeauto.so.0 ]]
command -v xfconf-query >/dev/null
command -v xrandr >/dev/null
[[ -x /usr/local/bin/apply-display-180hz ]]
[[ -r /etc/xdg/autostart/display-180hz.desktop ]]
dash -n /usr/local/bin/apply-display-180hz
dash -n /usr/local/bin/apply-fr-windows-caps
nft -c -f /etc/nftables.conf
nft list chain inet filter input | grep -Fq 'policy drop'
nft list chain inet filter forward | grep -Fq 'policy drop'
aa-status --enabled
verify_quad9_doh \
    || die "L'audit final ne confirme pas Quad9 DNS over HTTPS."
for unit in \
    apt-daily.timer \
    apt-daily-upgrade.timer \
    fstrim.timer \
    dnscrypt-proxy.socket; do
    systemctl is-enabled --quiet "$unit"
done
for unit in \
    apt-daily.timer \
    apt-daily-upgrade.timer \
    fstrim.timer \
    apparmor.service \
    nftables.service \
    dnscrypt-proxy.socket \
    dnscrypt-proxy.service \
    systemd-resolved.service \
    NetworkManager.service; do
    systemctl is-active --quiet "$unit"
done

printf '\nTerminé. Sauvegarde: %s\nJournal: %s\n' "$BACKUP_DIR" "$LOG_FILE"
printf 'Steam/GameMode: utiliser "gamemoderun %%command%%" dans les options de lancement.\n'
printf 'Redémarrage recommandé; le 180 Hz exige une connexion DisplayPort.\n'
