#!/usr/bin/env bash
# Debian 13 trixie / XFCE / AMD gaming workstation
# Stable defaults: native 2560x1440, 180 Hz when EDID exposes it, Xft 120 DPI,
# GameMode on demand, security updates, Quad9 DoT, UFW, AppArmor, AMD firmware.
set -Eeuo pipefail
IFS=$'\n\t'

readonly LOG=/var/log/debian13-xfce-setup.log
readonly CODENAME=trixie
readonly TS=$(date +%Y%m%d-%H%M%S)
WARNINGS=0

[ "$(id -u)" -eq 0 ] || { echo 'Lance ce script avec sudo.' >&2; exit 1; }
install -Dm600 /dev/null "$LOG"
exec > >(tee -a "$LOG") 2>&1
trap 'echo "ERREUR ligne $LINENO. Consulte: $LOG" >&2' ERR

say() { printf '\n==> %s\n' "$*"; }
warn() { WARNINGS=$((WARNINGS + 1)); printf 'AVERTISSEMENT: %s\n' "$*" >&2; }
backup() { [ -e "$1" ] && cp -a "$1" "$1.bak-$TS"; }
apt_install() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    -o Dpkg::Use-Pty=0 \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold "$@"
}

. /etc/os-release
[ "${ID:-}" = debian ] && [ "${VERSION_ID:-}" = 13 ] && [ "$(dpkg --print-architecture)" = amd64 ] || {
  echo 'Ce script cible uniquement Debian 13 amd64.' >&2; exit 1;
}
TARGET_USER="${SUDO_USER:-}"
[ -n "$TARGET_USER" ] || TARGET_USER="$(awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}' /etc/passwd)"
[ -n "$TARGET_USER" ] || { echo 'Utilisateur graphique introuvable.' >&2; exit 1; }
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
TARGET_UID=$(id -u "$TARGET_USER")

say 'Dépôts Debian, i386 et mise à jour complète'
backup /etc/apt/sources.list.d/debian.sources
cat > /etc/apt/sources.list.d/debian.sources <<EOF
Types: deb
URIs: https://deb.debian.org/debian
Suites: $CODENAME $CODENAME-updates
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: https://security.debian.org/debian-security
Suites: $CODENAME-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
if ! grep -q '^deb ' /etc/apt/sources.list 2>/dev/null; then :; else backup /etc/apt/sources.list; sed -i 's/^deb /# deb /' /etc/apt/sources.list; fi
dpkg --print-foreign-architectures | grep -qx i386 || dpkg --add-architecture i386
apt-get update
apt-get -y full-upgrade
apt_install ca-certificates curl gnupg gpgv dirmngr \
  build-essential dkms linux-headers-amd64 pciutils usbutils sudo

say 'Mises à jour de sécurité automatiques'
apt_install unattended-upgrades
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
cat > /etc/apt/apt.conf.d/52unattended-upgrades-local <<'EOF'
Unattended-Upgrade::Origins-Pattern {
  "origin=Debian,codename=${distro_codename},label=Debian-Security";
  "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
};
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::MinimalSteps "true";
EOF
systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
unattended-upgrades --dry-run --debug >/dev/null || warn 'dry-run unattended-upgrades non concluant'

say 'Télémétrie Debian'
if dpkg-query -W -f='${db:Status-Status}' popularity-contest 2>/dev/null | grep -qx installed; then
  apt-get purge -y popularity-contest
fi
cat > /etc/apt/preferences.d/99-no-popularity-contest <<'EOF'
Package: popularity-contest
Pin: version *
Pin-Priority: -1
EOF

say 'Flatpak et portails'
apt_install flatpak xdg-desktop-portal xdg-desktop-portal-gtk
flatpak remote-add --if-not-exists --system flathub https://dl.flathub.org/repo/flathub.flatpakrepo

say 'Pare-feu et AppArmor'
apt_install ufw apparmor apparmor-utils apparmor-profiles
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw logging low
ufw --force enable
systemctl enable --now apparmor.service

say 'Quad9 DNS-over-TLS'
apt_install systemd-resolved
install -d /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/99-quad9-dot.conf <<'EOF'
[Resolve]
DNS=9.9.9.9#dns.quad9.net 149.112.112.112#dns.quad9.net 2620:fe::fe#dns.quad9.net 2620:fe::9#dns.quad9.net
FallbackDNS=
Domains=~.
DNSOverTLS=yes
DNSSEC=no
DNSStubListener=yes
EOF
install -d /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/99-dns-systemd-resolved.conf <<'EOF'
[main]
dns=systemd-resolved
EOF
backup /etc/resolv.conf
ln -sfn /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
systemctl enable --now systemd-resolved.service
if systemctl is-enabled NetworkManager.service >/dev/null 2>&1; then
  systemctl restart NetworkManager.service
  # Replace DHCP DNS only on Ethernet and Wi-Fi connections. VPN DNS is preserved.
  while IFS=: read -r uuid type; do
    case "$type" in
      ethernet|wifi)
        nmcli connection modify uuid "$uuid" ipv4.ignore-auto-dns yes ipv6.ignore-auto-dns yes || warn "DNS non modifié: $uuid" ;;
    esac
  done < <(nmcli -t -f UUID,TYPE connection show 2>/dev/null || true)
  nmcli connection reload || true
fi
systemctl restart systemd-resolved.service
resolvectl query deb.debian.org >/dev/null || warn 'résolution Quad9 non vérifiée'

say 'Durcissement et paramètres système'
cat > /etc/sysctl.d/99-workstation-hardening.conf <<'EOF'
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.perf_event_paranoid = 3
kernel.kexec_load_disabled = 1
kernel.yama.ptrace_scope = 1
kernel.unprivileged_bpf_disabled = 1
kernel.randomize_va_space = 2
kernel.sysrq = 244
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
fs.suid_dumpable = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_rmem = 4096 262144 16777216
net.ipv4.tcp_wmem = 4096 262144 16777216
vm.swappiness = 10
vm.vfs_cache_pressure = 50
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10
vm.max_map_count = 1048576
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024
EOF
printf 'tcp_bbr\n' > /etc/modules-load.d/tcp-bbr.conf
modprobe tcp_bbr || true
sysctl --system >/dev/null
install -d /etc/systemd/coredump.conf.d
cat > /etc/systemd/coredump.conf.d/99-disable.conf <<'EOF'
[Coredump]
Storage=none
ProcessSizeMax=0
EOF
install -d /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/99-workstation.conf <<'EOF'
[Manager]
DefaultTimeoutStopSec=15s
DefaultLimitNOFILE=1024:1048576
EOF
systemctl daemon-reexec
install -d /etc/systemd/journald.conf.d
printf '[Journal]\nSystemMaxUse=500M\nSystemMaxFileSize=50M\nCompress=yes\n' > /etc/systemd/journald.conf.d/99-size.conf
systemctl restart systemd-journald.service
systemctl enable --now fstrim.timer

say 'Microcode, firmwares AMD et graphiques'
apt_install amd64-microcode firmware-amd-graphics firmware-realtek firmware-misc-nonfree \
  firmware-linux-free xserver-xorg-video-amdgpu mesa-vulkan-drivers mesa-va-drivers \
  libgl1-mesa-dri libglx-mesa0 libvulkan1 vulkan-tools mesa-utils vainfo radeontop
apt_install mesa-vulkan-drivers:i386 libgl1-mesa-dri:i386 libglx-mesa0:i386 \
  libvulkan1:i386 libc6:i386 || warn 'certaines bibliothèques graphiques i386 manquent'
# MT7922/RZ616 firmware: available in backports, not assumed in stable.
if apt-cache show firmware-mediatek >/dev/null 2>&1; then apt_install firmware-mediatek || warn 'firmware-mediatek non installé'; fi
update-initramfs -u -k all

say 'GameMode à la demande pour Steam'
apt_install gamemode libgamemodeauto0
install -d /etc
cat > /etc/gamemode.ini <<'EOF'
[general]
inhibit_screensaver=1
EOF
runuser -u "$TARGET_USER" -- env XDG_RUNTIME_DIR="/run/user/$TARGET_UID" gamemoded -t || warn 'test GameMode non concluant'
# No global governor override: Steam games opt in with gamemoderun %command%.
install -d -o "$TARGET_USER" -g "$TARGET_USER" "$TARGET_HOME/bin"
cat > "$TARGET_HOME/bin/steam-gamemode" <<'EOF'
#!/bin/sh
exec gamemoderun "$@"
EOF
chmod 0755 "$TARGET_HOME/bin/steam-gamemode"
chown "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/bin/steam-gamemode"

say 'Applications natives'
apt_install vlc qbittorrent filezilla steam-installer steam-devices
apt_install libxkbcommon-tools x11-xserver-utils xkb-data

say 'Clés et dépôts tiers officiels'
install -d -m0755 /usr/share/keyrings /etc/apt/sources.list.d
fetch_key() {
  local url=$1 out=$2 tmp
  tmp=$(mktemp)
  curl -fsSL --retry 3 "$url" -o "$tmp"
  gpg --batch --yes --dearmor -o "$out" "$tmp"
  rm -f "$tmp"
  chmod 0644 "$out"
  [ -s "$out" ]
}
# Brave official source file plus ASCII key converted for APT 3/sqv.
if fetch_key https://brave-browser-apt-release.s3.brave.com/brave-core.asc /usr/share/keyrings/brave-browser-archive-keyring.gpg \
 && curl -fsSL --retry 3 -o /etc/apt/sources.list.d/brave-browser-release.sources https://brave-browser-apt-release.s3.brave.com/brave-browser.sources; then :; else warn 'Brave repo non ajouté'; rm -f /etc/apt/sources.list.d/brave-browser-release.sources; fi
if fetch_key https://repo.vscodium.dev/vscodium.gpg /usr/share/keyrings/vscodium.gpg \
 && curl -fsSL --retry 3 -o /etc/apt/sources.list.d/vscodium.sources https://repo.vscodium.dev/vscodium.sources; then :; else warn 'VSCodium repo non ajouté'; rm -f /etc/apt/sources.list.d/vscodium.sources; fi
if fetch_key https://www.virtualbox.org/download/oracle_vbox_2016.asc /usr/share/keyrings/oracle-virtualbox-2016.gpg; then
cat > /etc/apt/sources.list.d/virtualbox.sources <<EOF
Types: deb
URIs: https://download.virtualbox.org/virtualbox/debian
Suites: $CODENAME
Components: contrib
Architectures: amd64
Signed-By: /usr/share/keyrings/oracle-virtualbox-2016.gpg
EOF
else warn 'VirtualBox repo non ajouté'; fi
if ! apt-get update; then
  warn 'Un dépôt tiers est invalide; retrait des dépôts tiers pour préserver APT Debian'
  rm -f /etc/apt/sources.list.d/brave-browser-release.sources \
        /etc/apt/sources.list.d/vscodium.sources \
        /etc/apt/sources.list.d/virtualbox.sources
  apt-get update
fi

say 'Applications tierces'
apt_install brave-browser || flatpak install -y --system flathub com.brave.Browser || warn 'Brave non installé'
apt_install codium || flatpak install -y --system flathub com.vscodium.codium || warn 'VSCodium non installé'
apt_install virtualbox-7.2 || warn 'VirtualBox non installé'
getent group vboxusers >/dev/null && usermod -aG vboxusers "$TARGET_USER" || true
flatpak install -y --system flathub com.discordapp.Discord || warn 'Discord non installé'
flatpak update -y || true

say 'Clavier français et XKB'
cat > /usr/share/X11/xkb/symbols/frwin <<'EOF'
default partial alphanumeric_keys
xkb_symbols "basic" {
    include "fr"
    name[Group1] = "French AZERTY Windows-like Caps Lock";
    override key <AE01> { type[Group1] = "FOUR_LEVEL_ALPHABETIC" };
    override key <AE02> { type[Group1] = "FOUR_LEVEL_ALPHABETIC" };
    override key <AE03> { type[Group1] = "FOUR_LEVEL_ALPHABETIC" };
    override key <AE04> { type[Group1] = "FOUR_LEVEL_ALPHABETIC" };
    override key <AE05> { type[Group1] = "FOUR_LEVEL_ALPHABETIC" };
    override key <AE06> { type[Group1] = "FOUR_LEVEL_ALPHABETIC" };
    override key <AE07> { type[Group1] = "FOUR_LEVEL_ALPHABETIC" };
    override key <AE08> { type[Group1] = "FOUR_LEVEL_ALPHABETIC" };
    override key <AE09> { type[Group1] = "FOUR_LEVEL_ALPHABETIC" };
    override key <AE10> { type[Group1] = "FOUR_LEVEL_ALPHABETIC" };
    override key <AE11> { type[Group1] = "FOUR_LEVEL_ALPHABETIC" };
    override key <AE12> { type[Group1] = "FOUR_LEVEL_ALPHABETIC" };
};
EOF
if xkbcli compile-keymap --model pc105 --layout frwin >/dev/null 2>&1; then KBD=frwin; else KBD=fr; warn 'variant clavier rejeté, repli fr'; fi
install -d /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/00-keyboard.conf <<EOF
Section "InputClass"
 Identifier "system-keyboard"
 MatchIsKeyboard "on"
 Option "XkbModel" "pc105"
 Option "XkbLayout" "$KBD"
 Option "XkbOptions" ""
EndSection
EOF
cat > /etc/default/keyboard <<'EOF'
XKBMODEL="pc105"
XKBLAYOUT="fr"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF

say 'Écran: 2560x1440 natif, 180 Hz, persistant XFCE'
# Native resolution is intentionally used: 1080p on this 1440p panel is interpolated.
install -d -o "$TARGET_USER" -g "$TARGET_USER" "$TARGET_HOME/.local/bin" "$TARGET_HOME/.config/autostart"
cat > "$TARGET_HOME/.local/bin/set-msi-275qf-display" <<'EOF'
#!/usr/bin/env bash
set -u
export DISPLAY="${DISPLAY:-:0}"
[ -n "${XAUTHORITY:-}" ] || export XAUTHORITY="$HOME/.Xauthority"
command -v xrandr >/dev/null 2>&1 || exit 0
for output in $(xrandr --query | awk '$2=="connected" {print $1}'); do
  if xrandr --query | awk -v o="$output" '
    $0 ~ "^"o" connected" {found=1; next}
    found && $1 == "2560x1440" && $0 ~ /180([.]00)?[*+ ]/ {ok=1}
    found && ok {exit 0}
    found && /^[[:space:]]*[0-9]+x[0-9]+/ && $1 != "2560x1440" {exit 1}
  '; then
    xrandr --output "$output" --mode 2560x1440 --rate 180 && exit 0
  fi
done
exit 0
EOF
chmod 0755 "$TARGET_HOME/.local/bin/set-msi-275qf-display"
cat > "$TARGET_HOME/.local/bin/xfce-display-init" <<'EOF'
#!/bin/sh
sleep 2
"$HOME/.local/bin/set-msi-275qf-display" || true
if command -v xrdb >/dev/null 2>&1; then xrdb -merge "$HOME/.Xresources" || true; fi
if command -v xfconf-query >/dev/null 2>&1; then xfconf-query -c xsettings -p /Xft/DPI -n -t int -s 120 2>/dev/null || xfconf-query -c xsettings -p /Xft/DPI -s 120 2>/dev/null || true; fi
EOF
chmod 0755 "$TARGET_HOME/.local/bin/xfce-display-init"
cat > "$TARGET_HOME/.config/autostart/msi-275qf-display.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=MSI MAG 275QF 180 Hz and 125% DPI
Exec=$TARGET_HOME/.local/bin/xfce-display-init
OnlyShowIn=XFCE;
X-GNOME-Autostart-enabled=true
EOF
cat > "$TARGET_HOME/.Xresources" <<'EOF'
! 125% equivalent for Xft-aware applications: 96 * 1.25 = 120.
Xft.dpi: 120
EOF
chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.local" "$TARGET_HOME/.config/autostart" "$TARGET_HOME/.Xresources"

say 'Contrôles finaux'
apt-get autoremove --purge -y
apt-get clean
printf '\nRésultat: %s avertissement(s)\n' "$WARNINGS"
printf 'Journal: %s\n' "$LOG"
printf '%s\n' 'Après reconnexion XFCE: ajouter gamemoderun %command% dans les options de lancement Steam des jeux qui en bénéficient.'
printf '%s\n' 'La session doit être X11 pour xrandr; en Wayland, choisir le mode dans le gestionnaire d affichage du compositeur.'
