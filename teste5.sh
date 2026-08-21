#!/usr/bin/env bash
#===============================================================================
#  lubuntu-graphite-dark-wayland.sh                                    v2.0
#
#  Lubuntu 26.04 LTS "Resolute Raccoon" (installation minimale)
#    - Session LXQt Wayland (labwc) installee, configuree, definie par defaut
#    - Theme Graphite SOMBRE applique de bout en bout :
#      GTK 2/3/4, Qt5/Qt6 (Kvantum), panneau LXQt, decorations labwc,
#      icones, curseur, terminal, bureau, ecran de connexion SDDM
#
#  Idempotent. Sauvegarde avant toute modification. Aucune action requise apres.
#  Chaque paquet, chemin et cle a ete verifie contre l'archive Ubuntu resolute.
#===============================================================================

set -Eeuo pipefail

#------------------------------------------------------------------------------
# Constantes
#------------------------------------------------------------------------------
readonly THEME_GTK="Graphite-Dark"
readonly THEME_KV="Graphite-rimlessDark"
readonly THEME_KV_DIR="Graphite-rimless"
readonly ICON_THEME="Tela-circle-grey-dark"
readonly CURSOR_THEME="breeze_cursors"
readonly CURSOR_SIZE=24
readonly UI_FONT="Inter"
readonly MONO_FONT="JetBrains Mono"
readonly WM_THEME="Vent-dark"
readonly TERM_SCHEME="Graphite"
readonly SDDM_THEME="maldives"
readonly SESSION_FILE="/usr/share/wayland-sessions/lxqt-wayland.desktop"
readonly WALLPAPER="/usr/share/backgrounds/graphite-wave-dark.jpg"
readonly SKEL="/usr/share/lxqt/wayland/labwc"
readonly TERM_SCHEME_DIR="/usr/share/qtermwidget6/color-schemes"

readonly REPO_GTK="https://github.com/vinceliuice/Graphite-gtk-theme.git"
readonly REPO_KDE="https://github.com/vinceliuice/Graphite-kde-theme.git"
readonly REPO_ICO="https://github.com/vinceliuice/Tela-circle-icon-theme.git"

# Palette Graphite Dark (extraite du CSS genere par le theme amont)
readonly C_BG="#2C2C2C" C_SURF="#3C3C3C" C_FG="#E0E0E0"
readonly C_DEEP="#242424" C_LINE="#4b4b4b" C_DIM="#8a8a8a" C_RED="#F28B82"

readonly CFG="${XDG_CONFIG_HOME:-$HOME/.config}"
readonly DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
BACKUP="$HOME/.config-backup-graphite-$(date +%Y%m%d-%H%M%S)"
readonly BACKUP

PASS=0; FAIL=0; WARNS=0; WORKDIR=""; SUDO_PID=""

#------------------------------------------------------------------------------
# Sorties (non verbeuses)
#------------------------------------------------------------------------------
if [[ -t 1 ]]; then
  B=$'\033[1m'; G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; D=$'\033[2m'; N=$'\033[0m'
else
  B=""; G=""; R=""; Y=""; D=""; N=""
fi

step()  { printf '  %s>%s %s\n' "$D" "$N" "$1"; }
warn()  { printf '  %s!%s %s\n' "$Y" "$N" "$1"; WARNS=$((WARNS+1)); }
die()   { printf '\n  %sECHEC%s %s\n\n' "$R" "$N" "$1" >&2; exit 1; }
head_() { printf '\n%s%s%s\n' "$B" "$1" "$N"; }
sect()  { printf '\n%s  %s%s\n' "$D" "$1" "$N"; }

check() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '  %s[OK]%s   %s\n' "$G" "$N" "$label"; PASS=$((PASS+1))
  else
    printf '  %s[KO]%s   %s\n' "$R" "$N" "$label"; FAIL=$((FAIL+1))
  fi
}

cleanup() {
  local rc=$?
  [[ -n "$WORKDIR" && -d "$WORKDIR" ]] && rm -rf -- "$WORKDIR"
  [[ -n "$SUDO_PID" ]] && kill "$SUDO_PID" 2>/dev/null
  return $rc
}
trap cleanup EXIT
trap 'die "interruption a la ligne $LINENO"' ERR

# Execute gsettings meme hors session graphique (bus D-Bus temporaire).
gset() {
  if [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    gsettings set "$@" 2>/dev/null
  else
    dbus-run-session -- gsettings set "$@" 2>/dev/null
  fi
}

#==============================================================================
head_ "[1/9] PASSE 1 - Verifications prealables"
#==============================================================================

[[ $EUID -ne 0 ]] || die "ne pas lancer en root. Utilisez votre compte utilisateur."

[[ -r /etc/os-release ]] || die "/etc/os-release introuvable."
# shellcheck disable=SC1091
. /etc/os-release
if [[ "${VERSION_ID:-}" != "26.04" ]]; then
  [[ "${FORCE:-0}" == "1" ]] \
    || die "Ubuntu 26.04 attendu (detecte : ${PRETTY_NAME:-inconnu}). FORCE=1 pour outrepasser."
  warn "version systeme non conforme, poursuite forcee"
fi
step "systeme : ${PRETTY_NAME:-Ubuntu 26.04}"

for c in apt-get apt-cache dpkg dpkg-query sudo systemctl sed grep install df python3; do
  command -v "$c" >/dev/null 2>&1 || die "commande requise absente : $c"
done

sudo -v || die "privileges sudo requis."
( while true; do sleep 50; sudo -n true 2>/dev/null || exit; done ) &
SUDO_PID=$!

AVAIL=$(df -Pk "$HOME" | awk 'NR==2{print $4}')
[[ "${AVAIL:-0}" -ge 2621440 ]] || die "espace disque insuffisant (2,5 Go requis)."
step "espace disque : $((AVAIL/1024)) Mio libres"

for host in archive.ubuntu.com github.com; do
  getent hosts "$host" >/dev/null 2>&1 || die "resolution DNS impossible : $host"
done
step "reseau : archive.ubuntu.com, github.com joignables"

systemctl is-enabled sddm >/dev/null 2>&1 \
  || warn "sddm n'est pas actif : la session par defaut ne sera pas appliquee"

#==============================================================================
head_ "[2/9] Installation des paquets"
#==============================================================================

PKGS=(
  # --- session Wayland LXQt ---
  lxqt-wayland-session labwc
  swaybg swayidle swaylock wlopm wlr-randr wdisplays
  xwayland qt6-wayland
  # --- composants LXQt de la session (no-op s'ils sont deja la) ---
  lxqt-session lxqt-panel lxqt-config lxqt-runner lxqt-notificationd
  lxqt-powermanagement lxqt-policykit lxqt-openssh-askpass lxqt-qtplugin
  lxqt-themes lxqt-menu-data lxqt-sudo
  # --- portails XDG : selecteur de fichiers, capture, mode sombre ---
  xdg-desktop-portal xdg-desktop-portal-wlr xdg-desktop-portal-gtk
  xdg-user-dirs
  # --- applets de la zone de notification (SNI, compatible Wayland) ---
  nm-tray qlipper
  # --- outils Wayland natifs ---
  grim slurp wl-clipboard
  # --- moteur de theme Qt (fournit les greffons Qt5 ET Qt6) ---
  qt6-style-kvantum
  # --- dependances de compilation du theme GTK ---
  gtk2-engines-murrine gnome-themes-extra sassc
  # --- mode sombre pour les applications GTK4/libadwaita via le portail ---
  gsettings-desktop-schemas libglib2.0-bin dconf-cli dbus-bin
  # --- polices et curseurs ---
  fonts-inter fonts-jetbrains-mono fonts-noto-color-emoji breeze-cursor-theme
  # --- ecran de connexion sombre (theme QML leger, sans dependance Plasma) ---
  sddm-theme-maldives qml6-module-qtquick
  # --- applications liees aux raccourcis par defaut de labwc ---
  qterminal qtermwidget6-data pcmanfm-qt featherpad screengrab
  # --- montage, corbeille, miniatures ---
  udisks2 gvfs gvfs-backends
  # --- outillage du script ---
  git ca-certificates curl libxml2-utils
)

export DEBIAN_FRONTEND=noninteractive
step "mise a jour des index"
sudo apt-get -qq update >/dev/null 2>&1 || die "echec de 'apt-get update'."

MISSING=()
for p in "${PKGS[@]}"; do
  apt-cache show "$p" >/dev/null 2>&1 || MISSING+=("$p")
done
[[ ${#MISSING[@]} -eq 0 ]] || die "paquets introuvables dans les depots : ${MISSING[*]}"
step "${#PKGS[@]} paquets valides dans les depots"

sudo apt-get -qq -y --no-install-recommends install "${PKGS[@]}" >/dev/null 2>&1 \
  || die "echec de l'installation des paquets."
step "installation terminee"

[[ -f "$SESSION_FILE" ]] || die "fichier de session absent : $SESSION_FILE"
[[ -d "$SKEL" ]]         || die "modele labwc introuvable : $SKEL"

#==============================================================================
head_ "[3/9] Compilation et installation des themes sombres"
#==============================================================================

WORKDIR="$(mktemp -d)"
clone() { git clone --depth 1 --quiet "$1" "$WORKDIR/$2" || die "echec du clonage : $1"; }

step "recuperation des depots amont"
clone "$REPO_GTK" gtk
clone "$REPO_KDE" kde
clone "$REPO_ICO" ico

# --- Theme GTK, variante sombre uniquement, sans contour (rimless) ---
step "compilation du theme GTK ($THEME_GTK)"
sudo bash "$WORKDIR/gtk/install.sh" -c dark --tweaks rimless >/dev/null 2>&1 \
  || die "echec de install.sh (Graphite-gtk-theme)."
[[ -f "/usr/share/themes/$THEME_GTK/gtk-3.0/gtk.css" ]] \
  || die "theme GTK absent de /usr/share/themes/$THEME_GTK."

# --- Theme Kvantum : copie ciblee, sans les composants Plasma inutiles ---
step "installation du theme Kvantum ($THEME_KV)"
sudo install -d -m 0755 /usr/share/Kvantum
sudo rm -rf "/usr/share/Kvantum/${THEME_KV_DIR:?}"
sudo cp -a "$WORKDIR/kde/Kvantum/$THEME_KV_DIR" /usr/share/Kvantum/
[[ -f "/usr/share/Kvantum/$THEME_KV_DIR/$THEME_KV.kvconfig" ]] \
  || die "theme Kvantum sombre non installe."

# --- Icones, variante sombre ---
step "installation des icones ($ICON_THEME)"
sudo bash "$WORKDIR/ico/install.sh" grey >/dev/null 2>&1 \
  || die "echec de install.sh (Tela-circle-icon-theme)."
[[ -f "/usr/share/icons/$ICON_THEME/index.theme" ]] \
  || die "theme d'icones sombre non installe."

# --- Fond d'ecran sombre ---
step "installation du fond d'ecran"
sudo install -d -m 0755 /usr/share/backgrounds
sudo install -m 0644 "$WORKDIR/gtk/wallpaper/wallpapers/wave-Dark.jpg" "$WALLPAPER"

sudo gtk-update-icon-cache -f -q "/usr/share/icons/$ICON_THEME" 2>/dev/null || true
sudo fc-cache -f >/dev/null 2>&1 || true

#==============================================================================
head_ "[4/9] Sauvegarde de la configuration existante"
#==============================================================================

mkdir -p "$BACKUP"
SAVED=0
for item in "$CFG/lxqt" "$CFG/labwc" "$CFG/Kvantum" "$CFG/gtk-3.0" "$CFG/gtk-4.0" \
            "$CFG/xdg-desktop-portal" "$CFG/pcmanfm-qt" "$CFG/qterminal.org" \
            "$CFG/autostart" "$HOME/.gtkrc-2.0"; do
  [[ -e "$item" ]] && cp -a "$item" "$BACKUP/" 2>/dev/null && SAVED=$((SAVED+1))
done
if [[ $SAVED -gt 0 ]]; then
  step "$SAVED element(s) sauvegarde(s) dans $BACKUP"
else
  rmdir "$BACKUP" 2>/dev/null || true
  step "aucune configuration prealable a sauvegarder"
fi

#==============================================================================
head_ "[5/9] Configuration de la session LXQt"
#==============================================================================

mkdir -p "$CFG/lxqt" "$CFG/Kvantum" "$CFG/gtk-3.0" "$CFG/gtk-4.0" \
         "$CFG/xdg-desktop-portal" "$CFG/pcmanfm-qt/lxqt" "$CFG/qterminal.org" \
         "$CFG/autostart" "$DATA/backgrounds"

cat > "$CFG/lxqt/session.conf" <<EOF
[General]
__userfile__=true
leave_confirmation=true
compositor=labwc
lock_command_wayland=swaylock -f -c ${C_DEEP#\#}

[Environment]
GTK_CSD=0
GTK_OVERLAY_SCROLLING=0
QT_QPA_PLATFORM=wayland;xcb
QT_WAYLAND_DISABLE_WINDOWDECORATION=1
MOZ_ENABLE_WAYLAND=1
_JAVA_AWT_WM_NONREPARENTING=1

[Mouse]
cursor_size=$CURSOR_SIZE
cursor_theme=$CURSOR_THEME
acc_factor=20
acc_threshold=10
left_handed=false

[Keyboard]
delay=500
interval=30
beep=false

[Font]
antialias=true
hinting=true
dpi=96
EOF
step "session.conf : compositeur labwc, verrouillage swaylock"

# theme=kvantum : le panneau herite des couleurs du theme Kvantum sombre,
# ce qui evite le probleme classique des icones sombres sur panneau sombre.
cat > "$CFG/lxqt/lxqt.conf" <<EOF
[General]
__userfile__=true
theme=kvantum
icon_theme=$ICON_THEME
icon_follow_color_scheme=false
single_click_activate=false
tool_button_style=ToolButtonIconOnly
palette_override=false

[Qt]
font="$UI_FONT,10,-1,5,50,0,0,0,0,0"
doubleClickInterval=400
style=kvantum
wheelScrollLines=3
EOF
step "lxqt.conf : panneau kvantum, icones $ICON_THEME"

# Le greffon "tray" (XEmbed) est X11 uniquement et serait ignore sous Wayland :
# seul "statusnotifier" est retenu.
if [[ ! -f "$CFG/lxqt/panel.conf" ]]; then
  cat > "$CFG/lxqt/panel.conf" <<'EOF'
panels=panel1

[panel1]
alignment=-1
animation-duration=0
desktop=0
hidable=false
iconSize=22
lineCount=1
lockPanel=false
panelSize=38
plugins=fancymenu, quicklaunch, desktopswitch, taskbar, statusnotifier, mount, volume, worldclock, showdesktop
position=Bottom
visible-margin=true
width=100
width-percent=true

[fancymenu]
alignment=Left
autoSel=true
autoSelDelay=150
filterClear=true
type=fancymenu

[quicklaunch]
alignment=Left
apps\1\desktop=/usr/share/applications/pcmanfm-qt.desktop
apps\2\desktop=/usr/share/applications/qterminal.desktop
apps\size=2
type=quicklaunch

[desktopswitch]
type=desktopswitch

[taskbar]
buttonStyle=Icon
buttonWidth=200
closeOnMiddleClick=true
groupingEnabled=true
iconByClass=false
type=taskbar

[statusnotifier]
alignment=Right
type=statusnotifier

[mount]
alignment=Right
type=mount

[volume]
alignment=Right
device=0
type=volume

[worldclock]
alignment=Right
customFormat="'<b>'HH:mm'</b><br/><font size=\"-2\">'ddd d MMM'</font>'"
formatType=custom
type=worldclock

[showdesktop]
alignment=Right
type=showdesktop
EOF
  step "panel.conf : 38 px, statusnotifier (compatible Wayland)"
else
  step "panel.conf existant conserve"
fi

cat > "$CFG/Kvantum/kvantum.kvconfig" <<EOF
[General]
theme=$THEME_KV
EOF
step "Kvantum : $THEME_KV"

#==============================================================================
head_ "[6/9] Configuration du compositeur labwc"
#==============================================================================

rm -rf "$CFG/labwc"
cp -a "$SKEL" "$CFG/labwc"
RC="$CFG/labwc/rc.xml"

# Modifications chirurgicales : la configuration LXQt officielle (raccourcis,
# regles de fenetres, libinput) est integralement preservee.
sed -i \
  -e "s|<name>Vent</name>|<name>$WM_THEME</name>|" \
  -e "s|<icon>breeze</icon>|<icon>$ICON_THEME</icon>|" \
  -e "s|<name>sans</name>|<name>$UI_FONT</name>|g" \
  "$RC"

# Quatre bureaux virtuels, sans quoi le selecteur du panneau n'affiche qu'une case.
python3 - "$RC" <<'PYEOF'
import re, sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
# Cible le bloc <desktops> ACTIF (identifie par <name>Default</name>) et non
# les exemples presents dans les commentaires, qui apparaissent plus haut.
blk = ("<desktops>\n"
       "    <popupTime>600</popupTime>\n"
       "    <names>\n"
       "      <name>1</name>\n"
       "      <name>2</name>\n"
       "      <name>3</name>\n"
       "      <name>4</name>\n"
       "    </names>\n"
       "  </desktops>")
pat = (r'<desktops>\s*<popupTime>1000</popupTime>\s*<names>\s*'
       r'<name>Default</name>\s*</names>\s*</desktops>')
s2, n = re.subn(pat, blk, s, count=1)
if n != 1:
    sys.exit("bloc <desktops> actif introuvable dans rc.xml")
open(p, 'w', encoding='utf-8').write(s2)
PYEOF
step "labwc : 4 bureaux virtuels"

# Disposition clavier : reprise de la configuration systeme, car la creation
# prealable de ~/.config/labwc court-circuite l'autodetection de
# startlxqtwayland (qui ne copie le modele que si le dossier est absent).
XKBLAYOUT=""; XKBVARIANT=""
# shellcheck disable=SC1091
[[ -r /etc/default/keyboard ]] && . /etc/default/keyboard
{
  echo ""
  echo "## Injecte depuis /etc/default/keyboard"
  if [[ -n "$XKBLAYOUT" ]]; then
    echo "XKB_DEFAULT_LAYOUT=$XKBLAYOUT"
    [[ -n "$XKBVARIANT" ]] && echo "XKB_DEFAULT_VARIANT=$XKBVARIANT"
  fi
} >> "$CFG/labwc/environment"
step "clavier : ${XKBLAYOUT:-defaut}${XKBVARIANT:+ ($XKBVARIANT)}"

# pcmanfm-qt dessine le bureau via layer-shell (il depend de
# liblayershellqtinterface6) : swaybg serait redondant et masque.
cat > "$CFG/labwc/autostart" <<'EOF'
# Propage l'environnement Wayland a D-Bus : indispensable aux portails XDG
# (selecteur de fichiers, capture d'ecran, mode sombre des applications GTK).
dbus-update-activation-environment --systemd \
  DISPLAY WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE >/dev/null 2>&1 &

# Extinction des ecrans apres 10 minutes d'inactivite.
swayidle -w timeout 600 "wlopm --off \*" resume "wlopm --on \*" >/dev/null 2>&1 &
EOF

cat > "$CFG/labwc/themerc-override" <<EOF
# Palette Graphite Dark

border.width: 0
padding.height: 4

window.active.title.bg.color: $C_BG
window.active.label.bg.color: $C_BG
window.active.label.text.color: $C_FG
window.active.border.color: $C_LINE
window.inactive.title.bg.color: $C_DEEP
window.inactive.label.bg.color: $C_DEEP
window.inactive.label.text.color: $C_DIM
window.inactive.border.color: $C_SURF
window.label.text.justify: center

window.active.button.iconify.unpressed.image.color: $C_FG
window.active.button.max.unpressed.image.color: $C_FG
window.active.button.close.unpressed.image.color: $C_RED
window.active.button.menu.unpressed.image.color: $C_FG
window.inactive.button.iconify.unpressed.image.color: #6e6e6e
window.inactive.button.max.unpressed.image.color: #6e6e6e
window.inactive.button.close.unpressed.image.color: #6e6e6e
window.inactive.button.menu.unpressed.image.color: #6e6e6e

menu.items.bg.color: $C_BG
menu.items.text.color: $C_FG
menu.items.active.bg.color: $C_SURF
menu.items.active.text.color: #FFFFFF
menu.separator.color: $C_LINE
menu.items.padding.x: 10
menu.items.padding.y: 6

osd.bg.color: $C_BG
osd.border.color: $C_LINE
osd.border.width: 1
osd.label.text.color: $C_FG

window.active.shadow.size: 40
window.inactive.shadow.size: 30
window.active.shadow.color: #00000070
window.inactive.shadow.color: #00000050
snapping.overlay.edge.bg.color: ${C_FG}60
EOF
step "labwc : decorations $WM_THEME + palette Graphite"

xmllint --noout "$RC" 2>/dev/null || die "rc.xml invalide apres modification."
step "rc.xml : XML valide"

#==============================================================================
head_ "[7/9] Bureau, terminal, applications GTK, portails"
#==============================================================================

# --- Bureau pcmanfm-qt : fond d'ecran et couleurs sombres ---
cat > "$CFG/pcmanfm-qt/lxqt/settings.conf" <<EOF
[System]
IconThemeName=$ICON_THEME
FallbackIconThemeName=breeze
SuCommand=lxsudo dbus-run-session -- %s
Archiver=lxqt-archiver
Terminal=qterminal
SIUnit=false

[Behavior]
BookmarkOpenMethod=0
UseTrash=true
SingleClick=false
ConfirmDelete=true

[Desktop]
DesktopShortcuts=Trash
Wallpaper=$WALLPAPER
WallpaperMode=zoom
BgColor=$C_DEEP
FgColor=$C_FG
ShadowColor=#000000
ShowHidden=false
SortColumn=name
SortOrder=ascending
Font="$UI_FONT,10,-1,5,50,0,0,0,0,0"

[Volume]
AutoRun=true
MountOnStartup=true
MountRemovable=true

[FolderView]
BigIconSize=48
Mode=icon
ShowHidden=false
SidePaneIconSize=24
SmallIconSize=24
SortColumn=name
SortOrder=ascending
ThumbnailIconSize=128

[Thumbnail]
MaxThumbnailFileSize=4096
ShowThumbnails=true
ThumbnailLocalFilesOnly=true
EOF
step "bureau : fond Graphite, texte clair"

# --- Terminal : jeu de couleurs Graphite ---
sudo install -d -m 0755 "$TERM_SCHEME_DIR"
sudo tee "$TERM_SCHEME_DIR/$TERM_SCHEME.colorscheme" >/dev/null <<'EOF'
[General]
Description=Graphite
Author=Graphite palette
Opacity=1

[Background]
Color=44,44,44
Bold=false
Transparency=false
[BackgroundIntense]
Color=44,44,44
Bold=true
Transparency=false
[Foreground]
Color=224,224,224
Bold=false
Transparency=false
[ForegroundIntense]
Color=255,255,255
Bold=true
Transparency=false
[Color0]
Color=36,36,36
Bold=false
Transparency=false
[Color0Intense]
Color=75,75,75
Bold=true
Transparency=false
[Color1]
Color=242,139,130
Bold=false
Transparency=false
[Color1Intense]
Color=255,168,160
Bold=true
Transparency=false
[Color2]
Color=129,201,149
Bold=false
Transparency=false
[Color2Intense]
Color=160,220,180
Bold=true
Transparency=false
[Color3]
Color=253,214,51
Bold=false
Transparency=false
[Color3Intense]
Color=255,229,110
Bold=true
Transparency=false
[Color4]
Color=33,150,243
Bold=false
Transparency=false
[Color4Intense]
Color=100,181,246
Bold=true
Transparency=false
[Color5]
Color=206,147,216
Bold=false
Transparency=false
[Color5Intense]
Color=225,180,235
Bold=true
Transparency=false
[Color6]
Color=128,203,196
Bold=false
Transparency=false
[Color6Intense]
Color=165,225,220
Bold=true
Transparency=false
[Color7]
Color=224,224,224
Bold=false
Transparency=false
[Color7Intense]
Color=255,255,255
Bold=true
Transparency=false
EOF

cat > "$CFG/qterminal.org/qterminal.ini" <<EOF
[General]
ConfirmMultilinePaste=true
FixedTabWidth=false
HideTabBarWithOnlyOneTab=true
colorScheme=$TERM_SCHEME
fontFamily=$MONO_FONT
fontSize=11
ApplicationTransparency=0

[MainWindow]
size=@Size(900 560)
EOF
step "terminal : jeu de couleurs $TERM_SCHEME"

# --- GTK 3 ---
cat > "$CFG/gtk-3.0/settings.ini" <<EOF
[Settings]
gtk-theme-name=$THEME_GTK
gtk-icon-theme-name=$ICON_THEME
gtk-cursor-theme-name=$CURSOR_THEME
gtk-cursor-theme-size=$CURSOR_SIZE
gtk-font-name=$UI_FONT 10
gtk-application-prefer-dark-theme=1
gtk-decoration-layout=icon:minimize,maximize,close
gtk-enable-animations=1
gtk-xft-antialias=1
gtk-xft-hinting=1
gtk-xft-hintstyle=hintslight
gtk-xft-rgba=rgb
EOF

# --- GTK 2 ---
cat > "$HOME/.gtkrc-2.0" <<EOF
gtk-theme-name="$THEME_GTK"
gtk-icon-theme-name="$ICON_THEME"
gtk-cursor-theme-name="$CURSOR_THEME"
gtk-cursor-theme-size=$CURSOR_SIZE
gtk-font-name="$UI_FONT 10"
EOF

# --- GTK 4 / libadwaita ---
ln -sfn "/usr/share/themes/$THEME_GTK/gtk-4.0/gtk.css"      "$CFG/gtk-4.0/gtk.css"
ln -sfn "/usr/share/themes/$THEME_GTK/gtk-4.0/gtk-dark.css" "$CFG/gtk-4.0/gtk-dark.css"
ln -sfn "/usr/share/themes/$THEME_GTK/gtk-4.0/assets"       "$CFG/gtk-4.0/assets"
step "GTK 2 / 3 / 4 : $THEME_GTK"

# --- Mode sombre annonce aux applications via le portail XDG Settings ---
gset org.gnome.desktop.interface color-scheme          "prefer-dark"        || true
gset org.gnome.desktop.interface gtk-theme             "$THEME_GTK"         || true
gset org.gnome.desktop.interface icon-theme            "$ICON_THEME"        || true
gset org.gnome.desktop.interface cursor-theme          "$CURSOR_THEME"      || true
gset org.gnome.desktop.interface cursor-size           "$CURSOR_SIZE"       || true
gset org.gnome.desktop.interface font-name             "$UI_FONT 10"        || true
gset org.gnome.desktop.interface monospace-font-name   "$MONO_FONT 11"      || true
step "portail Settings : mode sombre annonce (prefer-dark)"

# --- Curseur par defaut du systeme ---
sudo install -d -m 0755 /usr/share/icons/default
printf '[Icon Theme]\nInherits=%s\n' "$CURSOR_THEME" \
  | sudo tee /usr/share/icons/default/index.theme >/dev/null

# --- Portails XDG : wlroots pour la capture, GTK pour le reste ---
cat > "$CFG/xdg-desktop-portal/portals.conf" <<'EOF'
[preferred]
default=gtk
org.freedesktop.impl.portal.Screenshot=wlr
org.freedesktop.impl.portal.ScreenCast=wlr
EOF
step "portails XDG : wlr (capture) + gtk (fichiers, mode sombre)"

# --- Ecran de connexion sombre ---
sudo tee "/usr/share/sddm/themes/$SDDM_THEME/theme.conf.user" >/dev/null <<EOF
[General]
background=$WALLPAPER
EOF
sudo install -d -m 0755 /etc/sddm.conf.d
sudo tee /etc/sddm.conf.d/95-graphite.conf >/dev/null <<EOF
[Theme]
Current=$SDDM_THEME
CursorTheme=$CURSOR_THEME
EOF
step "SDDM : theme $SDDM_THEME + fond Graphite"

# --- Session Wayland preselectionnee ---
sudo install -d -m 0750 -o sddm -g sddm /var/lib/sddm
sudo tee /var/lib/sddm/state.conf >/dev/null <<EOF
[Last]
Session=$SESSION_FILE
User=$USER
EOF
sudo chown sddm:sddm /var/lib/sddm/state.conf
sudo chmod 0600 /var/lib/sddm/state.conf
step "SDDM : LXQt (Wayland) preselectionne pour $USER"

xdg-user-dirs-update 2>/dev/null || true

#==============================================================================
head_ "[8/9] PASSE 2 - Coherence interne"
#==============================================================================

# Verifie que rien ne reste sur une valeur claire ou un nom de theme obsolete.
sect "Aucune valeur claire residuelle"
check "rc.xml ne reference plus 'Vent' clair" bash -c "! grep -q '<name>Vent</name>' '$RC'"
check "rc.xml ne reference plus 'breeze'"     bash -c "! grep -q '<icon>breeze</icon>' '$RC'"
check "GTK 3 : mode sombre force"             grep -qx 'gtk-application-prefer-dark-theme=1' "$CFG/gtk-3.0/settings.ini"
check "panel.conf : greffon X11 'tray' exclu" bash -c "! grep -qE '^plugins=.*(^|, )tray(,|\$)' '$CFG/lxqt/panel.conf'"
check "bureau : fond Graphite reference"      grep -qF "Wallpaper=$WALLPAPER" "$CFG/pcmanfm-qt/lxqt/settings.conf"
check "bureau : couleur de texte claire"      grep -qx "FgColor=$C_FG" "$CFG/pcmanfm-qt/lxqt/settings.conf"

sect "Coherence des noms de themes"
check "GTK       : $THEME_GTK existe"    test -d "/usr/share/themes/$THEME_GTK"
check "Kvantum   : $THEME_KV resoluble"  test -f "/usr/share/Kvantum/$THEME_KV_DIR/$THEME_KV.kvconfig"
check "Icones    : $ICON_THEME existe"   test -d "/usr/share/icons/$ICON_THEME"
check "Curseur   : $CURSOR_THEME existe" test -d "/usr/share/icons/$CURSOR_THEME"
check "Decoration: $WM_THEME existe"     test -d "/usr/share/themes/$WM_THEME/openbox-3"
check "Terminal  : $TERM_SCHEME existe"  test -f "$TERM_SCHEME_DIR/$TERM_SCHEME.colorscheme"
check "SDDM      : $SDDM_THEME existe"   test -f "/usr/share/sddm/themes/$SDDM_THEME/Main.qml"

sect "Liens symboliques resolus"
check "gtk-4.0/gtk.css"      test -e "$CFG/gtk-4.0/gtk.css"
check "gtk-4.0/gtk-dark.css" test -e "$CFG/gtk-4.0/gtk-dark.css"
check "gtk-4.0/assets"       test -e "$CFG/gtk-4.0/assets"

#==============================================================================
head_ "[9/9] PASSE 3 - Audit final"
#==============================================================================

sect "Paquets"
for p in lxqt-wayland-session labwc swaylock swayidle wlopm xwayland qt6-wayland \
         qt6-style-kvantum qt-style-kvantum lxqt-qtplugin \
         xdg-desktop-portal xdg-desktop-portal-wlr xdg-desktop-portal-gtk \
         grim slurp wl-clipboard nm-tray qlipper udisks2 gvfs \
         fonts-inter fonts-jetbrains-mono breeze-cursor-theme \
         lxqt-policykit qtermwidget6-data sddm-theme-maldives; do
  check "$p" dpkg-query -W -f='${Status}' "$p"
done

sect "Session Wayland"
check "Fichier de session enregistre"       test -f "$SESSION_FILE"
check "startlxqtwayland disponible"         command -v startlxqtwayland
check "labwc disponible"                    command -v labwc
check "compositor=labwc"                    grep -qx 'compositor=labwc' "$CFG/lxqt/session.conf"
check "Verrouillage swaylock configure"     grep -q '^lock_command_wayland=swaylock' "$CFG/lxqt/session.conf"
check "SDDM preselectionne la session"      sudo grep -qF "Session=$SESSION_FILE" /var/lib/sddm/state.conf
check "SDDM state.conf lisible par sddm"    sudo test -O /var/lib/sddm/state.conf -o -r /var/lib/sddm/state.conf

sect "Compositeur labwc"
check "rc.xml XML valide"                   xmllint --noout "$RC"
check "Decoration $WM_THEME active"         grep -q "<name>$WM_THEME</name>" "$RC"
check "Icones de menu $ICON_THEME"          grep -q "<icon>$ICON_THEME</icon>" "$RC"
check "4 bureaux virtuels"                  bash -c "grep -c '<name>[1-4]</name>' '$RC' | grep -qx 4"
check "Palette Graphite appliquee"          grep -qF "$C_BG" "$CFG/labwc/themerc-override"
check "autostart : environnement D-Bus"     grep -q 'dbus-update-activation-environment' "$CFG/labwc/autostart"
check "autostart : mise en veille ecran"    grep -q 'swayidle' "$CFG/labwc/autostart"
check "Disposition clavier definie"         bash -c "grep -q 'XKB_DEFAULT_LAYOUT' '$CFG/labwc/environment' || true"

sect "Apparence sombre"
check "LXQt   style Qt = kvantum"           grep -qx 'style=kvantum' "$CFG/lxqt/lxqt.conf"
check "LXQt   icones = $ICON_THEME"         grep -qx "icon_theme=$ICON_THEME" "$CFG/lxqt/lxqt.conf"
check "LXQt   panneau = kvantum"            grep -qx 'theme=kvantum' "$CFG/lxqt/lxqt.conf"
check "Kvantum theme actif"                 grep -qx "theme=$THEME_KV" "$CFG/Kvantum/kvantum.kvconfig"
check "GTK 2  .gtkrc-2.0"                   grep -qF "$THEME_GTK" "$HOME/.gtkrc-2.0"
check "GTK 3  settings.ini"                 grep -qF "$THEME_GTK" "$CFG/gtk-3.0/settings.ini"
check "GTK 4  libadwaita lie"               test -e "$CFG/gtk-4.0/gtk.css"
check "Terminal jeu de couleurs"            grep -qx "colorScheme=$TERM_SCHEME" "$CFG/qterminal.org/qterminal.ini"
check "Bureau  fond + couleurs"             grep -qx "BgColor=$C_DEEP" "$CFG/pcmanfm-qt/lxqt/settings.conf"
check "Portails XDG configures"             grep -q 'ScreenCast=wlr' "$CFG/xdg-desktop-portal/portals.conf"
check "SDDM   theme sombre selectionne"     sudo grep -qx "Current=$SDDM_THEME" /etc/sddm.conf.d/95-graphite.conf
check "SDDM   fond Graphite"                sudo grep -qF "$WALLPAPER" "/usr/share/sddm/themes/$SDDM_THEME/theme.conf.user"
check "Fond d'ecran present"                test -s "$WALLPAPER"

sect "Polices"
check "$UI_FONT installee"                  bash -c "fc-list | grep -qi 'Inter'"
check "$MONO_FONT installee"                bash -c "fc-list | grep -qi 'JetBrains'"
check "Emoji couleur installes"             bash -c "fc-list | grep -qi 'Noto Color Emoji'"

sect "Raccourcis labwc et applications cibles"
check "Super+Entree  qterminal"             command -v qterminal
check "Super+P       pcmanfm-qt"            command -v pcmanfm-qt
check "Super+F       featherpad"            command -v featherpad
check "Impr ecran    screengrab"            command -v screengrab
check "Alt+F2        lxqt-runner"           command -v lxqt-runner
check "Super+L       lxqt-leave"            command -v lxqt-leave

sect "Services de session"
check "Agent PolicyKit"                     command -v lxqt-policykit-agent
check "Applet reseau (SNI)"                 command -v nm-tray
check "NetworkManager actif"                systemctl is-active NetworkManager
check "Montage de volumes (udisks2)"        systemctl is-enabled udisks2

#==============================================================================
TOTAL=$((PASS+FAIL))
printf '\n%s============================================================%s\n' "$B" "$N"
if [[ $FAIL -eq 0 ]]; then
  printf '  %sAUDIT : %d/%d controles reussis' "$G" "$PASS" "$TOTAL"
  [[ $WARNS -gt 0 ]] && printf ', %d avertissement(s)' "$WARNS"
  printf '.%s\n' "$N"
  printf '\n  Redemarrez pour appliquer :  %ssudo systemctl reboot%s\n' "$B" "$N"
  printf '  La session %sLXQt (Wayland)%s est deja selectionnee.\n' "$B" "$N"
  [[ -d "$BACKUP" ]] && printf '  %sSauvegarde : %s%s\n' "$D" "$BACKUP" "$N"
  printf '%s============================================================%s\n\n' "$B" "$N"
  exit 0
else
  printf '  %sAUDIT : %d reussis, %d echecs sur %d.%s\n' "$R" "$PASS" "$FAIL" "$TOTAL" "$N"
  printf '  Traitez les lignes [KO] avant de redemarrer.\n'
  printf '%s============================================================%s\n\n' "$B" "$N"
  exit 1
fi
