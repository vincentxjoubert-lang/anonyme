#!/usr/bin/env bash
# Lubuntu 26.04 LTS (Resolute) - post-installation silencieuse et idempotente.
# Le journal complet est conserve dans /var/log/lubuntu-26.04-postinstall.log.

set -Eeuo pipefail
umask 022

readonly LOG_FILE="/var/log/lubuntu-26.04-postinstall.log"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
readonly RUN_ID
readonly BACKUP_DIR="/var/backups/lubuntu-26.04-postinstall/${RUN_ID}"

exec 3>&1
touch "$LOG_FILE"
chmod 0600 "$LOG_FILE"
exec >>"$LOG_FILE" 2>&1

fail() {
    printf 'ERREUR: %s (journal: %s)\n' "$1" "$LOG_FILE" >&3
    exit 1
}

on_error() {
    local rc=$?
    printf 'ERREUR ligne %s, code %s (journal: %s)\n' "${BASH_LINENO[0]:-?}" "$rc" "$LOG_FILE" >&3
    exit "$rc"
}
trap on_error ERR

[[ $EUID -eq 0 ]] || fail "executez ce script avec sudo"

# shellcheck disable=SC1091
source /etc/os-release
[[ ${ID:-} == ubuntu && ${VERSION_ID:-} == 26.04 ]] || fail "Lubuntu/Ubuntu 26.04 est requis"
[[ $(dpkg --print-architecture) == amd64 ]] || fail "ce profil Liquorix/Steam/Discord requiert amd64"

TARGET_USER="${SUDO_USER:-}"
if [[ -z $TARGET_USER || $TARGET_USER == root ]]; then
    TARGET_USER="$(getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 {print $1; exit}')"
fi
[[ -n $TARGET_USER ]] || fail "aucun utilisateur de bureau detecte"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
TARGET_GROUP="$(id -gn "$TARGET_USER")"
[[ -n $TARGET_HOME && -d $TARGET_HOME && $TARGET_HOME != / ]] || fail "repertoire utilisateur invalide"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export APT_LISTCHANGES_FRONTEND=none

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
    local path=$1 mode=${2:-0644}
    backup_file "$path"
    mkdir -p "$(dirname "$path")"
    cat >"$path"
    chmod "$mode" "$path"
}

run_user() {
    runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" USER="$TARGET_USER" LOGNAME="$TARGET_USER" "$@"
}

install_available() {
    local available=() pkg
    for pkg in "$@"; do
        if apt-cache show "$pkg" >/dev/null 2>&1; then
            available+=("$pkg")
        else
            printf 'Paquet indisponible ignore: %s\n' "$pkg"
        fi
    done
    ((${#available[@]} == 0)) || apt-get install -y --no-install-recommends "${available[@]}"
}

install_optional() {
    local pkg=$1
    if apt-cache show "$pkg" >/dev/null 2>&1; then
        apt-get install -y "$pkg" || printf 'Installation optionnelle echouee: %s\n' "$pkg"
    else
        printf 'Application indisponible: %s\n' "$pkg"
    fi
}

disable_and_mask() {
    local unit
    for unit in "$@"; do
        if systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q .; then
            systemctl disable --now "$unit" || true
            systemctl mask "$unit" || true
        fi
    done
}

ini_set() {
    local file=$1 section=$2 key=$3 value=$4 tmp
    mkdir -p "$(dirname "$file")"
    touch "$file"
    tmp="$(mktemp)"
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
    install -o "$TARGET_USER" -g "$TARGET_GROUP" -m 0644 "$tmp" "$file"
    rm -f "$tmp"
}

# ---------- Pre-vol et mise a jour de la base ----------

secure_boot_enabled=false
if command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -qi enabled; then
    secure_boot_enabled=true
elif compgen -G '/sys/firmware/efi/efivars/SecureBoot-*' >/dev/null; then
    secure_boot_var="$(compgen -G '/sys/firmware/efi/efivars/SecureBoot-*' | head -n1)"
    [[ $(od -An -t u1 -j4 -N1 "$secure_boot_var" 2>/dev/null | tr -d ' ') == 1 ]] && secure_boot_enabled=true
fi
if $secure_boot_enabled; then
    fail "Secure Boot est actif; desactivez-le dans l'UEFI avant d'imposer Liquorix"
fi

dpkg --configure -a
apt-get update -qq
apt-get full-upgrade -y
apt-get install -y ca-certificates curl gpg software-properties-common

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
apt-get update -qq

# ---------- Paquets de base, pilotes, fichiers et affichage ----------

install_available \
    git rsync unzip xdg-utils xdg-user-dirs dbus-user-session \
    linux-firmware firmware-sof-signed ubuntu-drivers-common fwupd mokutil \
    mesa-vulkan-drivers mesa-libgallium mesa-utils libgl1-mesa-dri \
    mesa-vulkan-drivers:i386 libgl1-mesa-dri:i386 vulkan-tools vainfo \
    thunar thunar-archive-plugin thunar-media-tags-plugin thunar-volman \
    tumbler ffmpegthumbnailer gvfs gvfs-backends xarchiver \
    xdg-desktop-portal xdg-desktop-portal-lxqt xdg-desktop-portal-gtk \
    xdg-desktop-portal-wlr qtwayland5 qt6-wayland xwayland wlr-randr labwc \
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
    qt5-style-kvantum qt6-style-kvantum

case "$(awk -F: '/vendor_id/{gsub(/[[:space:]]/,"",$2); print $2; exit}' /proc/cpuinfo)" in
    GenuineIntel)
        install_available intel-microcode thermald intel-media-va-driver-non-free
        systemctl enable --now thermald.service || true
        ;;
    AuthenticAMD)
        install_available amd64-microcode
        ;;
esac

ubuntu-drivers install || printf 'ubuntu-drivers: aucun pilote additionnel installe ou echec non bloquant\n'

if lspci -nn 2>/dev/null | grep -qi 'NVIDIA'; then
    nvidia_branch="$(dpkg-query -W -f='${binary:Package}\n' 'nvidia-driver-*' 2>/dev/null \
        | sed -n 's/^nvidia-driver-\([0-9][0-9]*\).*$/\1/p' | sort -Vu | tail -n1)"
    [[ -z $nvidia_branch ]] || install_available "libnvidia-gl-${nvidia_branch}:i386"
fi

apt-get install -y linux-image-liquorix-amd64 linux-headers-liquorix-amd64
dpkg-query -W -f='${Status}\n' linux-image-liquorix-amd64 | grep -q 'install ok installed'

write_root_file /etc/default/grub.d/60-liquorix-default.cfg <<'EOF'
GRUB_DEFAULT=0
GRUB_SAVEDEFAULT=false
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
apt-get purge -y snapd || true
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
if curl -fLso "$discord_deb" 'https://discord.com/api/download?platform=linux&format=deb'; then
    apt-get install -y "$discord_deb" || printf 'Installation optionnelle echouee: Discord\n'
else
    printf 'Telechargement optionnel echoue: Discord\n'
fi
rm -f "$discord_deb"

# ---------- Audio PipeWire ----------

systemctl --global disable pulseaudio.service pulseaudio.socket || true
systemctl --global mask pulseaudio.service pulseaudio.socket || true
systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service || true

# ---------- Quad9 DoT par connexion physique, compatible VPN ----------

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

ln -sfn /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
systemctl enable --now systemd-resolved.service

while IFS=: read -r connection_name connection_type; do
    [[ $connection_type == 802-3-ethernet || $connection_type == 802-11-wireless ]] || continue
    nmcli connection modify "$connection_name" \
        ipv4.ignore-auto-dns yes \
        ipv4.dns '9.9.9.9 149.112.112.112' \
        ipv6.ignore-auto-dns yes \
        ipv6.dns '2620:fe::fe 2620:fe::9' \
        connection.dns-over-tls yes \
        connection.llmnr no \
        connection.mdns no || true
done < <(nmcli --terse --escape no --fields NAME,TYPE connection show)
systemctl reload NetworkManager.service || true

# ---------- Sysctl: faible latence, 2.5 Gb/s, RAM 32 Gio, hardening ----------

write_root_file /etc/modules-load.d/tcp-bbr.conf <<'EOF'
tcp_bbr
EOF

write_root_file /etc/sysctl.d/90-desktop-lowlatency-hardening.conf <<'EOF'
# Memoire: eviter les longues rafales d'ecriture et le swap precoce.
vm.swappiness = 10
vm.vfs_cache_pressure = 50
vm.dirty_background_bytes = 67108864
vm.dirty_bytes = 536870912
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

# Reseau: files courtes, buffers auto jusqu'a 16 Mio, VPN/multihoming permis.
net.core.default_qdisc = fq
net.core.netdev_max_backlog = 4096
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 16384 16777216
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

modprobe tcp_bbr || true
sysctl --system
systemctl enable fstrim.timer

# ---------- Pare-feu, AppArmor et mises a jour automatiques ----------

ufw default deny incoming
ufw default allow outgoing
ufw default deny routed
ufw logging low
ufw --force enable

systemctl enable --now apparmor.service
apparmor_parser -r /etc/apparmor.d/* 2>/dev/null || true

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
EOF
systemctl enable --now apt-daily.timer apt-daily-upgrade.timer

# ---------- Clavier FR legacy, verrouillage majuscules = Shift Lock ----------

write_root_file /etc/default/keyboard <<'EOF'
XKBMODEL="pc105"
XKBLAYOUT="fr"
XKBVARIANT="legacy"
XKBOPTIONS="caps:shiftlock"
BACKSPACE="guess"
EOF
localectl set-x11-keymap fr pc105 legacy caps:shiftlock || true

# ---------- Services non utilises et vie privee ----------

disable_and_mask \
    bluetooth.service cups.service cups.socket cups.path cups-browsed.service \
    whoopsie.service kerneloops.service apport-autoreport.timer motd-news.timer

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
systemctl enable --now radio-block.service

if [[ -f /etc/default/apport ]]; then
    backup_file /etc/default/apport
    sed -i 's/^enabled=.*/enabled=0/' /etc/default/apport
fi
if [[ -f /etc/popularity-contest.conf ]]; then
    backup_file /etc/popularity-contest.conf
    sed -i 's/^PARTICIPATE=.*/PARTICIPATE="no"/' /etc/popularity-contest.conf
fi
run_user ubuntu-report -f send no || true

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
chown "$TARGET_USER:$TARGET_GROUP" "$theme_tmp"
theme_checkout WhiteSur-gtk-theme "$THEME_GTK_SHA" "$theme_tmp/gtk"
theme_checkout WhiteSur-icon-theme "$THEME_ICON_SHA" "$theme_tmp/icons"
theme_checkout WhiteSur-cursors "$THEME_CURSOR_SHA" "$theme_tmp/cursors"
theme_checkout WhiteSur-kde "$THEME_KDE_SHA" "$theme_tmp/kde"

run_user bash -c "cd '$theme_tmp/gtk' && ./install.sh -d '$TARGET_HOME/.local/share/themes' -o solid -c dark -a normal -t default -s standard --silent-mode"
run_user bash -c "cd '$theme_tmp/icons' && ./install.sh -d '$TARGET_HOME/.local/share/icons' -t default"
run_user bash -c "cd '$theme_tmp/cursors' && ./install.sh"
run_user bash -c "cd '$theme_tmp/kde' && ./install.sh --opaque"
rm -rf -- "$theme_tmp"

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
if [[ -f $labwc_rc ]]; then
    backup_file "$labwc_rc"
    sed -i '/<theme>/,/<\/theme>/ s#<name>.*</name>#<name>WhiteSur-Openbox</name>#' "$labwc_rc"
    chown "$TARGET_USER:$TARGET_GROUP" "$labwc_rc"
fi

mkdir -p "$TARGET_HOME/.config/Kvantum"
write_root_file "$TARGET_HOME/.config/Kvantum/kvantum.kvconfig" <<'EOF'
[General]
theme=WhiteSur-opaqueDark
EOF
chown -R "$TARGET_USER:$TARGET_GROUP" "$TARGET_HOME/.config/Kvantum"

backup_file "$TARGET_HOME/.config/lxqt/lxqt.conf"
ini_set "$TARGET_HOME/.config/lxqt/lxqt.conf" General style kvantum
ini_set "$TARGET_HOME/.config/lxqt/lxqt.conf" General icon_theme WhiteSur-dark
ini_set "$TARGET_HOME/.config/lxqt/lxqt.conf" General icon_follow_color_scheme true
ini_set "$TARGET_HOME/.config/lxqt/lxqt.conf" General font 'Inter,10,-1,5,50,0,0,0,0,0'

backup_file "$TARGET_HOME/.config/lxqt/session.conf"
ini_set "$TARGET_HOME/.config/lxqt/session.conf" Mouse cursor_theme WhiteSur-cursors
ini_set "$TARGET_HOME/.config/lxqt/session.conf" Mouse cursor_size 24

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
fc-cache -f "$TARGET_HOME/.local/share/fonts" "$TARGET_HOME/.local/share/icons" || true

# ---------- Ecran 2560x1440, 180 Hz et echelle nette ----------

install -d -o "$TARGET_USER" -g "$TARGET_GROUP" \
    "$TARGET_HOME/.local/bin" "$TARGET_HOME/.config/autostart" \
    "$TARGET_HOME/.config/environment.d" "$TARGET_HOME/.Xresources.d"

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
set -u

if [[ ${XDG_SESSION_TYPE:-} == x11 ]] && command -v xrandr >/dev/null 2>&1; then
    command -v xrdb >/dev/null 2>&1 && xrdb -merge "$HOME/.Xresources.d/90-display" >/dev/null 2>&1
    output="$(xrandr --query | awk '
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
    [[ -n $output && -n $refresh ]] && xrandr --output "$output" --mode 2560x1440 --rate "$refresh" >/dev/null 2>&1
elif [[ ${XDG_SESSION_TYPE:-} == wayland ]] && command -v wlr-randr >/dev/null 2>&1; then
    state="$(wlr-randr 2>/dev/null)"
    output="$(printf '%s\n' "$state" | awk '
        /^[^[:space:]]/ {current=$1}
        /^[[:space:]]+Enabled:[[:space:]]+yes/ {print current; exit}
    ')"
    [[ -n $output ]] || output="$(printf '%s\n' "$state" | awk '/^[^[:space:]]/ {print $1; exit}')"
    refresh="$(printf '%s\n' "$state" | awk -v output="$output" '
        /^[^[:space:]]/ {active=($1==output)}
        active && /2560x1440 px,/ {
            for (i=1; i<=NF; i++) if ($i=="Hz") {r=$(i-1)+0; if (r>=179 && r<=181) {print r; exit}}
        }')"
    [[ -n $output && -n $refresh ]] && wlr-randr --output "$output" --mode "2560x1440@${refresh}Hz" --scale 1.25 >/dev/null 2>&1
fi
exit 0
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

# ---------- GameMode et validations finales ----------

write_root_file /etc/gamemode.ini <<'EOF'
[general]
softrealtime=auto
renice=10
ioprio=0
inhibit_screensaver=1
EOF
getent group gamemode >/dev/null 2>&1 && usermod -aG gamemode "$TARGET_USER"

systemctl daemon-reload
update-initramfs -u -k all
update-grub

default_kernel="$(awk '
    /^menuentry / {seen=1}
    seen && /^[[:space:]]*linux[[:space:]]/ {print $2; exit}
' /boot/grub/grub.cfg)"
[[ $default_kernel == *liquorix* ]] || fail "GRUB n'a pas place Liquorix en premier; noyau Ubuntu conserve comme secours"

aa-status || true
ufw status verbose
resolvectl status || true
dkms status || true
find /boot -maxdepth 1 -type f -name 'vmlinuz-*-liquorix-amd64' -print | sort -V

apt-get autoclean -y

printf 'Termine. Redemarrez le PC. Journal: %s | Sauvegarde: %s\n' "$LOG_FILE" "$BACKUP_DIR" >&3
