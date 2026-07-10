#!/usr/bin/env bash
# Lubuntu 26.04 LTS (Resolute) - post-installation silencieuse et idempotente.
# Le journal complet est conserve dans /var/log/lubuntu-26.04-postinstall.log.

set -Eeuo pipefail
umask 022

readonly LOG_FILE="/var/log/lubuntu-26.04-postinstall.log"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
readonly RUN_ID
readonly BACKUP_DIR="/var/backups/lubuntu-26.04-postinstall/${RUN_ID}"
TEMP_PATHS=()

exec 3>&1
if [[ $EUID -ne 0 ]]; then
    printf 'ERREUR: executez ce script avec sudo\n' >&3
    exit 1
fi

install -d -m 0755 /var/log /run/lock
touch "$LOG_FILE"
chmod 0600 "$LOG_FILE"
exec >>"$LOG_FILE" 2>&1

exec 9>/run/lock/lubuntu-26.04-postinstall.lock
flock -n 9 || { printf 'ERREUR: une autre execution est deja active\n' >&3; exit 1; }

fail() {
    printf 'ERREUR: %s (journal: %s)\n' "$1" "$LOG_FILE" >&3
    exit 1
}

warn() {
    printf 'AVERTISSEMENT: %s (journal: %s)\n' "$1" "$LOG_FILE" >&3
}

on_error() {
    local rc=$? line=${1:-?} command=${2:-?} temporary
    for temporary in "${TEMP_PATHS[@]}"; do
        [[ $temporary == /tmp/* ]] && rm -rf -- "$temporary"
    done
    printf 'ERREUR ligne %s, code %s: %s (journal: %s)\n' \
        "$line" "$rc" "$command" "$LOG_FILE" >&3
    exit "$rc"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

valid_desktop_user() {
    local candidate=$1 uid
    [[ -n $candidate && $candidate != root ]] || return 1
    uid="$(id -u "$candidate" 2>/dev/null)" || return 1
    [[ $uid =~ ^[0-9]+$ ]] && ((uid >= 1000 && uid < 60000))
}

TARGET_USER="${TARGET_USER:-${SUDO_USER:-}}"
if ! valid_desktop_user "$TARGET_USER"; then
    for candidate in "$(logname 2>/dev/null || true)" "$(stat -c %U "$PWD" 2>/dev/null || true)"; do
        if valid_desktop_user "$candidate"; then
            TARGET_USER=$candidate
            break
        fi
    done
fi
if ! valid_desktop_user "$TARGET_USER"; then
    mapfile -t desktop_users < <(getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 {print $1}')
    ((${#desktop_users[@]} == 1)) && TARGET_USER=${desktop_users[0]}
fi
valid_desktop_user "$TARGET_USER" \
    || fail "utilisateur de bureau ambigu; lancez avec: sudo TARGET_USER=votre_utilisateur bash ./lubuntu-26.04-postinstall.sh"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
TARGET_GROUP="$(id -gn "$TARGET_USER")"
[[ -n $TARGET_HOME && -d $TARGET_HOME && $TARGET_HOME != / ]] || fail "repertoire utilisateur invalide"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export APT_LISTCHANGES_FRONTEND=none

OPTIONAL_FAILURES=()

apt_get() {
    apt-get -o DPkg::Lock::Timeout=300 "$@"
}

mkdir -p "$BACKUP_DIR"
chmod 0700 "$BACKUP_DIR"

backup_file() {
    local path=$1 rel
    [[ -e $path || -L $path ]] || return 0
    rel="${path#/}"
    mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
    cp -a -- "$path" "$BACKUP_DIR/$rel"
}

write_root_file() {
    local path=$1 mode=${2:-0644} dir tmp
    backup_file "$path"
    dir="$(dirname "$path")"
    mkdir -p "$dir"
    tmp="$(mktemp --tmpdir="$dir" ".$(basename "$path").XXXXXX")"
    cat >"$tmp"
    chown root:root "$tmp"
    chmod "$mode" "$tmp"
    mv -f "$tmp" "$path"
}

run_user() {
    runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" USER="$TARGET_USER" LOGNAME="$TARGET_USER" "$@"
}

install_available() {
    apt_get install -y --no-install-recommends "$@"
}

install_optional() {
    local pkg=$1
    if ! apt_get install -y "$pkg"; then
        OPTIONAL_FAILURES+=("$pkg")
        printf 'Installation optionnelle echouee: %s\n' "$pkg"
    fi
}

disable_and_mask() {
    local unit
    for unit in "$@"; do
        if systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q .; then
            systemctl stop "$unit" || true
            systemctl disable "$unit" || true
            systemctl mask "$unit"
        fi
    done
}

ini_set() {
    local file=$1 section=$2 key=$3 value=$4 tmp dir
    dir="$(dirname "$file")"
    mkdir -p "$dir"
    touch "$file"
    tmp="$(mktemp --tmpdir="$dir" ".$(basename "$file").XXXXXX")"
    awk -v section="$section" -v key="$key" -v value="$value" '
        BEGIN { inside=0; found_section=0; wrote=0 }
        $0 == "[" section "]" {
            if (inside && !wrote) print key "=" value
            inside=1; found_section=1; wrote=0; print; next
        }
        /^\[/ {
            if (inside && !wrote) { print key "=" value; wrote=1 }
            inside=0
        }
        inside && index($0, key "=") == 1 {
            if (!wrote) print key "=" value
            wrote=1; next
        }
        { print }
        END {
            if (inside && !wrote) print key "=" value
            if (!found_section) print "\n[" section "]\n" key "=" value
        }
    ' "$file" >"$tmp"
    chown "$TARGET_USER:$TARGET_GROUP" "$tmp"
    chmod 0644 "$tmp"
    mv -f "$tmp" "$file"
}

write_root_file /etc/logrotate.d/lubuntu-postinstall <<'EOF'
/var/log/lubuntu-26.04-postinstall.log {
    monthly
    rotate 4
    size 5M
    missingok
    notifempty
    compress
    delaycompress
    create 0600 root root
}
EOF

# ---------- Mise a jour de la base ----------

secure_boot_enabled=false
if command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -qi enabled; then
    secure_boot_enabled=true
elif compgen -G '/sys/firmware/efi/efivars/SecureBoot-*' >/dev/null; then
    secure_boot_var="$(compgen -G '/sys/firmware/efi/efivars/SecureBoot-*' | head -n1)"
    [[ $(od -An -t u1 -j4 -N1 "$secure_boot_var" 2>/dev/null | tr -d ' ') == 1 ]] && secure_boot_enabled=true
fi

dpkg --configure -a
apt_get update -qq
apt_get full-upgrade -y
apt_get install -y ca-certificates curl gpg software-properties-common

add-apt-repository -y universe
add-apt-repository -y multiverse
add-apt-repository -y restricted

if ! grep -Rqs 'damentz/liquorix' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
    add-apt-repository -y ppa:damentz/liquorix
fi

curl -fsSLo /usr/share/keyrings/brave-browser-archive-keyring.gpg \
    https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg
curl -fsSLo /etc/apt/sources.list.d/brave-browser-release.sources \
    https://brave-browser-apt-release.s3.brave.com/brave-browser.sources

curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
    | gpg --dearmor --yes -o /usr/share/keyrings/microsoft.gpg
chmod 0644 /usr/share/keyrings/microsoft.gpg
write_root_file /etc/apt/sources.list.d/vscode.sources <<'EOF'
Types: deb
URIs: https://packages.microsoft.com/repos/code
Suites: stable
Components: main
Architectures: amd64
Signed-By: /usr/share/keyrings/microsoft.gpg
EOF

curl -fsSLo /usr/share/keyrings/mullvad-keyring.asc \
    https://repository.mullvad.net/deb/mullvad-keyring.asc
chmod 0644 /usr/share/keyrings/mullvad-keyring.asc
write_root_file /etc/apt/sources.list.d/mullvad.sources <<'EOF'
Types: deb
URIs: https://repository.mullvad.net/deb/stable
Suites: stable
Components: main
Architectures: amd64
Signed-By: /usr/share/keyrings/mullvad-keyring.asc
EOF

dpkg --add-architecture i386
apt_get update -qq

# ---------- Paquets de base, pilotes, fichiers et affichage ----------

install_available \
    git rsync unzip xdg-utils xdg-user-dirs dbus-user-session \
    linux-firmware ubuntu-drivers-common fwupd mokutil sbsigntool openssl \
    mesa-vulkan-drivers mesa-libgallium mesa-utils libgl1-mesa-dri \
    mesa-vulkan-drivers:i386 libgl1-mesa-dri:i386 vulkan-tools vainfo \
    thunar thunar-archive-plugin thunar-media-tags-plugin thunar-volman \
    tumbler ffmpegthumbnailer gvfs gvfs-backends xarchiver \
    xdg-desktop-portal xdg-desktop-portal-lxqt xdg-desktop-portal-gtk \
    xdg-desktop-portal-wlr qtwayland5 qt6-wayland xwayland wlr-randr labwc \
    lxqt-wayland-session swaylock grim slurp wl-clipboard \
    flatpak plasma-discover-backend-flatpak \
    pipewire pipewire-audio pipewire-pulse pipewire-alsa wireplumber pavucontrol \
    gamemode libgamemode0 libgamemodeauto0 libgamemode0:i386 libgamemodeauto0:i386 \
    ufw gufw apparmor apparmor-utils apparmor-profiles apparmor-profiles-extra \
    unattended-upgrades rfkill lm-sensors power-profiles-daemon \
    fonts-noto-core fonts-noto-cjk fonts-noto-extra fonts-noto-ui-core \
    fonts-noto-color-emoji fonts-noto-mono fonts-inter fonts-firacode \
    fonts-dejavu fonts-liberation2 fonts-kacst-one fonts-sil-scheherazade \
    fonts-sil-padauk fonts-khmeros-core fonts-thai-tlwg \
    sassc libglib2.0-dev-bin gtk2-engines-murrine gtk2-engines-pixbuf \
    qt5-style-kvantum qt6-style-kvantum libplasma7 \
    qml6-module-org-kde-breeze qml6-module-org-kde-kirigami \
    qml6-module-org-kde-plasma-plasma5support qml6-module-qt5compat-graphicaleffects \
    qml6-module-qtquick-controls qml6-module-qtquick-layouts \
    amd64-microcode

systemctl enable --now fwupd.service || true
fwupdmgr refresh --force || true
fwupdmgr get-updates || true

apt_get install -y linux-image-liquorix-amd64 linux-headers-liquorix-amd64

if $secure_boot_enabled; then
    mok_dir=/root/secureboot-liquorix
    install -d -m 0700 "$mok_dir"
    if [[ ! -s $mok_dir/MOK.key || ! -s $mok_dir/MOK.pem || ! -s $mok_dir/MOK.der ]]; then
        openssl req -new -x509 -newkey rsa:3072 -sha256 -nodes -days 3650 \
            -subj '/CN=Local Liquorix Secure Boot/' \
            -keyout "$mok_dir/MOK.key" -out "$mok_dir/MOK.pem"
        openssl x509 -outform DER -in "$mok_dir/MOK.pem" -out "$mok_dir/MOK.der"
        chmod 0600 "$mok_dir/MOK.key"
        chmod 0644 "$mok_dir/MOK.pem" "$mok_dir/MOK.der"
    fi

    write_root_file /etc/kernel/postinst.d/zz-sign-liquorix 0755 <<'EOF'
#!/bin/sh
set -eu
version=${1:-}
image=${2:-/boot/vmlinuz-$version}
case "$image" in
    *liquorix*) ;;
    *) exit 0 ;;
esac
[ -f "$image" ] || exit 0
key=/root/secureboot-liquorix/MOK.key
cert=/root/secureboot-liquorix/MOK.pem
[ -s "$key" ] && [ -s "$cert" ] || exit 1
sbverify --cert "$cert" "$image" >/dev/null 2>&1 && exit 0
tmp=$(mktemp "${image}.signed.XXXXXX")
trap 'rm -f "$tmp"' EXIT
sbsign --key "$key" --cert "$cert" --output "$tmp" "$image" >/dev/null
chmod --reference="$image" "$tmp"
chown --reference="$image" "$tmp"
mv -f "$tmp" "$image"
trap - EXIT
EOF

    while IFS= read -r liquorix_image; do
        liquorix_version="${liquorix_image#/boot/vmlinuz-}"
        /etc/kernel/postinst.d/zz-sign-liquorix "$liquorix_version" "$liquorix_image"
    done < <(find /boot -maxdepth 1 -type f -name 'vmlinuz-*-liquorix-amd64' -print | sort -V)

    if ! mokutil --test-key "$mok_dir/MOK.der" >/dev/null 2>&1 \
        && ! mokutil --list-new 2>/dev/null | grep -q 'Local Liquorix Secure Boot'; then
        printf 'Secure Boot: choisissez maintenant un mot de passe MOK temporaire. Au redemarrage: Enroll MOK > Continue > Yes.\n' >&3
        mokutil --import "$mok_dir/MOK.der" >&3
    fi
fi

write_root_file /etc/default/grub.d/60-liquorix-default.cfg <<'EOF'
GRUB_DEFAULT=0
GRUB_SAVEDEFAULT=false
EOF
write_root_file /etc/default/grub.d/61-amd-pstate.cfg <<'EOF'
GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT} amd_pstate=active"
EOF
update-grub

flatpak remote-add --system --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

# PCManFM-Qt reste installe uniquement pour le bureau LXQt; Thunar ouvre les dossiers.
run_user xdg-mime default thunar.desktop inode/directory
run_user xdg-mime default thunar.desktop application/x-gnome-saved-search
run_user gio mime inode/directory thunar.desktop || true
run_user xdg-user-dirs-update

# ---------- Suppression et blocage de Snap ----------

if command -v snap >/dev/null 2>&1; then
    for _ in 1 2 3; do
        mapfile -t snaps < <(snap list 2>/dev/null | awk 'NR>1 {print $1}' | tac)
        ((${#snaps[@]} == 0)) && break
        for snap_name in "${snaps[@]}"; do
            snap remove --purge "$snap_name" || true
        done
    done
fi
apt_get purge -y snapd || true
disable_and_mask snapd.service snapd.socket snapd.seeded.service snapd.apparmor.service
write_root_file /etc/apt/preferences.d/no-snap.pref <<'EOF'
Package: snapd
Pin: release a=*
Pin-Priority: -10
EOF
rm -rf -- /var/cache/snapd /snap
if [[ $TARGET_HOME == /home/* || $TARGET_HOME == /root ]]; then
    rm -rf -- "$TARGET_HOME/snap"
fi

# ---------- Applications natives (meilleur effort demande) ----------

printf '%s\n' 'steam steam/question select I AGREE' | debconf-set-selections || true
install_optional vlc
install_optional btop
install_optional brave-browser
install_optional code
install_optional mullvad-vpn
install_optional actiona
install_optional steam-installer
install_optional qbittorrent
install_optional filezilla
install_optional gammastep

discord_deb="$(mktemp --suffix=.deb)"
TEMP_PATHS+=("$discord_deb")
if curl -fLso "$discord_deb" 'https://discord.com/api/download?platform=linux&format=deb'; then
    if ! apt_get install -y "$discord_deb"; then
        OPTIONAL_FAILURES+=("discord")
        printf 'Installation optionnelle echouee: Discord\n'
    fi
else
    OPTIONAL_FAILURES+=("discord")
    printf 'Telechargement optionnel echoue: Discord\n'
fi
rm -f "$discord_deb"

systemctl enable --now mullvad-daemon.service || true

# ---------- Audio PipeWire ----------

systemctl --global disable pulseaudio.service pulseaudio.socket || true
systemctl --global mask pulseaudio.service pulseaudio.socket || true
systemctl --global enable pipewire.socket pipewire-pulse.socket

write_root_file /etc/pipewire/pipewire.conf.d/10-low-latency-stable.conf <<'EOF'
context.properties = {
    default.clock.rate = 48000
    default.clock.quantum = 256
    default.clock.min-quantum = 128
    default.clock.max-quantum = 1024
}
EOF

# ---------- Quad9 DoT par connexion physique, compatible VPN ----------

write_root_file /etc/brave/policies/managed/10-use-system-quad9.json <<'EOF'
{
  "DnsOverHttpsMode": "off"
}
EOF

write_root_file /etc/NetworkManager/conf.d/10-dns-systemd-resolved.conf <<'EOF'
[main]
dns=systemd-resolved
systemd-resolved=true
EOF

write_root_file /etc/systemd/resolved.conf.d/90-privacy.conf <<'EOF'
[Resolve]
DNSSEC=no
DNSOverTLS=no
LLMNR=no
MulticastDNS=no
Cache=yes
DNSStubListener=yes
EOF

backup_file /etc/resolv.conf
ln -sfn /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
systemctl enable --now systemd-resolved.service

write_root_file /usr/local/sbin/apply-quad9-dot 0755 <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
while IFS=: read -r connection_uuid connection_type; do
    [[ $connection_type == 802-3-ethernet || $connection_type == 802-11-wireless ]] || continue
    nmcli connection modify "$connection_uuid" \
        ipv4.ignore-auto-dns yes \
        ipv4.dns '9.9.9.9#dns.quad9.net,149.112.112.112#dns.quad9.net' \
        ipv6.ignore-auto-dns yes \
        ipv6.dns '2620:fe::fe#dns.quad9.net,2620:fe::9#dns.quad9.net' \
        connection.dns-over-tls yes \
        connection.llmnr no \
        connection.mdns no
done < <(nmcli --terse --fields UUID,TYPE connection show)
EOF

write_root_file /etc/systemd/system/quad9-dot-refresh.service <<'EOF'
[Unit]
Description=Apply strict Quad9 DNS-over-TLS to physical NetworkManager profiles
After=NetworkManager.service systemd-resolved.service
Wants=NetworkManager.service systemd-resolved.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/apply-quad9-dot
EOF

write_root_file /etc/systemd/system/quad9-dot-refresh.timer <<'EOF'
[Unit]
Description=Refresh Quad9 DNS-over-TLS on new NetworkManager profiles

[Timer]
OnBootSec=2min
OnUnitActiveSec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF

/usr/local/sbin/apply-quad9-dot
systemctl reload NetworkManager.service || true
while IFS=: read -r device device_type device_state; do
    [[ $device_state == connected ]] || continue
    [[ $device_type == ethernet || $device_type == wifi ]] || continue
    nmcli device reapply "$device" || true
done < <(nmcli --terse --fields DEVICE,TYPE,STATE device status)

# ---------- Sysctl: faible latence, 2.5 Gb/s, RAM 32 Gio, hardening ----------

write_root_file /etc/modules-load.d/tcp-bbr.conf <<'EOF'
tcp_bbr
EOF

write_root_file /etc/sysctl.d/90-desktop-lowlatency-hardening.conf <<'EOF'
# Memoire: faible pression cache et rafales d'ecriture bornees pour le NVMe.
vm.swappiness = 10
vm.vfs_cache_pressure = 100
vm.dirty_background_bytes = 33554432
vm.dirty_bytes = 268435456
vm.page-cluster = 0

# Developpement et gros repertoires sans reservation memoire statique.
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024

# Durcissement compatible navigateurs, Flatpak, Steam, VPN et partage d'ecran.
fs.protected_fifos = 2
fs.protected_regular = 2
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.suid_dumpable = 0
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.yama.ptrace_scope = 1
kernel.unprivileged_bpf_disabled = 1
kernel.kexec_load_disabled = 1

# Reseau: file bornee, buffers auto jusqu'a 64 Mio, VPN/multihoming permis.
net.core.default_qdisc = fq
net.core.netdev_max_backlog = 2048
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_rmem = 4096 131072 67108864
net.ipv4.tcp_wmem = 4096 16384 67108864
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fastopen = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
EOF

modprobe tcp_bbr
sysctl --system
write_root_file /etc/udev/rules.d/60-nvme-lowlatency.rules <<'EOF'
ACTION=="add|change", KERNEL=="nvme[0-9]*n[0-9]*", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="none"
EOF
while IFS= read -r scheduler_file; do
    grep -qw none "$scheduler_file" && printf 'none\n' >"$scheduler_file"
done < <(find /sys/block -path '*/nvme*n*/queue/scheduler' -type f -print 2>/dev/null)
systemctl enable --now fstrim.timer

# ---------- Pare-feu, AppArmor et mises a jour automatiques ----------

if [[ -f /etc/default/ufw ]]; then
    backup_file /etc/default/ufw
    sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
fi
ufw default deny incoming
ufw default allow outgoing
ufw default deny routed
ufw logging low
ufw --force enable

systemctl enable apparmor.service
systemctl restart apparmor.service

write_root_file /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
write_root_file /etc/apt/apt.conf.d/52unattended-local <<'EOF'
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "false";
Unattended-Upgrade::Remove-New-Unused-Dependencies "false";
Unattended-Upgrade::Remove-Unused-Dependencies "false";
Unattended-Upgrade::Origins-Pattern {
    "origin=LP-PPA-damentz-liquorix,codename=${distro_codename}";
    "site=brave-browser-apt-release.s3.brave.com";
    "site=packages.microsoft.com";
    "site=repository.mullvad.net";
};
EOF
systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
systemctl daemon-reload
systemctl enable --now quad9-dot-refresh.timer

# ---------- Clavier FR legacy, Verr. Maj active les chiffres ----------

write_root_file /etc/default/keyboard <<'EOF'
XKBMODEL="pc105"
XKBLAYOUT="fr"
XKBVARIANT="latin9"
XKBOPTIONS="caps:digits_row"
BACKSPACE="guess"
EOF
localectl --no-convert set-x11-keymap fr pc105 latin9 caps:digits_row || true

# ---------- Services non utilises et vie privee ----------

disable_and_mask \
    bluetooth.service cups.service cups.socket cups.path cups-browsed.service \
    avahi-daemon.service avahi-daemon.socket ModemManager.service \
    kdump-tools.service whoopsie.service kerneloops.service \
    apport-autoreport.timer motd-news.timer \
    ubuntu-insights.service ubuntu-insights.timer

write_root_file /etc/systemd/coredump.conf.d/90-privacy.conf <<'EOF'
[Coredump]
Storage=none
ProcessSizeMax=0
EOF

write_root_file /etc/systemd/system/radio-block.service <<'EOF'
[Unit]
Description=Disable Wi-Fi and Bluetooth radios
After=systemd-rfkill.service

[Service]
Type=oneshot
ExecStart=/usr/sbin/rfkill block wifi
ExecStart=/usr/sbin/rfkill block bluetooth
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable radio-block.service

if [[ -f /etc/default/apport ]]; then
    backup_file /etc/default/apport
    sed -i 's/^enabled=.*/enabled=0/' /etc/default/apport
fi
if [[ -f /etc/popularity-contest.conf ]]; then
    backup_file /etc/popularity-contest.conf
    sed -i 's/^PARTICIPATE=.*/PARTICIPATE="no"/' /etc/popularity-contest.conf
fi
run_user ubuntu-report -f send no || true
if command -v ubuntu-insights >/dev/null 2>&1; then
    run_user ubuntu-insights disable || true
fi

ini_set "$TARGET_HOME/.config/kwalletrc" Wallet Enabled false
ini_set "$TARGET_HOME/.config/baloofilerc" 'Basic Settings' Indexing-Enabled false

if command -v powerprofilesctl >/dev/null 2>&1; then
    systemctl enable --now power-profiles-daemon.service || true
    powerprofilesctl set balanced || true
fi

# ---------- Theme WhiteSur epingle et execute sans privileges ----------

readonly THEME_GTK_SHA='3bd1b21f7a097c2a4cd88d58ed94385463455692'
readonly THEME_ICON_SHA='be13578d05bc1ada81a0243516340d8892ebaccc'
readonly THEME_CURSOR_SHA='e190baf618ed95ee217d2fd45589bd309b37672b'
readonly THEME_KDE_SHA='1e4d960945572d05a3d96bec5253dd83971239f2'

theme_checkout() {
    local repo=$1 sha=$2 dir=$3
    install -d -o "$TARGET_USER" -g "$TARGET_GROUP" "$dir"
    run_user git -C "$dir" init -q
    run_user git -C "$dir" remote add origin "https://github.com/vinceliuice/${repo}.git"
    run_user git -C "$dir" fetch -q --depth=1 origin "$sha"
    run_user git -C "$dir" checkout -q --detach FETCH_HEAD
}

theme_tmp="$(mktemp -d)"
TEMP_PATHS+=("$theme_tmp")
chown "$TARGET_USER:$TARGET_GROUP" "$theme_tmp"
backup_file "$TARGET_HOME/.config/gtk-4.0"
theme_checkout WhiteSur-gtk-theme "$THEME_GTK_SHA" "$theme_tmp/gtk"
theme_checkout WhiteSur-icon-theme "$THEME_ICON_SHA" "$theme_tmp/icons"
theme_checkout WhiteSur-cursors "$THEME_CURSOR_SHA" "$theme_tmp/cursors"
theme_checkout WhiteSur-kde "$THEME_KDE_SHA" "$theme_tmp/kde"

run_user bash -c "cd '$theme_tmp/gtk' && ./install.sh -d '$TARGET_HOME/.local/share/themes' -o solid -c dark -a normal -t default -s standard -l --silent-mode"
run_user bash -c "cd '$theme_tmp/icons' && ./install.sh -d '$TARGET_HOME/.local/share/icons' -t default"
run_user bash -c "cd '$theme_tmp/cursors' && ./install.sh"
run_user bash -c "cd '$theme_tmp/kde' && ./install.sh --opaque"
bash "$theme_tmp/kde/sddm/install.sh"
rm -rf -- "$theme_tmp"

write_root_file /etc/sddm.conf.d/20-whitesur.conf <<'EOF'
[Theme]
Current=WhiteSur-dark
CursorTheme=WhiteSur-cursors
EOF

# Decoration Openbox/labwc legere avec controles type macOS a gauche.
openbox_theme="$TARGET_HOME/.themes/WhiteSur-Openbox/openbox-3"
install -d -o "$TARGET_USER" -g "$TARGET_GROUP" "$openbox_theme"
cat >"$openbox_theme/themerc" <<'EOF'
border.width: 1
border.color: #101010
padding.width: 5
padding.height: 4
window.handle.width: 3
window.active.client.color: #242424
window.inactive.client.color: #202020
window.active.title.bg: Solid
window.active.title.bg.color: #242424
window.inactive.title.bg: Solid
window.inactive.title.bg.color: #202020
window.active.label.bg: Parentrelative
window.inactive.label.bg: Parentrelative
window.active.label.text.color: #f2f2f2
window.inactive.label.text.color: #8a8a8a
window.label.text.justify: Center
window.active.button.unpressed.bg: Parentrelative
window.inactive.button.unpressed.bg: Parentrelative
window.active.button.hover.bg: Solid
window.active.button.hover.bg.color: #343434
window.active.button.close.unpressed.image.color: #ff5f57
window.active.button.iconify.unpressed.image.color: #febc2e
window.active.button.max.unpressed.image.color: #28c840
window.active.button.close.hover.image.color: #ff5f57
window.active.button.iconify.hover.image.color: #febc2e
window.active.button.max.hover.image.color: #28c840
window.inactive.button.unpressed.image.color: #666666
window.active.handle.bg: Solid
window.active.handle.bg.color: #242424
window.inactive.handle.bg: Solid
window.inactive.handle.bg.color: #202020
menu.border.width: 1
menu.border.color: #101010
menu.items.bg: Solid
menu.items.bg.color: #242424
menu.items.text.color: #f2f2f2
menu.items.active.bg: Solid
menu.items.active.bg.color: #3d78cc
menu.items.active.text.color: #ffffff
menu.title.bg: Solid
menu.title.bg.color: #1d1d1d
menu.title.text.color: #f2f2f2
menu.title.text.justify: Center
osd.bg: Solid
osd.bg.color: #242424
osd.label.text.color: #f2f2f2
EOF

for button in close iconify max; do
    cat >"$openbox_theme/${button}.xbm" <<EOF
#define ${button}_width 10
#define ${button}_height 10
static unsigned char ${button}_bits[] = {
  0x78, 0x00, 0xfe, 0x01, 0xff, 0x03, 0xff, 0x03, 0xff, 0x03,
  0xff, 0x03, 0xff, 0x03, 0xff, 0x03, 0xfe, 0x01, 0x78, 0x00 };
EOF
done
chown -R "$TARGET_USER:$TARGET_GROUP" "$TARGET_HOME/.themes/WhiteSur-Openbox"
openbox_data_theme="$TARGET_HOME/.local/share/themes/WhiteSur-Openbox"
if [[ -L $openbox_data_theme || ! -e $openbox_data_theme ]]; then
    ln -sfnT "$TARGET_HOME/.themes/WhiteSur-Openbox" "$openbox_data_theme"
    chown -h "$TARGET_USER:$TARGET_GROUP" "$openbox_data_theme"
fi

openbox_rc="$TARGET_HOME/.config/openbox/lxqt-rc.xml"
if [[ ! -f $openbox_rc ]]; then
    for template in /etc/xdg/xdg-Lubuntu/openbox/lxqt-rc.xml /etc/xdg/openbox/rc.xml; do
        if [[ -f $template ]]; then
            install -D -o "$TARGET_USER" -g "$TARGET_GROUP" -m 0644 "$template" "$openbox_rc"
            break
        fi
    done
fi
if [[ -f $openbox_rc ]]; then
    backup_file "$openbox_rc"
    sed -i '/<theme>/,/<\/theme>/ s#<name>.*</name>#<name>WhiteSur-Openbox</name>#' "$openbox_rc"
    sed -i 's#<titleLayout>.*</titleLayout>#<titleLayout>CIML</titleLayout>#' "$openbox_rc"
    chown "$TARGET_USER:$TARGET_GROUP" "$openbox_rc"
fi

labwc_rc="$TARGET_HOME/.config/labwc/rc.xml"
if [[ ! -f $labwc_rc && -f /etc/xdg/labwc/rc.xml ]]; then
    install -D -o "$TARGET_USER" -g "$TARGET_GROUP" -m 0644 /etc/xdg/labwc/rc.xml "$labwc_rc"
fi
if [[ ! -f $labwc_rc ]]; then
    install -d -o "$TARGET_USER" -g "$TARGET_GROUP" "$(dirname "$labwc_rc")"
    cat >"$labwc_rc" <<'EOF'
<?xml version="1.0"?>
<labwc_config>
  <core>
    <adaptiveSync>yes</adaptiveSync>
    <allowTearing>yes</allowTearing>
  </core>
  <theme><name>WhiteSur-Openbox</name></theme>
</labwc_config>
EOF
fi
if [[ -f $labwc_rc ]]; then
    backup_file "$labwc_rc"
    sed -i '/<theme>/,/<\/theme>/ s#<name>.*</name>#<name>WhiteSur-Openbox</name>#' "$labwc_rc"
    if grep -q '<adaptiveSync>' "$labwc_rc"; then
        sed -i 's#<adaptiveSync>.*</adaptiveSync>#<adaptiveSync>yes</adaptiveSync>#' "$labwc_rc"
    else
        sed -i '/<core>/a\    <adaptiveSync>yes</adaptiveSync>' "$labwc_rc"
    fi
    if grep -q '<allowTearing>' "$labwc_rc"; then
        sed -i 's#<allowTearing>.*</allowTearing>#<allowTearing>yes</allowTearing>#' "$labwc_rc"
    else
        sed -i '/<core>/a\    <allowTearing>yes</allowTearing>' "$labwc_rc"
    fi
    chown "$TARGET_USER:$TARGET_GROUP" "$labwc_rc"
fi

install -d -o "$TARGET_USER" -g "$TARGET_GROUP" \
    "$TARGET_HOME/.config/labwc" "$TARGET_HOME/.config/xdg-desktop-portal"
cat >"$TARGET_HOME/.config/labwc/environment" <<'EOF'
XKB_DEFAULT_MODEL=pc105
XKB_DEFAULT_LAYOUT=fr
XKB_DEFAULT_VARIANT=latin9
XKB_DEFAULT_OPTIONS=caps:digits_row
XCURSOR_THEME=WhiteSur-cursors
XCURSOR_SIZE=24
QT_QPA_PLATFORM=wayland
ELECTRON_OZONE_PLATFORM_HINT=auto
EOF

labwc_autostart="$TARGET_HOME/.config/labwc/autostart"
touch "$labwc_autostart"
if ! grep -q 'lubuntu-postinstall-portal-environment' "$labwc_autostart"; then
    cat >>"$labwc_autostart" <<'EOF'

# lubuntu-postinstall-portal-environment
dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE
systemctl --user restart xdg-desktop-portal.service xdg-desktop-portal-wlr.service
EOF
fi

for portal_config_name in portals.conf lxqt-portals.conf labwc-portals.conf wlroots-portals.conf; do
    backup_file "$TARGET_HOME/.config/xdg-desktop-portal/$portal_config_name"
done
cat >"$TARGET_HOME/.config/xdg-desktop-portal/lxqt-portals.conf" <<'EOF'
[preferred]
default=lxqt;gtk;
org.freedesktop.impl.portal.Access=lxqt;gtk;
org.freedesktop.impl.portal.FileChooser=lxqt;gtk;
org.freedesktop.impl.portal.ScreenCast=wlr;
org.freedesktop.impl.portal.Screenshot=wlr;
EOF
cp "$TARGET_HOME/.config/xdg-desktop-portal/lxqt-portals.conf" \
    "$TARGET_HOME/.config/xdg-desktop-portal/portals.conf"
cp "$TARGET_HOME/.config/xdg-desktop-portal/lxqt-portals.conf" \
    "$TARGET_HOME/.config/xdg-desktop-portal/labwc-portals.conf"
cp "$TARGET_HOME/.config/xdg-desktop-portal/lxqt-portals.conf" \
    "$TARGET_HOME/.config/xdg-desktop-portal/wlroots-portals.conf"
chown -R "$TARGET_USER:$TARGET_GROUP" \
    "$TARGET_HOME/.config/labwc" "$TARGET_HOME/.config/xdg-desktop-portal"

install -d -o "$TARGET_USER" -g "$TARGET_GROUP" "$TARGET_HOME/.config/autostart"
while IFS= read -r x11_autostart; do
    user_autostart="$TARGET_HOME/.config/autostart/$(basename "$x11_autostart")"
    backup_file "$user_autostart"
    install -o "$TARGET_USER" -g "$TARGET_GROUP" -m 0644 "$x11_autostart" "$user_autostart"
    if grep -q '^X-LXQt-X11-Only=' "$user_autostart"; then
        sed -i 's/^X-LXQt-X11-Only=.*/X-LXQt-X11-Only=true/' "$user_autostart"
    else
        sed -i '/^\[Desktop Entry\]/a X-LXQt-X11-Only=true' "$user_autostart"
    fi
done < <(grep -lE '^Exec=.*(picom|xscreensaver)' /etc/xdg/autostart/*.desktop 2>/dev/null || true)

mkdir -p "$TARGET_HOME/.config/Kvantum"
write_root_file "$TARGET_HOME/.config/Kvantum/kvantum.kvconfig" <<'EOF'
[General]
theme=WhiteSur-opaqueDark
EOF
chown -R "$TARGET_USER:$TARGET_GROUP" "$TARGET_HOME/.config/Kvantum"

backup_file "$TARGET_HOME/.config/lxqt/lxqt.conf"
ini_set "$TARGET_HOME/.config/lxqt/lxqt.conf" General style kvantum
ini_set "$TARGET_HOME/.config/lxqt/lxqt.conf" General theme WhiteSur
ini_set "$TARGET_HOME/.config/lxqt/lxqt.conf" General icon_theme WhiteSur-dark
ini_set "$TARGET_HOME/.config/lxqt/lxqt.conf" General icon_follow_color_scheme true
ini_set "$TARGET_HOME/.config/lxqt/lxqt.conf" General font 'Inter,10,-1,5,50,0,0,0,0,0'

backup_file "$TARGET_HOME/.config/lxqt/session.conf"
ini_set "$TARGET_HOME/.config/lxqt/session.conf" Mouse cursor_theme WhiteSur-cursors
ini_set "$TARGET_HOME/.config/lxqt/session.conf" Mouse cursor_size 24
ini_set "$TARGET_HOME/.config/lxqt/session.conf" General compositor labwc
ini_set "$TARGET_HOME/.config/lxqt/session.conf" General lock_command_wayland swaylock

lxqt_theme_dir="$TARGET_HOME/.local/share/lxqt/themes/WhiteSur"
install -d -o "$TARGET_USER" -g "$TARGET_GROUP" "$lxqt_theme_dir"
cat >"$lxqt_theme_dir/lxqt-panel.qss" <<'EOF'
LXQtPanel #BackgroundWidget {
    background: #202020;
    color: #f2f2f2;
}
LXQtPanel QToolButton {
    background: transparent;
    border: 0;
    border-radius: 7px;
    color: #f2f2f2;
    padding: 3px 6px;
}
LXQtPanel QToolButton:hover { background: #383838; }
LXQtPanel QToolButton:checked { background: #454545; }
QMenu {
    background: #242424;
    border: 1px solid #101010;
    border-radius: 8px;
    color: #f2f2f2;
    padding: 5px;
}
QMenu::item { border-radius: 5px; padding: 5px 22px; }
QMenu::item:selected { background: #3d78cc; color: white; }
EOF
cat >"$lxqt_theme_dir/lxqt-notificationd.qss" <<'EOF'
#notificationWidget {
    background: #242424;
    border: 1px solid #101010;
    border-radius: 12px;
    color: #f2f2f2;
}
#closeButton { border: 0; border-radius: 7px; background: #ff5f57; }
EOF
cat >"$lxqt_theme_dir/lxqt-runner.qss" <<'EOF'
QDialog { background: #242424; color: #f2f2f2; border-radius: 12px; }
QLineEdit { background: #303030; border: 1px solid #555; border-radius: 8px; padding: 8px; color: #fff; }
QListView { background: #242424; border: 0; color: #f2f2f2; }
QListView::item:selected { background: #3d78cc; border-radius: 6px; }
EOF
chown -R "$TARGET_USER:$TARGET_GROUP" "$TARGET_HOME/.local/share/lxqt"

backup_file "$TARGET_HOME/.config/gtk-3.0/settings.ini"
ini_set "$TARGET_HOME/.config/gtk-3.0/settings.ini" Settings gtk-theme-name WhiteSur-Dark-solid
ini_set "$TARGET_HOME/.config/gtk-3.0/settings.ini" Settings gtk-icon-theme-name WhiteSur-dark
ini_set "$TARGET_HOME/.config/gtk-3.0/settings.ini" Settings gtk-cursor-theme-name WhiteSur-cursors
ini_set "$TARGET_HOME/.config/gtk-3.0/settings.ini" Settings gtk-font-name 'Inter 10'
ini_set "$TARGET_HOME/.config/gtk-3.0/settings.ini" Settings gtk-application-prefer-dark-theme 1

backup_file "$TARGET_HOME/.gtkrc-2.0"
cat >"$TARGET_HOME/.gtkrc-2.0" <<'EOF'
gtk-theme-name="WhiteSur-Dark-solid"
gtk-icon-theme-name="WhiteSur-dark"
gtk-cursor-theme-name="WhiteSur-cursors"
gtk-font-name="Inter 10"
EOF
chown "$TARGET_USER:$TARGET_GROUP" "$TARGET_HOME/.gtkrc-2.0"

run_user flatpak override --user \
    --filesystem="$TARGET_HOME/.local/share/themes:ro" \
    --filesystem="$TARGET_HOME/.local/share/icons:ro" \
    --filesystem="$TARGET_HOME/.config/gtk-3.0:ro" \
    --filesystem="$TARGET_HOME/.config/gtk-4.0:ro"
run_user dbus-run-session gsettings set org.gnome.desktop.interface color-scheme prefer-dark || true

install -d -o "$TARGET_USER" -g "$TARGET_GROUP" "$TARGET_HOME/.icons/default"
cat >"$TARGET_HOME/.icons/default/index.theme" <<'EOF'
[Icon Theme]
Inherits=WhiteSur-cursors
Size=24
EOF
chown "$TARGET_USER:$TARGET_GROUP" "$TARGET_HOME/.icons/default/index.theme"

install -d -o "$TARGET_USER" -g "$TARGET_GROUP" "$TARGET_HOME/.config/fontconfig/conf.d"
cat >"$TARGET_HOME/.config/fontconfig/conf.d/90-crisp-120dpi.conf" <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <match target="pattern"><edit name="dpi" mode="assign"><double>120</double></edit></match>
  <match target="font">
    <edit name="antialias" mode="assign"><bool>true</bool></edit>
    <edit name="hinting" mode="assign"><bool>true</bool></edit>
    <edit name="hintstyle" mode="assign"><const>hintslight</const></edit>
    <edit name="rgba" mode="assign"><const>none</const></edit>
  </match>
</fontconfig>
EOF
chown "$TARGET_USER:$TARGET_GROUP" "$TARGET_HOME/.config/fontconfig/conf.d/90-crisp-120dpi.conf"
run_user fc-cache -f

# ---------- Ecran 2560x1440, 180 Hz et echelle nette ----------

write_root_file /etc/X11/xorg.conf.d/20-amdgpu-vrr.conf <<'EOF'
Section "OutputClass"
    Identifier "AMDgpu Variable Refresh"
    MatchDriver "amdgpu"
    Driver "amdgpu"
    Option "VariableRefresh" "true"
EndSection
EOF

install -d -o "$TARGET_USER" -g "$TARGET_GROUP" \
    "$TARGET_HOME/.local/bin" "$TARGET_HOME/.config/autostart" \
    "$TARGET_HOME/.config/environment.d" "$TARGET_HOME/.Xresources.d"

backup_file "$TARGET_HOME/.config/picom.conf"
cat >"$TARGET_HOME/.config/picom.conf" <<'EOF'
backend = "glx";
vsync = true;
use-damage = true;
unredir-if-possible = true;
unredir-if-possible-delay = 0;
detect-client-opacity = true;
mark-wmwin-focused = true;
mark-ovredir-focused = true;
EOF
chown "$TARGET_USER:$TARGET_GROUP" "$TARGET_HOME/.config/picom.conf"

cat >"$TARGET_HOME/.Xresources.d/90-display" <<'EOF'
Xft.dpi: 120
Xcursor.theme: WhiteSur-cursors
Xcursor.size: 24
EOF

cat >"$TARGET_HOME/.config/environment.d/90-desktop.conf" <<'EOF'
ELECTRON_OZONE_PLATFORM_HINT=auto
XCURSOR_THEME=WhiteSur-cursors
XCURSOR_SIZE=24
EOF

cat >"$TARGET_HOME/.local/bin/apply-display-profile" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

log() { logger -t lubuntu-display-profile -- "$*"; }
die() { log "ERREUR: $*"; exit 1; }

if [[ ${XDG_SESSION_TYPE:-} == x11 ]] && command -v xrandr >/dev/null 2>&1; then
    command -v xrdb >/dev/null 2>&1 && xrdb -merge "$HOME/.Xresources.d/90-display"
    output="$(xrandr --query | awk '
        $1 ~ /^(DP-|DisplayPort-)/ && $2=="connected" {print $1; exit}
        $2=="connected" {
            if ($3=="primary") {print $1; found=1; exit}
            if (first=="") first=$1
        }
        END {if (!found && first!="") print first}
    ')"
    refresh="$(xrandr --query | awk -v output="$output" '
        $1==output && $2=="connected" {active=1; next}
        /^[^[:space:]]/ {active=0}
        active && $1=="2560x1440" {
            for (i=2; i<=NF; i++) {gsub(/[+*]/,"",$i); if ($i+0>=179 && $i+0<=181) {print $i; exit}}
        }')"
    [[ -n $output ]] || die "aucune sortie connectee"
    [[ -n $refresh ]] || die "mode DisplayPort 2560x1440 a 180 Hz absent sur $output"
    xrandr --output "$output" --primary --mode 2560x1440 --rate "$refresh"
    xrandr --query | awk -v output="$output" '
        $1==output && $2=="connected" {active=1; next}
        /^[^[:space:]]/ {active=0}
        active && $1=="2560x1440" && $0~/\*/ {ok=1}
        END {exit(ok ? 0 : 1)}' || die "le mode 2560x1440 n'est pas actif"
    if xrandr --props | awk -v output="$output" '
        $1==output && $2=="connected" {active=1; next}
        /^[^[:space:]]/ {active=0}
        active && /vrr_capable:[[:space:]]+1/ {ok=1}
        END {exit(ok ? 0 : 1)}'; then
        log "$output: 2560x1440@${refresh}Hz, VRR disponible, DPI 120"
    else
        log "AVERTISSEMENT: $output est a 180 Hz mais VRR n'est pas annonce"
    fi
elif [[ ${XDG_SESSION_TYPE:-} == wayland ]] && command -v wlr-randr >/dev/null 2>&1; then
    state="$(wlr-randr)"
    output="$(printf '%s\n' "$state" | awk '
        /^DP-/ {print $1; exit}
        /^[^[:space:]]/ {current=$1}
        /^[[:space:]]+Enabled:[[:space:]]+yes/ {print current; exit}
    ')"
    [[ -n $output ]] || output="$(printf '%s\n' "$state" | awk '/^[^[:space:]]/ {print $1; exit}')"
    refresh="$(printf '%s\n' "$state" | awk -v output="$output" '
        /^[^[:space:]]/ {active=($1==output)}
        active && /2560x1440 px,/ {
            for (i=1; i<=NF; i++) if ($i=="Hz") {r=$(i-1)+0; if (r>=179 && r<=181) {print r; exit}}
        }')"
    [[ -n $output ]] || die "aucune sortie Wayland detectee"
    [[ -n $refresh ]] || die "mode DisplayPort 2560x1440 a 180 Hz absent sur $output"
    wlr-randr --output "$output" --mode "2560x1440@${refresh}Hz" --scale 1.25
    wlr-randr | awk -v output="$output" '
        /^[^[:space:]]/ {active=($1==output)}
        active && /2560x1440 px,/ && /current/ {ok=1}
        END {exit(ok ? 0 : 1)}' || die "le mode Wayland 2560x1440 n'est pas actif"
    log "$output: 2560x1440@${refresh}Hz, echelle 1.25; VRR demande dans Labwc"
else
    die "session graphique X11/Wayland non reconnue"
fi
EOF
chmod 0755 "$TARGET_HOME/.local/bin/apply-display-profile"

cat >"$TARGET_HOME/.config/autostart/apply-display-profile.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Display profile
Exec=$TARGET_HOME/.local/bin/apply-display-profile
OnlyShowIn=LXQt;
X-LXQt-Need-Tray=false
EOF

chown -R "$TARGET_USER:$TARGET_GROUP" \
    "$TARGET_HOME/.local/bin" "$TARGET_HOME/.config/autostart" \
    "$TARGET_HOME/.config/environment.d" "$TARGET_HOME/.Xresources.d"

# ---------- GameMode et finalisation ----------

write_root_file /etc/gamemode.ini <<'EOF'
[general]
softrealtime=auto
renice=10
ioprio=0
inhibit_screensaver=1
desiredgov=performance
EOF
getent group gamemode >/dev/null 2>&1 && usermod -aG gamemode "$TARGET_USER"

systemctl daemon-reload
update-initramfs -u -k all
update-grub

apt_get autoclean -y
systemctl start radio-block.service

if ((${#OPTIONAL_FAILURES[@]} > 0)); then
    printf 'Applications optionnelles non installees: %s\n' "${OPTIONAL_FAILURES[*]}" >&3
fi
if $secure_boot_enabled; then
    printf 'Au redemarrage, validez Enroll MOK pour autoriser le noyau Liquorix signe.\n' >&3
fi
printf 'Termine. Redemarrez le PC. Journal: %s | Sauvegarde: %s\n' \
    "$LOG_FILE" "$BACKUP_DIR" >&3
