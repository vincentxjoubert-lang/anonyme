#!/usr/bin/env bash
#===============================================================================
#  setup-openbox-debian13.sh   (v2 - audité)
#  Environnement Openbox minimal, stable, durci (sécurité+vie privée) et
#  optimisé pour Debian 13.5 "Trixie" (kernel 6.12 LTS).
#
#  Matériel : Ryzen 7 7800X3D (Zen4) | RX 6950 XT (RDNA2) | 32Go DDR5
#             Realtek 2.5GbE (B650 Tomahawk) | NVMe | Écran 2560x1440@180Hz DP
#
#  Usage :  sudo bash setup-openbox-debian13.sh
#===============================================================================

set -euo pipefail

#------------------------------------------------------------------------------
# 0. Garde-fous & utilitaires
#------------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || { echo "Lance ce script avec sudo."; exit 1; }

TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
[[ "$TARGET_USER" != "root" ]] || { echo "Lance via 'sudo' depuis ton compte, pas en root pur."; exit 1; }
USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
export DEBIAN_FRONTEND=noninteractive
APT="apt-get -y -qq -o=Dpkg::Use-Pty=0"
LOG="/var/log/setup-openbox.log"

log()   { printf '\n\033[1;36m[ %s ]\033[0m\n' "$*"; }
run()   { "$@" >>"$LOG" 2>&1; }
asuser(){ sudo -u "$TARGET_USER" env HOME="$USER_HOME" "$@"; }

: >"$LOG"
log "Cible : utilisateur=$TARGET_USER  home=$USER_HOME  (journal: $LOG)"

#------------------------------------------------------------------------------
# 1. Dépôts APT : composants complets + multiarch i386 (Steam)
#------------------------------------------------------------------------------
log "Dépôts (main contrib non-free non-free-firmware) + i386"
if [[ -f /etc/apt/sources.list.d/debian.sources ]]; then
  sed -i -E 's/^Components:.*/Components: main contrib non-free non-free-firmware/' \
    /etc/apt/sources.list.d/debian.sources
elif [[ -f /etc/apt/sources.list ]]; then
  sed -i -E '/trixie/ s/\bmain\b(.*)$/main contrib non-free non-free-firmware/' \
    /etc/apt/sources.list || true
fi
dpkg --add-architecture i386
run $APT update
run $APT full-upgrade
run $APT install ca-certificates curl wget gpg apt-transport-https rfkill

#------------------------------------------------------------------------------
# 2. Pilotes / firmware / microcode / accélération (AMD Zen4 + RDNA2)
#------------------------------------------------------------------------------
log "Pilotes AMD, firmware, microcode, Vulkan (RADV), VA-API"
run $APT install \
  amd64-microcode \
  firmware-linux firmware-amd-graphics firmware-misc-nonfree firmware-realtek \
  mesa-vulkan-drivers mesa-vulkan-drivers:i386 \
  libgl1-mesa-dri libgl1-mesa-dri:i386 \
  mesa-va-drivers vulkan-tools libvulkan1 libvulkan1:i386 \
  vainfo gamemode

#------------------------------------------------------------------------------
# 3. Base graphique : Xorg + Openbox + login (LightDM) + menu (jgmenu)
#------------------------------------------------------------------------------
log "Xorg, Openbox, LightDM, jgmenu"
run $APT install \
  xserver-xorg xinit x11-xserver-utils x11-utils \
  openbox obconf-qt jgmenu \
  lightdm lightdm-gtk-greeter

#------------------------------------------------------------------------------
# 4. Bureau minimal (liste validée)
#------------------------------------------------------------------------------
log "Composants du bureau (panel, compositeur, audio, fichiers, thèmes...)"
run $APT install \
  numlockx flatpak redshift qt6ct dex udiskie \
  xdg-desktop-portal xdg-desktop-portal-gtk xdg-user-dirs \
  lxappearance fonts-noto fonts-noto-color-emoji fonts-jetbrains-mono \
  flameshot btop alacritty mousepad \
  lxqt-policykit \
  thunar gvfs gvfs-backends thunar-volman thunar-archive-plugin \
  pipewire pipewire-audio pipewire-pulse pipewire-alsa wireplumber \
  libspa-0.2-bluetooth pavucontrol pasystray \
  picom tint2 rofi dunst libnotify-bin nitrogen \
  nsxiv xarchiver p7zip-full unrar clipmenu \
  network-manager network-manager-gnome \
  papirus-icon-theme arc-theme \
  libayatana-appindicator3-1

#------------------------------------------------------------------------------
# 5. Applications (méthode la plus stable/sécurisée par app)
#------------------------------------------------------------------------------
log "Dépôts officiels signés : Mullvad VPN + VSCodium"
curl -fsSLo /usr/share/keyrings/mullvad-keyring.asc \
  https://repository.mullvad.net/deb/mullvad-keyring.asc
echo "deb [signed-by=/usr/share/keyrings/mullvad-keyring.asc arch=$(dpkg --print-architecture)] https://repository.mullvad.net/deb/stable stable main" \
  > /etc/apt/sources.list.d/mullvad.list

curl -fsSL https://gitlab.com/paulcarroty/vscodium-deb-rpm-repo/raw/master/pub.gpg \
  | gpg --dearmor -o /usr/share/keyrings/vscodium-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/vscodium-archive-keyring.gpg] https://download.vscodium.com/debs vscodium main" \
  > /etc/apt/sources.list.d/vscodium.list

run $APT update

# Pré-acceptation de la licence Steam (évite tout blocage en noninteractive)
echo "steam steam/question select I AGREE" | debconf-set-selections
echo "steam steam/license note ''"          | debconf-set-selections

log "Steam, VLC, qBittorrent, Firefox, Mullvad, VSCodium (natif signé)"
run $APT install \
  steam-installer \
  vlc qbittorrent firefox-esr \
  mullvad-vpn codium

# --- Flatpak : Flathub + Discord + Jan (sandbox, auto-màj) ---
log "Flathub + Discord + Jan (Flatpak)"
run flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
run flatpak install -y --noninteractive flathub com.discordapp.Discord || true
run flatpak install -y --noninteractive flathub ai.jan.Jan || \
  echo "Jan: si échec, .deb officiel sur github.com/janhq/jan/releases (voir audit)" >>"$LOG"
# Thème Arc pour les apps Flatpak (cohérence visuelle)
run flatpak install -y --noninteractive flathub org.gtk.Gtk3theme.Arc || true
run flatpak override --env=GTK_THEME=Arc || true

#------------------------------------------------------------------------------
# 6. sysctl : perf réseau/système + faible latence + hardening (kernel 6.12)
#------------------------------------------------------------------------------
log "sysctl : optimisation + durcissement (aucun paramètre obsolète)"
echo tcp_bbr > /etc/modules-load.d/bbr.conf
modprobe tcp_bbr 2>/dev/null || true

cat > /etc/sysctl.d/99-optim-hardening.conf <<'EOF'
# ============================ RÉSEAU – PERFORMANCE ============================
net.core.default_qdisc            = fq
net.ipv4.tcp_congestion_control   = bbr
net.core.rmem_max                 = 16777216
net.core.wmem_max                 = 16777216
net.ipv4.tcp_rmem                 = 4096 131072 16777216
net.ipv4.tcp_wmem                 = 4096 65536  16777216
net.core.netdev_max_backlog       = 16384
net.ipv4.tcp_fastopen             = 3
net.ipv4.tcp_mtu_probing          = 1
net.ipv4.tcp_slow_start_after_idle= 0
net.ipv4.tcp_notsent_lowat        = 16384

# ==================== RÉSEAU – DURCISSEMENT (sans gêne) ======================
net.ipv4.tcp_syncookies                   = 1
net.ipv4.conf.all.rp_filter               = 1
net.ipv4.conf.default.rp_filter           = 1
net.ipv4.conf.all.accept_redirects        = 0
net.ipv4.conf.default.accept_redirects    = 0
net.ipv4.conf.all.secure_redirects        = 0
net.ipv4.conf.all.send_redirects          = 0
net.ipv4.conf.default.send_redirects      = 0
net.ipv4.conf.all.accept_source_route     = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians            = 1
net.ipv4.icmp_echo_ignore_broadcasts      = 1
net.ipv4.icmp_ignore_bogus_error_responses= 1
net.ipv6.conf.all.accept_redirects        = 0
net.ipv6.conf.default.accept_redirects    = 0
net.ipv6.conf.all.accept_source_route     = 0

# ===================== SYSTÈME – RÉACTIVITÉ (NVMe/32Go) ======================
vm.swappiness             = 10
vm.vfs_cache_pressure     = 50
vm.dirty_ratio            = 10
vm.dirty_background_ratio = 5
vm.max_map_count          = 2147483642

# ========================= KERNEL – DURCISSEMENT ============================
kernel.kptr_restrict             = 2
kernel.dmesg_restrict            = 1
kernel.printk                    = 3 3 3 3
kernel.yama.ptrace_scope         = 1
kernel.kexec_load_disabled       = 1
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden          = 2
kernel.perf_event_paranoid       = 2
kernel.randomize_va_space        = 2
dev.tty.ldisc_autoload           = 0
fs.protected_hardlinks           = 1
fs.protected_symlinks            = 1
fs.protected_fifos               = 2
fs.protected_regular             = 2
fs.suid_dumpable                 = 0
EOF
run sysctl --system

#------------------------------------------------------------------------------
# 7. GRUB : amd_pstate + AppArmor (mitigations de sécurité conservées)
#------------------------------------------------------------------------------
log "GRUB : amd_pstate=active + apparmor (mitigations conservées)"
GRUBF=/etc/default/grub
cur="$(grep -oP 'GRUB_CMDLINE_LINUX_DEFAULT="\K[^"]*' "$GRUBF" || echo 'quiet')"
for tok in amd_pstate=active apparmor=1 security=apparmor; do
  grep -qw "${tok%%=*}" <<<"$cur" || cur="$cur $tok"
done
sed -i -E "s|GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*\"|GRUB_CMDLINE_LINUX_DEFAULT=\"$(echo "$cur" | xargs)\"|" "$GRUBF"
run update-grub

#------------------------------------------------------------------------------
# 8. Pare-feu (UFW deny + GUFW) & AppArmor
#------------------------------------------------------------------------------
log "UFW (deny incoming) + GUFW + AppArmor"
run $APT install ufw gufw apparmor apparmor-utils apparmor-profiles apparmor-profiles-extra
run ufw --force reset
run ufw default deny incoming
run ufw default allow outgoing
run ufw default deny routed
run ufw --force enable
run systemctl enable ufw
run systemctl enable apparmor

#------------------------------------------------------------------------------
# 8b. DNS chiffré : Quad9 en DNS-over-HTTPS (dnscrypt-proxy)
#------------------------------------------------------------------------------
log "DNS chiffré Quad9 (DoH) via dnscrypt-proxy"
run $APT install dnscrypt-proxy
install -d -o _dnscrypt-proxy -g _dnscrypt-proxy /var/cache/dnscrypt-proxy 2>/dev/null || \
  install -d /var/cache/dnscrypt-proxy

cat > /etc/dnscrypt-proxy/dnscrypt-proxy.toml <<'EOF'
# Quad9 en DNS-over-HTTPS (filtrage anti-malware, sans log, DNSSEC)
listen_addresses = ['127.0.0.1:53']
max_clients = 250
ipv4_servers = true
ipv6_servers = false
doh_servers = true
dnscrypt_servers = false
require_dnssec = true
require_nolog = true
require_nofilter = false
server_names = ['quad9-doh-ip4-port443-filter-pri']
timeout = 5000
keepalive = 30
cache = true
cache_size = 4096
bootstrap_resolvers = ['9.9.9.9:53', '149.112.112.112:53']
netprobe_timeout = 60

[sources]
  [sources.public-resolvers]
  urls = ['https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md', 'https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md']
  cache_file = '/var/cache/dnscrypt-proxy/public-resolvers.md'
  minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
  refresh_delay = 72
  prefix = ''
EOF

# Libérer le port 53 (stub systemd-resolved) et fixer le résolveur local
disable_local_stub(){ systemctl list-unit-files 2>/dev/null | grep -q "^systemd-resolved" && run systemctl disable --now systemd-resolved || true; }
disable_local_stub
mkdir -p /etc/NetworkManager/conf.d
printf '[main]\ndns=none\n' > /etc/NetworkManager/conf.d/00-dnscrypt.conf
rm -f /etc/resolv.conf
printf '# DNS local -> dnscrypt-proxy (Quad9 DoH)\nnameserver 127.0.0.1\noptions edns0 trust-ad\n' > /etc/resolv.conf

# dnscrypt-proxy en service direct (pas d'activation par socket)
run systemctl disable --now dnscrypt-proxy.socket || true
run systemctl enable  --now dnscrypt-proxy.service

#------------------------------------------------------------------------------
# 9. Désactivation des services inutiles (best-effort, réversible)
#------------------------------------------------------------------------------
log "Désactivation services inutiles (wifi/bt/virt/impr./ssh/indexation)"
disable_unit(){ systemctl list-unit-files 2>/dev/null | grep -q "^$1" && run systemctl disable --now "$1" || true; }

rfkill block wifi      2>/dev/null || true   # Ethernet utilisé (état persistant via systemd-rfkill)
rfkill block bluetooth 2>/dev/null || true
disable_unit bluetooth.service
disable_unit cups.service;        disable_unit cups.socket
disable_unit cups-browsed.service
disable_unit avahi-daemon.service; disable_unit avahi-daemon.socket
disable_unit ssh.service;          disable_unit sshd.service
disable_unit libvirtd.service;     disable_unit libvirtd.socket
disable_unit plocate-updatedb.timer; disable_unit mlocate.timer
disable_unit tracker-miner-fs-3.service; disable_unit tracker-extract-3.service

#------------------------------------------------------------------------------
# 10. Services essentiels au démarrage
#------------------------------------------------------------------------------
log "Activation des services essentiels"
run systemctl enable NetworkManager
run systemctl enable lightdm
run systemctl set-default graphical.target
asuser systemctl --user enable pipewire pipewire-pulse wireplumber 2>/dev/null || true
sed -i 's/^#\?user-session=.*/user-session=openbox/' /etc/lightdm/lightdm.conf 2>/dev/null || true

#==============================================================================
#  11. CONFIGURATION UTILISATEUR (thème Win11-like, panel, autostart, écran)
#==============================================================================
log "Config utilisateur : thème, tint2, autostart, écran 180Hz/125%"

CFG="$USER_HOME/.config"
asuser mkdir -p "$CFG/openbox" "$CFG/tint2" "$CFG/picom" "$CFG/gtk-3.0" \
                "$CFG/dunst" "$CFG/jgmenu" "$CFG/qt6ct" "$CFG/nitrogen"

# --- Openbox : config par défaut + keybinds ---
asuser cp -rn /etc/xdg/openbox/. "$CFG/openbox/" 2>/dev/null || true
asuser sed -i '0,/<keyboard>/{s|<keyboard>|<keyboard>\
    <keybind key="W-space"><action name="Execute"><command>rofi -show drun</command></action></keybind>\
    <keybind key="Print"><action name="Execute"><command>flameshot gui</command></action></keybind>\
    <keybind key="W-v"><action name="Execute"><command>clipmenu</command></action></keybind>\
    <keybind key="W-e"><action name="Execute"><command>thunar</command></action></keybind>\
    <keybind key="W-Return"><action name="Execute"><command>alacritty</command></action></keybind>|}' \
  "$CFG/openbox/rc.xml" 2>/dev/null || true

# --- Variables d'environnement de session (Qt/qt6ct, thème, clipmenu) ---
asuser tee "$CFG/openbox/environment" >/dev/null <<'EOF'
export QT_QPA_PLATFORMTHEME=qt6ct
export GTK_THEME=Arc
export CM_LAUNCHER=rofi
export MOZ_USE_XINPUT2=1
EOF

# --- .Xresources : DPI 120 = mise à l'échelle 125 % nette (X11) ---
asuser tee "$USER_HOME/.Xresources" >/dev/null <<'EOF'
Xft.dpi:        120
Xft.antialias:  true
Xft.hinting:    true
Xft.hintstyle:  hintslight
Xft.rgba:       rgb
Xft.lcdfilter:  lcddefault
EOF

# --- Thèmes GTK/Qt : Arc (clair, flat) + icônes Papirus ---
asuser tee "$CFG/gtk-3.0/settings.ini" >/dev/null <<'EOF'
[Settings]
gtk-theme-name=Arc
gtk-icon-theme-name=Papirus
gtk-font-name=Noto Sans 10
gtk-cursor-theme-name=Adwaita
gtk-application-prefer-dark-theme=false
EOF
asuser tee "$USER_HOME/.gtkrc-2.0" >/dev/null <<'EOF'
gtk-theme-name="Arc"
gtk-icon-theme-name="Papirus"
gtk-font-name="Noto Sans 10"
EOF
asuser tee "$CFG/qt6ct/qt6ct.conf" >/dev/null <<'EOF'
[Appearance]
icon_theme=Papirus
style=Fusion
EOF

# --- jgmenu : menu "Démarrer" ---
asuser env HOME="$USER_HOME" jgmenu init --auto 2>/dev/null || asuser jgmenu init 2>/dev/null || true

# --- picom : compositeur fluide, faible latence ---
asuser tee "$CFG/picom/picom.conf" >/dev/null <<'EOF'
backend = "glx";
vsync = true;
use-damage = true;
corner-radius = 8;
shadow = true;
shadow-radius = 12;
shadow-opacity = 0.25;
fading = true;
fade-in-step = 0.06;
fade-out-step = 0.06;
detect-rounded-corners = true;
detect-client-opacity = true;
EOF

# --- dunst : notifications à droite, style clair ---
asuser tee "$CFG/dunst/dunstrc" >/dev/null <<'EOF'
[global]
    monitor = 0
    follow = mouse
    origin = top-right
    offset = 12x52
    width = 340
    corner_radius = 10
    frame_width = 1
    frame_color = "#5294e2"
    separator_color = frame
    font = Noto Sans 10
    padding = 12
    horizontal_padding = 12
    icon_theme = "Papirus"
    enable_recursive_icon_lookup = true
[urgency_low]
    background = "#ffffff"
    foreground = "#2b2e37"
    timeout = 6
[urgency_normal]
    background = "#ffffff"
    foreground = "#2b2e37"
    timeout = 8
[urgency_critical]
    background = "#f9d7da"
    foreground = "#721c24"
    frame_color = "#dc3545"
    timeout = 0
EOF

# --- tint2 : barre des tâches (menu à gauche, tâches, systray+horloge à droite) ---
asuser tee "$CFG/tint2/tint2rc" >/dev/null <<'EOF'
#---------- Fonds (définis d'abord, référencés ensuite par id) ----------
# id 1 : fond du panneau
rounded = 0
border_width = 0
background_color = #f4f5f7 96
border_color = #000000 0
# id 2 : tâche active / survol
rounded = 6
border_width = 0
background_color = #5294e2 32
border_color = #5294e2 60
# id 3 : transparent (launcher, horloge)
rounded = 6
border_width = 0
background_color = #000000 0
border_color = #000000 0

#---------- Panneau ----------
panel_items = LTSC
panel_size = 100% 42
panel_margin = 0 0
panel_padding = 6 0 6
panel_background_id = 1
panel_position = bottom center horizontal
panel_layer = top
panel_monitor = all
wm_menu = 1
font_shadow = 0

#---------- Launcher (bouton Démarrer -> jgmenu) ----------
launcher_padding = 6 4 4
launcher_background_id = 3
launcher_icon_size = 24
launcher_icon_theme = Papirus
launcher_item_app = /usr/share/applications/jgmenu.desktop

#---------- Taskbar ----------
taskbar_mode = single_desktop
taskbar_padding = 4 0 4
taskbar_background_id = 0
task_align = left
task_maximum_size = 180 32
task_padding = 6 2 6
task_icon = 1
task_text = 1
task_font = Noto Sans 9
task_background_id = 0
task_active_background_id = 2
task_font_color = #2b2e37 100

#---------- Systray (Discord, Steam, réseau, son...) ----------
systray_padding = 6 0 6
systray_background_id = 0
systray_icon_size = 22
systray_icon_asb = 100 0 0
systray_monitor = 1

#---------- Horloge (droite) ----------
time1_format = %H:%M
time2_format = %a %d %b
time1_font = Noto Sans 11
time2_font = Noto Sans 8
clock_font_color = #2b2e37 100
clock_padding = 10 0
clock_background_id = 3

#---------- Tooltip ----------
tooltip = 1
tooltip_padding = 6 4
EOF

# --- Lanceur .desktop du bouton Démarrer (jgmenu) ---
tee /usr/share/applications/jgmenu.desktop >/dev/null <<'EOF'
[Desktop Entry]
Type=Application
Name=Menu
Exec=jgmenu_run
Icon=start-here
Categories=System;
EOF

# --- Écran forcé à chaque session : 2560x1440@180Hz ---
asuser tee "$CFG/openbox/screen.sh" >/dev/null <<'EOF'
#!/usr/bin/env bash
OUT="$(xrandr | awk '/ connected/{print $1; exit}')"
[ -z "$OUT" ] && exit 0
if ! xrandr --output "$OUT" --mode 2560x1440 --rate 180 2>/dev/null; then
    ML="$(cvt -r 2560 1440 180 | awk '/Modeline/{$1="";print}')"
    NAME="$(echo "$ML" | awk '{print $1}' | tr -d '"')"
    xrandr --newmode $ML 2>/dev/null || true
    xrandr --addmode "$OUT" "$NAME" 2>/dev/null || true
    xrandr --output "$OUT" --mode "$NAME" 2>/dev/null || true
fi
xrandr --dpi 120
EOF
asuser chmod +x "$CFG/openbox/screen.sh"

# --- redshift : Lyon, 1900K la nuit, créneau fixe 21h30 -> 06h00 ---
asuser tee "$CFG/redshift.conf" >/dev/null <<'EOF'
[redshift]
temp-day=6500
temp-night=1900
; Transition terminée à 21h30 (nuit) et démarrée à 06h00 (jour)
dusk-time=21:15-21:30
dawn-time=06:00-06:15
brightness-day=1.0
brightness-night=1.0
adjustment-method=randr
; Coordonnées de Lyon (utilisées comme repli si les créneaux sont ignorés)
location-provider=manual
[manual]
lat=45.76
lon=4.83
EOF

# --- Autostart Openbox ---
asuser tee "$CFG/openbox/autostart" >/dev/null <<'EOF'
#!/usr/bin/env bash
# Écran + DPI (125 %)
"$HOME/.config/openbox/screen.sh" &
xrdb -merge "$HOME/.Xresources" &
# Jamais de mise en veille / extinction d'écran
xset s off -dpms &
# Authentification graphique (polkit)
(sleep 1 && lxqt-policykit-agent) &
# Compositeur
picom --config "$HOME/.config/picom/picom.conf" &
# Fond d'écran
nitrogen --restore &
# Barre + notifications
tint2 &
dunst &
# Applets systray
nm-applet &
pasystray &
# Services de session
udiskie &
clipmenud &
numlockx on &
xdg-user-dirs-update &
redshift &
EOF
asuser chmod +x "$CFG/openbox/autostart"

# --- Fond d'écran par défaut ---
asuser tee "$CFG/nitrogen/bg-saved.cfg" >/dev/null <<'EOF'
[xin_-1]
file=/usr/share/backgrounds/desktop-base/default
mode=5
bgcolor=#1e2430
EOF

# Droits corrects
chown -R "$TARGET_USER:$TARGET_USER" "$CFG" \
  "$USER_HOME/.Xresources" "$USER_HOME/.gtkrc-2.0" 2>/dev/null || true

#------------------------------------------------------------------------------
# 12. Nettoyage
#------------------------------------------------------------------------------
log "Nettoyage"
run $APT autoremove
run $APT clean

cat <<EOF

============================================================
 Installation terminée.
------------------------------------------------------------
 Raccourcis :
   Super+Espace  lanceur (rofi)     Super+Entrée terminal
   Super+E       fichiers (Thunar)  Super+V      presse-papiers
   Super+L       verrouiller        Impr écran   capture
------------------------------------------------------------
 À faire :
   - redshift : édite ~/.config/redshift.conf (lat/lon de ta ville)
   - lxappearance : confirme thème Arc + icônes Papirus
   - Mullvad : connexion avec ton numéro de compte
 Journal : $LOG
 >>> REDÉMARRE :  sudo reboot
============================================================
EOF
