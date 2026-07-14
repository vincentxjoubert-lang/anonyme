#!/usr/bin/env bash
#===============================================================================
#  lubuntu-vbox-optimize.sh  —  v3
#  Cible : Lubuntu 26.04 LTS Minimal (Resolute Raccoon) — invité VirtualBox
#  Usage : sudo ./lubuntu-vbox-optimize-v3.sh
#  Log   : /var/log/lubuntu-vbox-optimize.log
#===============================================================================
set -Eeuo pipefail

readonly LOG="/var/log/lubuntu-vbox-optimize.log"
readonly REAL_USER="${SUDO_USER:-$USER}"
readonly REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
readonly REAL_GROUP="$(id -gn "$REAL_USER")"          # FIX #5
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a

[[ $EUID -eq 0 ]] || { printf '\033[1;31m✗\033[0m À lancer avec sudo.\n'; exit 1; }
[[ -d "$REAL_HOME" ]] || { printf '✗ HOME de %s introuvable.\n' "$REAL_USER"; exit 1; }

readonly TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

exec 3>&1
: > "$LOG"
exec >>"$LOG" 2>&1
trap 'warn "Échec ligne $LINENO — voir $LOG"' ERR

step()  { printf '  \033[1;34m›\033[0m %s\n' "$*" >&3; }
ok()    { printf '  \033[1;32m✓\033[0m %s\n' "$*" >&3; }
warn()  { printf '  \033[1;33m!\033[0m %s\n' "$*" >&3; }
title() { printf '\n\033[1m%s\033[0m\n'      "$*" >&3; }

# FIX #1 : un paquet absent ne doit plus faire échouer tout le lot
pkg_install() {
  local p
  for p in "$@"; do
    apt-get install -y -qq --no-install-recommends "$p" \
      || warn "paquet indisponible : $p"
  done
}
pkg_purge()   { apt-get -y -qq purge "$@" 2>/dev/null || true; }   # motifs = REGEX
svc_disable() {
  local u
  for u in "$@"; do
    systemctl disable --now "$u" 2>/dev/null || true
    systemctl mask        "$u" 2>/dev/null || true
  done
}
write() { mkdir -p "$(dirname "$1")"; cat > "$1"; }

#===============================================================================
sys_update() {
  title "1/9 — Base système"
  step "Dépôts (universe) et mise à niveau"
  apt-get update -qq
  pkg_install software-properties-common curl wget ca-certificates gnupg jq
  add-apt-repository -y universe >/dev/null 2>&1 || true
  apt-get update -qq
  apt-get -y -qq full-upgrade
  ok "Système à jour"
}

#===============================================================================
kill_telemetry() {
  title "2/9 — Télémétrie"
  step "Purge des collecteurs"
  pkg_purge apport apport-symptoms whoopsie popularity-contest \
            ubuntu-report kerneloops packagekit
  svc_disable apport.service whoopsie.service kerneloops.service \
              popularity-contest.timer apt-news.service esm-cache.service \
              packagekit.service

  step "MOTD, pub, mises à jour automatiques"
  sed -i 's/^ENABLED=1/ENABLED=0/' /etc/default/motd-news 2>/dev/null || true
  chmod -x /etc/update-motd.d/* 2>/dev/null || true
  write /etc/apt/apt.conf.d/99-lean <<'EOF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
APT::Install-Recommends "false";
APT::Install-Suggests   "false";
Acquire::Languages      "none";
EOF
  ok "Télémétrie désactivée"
}

#===============================================================================
trim_services() {
  title "3/9 — Services résidents"
  step "Matériel et réseau superflus en VM"
  # NB : systemd-udev-settle NON masqué (dépendances LVM/mdadm, gain nul en VM)
  svc_disable \
    bluetooth.service cups.service cups-browsed.service cups.socket cups.path \
    avahi-daemon.service avahi-daemon.socket ModemManager.service \
    wpa_supplicant.service switcheroo-control.service thermald.service \
    fwupd.service fwupd-refresh.timer power-profiles-daemon.service \
    e2scrub_reap.service systemd-oomd.service systemd-oomd.socket \
    NetworkManager-wait-online.service systemd-networkd-wait-online.service \
    snapd.service snapd.socket snapd.seeded.service snapd.apparmor.service \
    apt-daily.timer apt-daily-upgrade.timer man-db.timer motd-news.timer

  step "Purge snapd + bluez (+ pin APT)"
  pkg_purge snapd bluez
  rm -rf /snap /var/snap /var/lib/snapd "$REAL_HOME/snap"
  write /etc/apt/preferences.d/no-snap <<'EOF'
Package: snapd
Pin: release a=*
Pin-Priority: -10
EOF

  step "Délais systemd réduits"
  write /etc/systemd/system.conf.d/99-timeouts.conf <<'EOF'
[Manager]
DefaultTimeoutStartSec=10s
DefaultTimeoutStopSec=5s
EOF
  ok "Services allégés"
}

#===============================================================================
kill_indexing() {
  title "4/9 — Indexation de fichiers"
  step "Purge tracker / baloo / zeitgeist / plocate"
  pkg_purge '^tracker' '^baloo' '^zeitgeist' plocate mlocate

  step "Blocage des agents en autostart"
  local ad="$REAL_HOME/.config/autostart" a
  mkdir -p "$ad"
  for a in tracker-miner-fs-3 tracker-extract-3 tracker-miner-rss \
           org.freedesktop.Tracker3.Miner.Files geoclue-demo-agent \
           blueman nm-applet print-applet; do
    printf '[Desktop Entry]\nType=Application\nName=%s\nHidden=true\nX-GNOME-Autostart-enabled=false\n' \
      "$a" > "$ad/${a}.desktop"
  done
  ok "Indexation neutralisée"
}

#===============================================================================
kill_compositing() {
  title "5/9 — Compositeur, effets, verrouillage"
  step "Purge compositeurs + verrouilleurs d'écran"
  pkg_purge picom compton xcompmgr light-locker xscreensaver

  step "Openbox / GTK : animations off"
  local ob="$REAL_HOME/.config/openbox" gt="$REAL_HOME/.config/gtk-3.0"
  [[ -f "$ob/lxqt-rc.xml" ]] && \
    sed -i 's#<animateIconify>yes</animateIconify>#<animateIconify>no</animateIconify>#' "$ob/lxqt-rc.xml"
  mkdir -p "$gt"
  grep -q gtk-enable-animations "$gt/settings.ini" 2>/dev/null || \
    printf '[Settings]\ngtk-enable-animations=0\n' >> "$gt/settings.ini"

  step "DPMS / veille écran désactivés"
  printf '[Desktop Entry]\nType=Application\nName=NoBlank\nExec=sh -c "xset s off -dpms"\n' \
    > "$REAL_HOME/.config/autostart/no-blank.desktop"

  chown -R "$REAL_USER:$REAL_GROUP" "$REAL_HOME/.config"   # FIX #5
  ok "Rendu sans compositeur"
}

#===============================================================================
tune_kernel() {
  title "6/9 — Noyau, mémoire, I/O"

  # FIX #4 : bbr doit être chargé, et sysctl ne doit pas tuer le script
  step "Module tcp_bbr"
  modprobe tcp_bbr 2>/dev/null || warn "tcp_bbr indisponible (BBR ignoré)"
  echo tcp_bbr > /etc/modules-load.d/bbr.conf

  # FIX #2 : swappiness ÉLEVÉ car le swap est en RAM compressée (zram)
  step "sysctl (zram-aware + latence réseau)"
  write /etc/sysctl.d/99-vm-guest.conf <<'EOF'
vm.swappiness = 100
vm.page-cluster = 0
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
kernel.nmi_watchdog = 0
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
EOF
  sysctl --system >/dev/null 2>&1 || warn "certains sysctl non appliqués"

  step "zram : swap compressé en RAM (zstd, 50%)"
  pkg_install zram-tools
  write /etc/default/zramswap <<'EOF'
ALGO=zstd
PERCENT=50
PRIORITY=100
EOF
  systemctl enable --now zramswap.service 2>/dev/null || true

  step "fstab : noatime sur la racine"
  if ! grep -qE '^\s*[^#].*[[:space:]]/[[:space:]].*noatime' /etc/fstab; then
    cp /etc/fstab "/etc/fstab.bak.$(date +%s)"
    awk 'BEGIN{OFS="\t"} !/^[[:space:]]*#/ && $2=="/" && $4 !~ /noatime/ {$4=$4",noatime"} {print}' \
      /etc/fstab > "$TMP/fstab"
    cat "$TMP/fstab" > /etc/fstab
  fi

  # FIX #3 : tmp.mount doit être copié depuis /usr/share, + plafond de taille
  step "/tmp en tmpfs (plafonné à 25% de la RAM)"
  if [[ -f /usr/share/systemd/tmp.mount ]]; then
    install -m644 /usr/share/systemd/tmp.mount /etc/systemd/system/tmp.mount
    write /etc/systemd/system/tmp.mount.d/99-size.conf <<'EOF'
[Mount]
Options=mode=1777,strictatime,nosuid,nodev,size=25%,nr_inodes=1m
EOF
    systemctl daemon-reload
    systemctl enable tmp.mount || warn "tmp.mount non activé"
  else
    warn "tmp.mount introuvable — /tmp reste sur disque"
  fi

  step "Ordonnanceur I/O : none"
  write /etc/udev/rules.d/60-io-scheduler.rules <<'EOF'
ACTION=="add|change", KERNEL=="sd[a-z]|vd[a-z]|nvme[0-9]n[0-9]", ATTR{queue/scheduler}="none"
EOF

  step "initramfs allégé (MODULES=dep, zstd)"
  sed -i 's/^MODULES=.*/MODULES=dep/'    /etc/initramfs-tools/initramfs.conf
  sed -i 's/^COMPRESS=.*/COMPRESS=zstd/' /etc/initramfs-tools/initramfs.conf
  update-initramfs -u -k all

  step "GRUB : boot direct"
  sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=0/' /etc/default/grub
  grep -q '^GRUB_TIMEOUT_STYLE' /etc/default/grub \
    && sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=hidden/' /etc/default/grub \
    || echo 'GRUB_TIMEOUT_STYLE=hidden' >> /etc/default/grub
  sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash mitigations=off nowatchdog"/' \
    /etc/default/grub
  update-grub

  # FIX #1 : installation individuelle (guest-x11 n'existe plus → ne doit pas
  # empêcher guest-utils, qui porte l'essentiel du gain en VM)
  step "Additions invité VirtualBox"
  pkg_install virtualbox-guest-utils virtualbox-guest-x11 virtualbox-guest-dkms
  getent group vboxsf >/dev/null && usermod -aG vboxsf "$REAL_USER" || true
  command -v VBoxClient >/dev/null || warn "VBoxClient absent : installez les Additions depuis le menu VirtualBox (Périphériques > Insérer l'image CD des Additions invité)"

  ok "Noyau et I/O optimisés"
}

#===============================================================================
install_actiona() {
  title "7/9 — Actiona"
  if command -v actiona >/dev/null; then ok "Déjà installé"; return; fi
  if apt-get install -y -qq actiona; then ok "Installé (apt)"; return; fi
  step "Repli : .deb officiel GitHub"
  local url
  url="$(curl -fsSL https://api.github.com/repos/Jmgr/actiona/releases/latest \
        | jq -r '.assets[].browser_download_url|select(endswith(".deb"))' | head -n1)" || true
  [[ -n "${url:-}" ]] || { warn "Actiona introuvable"; return; }
  curl -fsSL -o "$TMP/actiona.deb" "$url" && apt-get install -y -qq "$TMP/actiona.deb"
  ok "Installé (.deb)"
}

install_vesktop() {
  title "8/9 — Vesktop"
  if command -v vesktop >/dev/null; then ok "Déjà installé"; return; fi
  local arch url; arch="$(dpkg --print-architecture)"
  url="$(curl -fsSL https://api.github.com/repos/Vencord/Vesktop/releases/latest \
        | jq -r --arg a "$arch" '.assets[].browser_download_url
             |select(endswith(".deb"))|select(test($a))' | head -n1)" || true
  [[ -n "${url:-}" ]] || { warn "Aucun .deb Vesktop pour $arch"; return; }
  curl -fsSL -o "$TMP/vesktop.deb" "$url" && apt-get install -y -qq "$TMP/vesktop.deb"
  ok "Installé"
}

#===============================================================================
finalize() {
  title "9/9 — Nettoyage"
  step "Autoremove + caches + journal"
  apt-get -y -qq autoremove --purge
  apt-get -y -qq clean
  write /etc/systemd/journald.conf.d/99-small.conf <<'EOF'
[Journal]
SystemMaxUse=50M
RuntimeMaxUse=32M
EOF
  journalctl --vacuum-size=50M
  systemctl daemon-reload
  ok "Nettoyage terminé"
}

#===============================================================================
main() {
  printf '\n\033[1mOptimisation Lubuntu 26.04 — invité VirtualBox (v3)\033[0m\n' >&3
  printf 'Utilisateur : %s (%s) | Journal : %s\n' "$REAL_USER" "$REAL_GROUP" "$LOG" >&3
  sys_update; kill_telemetry; trim_services; kill_indexing
  kill_compositing; tune_kernel; install_actiona; install_vesktop; finalize
  cat >&3 <<'EOF'

Terminé. Redémarrez : sudo reboot

Vérifications après reboot :
  zramctl                 # swap compressé actif
  findmnt /tmp            # doit afficher tmpfs
  findmnt / -o OPTIONS    # doit contenir noatime
  systemd-analyze blame | head
  sysctl net.ipv4.tcp_congestion_control

À FAIRE CÔTÉ HÔTE VirtualBox (VM éteinte) :
  Système  > Accélération : Para-virtualisation = KVM, Pagination imbriquée = ON
  Système  > Processeur   : 2–4 vCPU max (jamais > moitié des cœurs physiques)
  Affichage> Écran        : VMSVGA, 128 Mo VRAM, accélération 3D = OFF
  Stockage > Contrôleur   : Cache E/S de l'hôte = ON, disque marqué SSD
  Audio / USB / Série     : désactivés si inutilisés
EOF
}
main "$@"
