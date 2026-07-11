#!/usr/bin/env bash
# ============================================================
#  Debian 13 (Trixie) — Openbox minimal + Vesktop + Actiona
#  Usage : sudo bash debian-openbox-minimal.sh
# ============================================================
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "[ERREUR] Lancer avec sudo." >&2; exit 1; }

# Utilisateur réel (celui qui a lancé sudo)
REAL_USER="${SUDO_USER:-$(logname)}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"

log()  { echo -e "\e[32m[OK]\e[0m $*"; }
info() { echo -e "\e[34m[..]\e[0m $*"; }

# ------------------------------------------------------------
# 1. Paquets — strict minimum
# ------------------------------------------------------------
info "Mise à jour des index APT"
apt-get update -qq

info "Installation du strict minimum (sans recommandés)"
apt-get install -y --no-install-recommends \
    openbox \
    xorg xserver-xorg-core xinit \
    actiona \
    wget ca-certificates \
    libnotify4 libxss1 libasound2 \
    fonts-dejavu-core \
    >/dev/null
log "Openbox + Actiona installés"

# ------------------------------------------------------------
# 2. Vesktop (.deb officiel GitHub, dernière release)
# ------------------------------------------------------------
info "Téléchargement de Vesktop (dernière release)"
VESKTOP_URL=$(wget -qO- https://api.github.com/repos/Vencord/Vesktop/releases/latest \
    | grep -oP '"browser_download_url":\s*"\K[^"]+amd64\.deb' | head -n1)
[[ -n "$VESKTOP_URL" ]] || { echo "[ERREUR] URL Vesktop introuvable." >&2; exit 1; }

wget -q "$VESKTOP_URL" -O /tmp/vesktop.deb
apt-get install -y --no-install-recommends /tmp/vesktop.deb >/dev/null
rm -f /tmp/vesktop.deb
log "Vesktop installé"

# ------------------------------------------------------------
# 3. Config Openbox utilisateur
# ------------------------------------------------------------
OB_DIR="$REAL_HOME/.config/openbox"
mkdir -p "$OB_DIR"

# --- Menu clic-droit minimal (remplace obmenu, mort/Python2) ---
cat > "$OB_DIR/menu.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_menu xmlns="http://openbox.org/3.4/menu">
  <menu id="root-menu" label="Menu">
    <item label="Vesktop">
      <action name="Execute"><command>vesktop</command></action>
    </item>
    <item label="Actiona">
      <action name="Execute"><command>actiona</command></action>
    </item>
    <item label="Terminal">
      <action name="Execute"><command>x-terminal-emulator</command></action>
    </item>
    <separator/>
    <item label="Redémarrer Openbox">
      <action name="Restart"/>
    </item>
    <item label="Quitter">
      <action name="Exit"><prompt>yes</prompt></action>
    </item>
  </menu>
</openbox_menu>
EOF
log "Menu clic-droit configuré (Vesktop + Actiona)"

# --- Autostart : lance Vesktop et Actiona au démarrage ---
cat > "$OB_DIR/autostart" <<'EOF'
vesktop &
actiona &
EOF
chmod +x "$OB_DIR/autostart"
log "Autostart configuré"

# --- rc.xml par défaut (léger) ---
[[ -f "$OB_DIR/rc.xml" ]] || cp /etc/xdg/openbox/rc.xml "$OB_DIR/rc.xml"

# --- .xinitrc : startx → openbox ---
cat > "$REAL_HOME/.xinitrc" <<'EOF'
exec openbox-session
EOF

chown -R "$REAL_USER:$REAL_USER" "$OB_DIR" "$REAL_HOME/.xinitrc"

# ------------------------------------------------------------
# 4. Allègement : désactiver les services inutiles
# ------------------------------------------------------------
info "Désactivation des services non essentiels"
for svc in bluetooth cups cups-browsed avahi-daemon ModemManager; do
    systemctl disable --now "$svc" 2>/dev/null || true
done
log "Services inutiles désactivés"

apt-get autoremove -y -qq >/dev/null
apt-get clean

# ------------------------------------------------------------
# Audit final
# ------------------------------------------------------------
echo
echo "================ AUDIT ================"
for bin in openbox actiona vesktop; do
    command -v "$bin" >/dev/null && echo " ✔ $bin : $(command -v $bin)" || echo " ✘ $bin : MANQUANT"
done
echo " ✔ Menu     : $OB_DIR/menu.xml"
echo " ✔ Autostart: $OB_DIR/autostart"
echo "========================================"
echo
echo "Démarrage de la session : tapez 'startx' après connexion."
echo "(Aucun display manager installé = zéro RAM gaspillée.)"
