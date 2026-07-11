#!/usr/bin/env bash
#===============================================================================
#  setup-lubuntu-2604.sh   (révision post-audit)
#  Post-installation Lubuntu 26.04 LTS "Resolute Raccoon" — X11 / LXQt 2.3 / Qt6
#  Matériel cible : Ryzen 7 7800X3D + RX 6950 XT (RDNA2) + 32 Go DDR5 + NVMe + 2.5GbE
#  Objectifs : latence & input-lag mini, perf max sans surchauffe, conso basse,
#              stabilité, sécurité, vie privée.
#
#  ⚠  PREREQUIS : Secure Boot DÉSACTIVÉ dans l'UEFI (noyau Liquorix non signé).
#  Robustesse : aucun échec de paquet n'interrompt le script ; tout est journalisé.
#  Usage : sudo ./setup-lubuntu-2604.sh
#===============================================================================
set -uo pipefail            # PAS de -e : le script va toujours au bout et rapporte

#------------------------------------------------------------------ Préflight ---
[[ $EUID -eq 0 ]] || { echo "Lance le script avec sudo."; exit 1; }
[[ "$(uname -m)" == "x86_64" ]] || { echo "Architecture non supportée."; exit 1; }

REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || true)}"
[[ -n "$REAL_USER" && "$REAL_USER" != "root" ]] || { echo "Utilisateur cible introuvable."; exit 1; }
USER_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
CODENAME="$(. /etc/os-release; echo "$VERSION_CODENAME")"
ARCH="$(dpkg --print-architecture)"
LOG="/var/log/lubuntu-setup.log"; : > "$LOG"

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1

#------------------------------------------------------------------- Helpers ---
c(){ printf '\033[%sm' "$1"; }
step(){ printf '  %s▸%s %s' "$(c '1;36')" "$(c 0)" "$*"; }
ok(){   printf ' %s✓%s\n' "$(c '1;32')" "$(c 0)"; }
skip(){ printf ' %s—%s %s\n' "$(c '1;33')" "$(c 0)" "${1:-}"; }
warn(){ printf ' %s✗%s\n' "$(c '1;31')" "$(c 0)"; echo "WARN: $*" >>"$LOG"; }
title(){ printf '\n%s%s%s\n' "$(c '1;35')" "$*" "$(c 0)"; }

apt_get(){ apt-get -y -o Dpkg::Use-Pty=0 -o Dpkg::Options::=--force-confold "$@"; }
pkg(){ apt_get install --no-install-recommends "$@"; }            # (n'ombre plus 'install')
# installe chaque paquet indépendamment : un échec isolé n'entraîne pas les autres
pkg_loop(){ local p r=0; for p in "$@"; do pkg "$p" >>"$LOG" 2>&1 || { echo "PKG FAIL: $p" >>"$LOG"; r=1; }; done; return $r; }
as_user(){ sudo -u "$REAL_USER" HOME="$USER_HOME" "$@"; }
uconf(){ local f="$1"; /usr/bin/install -d -o "$REAL_USER" -g "$REAL_USER" "$(dirname "$f")"
         cat > "$f"; chown "$REAL_USER:$REAL_USER" "$f"; }
# exécute un bloc en silence puis rapporte ✓/✗ (ne s'arrête jamais)
DO(){ local m="$1"; shift; step "$m"; if { "$@"; } >>"$LOG" 2>&1; then ok; else warn "$m"; fi; }

printf '%sLubuntu 26.04 — configuration (%s / %s / user=%s)%s\n' \
  "$(c '1;37')" "$CODENAME" "$ARCH" "$REAL_USER" "$(c 0)"
printf 'Journal détaillé : %s\n' "$LOG"

#============================================================ 1. Dépôts / base ==
title "1. Dépôts (universe/multiverse/restricted, i386) + mise à jour"
DO "architecture i386"      dpkg --add-architecture i386
DO "outils de base"         pkg software-properties-common curl wget gpg ca-certificates apt-transport-https lsb-release
step "composants Ubuntu"; { add-apt-repository -y universe && add-apt-repository -y multiverse && add-apt-repository -y restricted; } >>"$LOG" 2>&1 && ok || warn "composants"
DO "apt update"             apt_get update

#================================================================ 2. Liquorix ==
title "2. Noyau Liquorix (dernière version) + défaut GRUB"
step "PPA damentz/liquorix"; { add-apt-repository -y ppa:damentz/liquorix && apt_get update; } >>"$LOG" 2>&1 && ok || warn "ppa liquorix"
DO "installation noyau"     pkg linux-image-liquorix-amd64 linux-headers-liquorix-amd64
step "GRUB (menu 3 s, noyau récent par défaut)"
sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=3/' /etc/default/grub 2>>"$LOG"
grep -q '^GRUB_DEFAULT=' /etc/default/grub && sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=0/' /etc/default/grub || echo 'GRUB_DEFAULT=0' >> /etc/default/grub
ok

#================================================= 3. Pilotes AMD / Mesa / µcode ==
title "3. Firmware, micro-code AMD, Mesa/RADV (RDNA2) + Vulkan (64/32 bits)"
DO "microcode + firmware"   pkg amd64-microcode linux-firmware
DO "Mesa + Vulkan"          pkg_loop mesa-vulkan-drivers mesa-vulkan-drivers:i386 \
                                libgl1-mesa-dri libgl1-mesa-dri:i386 \
                                mesa-va-drivers mesa-vdpau-drivers \
                                libvulkan1 libvulkan1:i386 vulkan-tools vainfo mesa-utils radeontop

#================================================== 4. sysctl (réseau + hardening) ==
title "4. sysctl : réseau 2.5 Gbps + durcissement + RAM/SSD"
step "écriture /etc/sysctl.d/99-tuning.conf"
cat > /etc/sysctl.d/99-tuning.conf <<'EOF'
# --- Réseau : débit 2.5GbE + faible latence (BBR + fq) ---
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 131072 16777216
net.ipv4.tcp_wmem=4096 16384 16777216
net.core.netdev_max_backlog=16384
net.core.somaxconn=8192
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_notsent_lowat=131072
net.ipv4.tcp_syncookies=1
# --- Durcissement réseau (n'entrave ni VPN, ni jeux, ni partage d'écran) ---
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
net.ipv4.conf.all.accept_source_route=0
net.ipv6.conf.all.accept_source_route=0
net.ipv4.conf.all.accept_redirects=0
net.ipv6.conf.all.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.all.log_martians=1
net.ipv4.icmp_echo_ignore_broadcasts=1
# --- Durcissement noyau ---
kernel.kptr_restrict=2
kernel.dmesg_restrict=1
kernel.kexec_load_disabled=1
kernel.unprivileged_bpf_disabled=1
net.core.bpf_jit_harden=2
kernel.yama.ptrace_scope=1
fs.protected_hardlinks=1
fs.protected_symlinks=1
fs.protected_fifos=2
fs.protected_regular=2
# Laisse Steam/Proton, Discord (partage d'écran) et Brave utiliser les user namespaces
kernel.apparmor_restrict_unprivileged_userns=0
# --- RAM 32 Go + SSD NVMe ---
vm.swappiness=10
vm.vfs_cache_pressure=50
vm.dirty_ratio=10
vm.dirty_background_ratio=5
EOF
chmod 644 /etc/sysctl.d/99-tuning.conf; ok
DO "application sysctl"     sysctl --system
step "planificateur I/O NVMe = none"
echo 'ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/scheduler}="none"' > /etc/udev/rules.d/60-nvme-scheduler.rules; ok
DO "fstrim.timer"           systemctl enable fstrim.timer

#===================================================== 5. DNS Quad9 (DoT, sans dnscrypt) ==
title "5. DNS Quad9 chiffré (DNS-over-TLS via systemd-resolved)"
step "config resolved"
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/quad9.conf <<'EOF'
[Resolve]
DNS=9.9.9.9#dns.quad9.net 149.112.112.112#dns.quad9.net 2620:fe::fe#dns.quad9.net 2620:fe::9#dns.quad9.net
DNSOverTLS=yes
DNSSEC=allow-downgrade
Cache=yes
FallbackDNS=
EOF
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf; ok
DO "activation resolved"    bash -c 'systemctl enable --now systemd-resolved && systemctl restart systemd-resolved'

#=========================================================== 6. Snap → Flatpak ==
title "6. Suppression totale de Snap → Flatpak + Flathub"
step "retrait des snaps (dont Firefox)"
if command -v snap >/dev/null; then
  snap remove --purge firefox >>"$LOG" 2>&1 || true
  for s in $(snap list 2>/dev/null | awk 'NR>1{print $1}'); do snap remove --purge "$s" >>"$LOG" 2>&1 || true; done
fi; ok
step "purge snapd + blocage réinstallation"
{ systemctl disable --now snapd.socket snapd.service snapd.seeded.service 2>/dev/null
  apt_get purge snapd
  apt-mark hold snapd; } >>"$LOG" 2>&1
printf 'Package: snapd\nPin: release *\nPin-Priority: -1\n' > /etc/apt/preferences.d/no-snapd
rm -rf "$USER_HOME/snap" /snap /var/snap /var/lib/snapd 2>/dev/null; ok
DO "Flatpak" pkg flatpak
step "dépôt Flathub (user)"; as_user flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo >>"$LOG" 2>&1 && ok || warn "flathub"

#=============================================================== 7. Audio PipeWire ==
title "7. Audio : bascule complète sur PipeWire (retrait PulseAudio)"
step "purge pulseaudio"; { apt_get purge pulseaudio pulseaudio-utils; } >>"$LOG" 2>&1; ok
DO "install pipewire"       pkg_loop pipewire pipewire-pulse pipewire-alsa wireplumber pavucontrol firmware-sof-signed
step "activation (user)"
as_user systemctl --user enable pipewire pipewire-pulse wireplumber >>"$LOG" 2>&1 || true
systemctl --global disable pulseaudio.service pulseaudio.socket >>"$LOG" 2>&1 || true; ok

#=========================================== 8. Thunar (remplace PCManFM-Qt) + vignettes ==
title "8. Gestionnaire de fichiers Thunar (+ vignettes images/vidéos/archives)"
DO "installation Thunar & greffons" pkg_loop thunar thunar-archive-plugin thunar-volman thunar-media-tags-plugin \
        tumbler tumbler-plugins-extra ffmpegthumbnailer xdg-user-dirs xdg-user-dirs-gtk gvfs gvfs-backends libgsf-bin
step "Thunar par défaut (dossiers)"
as_user xdg-mime default thunar.desktop inode/directory >>"$LOG" 2>&1 || true
as_user xdg-user-dirs-update >>"$LOG" 2>&1 || true; ok
step "retrait PCManFM-Qt"; { apt_get purge pcmanfm-qt; } >>"$LOG" 2>&1 && ok || skip "conservé (dépendance bureau)"

#================================================== 9. Compatibilité Wayland (paquets) ==
title "9. Paquets de compatibilité Wayland (session X11 conservée par défaut)"
DO "portails + Qt wayland" pkg_loop xdg-desktop-portal xdg-desktop-portal-wlr xdg-desktop-portal-gtk qtwayland5 qt6-wayland xwayland

#===================================================== 10. GameMode (64 + 32 bits) ==
title "10. GameMode + support 32 bits"
DO "gamemode 64/32" pkg_loop gamemode libgamemode0 libgamemode0:i386 libgamemodeauto0 libgamemodeauto0:i386
usermod -aG gamemode "$REAL_USER" >>"$LOG" 2>&1 || true

#========================================================= 11. Polices internationales ==
title "11. Polices : latin, CJK (中/日/한), arabe, emoji couleur"
DO "familles Noto + arabe" pkg_loop fonts-noto-core fonts-noto-ui-core fonts-noto-extra \
        fonts-noto-cjk fonts-noto-cjk-extra fonts-noto-color-emoji fonts-noto-mono \
        fonts-liberation2 fonts-dejavu-core fonts-hosny-amiri fonts-sil-scheherazade fonts-kacst fonts-inter
DO "cache polices" fc-cache -f

#================================================== 12. Pare-feu (UFW/GUFW, DROP) + AppArmor ==
title "12. Pare-feu UFW + GUFW en DROP + AppArmor"
DO "installation" pkg ufw gufw apparmor apparmor-utils apparmor-profiles
step "règles UFW (deny in / allow out)"
{ ufw --force reset
  ufw default deny incoming        # = DROP en entrée
  ufw default allow outgoing       # laisse passer VPN / jeux / partage d'écran
  ufw logging low
  ufw --force enable
  systemctl enable ufw; } >>"$LOG" 2>&1 && ok || warn "ufw"
DO "AppArmor actif" systemctl enable --now apparmor

#===================================================== 13. Clavier (FR legacy, Verr.Maj=chiffres) ==
title "13. Clavier : Français Legacy (AZERTY) + Verr.Maj = verrou Maj (chiffres, comme Windows)"
cat > /etc/default/keyboard <<'EOF'
XKBMODEL="pc105"
XKBLAYOUT="fr"
XKBVARIANT=""
# caps:shiftlock -> Verr.Maj agit comme un "Shift lock" : la rangée du haut tape
# directement 1234567890 (comportement Windows AZERTY), idéal sur TKL sans pavé num.
XKBOPTIONS="caps:shiftlock,grp_led:caps"
BACKSPACE="guess"
EOF
DO "application layout" setupcon --force

#=========================================== 14. Écran : 2560x1440 @180Hz + 125% net (au boot) ==
title "14. Écran forcé au démarrage : 2560×1440 @ 180 Hz, échelle 125% nette (DPI, sans flou)"
cat > /usr/local/bin/set-display.sh <<'EOF'
#!/usr/bin/env bash
OUT="$(xrandr 2>/dev/null | awk '/ connected/{print $1; exit}')"
[ -n "$OUT" ] && xrandr --output "$OUT" --primary --mode 2560x1440 --rate 180 2>/dev/null || true
printf 'Xft.dpi: 120\n' | xrdb -merge 2>/dev/null || true   # 96*1.25=120 -> 125% net
EOF
chmod +x /usr/local/bin/set-display.sh
grep -q '^QT_FONT_DPI' /etc/environment || echo 'QT_FONT_DPI=120' >> /etc/environment
uconf "$USER_HOME/.config/autostart/set-display.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Force Display 180Hz 1440p
Exec=/usr/local/bin/set-display.sh
OnlyShowIn=LXQt;
EOF
uconf "$USER_HOME/.Xresources" <<'EOF'
Xft.dpi: 120
Xft.hinting: true
Xft.hintstyle: hintslight
Xft.rgba: rgb
Xft.antialias: true
EOF
step "autostart écran configuré"; ok

#========================= 15. Thème macOS Dark complet (fenêtres Openbox + Qt/Kvantum + GTK + icônes + curseur) ==
title "15. Thème macOS Dark : Openbox (fenêtres) + Qt/Kvantum + GTK + icônes + curseur"
# Outils de build EN PREMIER (indispensables au clonage) — chacun indépendant
DO "outils de build thème" pkg_loop git sassc libglib2.0-dev-bin optipng
# Moteur Kvantum Qt6 (souvent déjà présent sur Lubuntu 26.04) — non bloquant
DO "moteur Kvantum Qt6" pkg_loop qt6-style-kvantum qt6-style-kvantum-themes
TMP="$(mktemp -d)"; chown "$REAL_USER:$REAL_USER" "$TMP"
_git(){ as_user git clone --depth=1 "$1" "$2" >>"$LOG" 2>&1; }

step "thème GTK WhiteSur (dark)"
as_user rm -rf "$USER_HOME/.themes/WhiteSur"* "$USER_HOME/.local/share/themes/WhiteSur"* >/dev/null 2>&1
{ _git https://github.com/vinceliuice/WhiteSur-gtk-theme "$TMP/gtk" && timeout 600 as_user bash -c "cd '$TMP/gtk' && bash install.sh -c Dark -l"; } </dev/null >>"$LOG" 2>&1 && ok || warn "GTK"

step "icônes WhiteSur (dark)"
as_user rm -rf "$USER_HOME/.local/share/icons/WhiteSur"* "$USER_HOME/.icons/WhiteSur"* >/dev/null 2>&1
{ _git https://github.com/vinceliuice/WhiteSur-icon-theme "$TMP/icons" && timeout 600 as_user bash -c "cd '$TMP/icons' && bash install.sh -b"; } </dev/null >>"$LOG" 2>&1 && ok || warn "icônes"

step "curseur macOS WhiteSur (système)"
rm -rf /usr/share/icons/WhiteSur-cursors >/dev/null 2>&1
{ _git https://github.com/vinceliuice/WhiteSur-cursors "$TMP/cursors" && ( cd "$TMP/cursors" && timeout 300 bash install.sh ); } </dev/null >>"$LOG" 2>&1 && ok || warn "curseur"

step "thème Qt/Kvantum WhiteSurDark"
if _git https://github.com/vinceliuice/WhiteSur-kde "$TMP/kde" >>"$LOG" 2>&1; then
  KV="$USER_HOME/.config/Kvantum"; /usr/bin/install -d -o "$REAL_USER" -g "$REAL_USER" "$KV"
  cp -r "$TMP"/kde/Kvantum/WhiteSur "$KV"/ 2>>"$LOG"
  chown -R "$REAL_USER:$REAL_USER" "$KV"
  uconf "$KV/kvantum.kvconfig" <<'EOF'
[General]
theme=WhiteSurDark
EOF
  ok
else warn "Kvantum"; fi

# --- Décorations de fenêtres Openbox : thème sombre couleurs macOS (auto-écrit, sans téléchargement) ---
step "thème Openbox macOS (bords de fenêtres)"
OBDIR="/usr/share/themes/WhiteSur-Dark-OB/openbox-3"; mkdir -p "$OBDIR"
cat > "$OBDIR/themerc" <<'EOF'
! WhiteSur-Dark-OB — décoration Openbox sombre, accents macOS
border.width: 1
padding.width: 7
padding.height: 5
window.handle.width: 0
window.active.border.color: #1b1b1b
window.inactive.border.color: #1b1b1b
window.active.title.bg: flat solid
window.active.title.bg.color: #2b2b2b
window.inactive.title.bg: flat solid
window.inactive.title.bg.color: #232323
window.active.label.bg: parentrelative
window.active.label.text.color: #f2f2f2
window.inactive.label.bg: parentrelative
window.inactive.label.text.color: #8a8a8a
window.label.text.justify: center
window.active.button.unpressed.bg: flat solid
window.inactive.button.unpressed.bg: flat solid
window.active.button.unpressed.image.color: #cfcfcf
window.inactive.button.unpressed.image.color: #6a6a6a
window.active.button.hover.image.color: #ffffff
! feux macOS
window.active.button.close.unpressed.image.color: #ff5f57
window.active.button.iconify.unpressed.image.color: #febc2e
window.active.button.maximize.unpressed.image.color: #28c840
! menus
menu.border.width: 1
menu.border.color: #1b1b1b
menu.title.bg: flat solid
menu.title.bg.color: #2b2b2b
menu.title.text.color: #f2f2f2
menu.items.bg: flat solid
menu.items.bg.color: #242424
menu.items.text.color: #e6e6e6
menu.items.active.bg: flat solid
menu.items.active.bg.color: #0a84ff
menu.items.active.text.color: #ffffff
osd.bg: flat solid
osd.bg.color: #242424
osd.label.text.color: #f2f2f2
EOF
# Applique le thème + boutons à gauche (ordre macOS) dans la conf Openbox de LXQt
patch_openbox(){
python3 - "$1" <<'PY'
import sys, xml.etree.ElementTree as ET
f=sys.argv[1]; NS="http://openbox.org/3.4/rc"; ns="{%s}"%NS
ET.register_namespace("",NS)
try: t=ET.parse(f); r=t.getroot()
except Exception: sys.exit(1)
th=r.find(ns+"theme")
if th is None: sys.exit(1)
def s(p,tag,val):
    e=p.find(ns+tag)
    if e is None: e=ET.SubElement(p,ns+tag)
    e.text=val
s(th,"name","WhiteSur-Dark-OB")
s(th,"titleLayout","CIML")   # Close Iconify Maximize à gauche, puis Label
t.write(f,xml_declaration=True,encoding="UTF-8"); sys.exit(0)
PY
}
{ patch_openbox /etc/xdg/openbox/lxqt-rc.xml
  if [ -f "$USER_HOME/.config/openbox/lxqt-rc.xml" ]; then
     patch_openbox "$USER_HOME/.config/openbox/lxqt-rc.xml"
     chown "$REAL_USER:$REAL_USER" "$USER_HOME/.config/openbox/lxqt-rc.xml"
  fi; } >>"$LOG" 2>&1 && ok || warn "openbox"

# --- Sélection par défaut : LXQt (style Qt + icônes + panneau), GTK 2/3/4, curseur ---
step "application des réglages par défaut"
# Panneau LXQt suit Kvantum (theme=kvantum) + style Qt = kvantum-dark
uconf "$USER_HOME/.config/lxqt/lxqt.conf" <<'EOF'
[General]
icon_theme=WhiteSur-dark
theme=kvantum

[Qt]
style=kvantum-dark
font_size=10
EOF
# GTK 3 / 4
for g in gtk-3.0 gtk-4.0; do
uconf "$USER_HOME/.config/$g/settings.ini" <<'EOF'
[Settings]
gtk-theme-name=WhiteSur-Dark
gtk-icon-theme-name=WhiteSur-dark
gtk-cursor-theme-name=WhiteSur-cursors
gtk-font-name=Inter 10
gtk-application-prefer-dark-theme=1
EOF
done
# GTK 2 (applis anciennes)
uconf "$USER_HOME/.gtkrc-2.0" <<'EOF'
gtk-theme-name="WhiteSur-Dark"
gtk-icon-theme-name="WhiteSur-dark"
gtk-cursor-theme-name="WhiteSur-cursors"
gtk-font-name="Inter 10"
EOF
# Curseur système par défaut
mkdir -p /usr/share/icons/default
printf '[Icon Theme]\nInherits=WhiteSur-cursors\n' > /usr/share/icons/default/index.theme
ok
rm -rf "$TMP"

#================================================================ 16. Applications ==
title "16. Applications natives (dépôts officiels, tolérant aux échecs)"
step "dépôt VS Code"
{ curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > /usr/share/keyrings/microsoft.gpg \
  && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/code stable main" > /etc/apt/sources.list.d/vscode.list; } >>"$LOG" 2>&1 && ok || warn "repo vscode"

step "dépôt Brave"
{ curl -fsSL https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg -o /usr/share/keyrings/brave-browser-archive-keyring.gpg \
  && echo "deb [signed-by=/usr/share/keyrings/brave-browser-archive-keyring.gpg] https://brave-browser-apt-release.s3.brave.com/ stable main" > /etc/apt/sources.list.d/brave-browser-release.list; } >>"$LOG" 2>&1 && ok || warn "repo brave"

step "dépôt Mullvad VPN"
# NB : dépôt distro-agnostique -> suite littérale 'stable', PAS le nom de code Ubuntu.
{ curl -fsSL https://repository.mullvad.net/deb/mullvad-keyring.asc -o /usr/share/keyrings/mullvad-keyring.asc \
  && echo "deb [signed-by=/usr/share/keyrings/mullvad-keyring.asc arch=$ARCH] https://repository.mullvad.net/deb/stable stable main" > /etc/apt/sources.list.d/mullvad.list; } >>"$LOG" 2>&1 && ok || warn "repo mullvad"

DO "apt update (dépôts tiers)" apt_get update

step "installation paquets APT"
for p in vlc code brave-browser mullvad-vpn btop qbittorrent filezilla gammastep actiona steam-installer; do
  pkg "$p" >>"$LOG" 2>&1 && echo "APT OK: $p" >>"$LOG" || echo "APT FAIL: $p" >>"$LOG"
done; ok

step "Discord (.deb officiel)"
DEB="$(mktemp --suffix=.deb)"
{ curl -fsSL "https://discord.com/api/download?platform=linux&format=deb" -o "$DEB" && apt_get install "$DEB"; } >>"$LOG" 2>&1 && ok || warn "discord"
rm -f "$DEB"

#===================================================== 17. Mises à jour de sécurité auto ==
title "17. Mises à jour de sécurité automatiques (unattended-upgrades)"
DO "installation" pkg unattended-upgrades apt-listchanges
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF
cat > /etc/apt/apt.conf.d/51security-only <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
DO "activation" systemctl enable --now unattended-upgrades

#=============================================== 18. Désactivation services/fonctions inutiles ==
title "18. Désactivation : télémétrie, Bluetooth, WiFi, imprimante, portefeuille, indexation"
step "télémétrie Ubuntu (apport/whoopsie/report/popcon)"
{ apt_get purge apport whoopsie popularity-contest ubuntu-report
  systemctl disable --now apport.service whoopsie.service; } >>"$LOG" 2>&1; ok
step "Bluetooth"; { systemctl disable --now bluetooth.service; rfkill block bluetooth; } >>"$LOG" 2>&1; ok
step "WiFi (bloqué au boot)"
rfkill block wifi >>"$LOG" 2>&1 || true
cat > /etc/systemd/system/rfkill-block.service <<'EOF'
[Unit]
Description=Bloque WiFi et Bluetooth au démarrage
After=multi-user.target
[Service]
Type=oneshot
ExecStart=/usr/sbin/rfkill block wifi
ExecStart=/usr/sbin/rfkill block bluetooth
[Install]
WantedBy=multi-user.target
EOF
systemctl enable rfkill-block.service >>"$LOG" 2>&1 || true; ok
step "Impression (CUPS)"; { systemctl disable --now cups.service cups.socket cups-browsed.service; } >>"$LOG" 2>&1; ok
step "Portefeuille KWallet"
{ apt_get purge kwalletmanager; } >>"$LOG" 2>&1 || true
uconf "$USER_HOME/.config/kwalletrc" <<'EOF'
[Wallet]
Enabled=false
First Use=false
EOF
ok
step "Indexation de fichiers (baloo si présent)"
{ as_user balooctl6 disable || as_user balooctl disable; } >>"$LOG" 2>&1 || true
skip "aucun indexeur par défaut sur Lubuntu"

#==================================================================== 19. Finalisation ==
title "19. Finalisation"
DO "reconstruction GRUB (Liquorix par défaut)" update-grub
step "nettoyage apt"; { apt_get autoremove --purge; apt_get clean; } >>"$LOG" 2>&1; ok
step "droits fichiers utilisateur"; chown -R "$REAL_USER:$REAL_USER" "$USER_HOME/.config" "$USER_HOME/.local" 2>/dev/null; ok

#========================================================================= Résumé ==
title "Terminé."
cat <<EOF
  $(c '1;32')Configuration appliquée.$(c 0)  Journal : $LOG

  À FAIRE : REDÉMARRER, puis se reconnecter (le thème s'applique à l'ouverture de session).

  Vérifications post-reboot :
    uname -r            -> doit contenir « liquorix »
    resolvectl status   -> DNS = Quad9, DNSOverTLS=yes
    ufw status verbose  -> deny (incoming)
    aa-status           -> AppArmor actif

  Thème macOS Dark — si un élément n'est pas appliqué automatiquement,
  ouvrir « Configuration LXQt » -> Apparence et vérifier :
    • Style des widgets Qt : kvantum-dark      • Icônes : WhiteSur-dark
    • Thème LXQt (panneau)  : kvantum          • Curseur : WhiteSur-cursors
  Bords de fenêtres : Préférences -> Openbox Settings -> onglet Theme -> "WhiteSur-Dark-OB".

  Rappels :
    • Secure Boot doit rester DÉSACTIVÉ (Liquorix non signé).
    • WiFi/Bluetooth bloqués : 'sudo rfkill unblock wifi' pour réactiver ponctuellement.
    • Écran 180 Hz : si le mode 2560x1440@180 n'est pas dans l'EDID, il faudra un modeline
      personnalisé (dis-le-moi, je te le génère).
EOF
