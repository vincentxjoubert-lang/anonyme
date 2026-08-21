#!/usr/bin/env bash
#===============================================================================
#  fix-session-wayland.sh
#
#  Corrige la cause du demarrage sur labwc nu (menu Openbox, ecran noir) :
#  le paquet labwc installe sa propre entree de session
#  /usr/share/wayland-sessions/labwc.desktop (Exec=labwc), que SDDM a lancee
#  a la place de lxqt-wayland.desktop (Exec=startlxqtwayland).
#
#  1. Masque l'entree "labwc" nue, de facon reversible et resistante aux mises a jour
#  2. Reecrit l'etat SDDM avec le NOM DE FICHIER attendu, non un chemin absolu
#  3. Verifie la configuration LXQt/labwc de l'utilisateur
#===============================================================================

set -Eeuo pipefail

readonly SESSION_NAME="lxqt-wayland.desktop"
readonly SESSION_FILE="/usr/share/wayland-sessions/$SESSION_NAME"
readonly LABWC_ENTRY="/usr/share/wayland-sessions/labwc.desktop"
readonly CFG="${XDG_CONFIG_HOME:-$HOME/.config}"

if [[ -t 1 ]]; then
  B=$'\033[1m'; G=$'\033[32m'; R=$'\033[31m'; D=$'\033[2m'; N=$'\033[0m'
else B=""; G=""; R=""; D=""; N=""; fi

PASS=0; FAIL=0
step() { printf '  %s>%s %s\n' "$D" "$N" "$1"; }
die()  { printf '\n  %sECHEC%s %s\n\n' "$R" "$N" "$1" >&2; exit 1; }
check() {
  local l="$1"; shift
  if "$@" >/dev/null 2>&1; then printf '  %s[OK]%s   %s\n' "$G" "$N" "$l"; PASS=$((PASS+1))
  else printf '  %s[KO]%s   %s\n' "$R" "$N" "$l"; FAIL=$((FAIL+1)); fi
}

[[ $EUID -ne 0 ]] || die "lancez ce script avec votre compte utilisateur, pas en root."
sudo -v || die "privileges sudo requis."

printf '\n%sCorrection de la session par defaut%s\n' "$B" "$N"

# --- 1. Masquer l'entree labwc nue -------------------------------------------
[[ -f "$SESSION_FILE" ]] || die "$SESSION_FILE absent : reinstallez lxqt-wayland-session."

if [[ -e "$LABWC_ENTRY" ]]; then
  sudo dpkg-divert --quiet --local --rename \
       --divert "${LABWC_ENTRY}.disabled" --add "$LABWC_ENTRY" >/dev/null
  step "entree 'labwc' nue masquee (reversible)"
else
  step "entree 'labwc' nue deja masquee"
fi

# --- 2. Etat SDDM : nom de fichier, pas chemin absolu ------------------------
sudo install -d -m 0750 -o sddm -g sddm /var/lib/sddm
sudo tee /var/lib/sddm/state.conf >/dev/null <<CONF
[Last]
Session=$SESSION_NAME
User=$USER
CONF
sudo chown sddm:sddm /var/lib/sddm/state.conf
sudo chmod 0644 /var/lib/sddm/state.conf
step "SDDM : session preselectionnee = $SESSION_NAME"

# --- 3. Verification de la configuration utilisateur -------------------------
printf '\n%s  Verification%s\n' "$D" "$N"
check "Entree labwc nue absente du menu"      test ! -e "$LABWC_ENTRY"
check "Entree LXQt (Wayland) presente"        test -f "$SESSION_FILE"
check "Exec=startlxqtwayland"                 grep -qx 'Exec=startlxqtwayland' "$SESSION_FILE"
check "SDDM pointe sur $SESSION_NAME"         sudo grep -qx "Session=$SESSION_NAME" /var/lib/sddm/state.conf
check "state.conf lisible par sddm"           sudo -u sddm test -r /var/lib/sddm/state.conf
check "compositor=labwc"                      grep -qx 'compositor=labwc' "$CFG/lxqt/session.conf"
check "Config labwc : rc.xml"             test -f "$CFG/labwc/rc.xml"
check "Config labwc : menu.xml"         test -f "$CFG/labwc/menu.xml"
check "Config labwc : autostart"       test -f "$CFG/labwc/autostart"
check "Decoration Vent-dark"                  grep -q '<name>Vent-dark</name>' "$CFG/labwc/rc.xml"
check "lxqt-session installe"                 command -v lxqt-session
check "lxqt-panel installe"                   command -v lxqt-panel
check "pcmanfm-qt installe"                   command -v pcmanfm-qt

printf '\n%s====================================================%s\n' "$B" "$N"
if [[ $FAIL -eq 0 ]]; then
  printf '  %s%d/%d controles reussis.%s\n' "$G" "$PASS" "$((PASS+FAIL))" "$N"
  printf '\n  %ssudo systemctl restart sddm%s\n' "$B" "$N"
  printf '  Choisissez %sLXQt (Wayland)%s si le menu de session s%s affiche.\n' "$B" "$N" "'"
else
  printf '  %s%d reussis, %d echecs.%s\n' "$R" "$PASS" "$FAIL" "$N"
fi
printf '%s====================================================%s\n\n' "$B" "$N"
[[ $FAIL -eq 0 ]]
