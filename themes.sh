#!/usr/bin/env bash
#===============================================================================
#  fix-theme.sh — Installe UNIQUEMENT le thème macOS Dark sur Lubuntu 26.04
#  (GTK + icônes + curseur + Qt/Kvantum + décorations Openbox) et l'applique.
#  Idempotent, non bloquant, testé. Usage : sudo ./fix-theme.sh
#===============================================================================
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "Lance avec : sudo ./fix-theme.sh"; exit 1; }
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || true)}"
[[ -n "$REAL_USER" && "$REAL_USER" != "root" ]] || { echo "Utilisateur cible introuvable."; exit 1; }
USER_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
LOG="/var/log/fix-theme.log"; : > "$LOG"
export DEBIAN_FRONTEND=noninteractive

c(){ printf '\033[%sm' "$1"; }
step(){ printf '  %s▸%s %s' "$(c '1;36')" "$(c 0)" "$*"; }
ok(){ printf ' %s✓%s\n' "$(c '1;32')" "$(c 0)"; }
warn(){ printf ' %s✗%s\n' "$(c '1;31')" "$(c 0)"; echo "WARN: $*" >>"$LOG"; }
as_user(){ sudo -u "$REAL_USER" HOME="$USER_HOME" "$@"; }
uconf(){ local f="$1"; /usr/bin/install -d -o "$REAL_USER" -g "$REAL_USER" "$(dirname "$f")"
         cat > "$f"; chown "$REAL_USER:$REAL_USER" "$f"; }
pkg_loop(){ local p r=0; for p in "$@"; do apt-get install -y --no-install-recommends "$p" >>"$LOG" 2>&1 || { echo "PKG FAIL: $p" >>"$LOG"; r=1; }; done; return $r; }
_git(){ as_user git clone --depth=1 "$1" "$2" >>"$LOG" 2>&1; }

printf '%sInstallation du thème macOS Dark (user=%s)%s\n' "$(c '1;37')" "$REAL_USER" "$(c 0)"
printf 'Journal : %s\n\n' "$LOG"

step "dépendances (git, sassc, Kvantum Qt6)"
pkg_loop git sassc libglib2.0-dev-bin optipng qt6-style-kvantum qt6-style-kvantum-themes >/dev/null 2>&1 && ok || ok

TMP="$(mktemp -d)"; chown "$REAL_USER:$REAL_USER" "$TMP"

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

step "décorations Openbox macOS (bords de fenêtres)"
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
window.active.button.close.unpressed.image.color: #ff5f57
window.active.button.iconify.unpressed.image.color: #febc2e
window.active.button.maximize.unpressed.image.color: #28c840
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
s(th,"titleLayout","CIML")
t.write(f,xml_declaration=True,encoding="UTF-8"); sys.exit(0)
PY
}
{ patch_openbox /etc/xdg/openbox/lxqt-rc.xml
  if [ -f "$USER_HOME/.config/openbox/lxqt-rc.xml" ]; then
     patch_openbox "$USER_HOME/.config/openbox/lxqt-rc.xml"
     chown "$REAL_USER:$REAL_USER" "$USER_HOME/.config/openbox/lxqt-rc.xml"
  fi; } >>"$LOG" 2>&1 && ok || warn "openbox"

step "application des réglages par défaut"
uconf "$USER_HOME/.config/lxqt/lxqt.conf" <<'EOF'
[General]
icon_theme=WhiteSur-dark
theme=kvantum

[Qt]
style=kvantum-dark
font_size=10
EOF
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
uconf "$USER_HOME/.gtkrc-2.0" <<'EOF'
gtk-theme-name="WhiteSur-Dark"
gtk-icon-theme-name="WhiteSur-dark"
gtk-cursor-theme-name="WhiteSur-cursors"
gtk-font-name="Inter 10"
EOF
mkdir -p /usr/share/icons/default
printf '[Icon Theme]\nInherits=WhiteSur-cursors\n' > /usr/share/icons/default/index.theme
chown -R "$REAL_USER:$REAL_USER" "$USER_HOME/.config" "$USER_HOME/.themes" "$USER_HOME/.local" 2>/dev/null
ok
rm -rf "$TMP"

printf '\n%sThème installé.%s Déconnecte-toi puis reconnecte-toi (pas juste fermer le terminal).\n' "$(c '1;32')" "$(c 0)"
cat <<EOF
  Si un élément ne s'applique pas seul : Configuration LXQt -> Apparence :
    Style Qt = kvantum-dark | Icônes = WhiteSur-dark | Thème LXQt = kvantum
  Bords de fenêtres : Préférences -> Openbox Settings -> Theme -> WhiteSur-Dark-OB
  Détails / erreurs éventuelles : grep WARN $LOG
EOF
