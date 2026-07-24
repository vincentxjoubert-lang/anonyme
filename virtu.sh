#!/usr/bin/env bash
#
# Post-installation Lubuntu 26.04 minimal (invité VirtualBox)
# - Désactive la télémétrie
# - Optimise la pile réseau
# - Installe : Guest Additions, Brave, Discord (deb officiel), VLC, Actiona
#
# Usage : sudo ./setup-lubuntu-vbox.sh
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo "À lancer avec sudo." >&2; exit 1; }
REAL_USER="${SUDO_USER:-root}"

export DEBIAN_FRONTEND=noninteractive
APT="apt-get -qq -y -o Dpkg::Use-Pty=0"
LOG=/var/log/setup-lubuntu-vbox.log
exec 3>&1
exec >>"$LOG" 2>&1
step() { echo "[*] $*" >&3; }
trap 'echo "[!] Échec ligne $LINENO — voir $LOG" >&3' ERR

# ---------------------------------------------------------------- Base
step "Mise à jour du système"
$APT update
$APT upgrade
$APT install curl wget gnupg ca-certificates apt-transport-https software-properties-common

# ---------------------------------------------------- VirtualBox Guest Additions
step "Guest Additions VirtualBox"
$APT install virtualbox-guest-x11 virtualbox-guest-utils || true
adduser "$REAL_USER" vboxsf >/dev/null 2>&1 || true

# ---------------------------------------------------------------- Télémétrie
step "Désactivation de la télémétrie"
$APT purge popularity-contest ubuntu-report apport apport-symptoms whoopsie 2>/dev/null || true
systemctl disable --now apport.service whoopsie.service 2>/dev/null || true
systemctl mask apport.service whoopsie.service 2>/dev/null || true
printf 'enabled=0\n' > /etc/default/apport
[[ -f /etc/apport/crashdb.conf ]] && sed -i 's/^problem_types.*/problem_types = ['"'"'Bug'"'"', '"'"'Package'"'"']/' /etc/apport/crashdb.conf

# Motd publicitaire / Ubuntu Pro advertising
chmod -x /etc/update-motd.d/* 2>/dev/null || true
sed -i 's/^ENABLED=1/ENABLED=0/' /etc/default/motd-news 2>/dev/null || true
systemctl disable --now motd-news.timer 2>/dev/null || true

# Rapports d'erreurs / analytics divers
rm -f /var/crash/* 2>/dev/null || true
mkdir -p /etc/xdg/autostart
for f in apport-gtk.desktop update-notifier.desktop; do
  [[ -f /etc/xdg/autostart/$f ]] && echo "Hidden=true" >> "/etc/xdg/autostart/$f"
done

# ---------------------------------------------------------------- Réseau
step "Optimisation réseau"
cat > /etc/sysctl.d/99-network-tuning.conf <<'EOF'
# Contrôle de congestion moderne + qdisc
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Buffers
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_max_syn_backlog = 8192

# Latence / réutilisation
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15

# Mémoire (VM)
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF
modprobe tcp_bbr 2>/dev/null || true
grep -qx tcp_bbr /etc/modules-load.d/bbr.conf 2>/dev/null || echo tcp_bbr > /etc/modules-load.d/bbr.conf
sysctl --system

# Cache DNS local (résolution plus rapide)
if systemctl is-active --quiet systemd-resolved; then
  mkdir -p /etc/systemd/resolved.conf.d
  cat > /etc/systemd/resolved.conf.d/99-cache.conf <<'EOF'
[Resolve]
Cache=yes
DNSStubListener=yes
DNSOverTLS=opportunistic
EOF
  systemctl restart systemd-resolved
fi

# ---------------------------------------------------------------- Brave
step "Installation de Brave"
install -d -m 0755 /usr/share/keyrings
curl -fsSL https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg \
  -o /usr/share/keyrings/brave-browser-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/brave-browser-archive-keyring.gpg] https://brave-browser-apt-release.s3.brave.com/ stable main" \
  > /etc/apt/sources.list.d/brave-browser-release.list
$APT update
$APT install brave-browser

# ---------------------------------------------------------------- VLC + Actiona
step "Installation de VLC et Actiona"
$APT install vlc actiona

# ---------------------------------------------------------------- Discord
step "Installation de Discord (paquet officiel)"
TMPDEB=$(mktemp --suffix=.deb)
curl -fsSL -o "$TMPDEB" "https://discord.com/api/download?platform=linux&format=deb"
$APT install "$TMPDEB"
rm -f "$TMPDEB"

# ---------------------------------------------------------------- Nettoyage
step "Nettoyage"
$APT autoremove --purge
$APT clean

step "Terminé — redémarrage recommandé (log : $LOG)"
