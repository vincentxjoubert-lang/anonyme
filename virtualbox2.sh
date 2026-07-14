#!/usr/bin/env bash
#===============================================================================
#  lubuntu-vbox-optimize.sh  —  v4
#  Cible : Lubuntu 26.04 LTS Minimal (Resolute Raccoon) — invité VirtualBox
#  Usage : sudo ./lubuntu-vbox-optimize-v4.sh
#  Log   : /var/log/lubuntu-vbox-optimize.log
#
#  v4 : - sections ISOLÉES (l'échec d'une étape n'annule plus les suivantes)
#       - installations AVANT les réglages noyau (plus jamais préemptées)
#       - Actiona : AppImage (le projet ne publie AUCUN .deb en amont)
#       - Vesktop : URL stable vencord.dev (l'API GitHub renvoie des 403)
#       - correctif AppArmor userns, sans quoi Electron/Vesktop crashe au lancement
#===============================================================================
set -uo pipefail          # PAS de -e : on gère les erreurs section par section

readonly LOG="/var/log/lubuntu-vbox-optimize.log"
readonly REAL_USER="${SUDO_USER:-$USER}"
readonly REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
readonly REAL_GROUP="$(id -gn "$REAL_USER")"
readonly ARCH="$(dpkg --print-architecture)"
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a

[[ $EUID -eq 0 ]] || { printf '\033[1;31m✗\033[0m À lancer avec sudo.\n'; exit 1; }
[[ -d "$REAL_HOME" ]] || { printf '✗ HOME de %s introuvable.\n' "$REAL_USER"; exit 1; }

readonly TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

exec 3>&1
: > "$LOG"
exec >>"$LOG" 2>&1

FAILED=()
step()  { printf '  \033[1;34m›\033[0m %s\n' "$*" >&3; }
ok()    { printf '  \033[1;32m✓\033[0m %s\n' "$*" >&3; }
warn()  { printf '  \033[1;33m!\033[0m %s\n' "$*" >&3; }
err()   { printf '  \033[1;31m✗\033[0m %s\n' "$*" >&3; }
title() { printf '\n\033[1m%s\033[0m\n'      "$*" >&3; }

# CŒUR DU CORRECTIF : chaque section est isolée. Elle peut échouer sans
# entraîner l'abandon du script, et son échec est reporté à la fin.
section() {
  local name="$1" fn="$2"
  title "$name"
  if "$fn"; then :; else FAILED+=("$name"); err "section en échec — voir $LOG"; fi
  return 0
}

pkg_install() {                 # un paquet absent n'annule plus tout le lot
  local p rc=0
  for p in "$@"; do
    apt-get install -y -qq --no-install-recommends "$p" || { warn "indisponible : $p"; rc=1; }
  done
  return $rc
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

# Récupère l'URL d'un asset GitHub SANS dépendre de l'API (qui rate-limite en 403).
# Passe par la page HTML des releases, qui n'est pas limitée.
gh_asset() {
  local repo="$1" pattern="$2" tag url
  tag="$(curl -fsSLo /dev/null -w '%{url_effective}' \
        "https://github.com/${repo}/releases/latest" 2>/dev/null | sed 's#.*/tag/##')" || return 1
  [[ -n "$tag" ]] || return 1
  url="$(curl -fsSL "https://github.com/${repo}/releases/expanded_assets/${tag}" 2>/dev/null \
        | grep -oE 'href="[^"]+"' | cut -d'"' -f2 | grep -E "$pattern" | head -n1)" || return 1
  [[ -n "$url" ]] || return 1
  printf 'https://github.com%s\n' "$url"
}

#===============================================================================
sys_update() {
  step "Dépôts (universe) et mise à niveau"
  apt-get update -qq || return 1
  pkg_install software-properties-common curl wget ca-certificates gnupg jq
  add-apt-repository -y universe >/dev/null 2>&1 || warn "universe déjà présent ou indisponible"
  apt-get update -qq
  apt-get -y -qq full-upgrade || warn "full-upgrade partiel"
  ok "Système à jour"
}

#===============================================================================
kill_telemetry() {
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
  step "Services matériels et réseau superflus en VM"
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

  chown -R "$REAL_USER:$REAL_GROUP" "$REAL_HOME/.config"
  ok "Rendu sans compositeur"
}

#===============================================================================
# APPLICATIONS — placées AVANT les réglages noyau pour ne plus être préemptées
#===============================================================================
electron_fix() {
  # Depuis Ubuntu 24.04, apparmor_restrict_unprivileged_userns fait crasher au
  # démarrage les applis Chromium/Electron dépourvues de profil AppArmor.
  step "Correctif AppArmor pour Electron (userns)"
  write /etc/sysctl.d/60-apparmor-userns.conf <<'EOF'
kernel.apparmor_restrict_unprivileged_userns = 0
EOF
  sysctl -p /etc/sysctl.d/60-apparmor-userns.conf >/dev/null 2>&1 \
    || warn "sysctl userns non appliqué (noyau sans cette option : sans effet)"
}

install_actiona() {
  if command -v actiona >/dev/null 2>&1 || [[ -x /opt/actiona/actiona ]]; then
    ok "Actiona déjà présent"; return 0
  fi

  # PRIORITÉ À L'APPIMAGE : le paquet universe est figé en 3.10.1 (2020, Qt5,
  # crash au démarrage sous Wayland). L'AppImage amont est en 3.11.x.
  # Actiona ne publie AUCUN .deb : uniquement AppImage + sources.
  step "Dépendance AppImage (libfuse2)"
  pkg_install libfuse2t64 || pkg_install libfuse2 || warn "libfuse2 indisponible"

  step "Recherche de l'AppImage officielle"
  local url
  if url="$(gh_asset Jmgr/actiona '\.AppImage$')" && [[ -n "$url" ]]; then
    step "Téléchargement : ${url##*/}"
    if curl -fsSL --retry 3 -o "$TMP/actiona.AppImage" "$url" \
       && head -c4 "$TMP/actiona.AppImage" | grep -q ELF; then
      step "Installation dans /opt"
      install -d /opt/actiona
      install -m755 "$TMP/actiona.AppImage" /opt/actiona/actiona
      ln -sf /opt/actiona/actiona /usr/local/bin/actiona

      # Icône : extraite de l'AppImage si possible, sinon icône générique
      local icon="applications-utilities"
      ( cd "$TMP" && /opt/actiona/actiona --appimage-extract >/dev/null 2>&1 \
        && find squashfs-root -maxdepth 1 -name '*.png' -print -quit ) >/dev/null 2>&1
      if [[ -f "$TMP/squashfs-root/actiona.png" ]]; then
        install -Dm644 "$TMP/squashfs-root/actiona.png" /usr/share/pixmaps/actiona.png
        icon="actiona"
      fi

      write /usr/share/applications/actiona.desktop <<EOF
[Desktop Entry]
Type=Application
Name=Actiona
Comment=Outil d'automatisation
Exec=/opt/actiona/actiona
Icon=${icon}
Terminal=false
Categories=Utility;Development;
EOF
      ok "Actiona installé (AppImage, ${url##*-})"
      return 0
    fi
    warn "AppImage corrompue ou téléchargement échoué"
  else
    warn "AppImage introuvable (pas de build pour $ARCH ?)"
  fi

  step "Repli : paquet des dépôts (version ancienne)"
  if apt-get install -y -qq actiona 2>/dev/null && command -v actiona >/dev/null; then
    warn "Actiona $(dpkg-query -W -f='${Version}' actiona) depuis apt — obsolète, instable sous Wayland"
    return 0
  fi
  err "Actiona introuvable (ni AppImage ni dépôts)"
  return 1
}

install_vesktop() {
  if command -v vesktop >/dev/null 2>&1; then ok "Vesktop déjà présent"; return 0; fi

  local deb="$TMP/vesktop.deb"

  # Source primaire : redirection stable de l'éditeur (pas d'API GitHub, pas de 403)
  step "Téléchargement (vencord.dev, $ARCH)"
  if ! curl -fsSL --retry 3 -o "$deb" "https://vencord.dev/download/vesktop/${ARCH}/deb"; then
    warn "vencord.dev injoignable — repli sur GitHub"
    local url
    url="$(gh_asset Vencord/Vesktop "_${ARCH}\.deb$")" || { err "aucun .deb Vesktop pour $ARCH"; return 1; }
    curl -fsSL --retry 3 -o "$deb" "$url" || { err "téléchargement échoué"; return 1; }
  fi

  step "Vérification du paquet"
  dpkg-deb --info "$deb" >/dev/null 2>&1 || { err "fichier téléchargé invalide (page d'erreur ?)"; return 1; }

  step "Installation (+ dépendances Electron)"
  apt-get install -y -qq "$deb" || { apt-get -y -qq --fix-broken install; apt-get install -y -qq "$deb"; } \
    || { err "dpkg/apt en échec"; return 1; }

  command -v vesktop >/dev/null || { err "vesktop absent après installation"; return 1; }
  ok "Vesktop installé ($(dpkg-query -W -f='${Version}' vesktop 2>/dev/null))"
}

#===============================================================================
tune_kernel() {
  step "Module tcp_bbr"
  modprobe tcp_bbr 2>/dev/null || warn "tcp_bbr indisponible (BBR ignoré)"
  echo tcp_bbr > /etc/modules-load.d/bbr.conf

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
  systemctl enable --now zramswap.service 2>/dev/null || warn "zramswap non activé"

  step "fstab : noatime sur la racine"
  if ! grep -qE '^\s*[^#].*[[:space:]]/[[:space:]].*noatime' /etc/fstab; then
    cp /etc/fstab "/etc/fstab.bak.$(date +%s)"
    awk 'BEGIN{OFS="\t"} !/^[[:space:]]*#/ && $2=="/" && $4 !~ /noatime/ {$4=$4",noatime"} {print}' \
      /etc/fstab > "$TMP/fstab" && cat "$TMP/fstab" > /etc/fstab
  fi

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
  if [[ -f /etc/initramfs-tools/initramfs.conf ]]; then
    sed -i 's/^MODULES=.*/MODULES=dep/'    /etc/initramfs-tools/initramfs.conf
    sed -i 's/^COMPRESS=.*/COMPRESS=zstd/' /etc/initramfs-tools/initramfs.conf
    update-initramfs -u -k all || warn "update-initramfs en échec"
  fi

  step "GRUB : boot direct"
  if [[ -f /etc/default/grub ]]; then
    sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=0/' /etc/default/grub
    grep -q '^GRUB_TIMEOUT_STYLE' /etc/default/grub \
      && sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=hidden/' /etc/default/grub \
      || echo 'GRUB_TIMEOUT_STYLE=hidden' >> /etc/default/grub
    sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash mitigations=off nowatchdog"/' \
      /etc/default/grub
    update-grub || warn "update-grub en échec"
  fi

  step "Additions invité VirtualBox"
  pkg_install virtualbox-guest-utils virtualbox-guest-x11 virtualbox-guest-dkms
  getent group vboxsf >/dev/null && usermod -aG vboxsf "$REAL_USER"
  command -v VBoxClient >/dev/null \
    || warn "VBoxClient absent : installez les Additions via le menu VirtualBox (Périphériques > Insérer l'image CD des Additions invité)"

  ok "Noyau et I/O optimisés"
}

#===============================================================================
finalize() {
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
report() {
  title "Vérification finale"
  local a v
  if command -v actiona >/dev/null 2>&1 || [[ -x /opt/actiona/actiona ]]; then
    a="$(command -v actiona || echo /opt/actiona/actiona)"; ok "Actiona : $a"
  else err "Actiona : NON INSTALLÉ"; fi
  if v="$(command -v vesktop 2>/dev/null)"; then ok "Vesktop : $v"
  else err "Vesktop : NON INSTALLÉ"; fi

  if ((${#FAILED[@]})); then
    warn "Sections en échec : ${FAILED[*]}"
    warn "Détail complet : $LOG"
  else
    ok "Toutes les sections ont abouti"
  fi
}

#===============================================================================
main() {
  printf '\n\033[1mOptimisation Lubuntu 26.04 — invité VirtualBox (v4)\033[0m\n' >&3
  printf 'Utilisateur : %s (%s) | Arch : %s | Journal : %s\n' \
    "$REAL_USER" "$REAL_GROUP" "$ARCH" "$LOG" >&3

  section "1/9 — Base système"            sys_update
  section "2/9 — Télémétrie"              kill_telemetry
  section "3/9 — Services résidents"      trim_services
  section "4/9 — Indexation de fichiers"  kill_indexing
  section "5/9 — Compositeur et effets"   kill_compositing
  section "6/9 — Correctif Electron"      electron_fix
  section "7/9 — Actiona"                 install_actiona
  section "8/9 — Vesktop"                 install_vesktop
  section "9/9 — Noyau, mémoire, I/O"     tune_kernel
  section "Nettoyage"                     finalize
  report

  cat >&3 <<'EOF'

Redémarrez : sudo reboot

IMPORTANT — Actiona et Wayland :
  Actiona automatise le clavier/la souris via XTEST, qui n'existe pas sous
  Wayland. Si Lubuntu 26.04 démarre en session labwc/Wayland, Actiona ne
  pourra rien piloter (et les anciennes versions crashaient au démarrage).
  Vérifiez :  echo $XDG_SESSION_TYPE
  Si "wayland", choisissez la session "Lubuntu (X11)" à l'écran de connexion.

Contrôles après reboot :
  zramctl ; findmnt /tmp ; findmnt / -o OPTIONS ; systemd-analyze blame | head

CÔTÉ HÔTE VirtualBox (VM éteinte) :
  Accélération : Para-virtualisation = KVM, Pagination imbriquée = ON
  Processeur   : 2–4 vCPU (jamais > moitié des cœurs physiques)
  Affichage    : VMSVGA, 128 Mo VRAM, accélération 3D = OFF
  Stockage     : Cache E/S de l'hôte = ON, disque marqué SSD
EOF
}
main "$@"
