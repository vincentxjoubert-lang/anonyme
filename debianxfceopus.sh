#!/usr/bin/env bash
# =============================================================================
#  Debian 13 "trixie" / XFCE  —  post-install : maj, durcissement, tuning, apps
#  Révision 2 — corrige 22 défauts identifiés lors de l'audit de la révision 1.
#
#  Matériel ciblé : Ryzen 7 7800X3D (Zen 4, iGPU Raphael) · MSI MAG B650
#                   TOMAHAWK WIFI (LAN Realtek RTL8125BG 2,5G · Wi-Fi MT7922)
#                   · XFX RX 6950 XT (RDNA 2, navi21) · 32 Go DDR5 · NVMe M.2
#                   · MSI MAG 275QF 1440p 180 Hz FreeSync · Logitech G413 TKL FR
#  Vérifié contre  : Debian 13.6 (11/07/2026) · noyau 6.12 LTS · Mesa 25.0.7
#                    APT 3.x (vérification sqv) · xkeyboard-config 2.44
#  Usage           : sudo ./debian13-setup.sh
# =============================================================================
set -Eeuo pipefail

readonly LOG="/var/log/debian13-setup.log"
readonly TS="$(date +%F_%H-%M-%S)"
readonly CODENAME="trixie"
WARNINGS=0

# -- AUDIT #14 : le test root doit précéder toute écriture dans /var/log -------
[ "$(id -u)" -eq 0 ] || { echo "Ce script doit être lancé avec sudo." >&2; exit 1; }
: >"$LOG"; chmod 600 "$LOG"

trap 'printf "\n[ARRÊT] échec ligne %s — détails : %s\n" "$LINENO" "$LOG" >&2' ERR

# ---------- helpers ----------------------------------------------------------
step() { printf '  %-58s' "$1"; }
ok()   { printf '[ OK ]\n'; }
skp()  { printf '[SKIP] %s\n' "${1:-}"; }
wrn()  { WARNINGS=$((WARNINGS+1)); printf '[ !! ] %s\n' "${1:-voir le log}"; }
sec()  { printf '\n\033[1m%s\033[0m\n' "$1"; }
run()  { "$@" >>"$LOG" 2>&1; }
# AUDIT #8 : plus jamais « cmd || wrn; ok » — on utilise systématiquement if/else.

readonly APT_OPTS=(-y -qq -o Dpkg::Use-Pty=0
                   -o Dpkg::Options::=--force-confdef
                   -o Dpkg::Options::=--force-confold)

apt_install() {                        # groupé, puis paquet par paquet si échec
  DEBIAN_FRONTEND=noninteractive apt-get install "${APT_OPTS[@]}" "$@" >>"$LOG" 2>&1 && return 0
  local p rc=0
  for p in "$@"; do
    DEBIAN_FRONTEND=noninteractive apt-get install "${APT_OPTS[@]}" "$p" >>"$LOG" 2>&1 \
      || { echo "ÉCHEC installation: $p" >>"$LOG"; rc=1; }
  done
  return $rc
}

# AUDIT #3 : APT 3.x de trixie vérifie via sqv, qui rejette les keyrings au
# format « keybox » GnuPG. On ne télécharge donc JAMAIS un .gpg fourni tel quel :
# on récupère l'armure ASCII et on la convertit en anneau OpenPGP v4 valide.
fetch_key() {                          # $1 = URL du .asc  $2 = destination .gpg
  local tmp; tmp="$(mktemp)"
  curl -fsSL --retry 3 --connect-timeout 15 "$1" -o "$tmp" 2>>"$LOG" || { rm -f "$tmp"; return 1; }
  gpg --batch --yes --dearmor -o "$2" "$tmp" 2>>"$LOG" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"; chmod 0644 "$2"
  # Contrôle : sqv doit savoir lire l'anneau produit.
  [ -s "$2" ] && gpg --batch --show-keys "$2" >>"$LOG" 2>&1
}

# AUDIT #15 : test d'un dépôt en bac à sable complet (listes isolées),
# sans polluer /var/lib/apt/lists. Le dépôt est retiré s'il ne valide pas.
add_repo() {                           # $1 = nom  $2 = chemin du .sources
  local name="$1" file="$2" tmp ret=0
  tmp="$(mktemp -d)"; mkdir -p "$tmp/parts" "$tmp/lists/partial"; cp "$file" "$tmp/parts/"
  apt-get update -qq \
      -o Dir::Etc::sourcelist=/dev/null \
      -o Dir::Etc::sourceparts="$tmp/parts" \
      -o Dir::State::lists="$tmp/lists" \
      -o APT::Get::List-Cleanup=0 >>"$LOG" 2>&1 || ret=1
  rm -rf "$tmp"
  [ $ret -eq 0 ] || { rm -f "$file"; echo "Dépôt invalide retiré: $name" >>"$LOG"; }
  return $ret
}

backup() { [ -e "$1" ] && cp -a "$1" "$1.bak-$TS"; return 0; }

# Exécute une commande dans la session graphique de l'utilisateur (best-effort).
as_user_gui() {
  local uid; uid="$(id -u "$TARGET_USER")"
  runuser -u "$TARGET_USER" -- env \
      DISPLAY="${DISP:-:0}" \
      XAUTHORITY="$TARGET_HOME/.Xauthority" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
      "$@" >>"$LOG" 2>&1
}

# ---------- 00 · pré-vol -----------------------------------------------------
sec "00 · Vérifications préalables"

step "Debian 13 (trixie) / amd64"
. /etc/os-release
if [ "${ID:-}" = debian ] && [ "${VERSION_ID:-}" = 13 ] && [ "$(dpkg --print-architecture)" = amd64 ]; then
  ok
else printf '[STOP] système non conforme\n'; exit 1; fi

step "Connectivité réseau"
if run getent hosts deb.debian.org; then ok; else printf '[STOP] pas de résolution DNS\n'; exit 1; fi

step "Utilisateur cible"
TARGET_USER="${SUDO_USER:-}"
[ -z "$TARGET_USER" ] && TARGET_USER="$(awk -F: '$3>=1000 && $3<65534 {print $1; exit}' /etc/passwd)"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)"
if [ -n "$TARGET_USER" ] && [ -d "${TARGET_HOME:-}" ]; then printf '[ %s ]\n' "$TARGET_USER"
else printf '[STOP] utilisateur introuvable\n'; exit 1; fi
DISP="$(ls -1 /tmp/.X11-unix/ 2>/dev/null | head -1 | sed 's/^X/:/')"; DISP="${DISP:-:0}"

# AUDIT #22 : on ne présume plus que NetworkManager gère le réseau.
step "Gestionnaire réseau"
if systemctl is-enabled NetworkManager.service >/dev/null 2>&1; then
  NM=1; printf '[ NetworkManager ]\n'
else NM=0; printf '[ autre (ifupdown/networkd) ]\n'; fi

# ---------- 01 · sources APT + multiarch -------------------------------------
sec "01 · Sources APT (main contrib non-free non-free-firmware) + i386"

step "Réécriture de debian.sources (format deb822)"
backup /etc/apt/sources.list.d/debian.sources
cat >/etc/apt/sources.list.d/debian.sources <<EOF
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
ok

step "Neutralisation de l'ancien sources.list"
if [ -s /etc/apt/sources.list ] && grep -qE '^[[:space:]]*deb' /etc/apt/sources.list; then
  backup /etc/apt/sources.list
  sed -i 's/^[[:space:]]*deb/#deb/' /etc/apt/sources.list; ok
else skp "déjà inactif"; fi

step "Architecture i386 (Steam / jeux 32 bits)"
if dpkg --print-foreign-architectures | grep -qx i386; then skp "déjà active"
else run dpkg --add-architecture i386; ok; fi

step "apt-get update"
if run apt-get update; then ok; else wrn "voir le log"; fi

# ---------- 02 · mise à jour complète ----------------------------------------
sec "02 · Mise à jour complète du système"

step "full-upgrade"
if DEBIAN_FRONTEND=noninteractive apt-get full-upgrade "${APT_OPTS[@]}" >>"$LOG" 2>&1; then ok
else wrn; fi

step "Outillage de base"
if apt_install ca-certificates curl gnupg dirmngr apt-transport-https \
               build-essential dkms linux-headers-amd64 pciutils usbutils; then ok; else wrn; fi

step "Nettoyage initial"
if run apt-get autoremove --purge -y -qq; then ok; else wrn; fi

# ---------- 03 · mises à jour de sécurité automatiques -----------------------
sec "03 · Mises à jour de sécurité automatiques"

# AUDIT #12 : apt-listchanges retiré — son frontal peut bloquer une exécution
# non interactive d'unattended-upgrades.
step "Installation unattended-upgrades"
if apt_install unattended-upgrades; then ok; else wrn; fi

step "Cadence APT"
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
ok

step "Politique locale (sécurité seule, sans reboot auto)"
cat >/etc/apt/apt.conf.d/52unattended-upgrades-local <<'EOF'
// Chargé après 50unattended-upgrades (ordre lexical) : prioritaire.
Unattended-Upgrade::Origins-Pattern {
        "origin=Debian,codename=${distro_codename},label=Debian-Security";
        "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
};
Unattended-Upgrade::Package-Blacklist { };
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::SyslogEnable "true";
EOF
ok

step "Activation des timers"
if run systemctl enable --now apt-daily.timer apt-daily-upgrade.timer; then ok; else wrn; fi

step "Validation à blanc"
if run unattended-upgrades --dry-run --debug; then ok; else wrn "dry-run non concluant"; fi

# ---------- 04 · télémétrie --------------------------------------------------
sec "04 · Télémétrie"

step "popularity-contest (unique collecteur Debian)"
if dpkg -s popularity-contest >/dev/null 2>&1; then
  if run apt-get purge -y -qq popularity-contest; then ok; else wrn; fi
else skp "non installé"; fi

step "Verrou anti-réinstallation"
cat >/etc/apt/preferences.d/99-no-popcon <<'EOF'
Package: popularity-contest
Pin: release *
Pin-Priority: -1
EOF
ok
# Debian ne fournit ni apport, ni whoopsie, ni ubuntu-report : rien d'autre à retirer.

# ---------- 05 · dépôt universel (Flatpak / Flathub) -------------------------
sec "05 · Dépôt universel Flatpak + portails XDG"

step "flatpak + portails"
if apt_install flatpak xdg-desktop-portal xdg-desktop-portal-gtk; then ok; else wrn; fi

step "Remote Flathub (système)"
if run flatpak remote-add --if-not-exists --system \
       flathub https://dl.flathub.org/repo/flathub.flatpakrepo; then ok; else wrn; fi

# ---------- 06 · pare-feu + AppArmor -----------------------------------------
sec "06 · Pare-feu (politique DROP) et AppArmor"

step "Installation ufw"
if apt_install ufw; then ok; else wrn; fi

# AUDIT #20 : « ufw enable » active déjà l'unité, pas de systemctl enable en plus.
step "Politique : entrant DROP, sortant autorisé"
if run ufw --force reset && run ufw default deny incoming \
   && run ufw default allow outgoing && run ufw logging low \
   && run ufw --force enable; then
  ufw status verbose >>"$LOG" 2>&1; ok
else wrn; fi

# apparmor-profiles fournit des profils supplémentaires chargés en mode
# « complain » : aucun risque de casse, on ne touche pas à -extra (trop strict).
step "AppArmor (profils système en enforce)"
if apt_install apparmor apparmor-utils apparmor-profiles; then
  run systemctl enable --now apparmor
  if run aa-enabled; then ok; else wrn "AppArmor inactif côté noyau"; fi
else wrn; fi

# ---------- 07 · DNS Quad9 chiffré (DoT) -------------------------------------
sec "07 · DNS Quad9 sécurisé — DNS-over-TLS strict"

step "systemd-resolved"
if apt_install systemd-resolved; then ok; else wrn; fi

step "Profil Quad9 global"
install -d /etc/systemd/resolved.conf.d
cat >/etc/systemd/resolved.conf.d/99-quad9-dot.conf <<'EOF'
[Resolve]
DNS=9.9.9.9#dns.quad9.net 149.112.112.112#dns.quad9.net 2620:fe::fe#dns.quad9.net 2620:fe::9#dns.quad9.net
FallbackDNS=
Domains=~.
DNSOverTLS=yes
DNSSEC=no
Cache=yes
DNSStubListener=yes
ReadEtcHosts=yes
EOF
ok

# =============================================================================
#  AUDIT #1 — CORRECTIF MAJEUR
#  systemd-resolved privilégie TOUJOURS les serveurs DNS d'un lien sur le DNS
#  global. NetworkManager pousse par défaut les DNS du DHCP sur chaque lien :
#  le profil Quad9 ci-dessus était donc purement décoratif et les requêtes
#  partaient en clair vers la box (systemd#33973).
#  Correctif : imposer ignore-auto-dns sur ethernet et wifi. Les VPN ne sont
#  volontairement PAS filtrés, pour ne pas casser leur résolution interne.
# =============================================================================
if [ "$NM" = 1 ]; then
  step "NetworkManager : purge des DNS DHCP (anti-fuite)"
  install -d /etc/NetworkManager/conf.d
  cat >/etc/NetworkManager/conf.d/99-dns-resolved.conf <<'EOF'
[main]
dns=systemd-resolved
systemd-resolved=true

[connection-quad9-no-dhcp-dns]
match-device=type:ethernet,type:wifi
ipv4.ignore-auto-dns=true
ipv6.ignore-auto-dns=true
EOF
  ok
else
  step "NetworkManager absent"
  skp "vérifiez manuellement l'absence de DNS par lien"
fi

step "resolv.conf -> stub systemd"
backup /etc/resolv.conf
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
if run systemctl enable --now systemd-resolved; then ok; else wrn; fi

step "Redémarrage réseau + contrôle de résolution"
[ "$NM" = 1 ] && run systemctl restart NetworkManager || true
run systemctl restart systemd-resolved
sleep 3
if run resolvectl query deb.debian.org; then ok; else wrn "résolution KO, voir le log"; fi

step "Contrôle : aucun DNS résiduel par lien"
if resolvectl status 2>/dev/null | awk '/^Link/{l=1} l&&/DNS Servers/{print}' \
     | grep -qv '9\.9\.9\.9\|149\.112\.112\.112\|2620:fe::'; then
  wrn "un lien porte encore un DNS DHCP — voir 'resolvectl status'"
else ok; fi

# ---------- 08 · sysctl : durcissement + performances ------------------------
sec "08 · sysctl prioritaire (durcissement + réseau + RAM + SSD)"

step "/etc/sysctl.d/99-hardening-tuning.conf"
cat >/etc/sysctl.d/99-hardening-tuning.conf <<'EOF'
# =========================================================================
#  Préfixe 99- : appliqué en dernier, prioritaire sur tous les autres
#  fichiers de /usr/lib/sysctl.d, /run/sysctl.d et /etc/sysctl.d.
#
#  Choix assumés pour ne pas gêner l'usage quotidien :
#   - les namespaces utilisateurs non privilégiés restent ACTIFS : les
#     désactiver casse Flatpak, le bac à sable de Brave/Chromium, Steam
#     et les conteneurs de VSCodium ;
#   - rp_filter en mode « loose » (2) et non « strict » (1), sinon les VPN,
#     le routage asymétrique et les ponts VirtualBox tombent ;
#   - sysrq complet REISUB, pour garder un arrêt d'urgence propre.
# =========================================================================

# --- Noyau ---------------------------------------------------------------
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.perf_event_paranoid = 3      # profilage bloqué ; réversible à chaud
kernel.kexec_load_disabled = 1      # verrou définitif jusqu'au reboot
kernel.yama.ptrace_scope = 1
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
kernel.randomize_va_space = 2
kernel.sysrq = 244                  # AUDIT #4 : 4+16+32+64+128 = REISUB complet

# --- Système de fichiers -------------------------------------------------
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
fs.suid_dumpable = 0

# --- Réseau : sécurité ---------------------------------------------------
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
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

# --- Réseau : débit (2,5 Gb/s descendant / 850 Mb/s montant) -------------
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.optmem_max = 65536
net.core.netdev_max_backlog = 16384
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000
net.core.somaxconn = 8192
net.ipv4.tcp_rmem = 4096 262144 16777216
net.ipv4.tcp_wmem = 4096 262144 16777216
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_window_scaling = 1

# --- Mémoire : 32 Go, machine allumée en permanence ----------------------
vm.swappiness = 10
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
vm.dirty_expire_centisecs = 1500
vm.dirty_writeback_centisecs = 1500
vm.max_map_count = 1048576          # requis par de nombreux titres Proton/DX12
vm.mmap_min_addr = 65536
vm.min_free_kbytes = 262144

# --- Confort applicatif (VSCodium, Steam) --------------------------------
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024
fs.file-max = 2097152
EOF
ok

step "Module tcp_bbr"
echo tcp_bbr >/etc/modules-load.d/bbr.conf
if run modprobe tcp_bbr; then ok; else wrn "tcp_bbr indisponible, cubic conservé"; fi

step "Application des sysctl"
if run sysctl --system -e; then ok; else wrn; fi

step "Contrôle BBR + fq actifs"
if [ "$(sysctl -n net.ipv4.tcp_congestion_control)" = bbr ] \
   && [ "$(sysctl -n net.core.default_qdisc)" = fq ]; then ok; else wrn "non appliqué"; fi

# AUDIT #11 : on n'écrase plus core_pattern à la main, on désactive proprement
# la collecte via systemd-coredump.
step "Vidages mémoire désactivés (systemd-coredump)"
install -d /etc/systemd/coredump.conf.d
printf '[Coredump]\nStorage=none\nProcessSizeMax=0\n' \
  >/etc/systemd/coredump.conf.d/99-disable.conf
ok

# AUDIT #17 : daemon-reexec obligatoire pour que system.conf.d prenne effet.
step "Défauts systemd (arrêt rapide, limites de fichiers)"
install -d /etc/systemd/system.conf.d
cat >/etc/systemd/system.conf.d/99-defaults.conf <<'EOF'
[Manager]
DefaultTimeoutStopSec=15s
DefaultLimitNOFILE=1024:1048576
EOF
if run systemctl daemon-reexec; then ok; else wrn; fi

step "Journal borné à 500 Mo"
install -d /etc/systemd/journald.conf.d
printf '[Journal]\nSystemMaxUse=500M\nSystemMaxFileSize=50M\nCompress=yes\n' \
  >/etc/systemd/journald.conf.d/99-size.conf
if run systemctl restart systemd-journald; then ok; else wrn; fi

step "SSD M.2 : TRIM hebdomadaire"
if run systemctl enable --now fstrim.timer; then ok; else wrn; fi

step "NVMe : ordonnanceur none + file profonde"
cat >/etc/udev/rules.d/60-nvme-scheduler.rules <<'EOF'
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="nvme[0-9]*n[0-9]*", \
  ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="none", ATTR{queue/nr_requests}="1024"
EOF
if run udevadm control --reload; then ok; else wrn; fi

# ---------- 09 · pilotes AMD -------------------------------------------------
sec "09 · Microcode, firmwares et pile graphique AMD"

step "Microcode CPU Zen 4"
if apt_install amd64-microcode; then ok; else wrn; fi

# AUDIT #18 : le B650 TOMAHAWK WIFI embarque une MediaTek MT7922 (« AMD RZ616 »)
# et un Realtek RTL8125BG 2,5G. Les deux firmwares sont désormais explicites.
step "Firmwares : GPU AMD · Realtek 2,5G · MediaTek Wi-Fi 6E"
if apt_install firmware-amd-graphics firmware-realtek firmware-mediatek \
               firmware-misc-nonfree firmware-linux-free; then ok; else wrn; fi

step "Pile graphique amdgpu / Mesa (64 bits)"
if apt_install xserver-xorg-video-amdgpu mesa-vulkan-drivers mesa-va-drivers \
               libgl1-mesa-dri libglx-mesa0 libvulkan1 vulkan-tools mesa-utils \
               libva-drm2 vainfo radeontop; then ok; else wrn; fi

step "Pile graphique 32 bits (Steam / Proton)"
if apt_install mesa-vulkan-drivers:i386 libgl1-mesa-dri:i386 libglx-mesa0:i386 \
               libvulkan1:i386 libc6:i386; then ok; else wrn; fi

# AUDIT #19 : le MAG 275QF est un 180 Hz FreeSync — le VRR n'était pas activé.
# OutputClass + MatchDriver : ne cible que le pilote amdgpu et ne risque pas de
# se lier au mauvais GPU (le 7800X3D possède un iGPU Raphael également amdgpu).
step "FreeSync / VRR sur X11"
install -d /etc/X11/xorg.conf.d
cat >/etc/X11/xorg.conf.d/20-amdgpu-vrr.conf <<'EOF'
Section "OutputClass"
    Identifier  "AMDGPU VRR"
    MatchDriver "amdgpu"
    Driver      "amdgpu"
    Option      "VariableRefresh" "true"
    Option      "TearFree"        "false"
    Option      "DRI"             "3"
EndSection
EOF
ok

step "initramfs (chargement précoce du microcode)"
if run update-initramfs -u -k all; then ok; else wrn; fi

# ---------- 10 · stabilité ---------------------------------------------------
sec "10 · Stabilité système"

step "earlyoom (anti-gel sous pression mémoire)"
if apt_install earlyoom && run systemctl enable --now earlyoom; then ok; else wrn; fi

# AUDIT #2 : l'unité Debian s'appelle smartmontools.service ; smartd.service
# n'est qu'un alias et systemd refuse « systemctl enable » sur un alias.
step "smartmontools (santé NVMe)"
if apt_install smartmontools && run systemctl enable --now smartmontools.service; then ok
else wrn; fi

step "fwupd (firmwares UEFI / SSD)"
if apt_install fwupd && run systemctl enable --now fwupd-refresh.timer; then ok; else wrn; fi

step "Audio PipeWire (Discord / Steam)"
if dpkg -s pipewire >/dev/null 2>&1; then
  if apt_install pipewire-audio libspa-0.2-bluetooth; then ok; else wrn; fi
else skp "PulseAudio conservé, pas de bascule risquée"; fi

# ---------- 11 · dépôts tiers ------------------------------------------------
sec "11 · Dépôts tiers (clés réarmurées, deb822, testés isolément)"

BRAVE_APT=1; CODIUM_APT=1; VBOX_APT=1

step "Brave (clé réarmurée pour sqv)"
if fetch_key https://brave-browser-apt-release.s3.brave.com/brave-core.asc \
             /usr/share/keyrings/brave-browser-archive-keyring.gpg \
   && curl -fsSL --retry 3 -o /etc/apt/sources.list.d/brave-browser-release.sources \
        https://brave-browser-apt-release.s3.brave.com/brave-browser.sources 2>>"$LOG" \
   && add_repo brave /etc/apt/sources.list.d/brave-browser-release.sources; then ok
else BRAVE_APT=0; wrn "bascule Flatpak prévue"; fi

step "VSCodium"
if fetch_key https://repo.vscodium.dev/vscodium.gpg /usr/share/keyrings/vscodium.gpg \
   && curl -fsSL --retry 3 -o /etc/apt/sources.list.d/vscodium.sources \
        https://repo.vscodium.dev/vscodium.sources 2>>"$LOG" \
   && add_repo vscodium /etc/apt/sources.list.d/vscodium.sources; then ok
else CODIUM_APT=0; wrn "bascule Flatpak prévue"; fi

step "Oracle VirtualBox 7.2"
if fetch_key https://www.virtualbox.org/download/oracle_vbox_2016.asc \
             /usr/share/keyrings/oracle-virtualbox-2016.gpg; then
  cat >/etc/apt/sources.list.d/virtualbox.sources <<EOF
Types: deb
URIs: https://download.virtualbox.org/virtualbox/debian
Suites: $CODENAME
Components: contrib
Architectures: amd64
Signed-By: /usr/share/keyrings/oracle-virtualbox-2016.gpg
EOF
  if add_repo virtualbox /etc/apt/sources.list.d/virtualbox.sources; then ok
  else VBOX_APT=0; wrn; fi
else VBOX_APT=0; wrn; fi

step "apt-get update global"
if run apt-get update; then ok; else wrn; fi

# ---------- 12 · applications ------------------------------------------------
sec "12 · Applications"

step "VLC · qBittorrent · FileZilla (natifs Debian)"
if apt_install vlc qbittorrent filezilla; then ok; else wrn; fi

step "Brave"
if [ "$BRAVE_APT" = 1 ] && apt_install brave-browser; then ok
elif run flatpak install -y --system --noninteractive flathub com.brave.Browser; then ok
else wrn; fi

step "VSCodium"
if [ "$CODIUM_APT" = 1 ] && apt_install codium; then ok
elif run flatpak install -y --system --noninteractive flathub com.vscodium.codium; then ok
else wrn; fi

step "Steam (steam-installer + périphériques)"
if apt_install steam-installer steam-devices; then ok; else wrn; fi

# AUDIT #21 : le service vboxdrv n'est pas garanti selon la version du deb ;
# /sbin/vboxconfig est le point d'entrée officiel de reconstruction DKMS.
step "VirtualBox 7.2 (DKMS, Secure Boot désactivé)"
if [ "$VBOX_APT" = 1 ] && apt_install virtualbox-7.2; then
  run usermod -aG vboxusers "$TARGET_USER"
  run systemctl enable --now vboxdrv.service || run /sbin/vboxconfig || true
  if lsmod | grep -q '^vboxdrv'; then ok
  else wrn "module non chargé — voir /var/log/vbox-setup.log"; fi
else wrn "dépôt Oracle indisponible"; fi

step "Discord (Flatpak : évite les màj forcées cassant le .deb)"
if run flatpak install -y --system --noninteractive flathub com.discordapp.Discord; then ok
else wrn; fi

step "Mise à jour Flatpak"
run flatpak update -y --noninteractive || true; ok

# ---------- 13 · clavier FR façon Windows 11 ---------------------------------
sec "13 · Clavier AZERTY FR — Verr.Maj façon Windows, sans Shift maintenu"

# AUDIT #5 : validation par xkbcli (XKB réel) et non par ckbcomp (keymap console).
step "Outils de validation XKB"
if apt_install libxkbcommon-tools xkb-data x11-xkb-utils; then ok; else wrn; fi

read -r -d '' FRWIN_SYMBOLS <<'EOF' || true
// ---------------------------------------------------------------------------
//  frwin — AZERTY français « legacy » avec Verr.Maj au comportement Windows.
//
//  Pourquoi ce variant plutôt que l'option caps:shiftlock :
//    caps:shiftlock VERROUILLE le modificateur Shift lui-même. Résultat : la
//    sélection étendue au clic, l'ouverture de liens dans un nouvel onglet et
//    tous les raccourcis Shift+X restent actifs en permanence.
//
//  Ici on ne modifie AUCUN symbole : on change seulement le TYPE des touches
//  concernées. FOUR_LEVEL_ALPHABETIC réagit au modificateur Lock et déclare
//  preserve[Lock], donc Shift n'est jamais synthétisé.
//
//  Table de correspondance obtenue (identique à Windows) :
//    Verr.Maj OFF            -> &  é  "  '  (  ...
//    Verr.Maj ON             -> 1  2  3  4  5  ...
//    Verr.Maj ON + Maj       -> &  é  "  '  (  ...   (Shift+Lock non mappé,
//                                                     retombe au niveau 1)
//    Verr.Maj ON/OFF + AltGr -> ~  #  {  [  |  ...   (niveau 3 préservé)
// ---------------------------------------------------------------------------
default partial alphanumeric_keys
xkb_symbols "basic" {

    // AUDIT #16 : « fr » et non « fr(basic) » — on suit la section par défaut
    // déclarée en amont, insensible à un renommage dans xkeyboard-config.
    include "fr"
    name[Group1] = "French (AZERTY, Windows-like Caps Lock)";

    // Rangée des chiffres
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

    // Ponctuation soumise au verrou sous Windows
    override key <AD11> { type[Group1] = "FOUR_LEVEL_ALPHABETIC" };
    override key <AD12> { type[Group1] = "FOUR_LEVEL_ALPHABETIC" };
    override key <AC10> { type[Group1] = "FOUR_LEVEL_ALPHABETIC" };
    override key <AC11> { type[Group1] = "FOUR_LEVEL_ALPHABETIC" };
    override key <BKSL> { type[Group1] = "FOUR_LEVEL_ALPHABETIC" };
    override key <AB07> { type[Group1] = "FOUR_LEVEL_ALPHABETIC" };
    override key <AB08> { type[Group1] = "FOUR_LEVEL_ALPHABETIC" };
    override key <AB09> { type[Group1] = "FOUR_LEVEL_ALPHABETIC" };
    override key <AB10> { type[Group1] = "FOUR_LEVEL_ALPHABETIC" };
    override key <LSGT> { type[Group1] = "FOUR_LEVEL_ALPHABETIC" };
};
EOF

# AUDIT #6 : xkbcomp (X11) ne lit QUE /usr/share/X11/xkb ; libxkbcommon
# (GTK, Wayland, XFCE 4.20) lit /etc/xkb. Le variant est déposé aux deux
# emplacements, sinon il est invisible pour la moitié de la pile graphique.
step "Dépôt du variant frwin (X11 + libxkbcommon)"
install -d /usr/share/X11/xkb/symbols /etc/xkb/symbols
printf '%s\n' "$FRWIN_SYMBOLS" >/usr/share/X11/xkb/symbols/frwin
printf '%s\n' "$FRWIN_SYMBOLS" >/etc/xkb/symbols/frwin
chmod 0644 /usr/share/X11/xkb/symbols/frwin /etc/xkb/symbols/frwin
ok

step "Compilation de contrôle du keymap"
if run xkbcli compile-keymap --model pc105 --layout frwin; then
  KBD_LAYOUT=frwin; ok
else
  KBD_LAYOUT=fr
  rm -f /usr/share/X11/xkb/symbols/frwin /etc/xkb/symbols/frwin
  wrn "variant rejeté, repli sur 'fr' standard"
fi

step "Configuration X11 (aucune option caps:*)"
backup /etc/X11/xorg.conf.d/00-keyboard.conf
cat >/etc/X11/xorg.conf.d/00-keyboard.conf <<EOF
Section "InputClass"
    Identifier      "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbModel"   "pc105"
    Option "XkbLayout"  "$KBD_LAYOUT"
    Option "XkbVariant" ""
    Option "XkbOptions" ""
EndSection
EOF
ok

step "Console TTY (layout fr standard)"
backup /etc/default/keyboard
cat >/etc/default/keyboard <<'EOF'
XKBMODEL="pc105"
XKBLAYOUT="fr"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF
if command -v setupcon >/dev/null 2>&1; then run setupcon --save-only || true; fi
ok

# AUDIT #7 : xfconfd garde sa configuration en mémoire et réécrit le XML à la
# fermeture de session. Écrire le fichier ne suffit pas : il faut passer par le
# bus de session, sinon le réglage est perdu au premier logout.
step "XFCE : neutralisation de la gestion XKB"
XFCONF_DIR="$TARGET_HOME/.config/xfce4/xfconf/xfce-perchannel-xml"
install -d -o "$TARGET_USER" -g "$TARGET_USER" "$XFCONF_DIR"
backup "$XFCONF_DIR/keyboard-layout.xml"
cat >"$XFCONF_DIR/keyboard-layout.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="keyboard-layout" version="1.0">
  <property name="Default" type="empty">
    <property name="XkbDisable" type="bool" value="true"/>
  </property>
</channel>
EOF
chown "$TARGET_USER:$TARGET_USER" "$XFCONF_DIR/keyboard-layout.xml"
if as_user_gui xfconf-query -c keyboard-layout -p /Default/XkbDisable -n -t bool -s true \
   || as_user_gui xfconf-query -c keyboard-layout -p /Default/XkbDisable -s true; then ok
else skp "appliqué au prochain démarrage de session"; fi

# AUDIT #16 : setxkbmap nécessite DISPLAY *et* XAUTHORITY, sinon échec muet.
step "Application immédiate (session en cours)"
if as_user_gui setxkbmap -model pc105 -layout "$KBD_LAYOUT" -option ""; then ok
else skp "effectif à la reconnexion"; fi

# ---------- 14 · finalisation ------------------------------------------------
sec "14 · Finalisation"

step "Nettoyage APT"
run apt-get autoremove --purge -y -qq || true
run apt-get clean || true; ok

step "Collecte des vérifications finales"
{ echo "=== ufw ===";            ufw status verbose
  echo "=== apparmor ===";       aa-status || true
  echo "=== dns ===";            resolvectl status
  echo "=== congestion ===";     sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc
  echo "=== sysrq ===";          sysctl kernel.sysrq
  echo "=== microcode ===";      grep -m1 microcode /proc/cpuinfo || true
  echo "=== vulkan ===";         vulkaninfo --summary 2>/dev/null | head -40 || true
  echo "=== unités ===";         systemctl is-active smartmontools apparmor systemd-resolved earlyoom
  echo "=== clavier x11 ===";    cat /etc/X11/xorg.conf.d/00-keyboard.conf
} >>"$LOG" 2>&1
ok

printf '\n'
if [ "$WARNINGS" -eq 0 ]; then
  printf '  \033[1mTerminé sans avertissement.\033[0m\n'
else
  printf '  \033[1mTerminé avec %s avertissement(s).\033[0m\n' "$WARNINGS"
fi
cat <<EOF

  Journal complet : $LOG

  Redémarrage requis (microcode, initramfs, AppArmor, sysctl, XKB, VRR).

  Contrôles après reboot :
    resolvectl status | grep -iE 'DNSOverTLS|Current DNS'   -> Quad9 + DoT actif
    resolvectl status | grep -A3 '^Link'                    -> aucun DNS de box
    ufw status verbose                                      -> deny (incoming)
    sysctl kernel.sysrq                                     -> 244
    vulkaninfo --summary | grep -i radv                     -> RADV navi21
    xrandr --props | grep -i "vrr\|variable"                -> VRR disponible
    Verr.Maj puis rangée du haut                            -> 1234567890
    Verr.Maj + clic dans un texte                           -> pas de sélection

  Réversible à chaud si besoin :
    sudo sysctl kernel.perf_event_paranoid=1   # réactive les profileurs

EOF
