#!/usr/bin/env bash
#===============================================================================
#  lubuntu-vm-tune.sh  —  v1.0
#
#  Cible : Lubuntu 26.04 LTS "Resolute Raccoon" (LXQt 2.3 / X11 / noyau 7.0)
#          tournant COMME INVITÉ dans VirtualBox.
#
#  1. Installe Vesktop (client Discord) et Actiona
#  2. Installe/vérifie les Guest Additions VirtualBox
#  3. Applique un profil de performance "ultra-stable" pour machine virtuelle
#  4. Réduit l'empreinte mémoire (zram, earlyoom, services, autostart)
#
#  Sortie volontairement minimale : tout le détail part dans le journal.
#  Chaque fichier modifié est sauvegardé ; `--revert` annule l'ensemble.
#
#  Usage :  sudo ./lubuntu-vm-tune.sh [options]
#===============================================================================

set -Eeuo pipefail

VERSION="1.0"
LOGFILE="/var/log/lubuntu-vm-tune.log"
STATE_DIR="/var/lib/lubuntu-vm-tune"
BACKUP_ROOT="$STATE_DIR/backups"
SYSCTL_F="/etc/sysctl.d/99-lubuntu-vm-tune.conf"
UDEV_F="/etc/udev/rules.d/99-lubuntu-vm-tune-iosched.rules"
JOURNALD_F="/etc/systemd/journald.conf.d/99-lubuntu-vm-tune.conf"
ZRAM_F="/etc/systemd/zram-generator.conf"

OPT_AGGRESSIVE=0     # mitigations=off + audit=0  (perf ++ / sécurité --)
OPT_APPS=1           # installer Vesktop + Actiona
OPT_TUNE=1           # appliquer les optimisations
OPT_SNAPD=0          # désactiver snapd (attention : Firefox est un snap)
OPT_REVERT=0

#------------------------------------------------------------------ interface --
if [ -t 1 ]; then
    C_OK=$'\033[32m'; C_SK=$'\033[33m'; C_ER=$'\033[31m'; C_B=$'\033[1m'; C_0=$'\033[0m'
else
    C_OK=''; C_SK=''; C_ER=''; C_B=''; C_0=''
fi

usage() {
cat <<EOF
lubuntu-vm-tune.sh v$VERSION — optimisation Lubuntu 26.04 invité VirtualBox

  sudo $0 [options]

  --aggressive     ajoute mitigations=off et audit=0 au noyau
                   (gain CPU net en VM, mais désactive les contre-mesures
                   Spectre/Meltdown : à réserver à une VM de confiance)
  --no-apps        n'installe ni Vesktop ni Actiona
  --no-tune        installe seulement les applications, sans optimiser
  --disable-snapd  désactive snapd (libère ~150-250 Mo de RAM)
                   /!\\ casse Firefox s'il est installé en snap
  --revert         restaure l'état d'avant la dernière exécution
  -h, --help       cette aide

Journal complet : $LOGFILE
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --aggressive)    OPT_AGGRESSIVE=1 ;;
        --no-apps)       OPT_APPS=0 ;;
        --no-tune)       OPT_TUNE=0 ;;
        --disable-snapd) OPT_SNAPD=1 ;;
        --revert)        OPT_REVERT=1 ;;
        -h|--help)       usage; exit 0 ;;
        *)               printf '%sOption inconnue : %s%s\n' "$C_ER" "$1" "$C_0" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

[ "$(id -u)" -eq 0 ] || { printf '%sÀ lancer avec sudo.%s\n' "$C_ER" "$C_0" >&2; exit 1; }

#-------------------------------------------------------------------- journal --
mkdir -p "$(dirname "$LOGFILE")" "$BACKUP_ROOT"
exec 3>&1 4>&2                 # fd 3 = console stdout, fd 4 = console stderr
exec >>"$LOGFILE" 2>&1         # tout le reste part dans le journal
set -x

ok()   { set +x; printf '  %s✓%s %s\n' "$C_OK" "$C_0" "$*" >&3; set -x; }
sk()   { set +x; printf '  %s·%s %s\n' "$C_SK" "$C_0" "$*" >&3; set -x; }
wn()   { set +x; printf '  %s!%s %s\n' "$C_ER" "$C_0" "$*" >&3; set -x; }
hd()   { set +x; printf '%s%s%s\n' "$C_B" "$*" "$C_0" >&3; set -x; }
nl()   { set +x; printf '\n' >&3; set -x; }

trap 'rc=$?; set +x; printf "\n%s✗ Échec ligne %s (code %s). Détails : %s%s\n" \
      "$C_ER" "$LINENO" "$rc" "$LOGFILE" "$C_0" >&4; exit $rc' ERR

echo "=== $(date -Is) : démarrage v$VERSION ==="

#--------------------------------------------------------------------- outils --
have()          { command -v "$1" >/dev/null 2>&1; }
pkg_avail()     { apt-cache show "$1" >/dev/null 2>&1; }
pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'ok installed'; }
unit_exists()   { systemctl list-unit-files "$1" --no-legend 2>/dev/null | grep -q .; }

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

apt_q() {
    apt-get -y -qq -o Dpkg::Use-Pty=0 \
        -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold "$@"
}

install_pkgs() {
    local p want=()
    for p in "$@"; do
        if pkg_installed "$p"; then continue; fi
        if pkg_avail "$p"; then want+=("$p"); fi
    done
    if [ "${#want[@]}" -gt 0 ]; then apt_q install "${want[@]}"; fi
}

# ----- utilisateur cible (le script tourne en root via sudo) -------------------
TARGET_USER="${SUDO_USER:-}"
[ -n "$TARGET_USER" ] || TARGET_USER="$(logname 2>/dev/null || true)"
[ -n "$TARGET_USER" ] || TARGET_USER="$(awk -F: '$3>=1000 && $3<65534 {print $1; exit}' /etc/passwd)"
TARGET_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6 || true)"
[ -n "${TARGET_HOME:-}" ] || TARGET_HOME="/root"
TARGET_GROUP="$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")"

uinstall_d() { install -d -o "$TARGET_USER" -g "$TARGET_GROUP" -m 0755 "$1"; }
uown()       { chown "$TARGET_USER:$TARGET_GROUP" "$1"; }

# ----- sauvegarde / manifeste -------------------------------------------------
BACKUP_DIR="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
MANIFEST="$BACKUP_DIR/created-files.txt"
UNITS_F="$BACKUP_DIR/disabled-units.txt"
: >"$MANIFEST"; : >"$UNITS_F"

backup_file() {
    local f="$1"
    [ -e "$f" ] || return 0
    [ -e "$BACKUP_DIR$f" ] && return 0
    mkdir -p "$BACKUP_DIR$(dirname "$f")"
    cp -a "$f" "$BACKUP_DIR$f"
}
track()   { echo "$1" >>"$MANIFEST"; }

set_kv() {                       # set_kv <fichier> <clé> <valeur>
    local f="$1" k="$2" v="$3"
    if grep -qE "^[#[:space:]]*${k}=" "$f"; then
        sed -i -E "s|^[#[:space:]]*${k}=.*|${k}=${v}|" "$f"
    else
        printf '%s=%s\n' "$k" "$v" >>"$f"
    fi
}

disable_units() {
    local u
    for u in "$@"; do
        if unit_exists "$u"; then
            systemctl disable --now "$u" 2>/dev/null || true
            echo "$u" >>"$UNITS_F"
        fi
    done
}

#===============================================================================
#  MODE --revert
#===============================================================================
if [ "$OPT_REVERT" -eq 1 ]; then
    hd "Restauration"
    LAST="$(readlink -f "$STATE_DIR/last" 2>/dev/null || true)"
    if [ -z "$LAST" ] || [ ! -d "$LAST" ]; then
        wn "Aucune sauvegarde trouvée dans $BACKUP_ROOT"; exit 1
    fi
    rm -rf "$BACKUP_DIR"

    while IFS= read -r f; do [ -n "$f" ] && rm -f "$f"; done <"$LAST/created-files.txt" 2>/dev/null || true
    ok "Fichiers ajoutés supprimés"

    ( cd "$LAST" && find . -type f \
        ! -name created-files.txt ! -name disabled-units.txt \
        -printf '%P\n' ) | while IFS= read -r rel; do
            cp -a "$LAST/$rel" "/$rel"
    done
    ok "Fichiers modifiés restaurés"

    while IFS= read -r u; do
        [ -n "$u" ] && systemctl enable --now "$u" 2>/dev/null || true
    done <"$LAST/disabled-units.txt" 2>/dev/null || true
    ok "Services réactivés"

    udevadm control --reload 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    sysctl --system >/dev/null 2>&1 || true
    have update-grub && update-grub || true
    rm -f "$STATE_DIR/last"
    nl; hd "Terminé — redémarrez pour finaliser."
    exit 0
fi

#===============================================================================
#  1. PRÉ-REQUIS
#===============================================================================
nl
hd "Lubuntu 26.04 — optimisation VM VirtualBox (v$VERSION)"
nl

if ! grep -qi 'virtualbox\|innotek\|oracle' /sys/class/dmi/id/sys_vendor \
        /sys/class/dmi/id/product_name 2>/dev/null; then
    wn "VirtualBox non détecté — le profil est appliqué quand même"
fi

hd "Paquets de base"
apt_q update
ok "Index APT à jour"

if ! pkg_avail actiona; then
    install_pkgs software-properties-common
    add-apt-repository -y universe >/dev/null 2>&1 || true
    apt_q update
fi
install_pkgs curl ca-certificates wget xdg-utils
ok "Utilitaires présents"

#===============================================================================
#  2. APPLICATIONS
#===============================================================================
if [ "$OPT_APPS" -eq 1 ]; then
    nl; hd "Applications"

    # ---------- Vesktop -------------------------------------------------------
    if pkg_installed vesktop || have vesktop; then
        sk "Vesktop déjà présent"
    else
        VS_ARCH=""
        case "$(dpkg --print-architecture)" in
            amd64) VS_ARCH=amd64 ;;
            arm64) VS_ARCH=arm64 ;;
        esac
        VS_URL=""
        if [ -n "$VS_ARCH" ]; then
            VS_URL="$(curl -fsSL --max-time 30 \
                https://api.github.com/repos/Vencord/Vesktop/releases/latest 2>/dev/null \
                | grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+_'"$VS_ARCH"'\.deb"' \
                | grep -oE 'https://[^"]+' | head -n1 || true)"
        fi
        VS_DONE=0
        if [ -n "$VS_URL" ]; then
            VS_TMP="$(mktemp -d)"
            if curl -fsSL --max-time 600 -o "$VS_TMP/vesktop.deb" "$VS_URL" \
               && apt_q install "$VS_TMP/vesktop.deb"; then
                VS_DONE=1
            fi
            rm -rf "$VS_TMP"
        fi
        if [ "$VS_DONE" -eq 1 ]; then
            ok "Vesktop installé (.deb officiel)"
        else
            install_pkgs flatpak
            if have flatpak \
               && flatpak remote-add --if-not-exists flathub \
                    https://dl.flathub.org/repo/flathub.flatpakrepo \
               && flatpak install -y --noninteractive flathub dev.vencord.Vesktop; then
                ok "Vesktop installé (Flatpak)"
            else
                wn "Vesktop : installation impossible (réseau ?)"
            fi
        fi
    fi

    # Vesktop est un Electron : on allège son lancement pour la VM.
    VS_DESK="/usr/share/applications/vesktop.desktop"
    if [ -f "$VS_DESK" ] && [ "$OPT_TUNE" -eq 1 ]; then
        VS_FLAGS='--in-process-gpu --disable-gpu-compositing --js-flags=--max-old-space-size=512'
        VS_DST="$TARGET_HOME/.local/share/applications/vesktop.desktop"
        uinstall_d "$TARGET_HOME/.local/share/applications"
        if [ -e "$VS_DST" ]; then backup_file "$VS_DST"; else track "$VS_DST"; fi
        sed -E "s|^Exec=([^ ]+)(.*)$|Exec=\1 $VS_FLAGS\2|" "$VS_DESK" >"$VS_DST"
        uown "$VS_DST"
        ok "Vesktop : lancement allégé (~100-150 Mo de RAM en moins)"
    fi

    # ---------- Actiona -------------------------------------------------------
    if pkg_installed actiona; then
        sk "Actiona déjà présent"
    elif pkg_avail actiona; then
        apt_q install actiona
        ok "Actiona installé (dépôt universe)"
    else
        wn "Actiona introuvable dans les dépôts"
    fi
fi

if [ "$OPT_TUNE" -eq 0 ]; then
    nl; hd "Terminé (mode --no-tune)."
    exit 0
fi

#===============================================================================
#  3. INTÉGRATION VIRTUALBOX
#===============================================================================
nl; hd "Intégration VirtualBox"

if [ -d /opt/VBoxGuestAdditions ] || ls -d /opt/VBoxGuestAdditions-* >/dev/null 2>&1; then
    sk "Guest Additions déjà installées depuis l'ISO (on n'y touche pas)"
else
    install_pkgs virtualbox-guest-utils virtualbox-guest-x11 virtualbox-guest-dkms
    ok "Guest Additions (paquets Ubuntu) installées"
fi

if getent group vboxsf >/dev/null 2>&1; then
    usermod -aG vboxsf "$TARGET_USER" || true
    ok "$TARGET_USER ajouté au groupe vboxsf (dossiers partagés)"
fi
unit_exists 'vboxadd-service.service' && systemctl enable vboxadd-service.service || true
unit_exists 'virtualbox-guest-utils.service' && systemctl enable virtualbox-guest-utils.service || true

#===============================================================================
#  4. MÉMOIRE : zram + paramètres noyau
#===============================================================================
nl; hd "Mémoire"

# ---------- zram : ~2x plus d'applications ouvertes à RAM constante -----------
if pkg_avail systemd-zram-generator; then
    install_pkgs systemd-zram-generator
    backup_file "$ZRAM_F"
    [ -e "$ZRAM_F" ] || track "$ZRAM_F"
    cat >"$ZRAM_F" <<'EOF'
# Généré par lubuntu-vm-tune.sh
# zram = swap compressé en RAM. Sur une VM sans SSD dédié c'est le moyen
# le plus efficace de gagner de la mémoire utile sans toucher au disque.
[zram0]
zram-size = min(ram / 2, 4096)
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
EOF
    systemctl daemon-reload
    systemctl restart systemd-zram-setup@zram0.service 2>/dev/null || true
    ok "zram activé (zstd, 50 % de la RAM, prioritaire sur le swap disque)"
elif pkg_avail zram-config; then
    install_pkgs zram-config
    ok "zram activé (paquet zram-config)"
else
    wn "Aucun paquet zram disponible"
fi

# ---------- earlyoom : plus jamais de VM figée par un OOM ---------------------
if pkg_avail earlyoom; then
    install_pkgs earlyoom
    backup_file /etc/default/earlyoom
    cat >/etc/default/earlyoom <<'EOF'
# Généré par lubuntu-vm-tune.sh
# Tue le processus le plus gourmand AVANT que le noyau ne fige la machine.
EARLYOOM_ARGS="-r 3600 -m 5,2 -s 5,2 \
--avoid '(^|/)(systemd|systemd-journald|sshd|Xorg|lxqt-session|sddm|dbus-daemon)$' \
--prefer '(^|/)(vesktop|firefox|chromium|thunderbird|libreoffice)'"
EOF
    systemctl enable --now earlyoom.service 2>/dev/null || true
    ok "earlyoom actif (protection anti-freeze mémoire)"
fi

# systemd-oomd fait doublon avec earlyoom et tue trop agressivement en VM
disable_units systemd-oomd.service
[ -s "$UNITS_F" ] && grep -q systemd-oomd "$UNITS_F" && ok "systemd-oomd désactivé (remplacé par earlyoom)" || true

# ---------- sysctl ------------------------------------------------------------
backup_file "$SYSCTL_F"
[ -e "$SYSCTL_F" ] || track "$SYSCTL_F"
cat >"$SYSCTL_F" <<'EOF'
# Généré par lubuntu-vm-tune.sh — profil « invité VirtualBox, RAM réduite »

# --- Swap : avec zram, swapper tôt et par petites pages est GAGNANT ----------
vm.swappiness = 180
vm.page-cluster = 0
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125

# --- Cache : garder inodes/dentries plus longtemps, moins de relectures ------
vm.vfs_cache_pressure = 50

# --- Écritures : petits paquets = pas de à-coups sur un disque virtuel -------
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
vm.dirty_expire_centisecs = 1500
vm.dirty_writeback_centisecs = 1500

# --- Divers ------------------------------------------------------------------
vm.max_map_count = 1048576
kernel.nmi_watchdog = 0
kernel.sched_autogroup_enabled = 1
fs.file-max = 262144
EOF
sysctl --system >/dev/null 2>&1 || true
ok "Paramètres noyau mémoire appliqués"

#===============================================================================
#  5. DISQUE VIRTUEL
#===============================================================================
nl; hd "Disque virtuel"

# ---------- ordonnanceur d'E/S : aucun, l'hôte s'en charge --------------------
backup_file "$UDEV_F"
[ -e "$UDEV_F" ] || track "$UDEV_F"
cat >"$UDEV_F" <<'EOF'
# Généré par lubuntu-vm-tune.sh
# Dans une VM, l'hôte réordonne déjà les E/S : un second ordonnanceur
# dans l'invité ne fait qu'ajouter de la latence.
ACTION=="add|change", KERNEL=="sd[a-z]|vd[a-z]", ATTR{queue/scheduler}="none"
ACTION=="add|change", KERNEL=="sd[a-z]|vd[a-z]", ATTR{queue/rotational}="0"
ACTION=="add|change", KERNEL=="sd[a-z]|vd[a-z]", ATTR{queue/add_random}="0"
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/scheduler}="none"
EOF
udevadm control --reload >/dev/null 2>&1 || true
udevadm trigger --subsystem-match=block >/dev/null 2>&1 || true
ok "Ordonnanceur d'E/S neutralisé (none)"

# ---------- noatime : ~15-20 % d'écritures en moins ---------------------------
FSTAB=/etc/fstab
if [ -f "$FSTAB" ] && ! grep -qE '^[^#].*[[:space:]]/[[:space:]].*noatime' "$FSTAB"; then
    backup_file "$FSTAB"
    awk 'BEGIN{ok=1}
         /^[[:space:]]*#/  {print; next}
         NF<4              {print; next}
         ($3=="ext4"||$3=="xfs"||$3=="btrfs") && $4 !~ /(^|,)noatime(,|$)/ {
              $4=$4",noatime" }
         {print}' OFS='\t' "$FSTAB" >"$FSTAB.tune.new"
    if [ "$(wc -l <"$FSTAB")" -eq "$(wc -l <"$FSTAB.tune.new")" ]; then
        mv "$FSTAB.tune.new" "$FSTAB"
        mount -o remount,noatime / 2>/dev/null || true
        ok "noatime activé sur les systèmes de fichiers locaux"
    else
        rm -f "$FSTAB.tune.new"
        wn "fstab laissé intact (structure inattendue)"
    fi
else
    sk "noatime déjà en place"
fi

# ---------- journal systemd borné --------------------------------------------
mkdir -p /etc/systemd/journald.conf.d
backup_file "$JOURNALD_F"
[ -e "$JOURNALD_F" ] || track "$JOURNALD_F"
cat >"$JOURNALD_F" <<'EOF'
# Généré par lubuntu-vm-tune.sh
[Journal]
Storage=persistent
Compress=yes
SystemMaxUse=50M
SystemMaxFileSize=10M
RuntimeMaxUse=16M
MaxRetentionSec=1week
EOF
systemctl restart systemd-journald 2>/dev/null || true
journalctl --vacuum-size=50M >/dev/null 2>&1 || true
ok "Journal systemd limité à 50 Mo"

#===============================================================================
#  6. SERVICES ET DÉMARRAGE
#===============================================================================
nl; hd "Services inutiles en VM"

disable_units \
    cups.service cups.socket cups.path cups-browsed.service \
    bluetooth.service \
    ModemManager.service \
    avahi-daemon.service avahi-daemon.socket \
    apport.service whoopsie.service kerneloops.service \
    packagekit.service packagekit-offline-update.service \
    NetworkManager-wait-online.service \
    fwupd-refresh.timer \
    switcheroo-control.service \
    power-profiles-daemon.service
ok "$(grep -c . "$UNITS_F" 2>/dev/null || echo 0) services/timers désactivés"

if [ "$OPT_SNAPD" -eq 1 ]; then
    disable_units snapd.service snapd.socket snapd.seeded.service snapd.apparmor.service
    ok "snapd désactivé"
else
    sk "snapd conservé (--disable-snapd pour l'éteindre)"
fi

# ---------- autostart de session ---------------------------------------------
uinstall_d "$TARGET_HOME/.config/autostart"
AS_COUNT=0
for entry in picom compton lxqt-compton blueman blueman-applet \
             print-applet system-config-printer update-notifier \
             snap-userd-autostart xscreensaver org.gnome.SettingsDaemon.PrintNotifications; do
    src=""
    [ -f "/etc/xdg/autostart/$entry.desktop" ] && src="/etc/xdg/autostart/$entry.desktop"
    [ -f "$TARGET_HOME/.config/autostart/$entry.desktop" ] && src="$TARGET_HOME/.config/autostart/$entry.desktop"
    [ -n "$src" ] || continue
    dst="$TARGET_HOME/.config/autostart/$entry.desktop"
    if [ -e "$dst" ]; then backup_file "$dst"; else track "$dst"; fi
    { grep -vE '^(Hidden|X-GNOME-Autostart-enabled)=' "$src"
      echo "Hidden=true"
      echo "X-GNOME-Autostart-enabled=false"; } >"$dst.tmp"
    mv "$dst.tmp" "$dst"
    uown "$dst"
    AS_COUNT=$((AS_COUNT+1))
done
ok "$AS_COUNT lancements automatiques neutralisés (dont le compositeur)"

#===============================================================================
#  7. NOYAU / GRUB
#===============================================================================
nl; hd "Amorçage"

GRUB=/etc/default/grub
if [ -f "$GRUB" ]; then
    backup_file "$GRUB"
    ADD="nowatchdog nmi_watchdog=0 zswap.enabled=0 transparent_hugepage=madvise"
    [ "$OPT_AGGRESSIVE" -eq 1 ] && ADD="$ADD mitigations=off audit=0"

    CUR="$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB" | head -n1 \
           | sed -E 's/^[^=]+=//; s/^"//; s/"$//' || true)"
    NEW=" ${CUR:-quiet splash} "
    for p in $ADD; do
        k="${p%%=*}"
        NEW="$(printf '%s' "$NEW" | sed -E "s/ ${k}(=[^ ]*)? / /g")"
        NEW="$NEW$p "
    done
    NEW="$(printf '%s' "$NEW" | tr -s ' ' | sed 's/^ //; s/ $//')"

    sed -i -E "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$NEW\"|" "$GRUB"
    set_kv "$GRUB" GRUB_TIMEOUT 2
    set_kv "$GRUB" GRUB_RECORDFAIL_TIMEOUT 2
    set_kv "$GRUB" GRUB_DISABLE_OS_PROBER true
    update-grub >/dev/null 2>&1 || update-grub
    if [ "$OPT_AGGRESSIVE" -eq 1 ]; then
        ok "GRUB mis à jour (mode agressif : mitigations=off)"
    else
        ok "GRUB mis à jour (profil sûr)"
    fi
fi

#===============================================================================
#  8. NETTOYAGE
#===============================================================================
nl; hd "Nettoyage"
apt_q autoremove --purge
apt_q clean
fstrim -a 2>/dev/null || true
ok "Paquets orphelins et caches supprimés"

ln -sfn "$BACKUP_DIR" "$STATE_DIR/last"

#===============================================================================
#  RÉSUMÉ
#===============================================================================
MEM_TOT="$(awk '/MemTotal/{printf "%.1f", $2/1048576}' /proc/meminfo)"
MEM_AV="$(awk '/MemAvailable/{printf "%.1f", $2/1048576}' /proc/meminfo)"

set +x
{
  printf '\n%s────────────────────────────────────────────────────────%s\n' "$C_B" "$C_0"
  printf '  RAM : %s Gio disponibles sur %s Gio\n' "$MEM_AV" "$MEM_TOT"
  printf '  Sauvegarde : %s   (annuler : sudo %s --revert)\n' "$BACKUP_DIR" "$0"
  printf '  Journal    : %s\n' "$LOGFILE"
  printf '\n  %sRedémarrez pour appliquer zram, GRUB et les Guest Additions.%s\n\n' "$C_B" "$C_0"
} >&3

echo "=== $(date -Is) : terminé ==="
exit 0
