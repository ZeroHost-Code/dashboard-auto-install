#!/bin/sh
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

info()  { printf "${CYAN}[INFO]${NC}  %s\n" "$1"; }
ok()    { printf "${GREEN}[OK]${NC}    %s\n" "$1"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$1"; }
err()   { printf "${RED}[ERR]${NC}   %s\n" "$1"; }

# ─── Vérification root ───────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    echo ""
    err "Ce script doit être exécuté en tant que root (UID 0)."
    err "Connectez-vous en root avec : su -"
    exit 1
fi
ok "Exécuté en tant que root"

# ─── Détection OS ────────────────────────────────────────────────────────────
if ! command -v apt-get >/dev/null 2>&1; then
    err "Ce script nécessite apt-get (Debian/Ubuntu)."
    exit 1
fi

# ─── Détection du vrai terminal ──────────────────────────────────────────────
TTY_DEV=""
tty_path="$(tty 2>/dev/null || true)"
case "$tty_path" in
    /dev/*)
        if [ -c "$tty_path" ] 2>/dev/null; then
            TTY_DEV="$tty_path"
        fi
        ;;
esac
# Fallback: essayer /dev/tty
if [ -z "$TTY_DEV" ] && [ -c /dev/tty ] 2>/dev/null; then
    TTY_DEV="/dev/tty"
fi
# Fallback: si stdin est un terminal
if [ -z "$TTY_DEV" ] && [ -t 0 ]; then
    TTY_DEV="stdin"
fi
if [ -z "$TTY_DEV" ]; then
    err "Aucun terminal interactif trouvé."
    err "Exécutez le script directement sur le serveur via SSH."
    exit 1
fi

# ─── Fonctions de saisie (variables globales, PAS de subshell) ──────────────
get_input() {
    prompt="$1"
    printf "${CYAN}>>>${NC} %s " "$prompt" >&2
    if [ "$TTY_DEV" = "stdin" ]; then
        read -r input_val
    else
        read -r input_val < "$TTY_DEV"
    fi
}

get_input_default() {
    prompt="$1"
    default="$2"
    printf "${CYAN}>>>${NC} %s [%s]: " "$prompt" "$default" >&2
    if [ "$TTY_DEV" = "stdin" ]; then
        read -r input_val
    else
        read -r input_val < "$TTY_DEV"
    fi
    if [ -z "$input_val" ]; then input_val="$default"; fi
}

read_password() {
    prompt="$1"
    printf "${CYAN}>>>${NC} %s " "$prompt" >&2
    if [ "$TTY_DEV" = "stdin" ]; then
        read -r input_val
    else
        stty -echo < "$TTY_DEV" 2>/dev/null
        read -r input_val < "$TTY_DEV"
        stty echo < "$TTY_DEV" 2>/dev/null
    fi
    echo "" >&2
}

confirm() {
    prompt="$1"
    default="${2:-y}"
    if [ "$default" = "y" ] || [ "$default" = "Y" ]; then
        printf "${CYAN}>>>${NC} %s (Y/n) " "$prompt" >&2
    else
        printf "${CYAN}>>>${NC} %s (y/N) " "$prompt" >&2
    fi
    if [ "$TTY_DEV" = "stdin" ]; then
        read -r confirm_val
    else
        read -r confirm_val < "$TTY_DEV"
    fi
    if [ -z "$confirm_val" ]; then confirm_val="$default"; fi
    case "$confirm_val" in
        [YyOo]*) return 0 ;;
        *) return 1 ;;
    esac
}

# ─── Installation des dépendances système ────────────────────────────────────
info "Mise à jour des paquets..."
apt-get update -qq || { err "apt-get update a échoué"; exit 1; }

info "Installation des dépendances système..."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl wget gnupg2 ca-certificates \
    git openssl 2>&1 | tail -5

ok "Dépendances système installées"

# ─── Installation de Node.js 22.x LTS ────────────────────────────────────────
if command -v node >/dev/null 2>&1; then
    ok "Node.js déjà installé : $(node -v)"
else
    info "Installation de Node.js 22.x LTS..."
    curl -fsSL https://deb.nodesource.com/setup_22.x | sh -
    DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs 2>&1 | tail -3
    ok "Node.js installé : $(node -v)"
    ok "npm installé : $(npm -v)"
fi

# ─── Installation de MariaDB ─────────────────────────────────────────────────
if command -v mariadb >/dev/null 2>&1; then
    ok "MariaDB déjà installé : $(mariadb --version 2>/dev/null | head -1)"
else
    info "Installation de MariaDB..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y mariadb-server mariadb-client 2>&1 | tail -5

    systemctl enable mariadb --now 2>/dev/null || true
    sleep 2

    info "Sécurisation de MariaDB..."
    mysql <<-EOSQL
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOSQL
    ok "MariaDB installé et sécurisé"
fi

if ! systemctl is-active --quiet mariadb 2>/dev/null; then
    info "Démarrage de MariaDB..."
    systemctl start mariadb 2>/dev/null || true
    sleep 1
fi
ok "MariaDB est actif"

# ─── Création de la base de données et utilisateur ──────────────────────────
echo ""
info "--- Configuration de la base de données ---"
echo ""

DB_NAME="zerohost_dashboard"
DB_USER="zerohost"

get_input_default "Nom de la base de données" "$DB_NAME"
DB_NAME="$input_val"

get_input_default "Nom d'utilisateur MariaDB" "$DB_USER"
DB_USER="$input_val"

if confirm "Voulez-vous spécifier un mot de passe MariaDB ?" "n"; then
    while true; do
        read_password "Mot de passe MariaDB :"
        DB_PASSWORD="$input_val"
        read_password "Confirmer le mot de passe :"
        DB_PASSWORD2="$input_val"
        if [ "$DB_PASSWORD" = "$DB_PASSWORD2" ]; then
            break
        fi
        warn "Les mots de passe ne correspondent pas. Réessayez."
    done
else
    DB_PASSWORD=$(openssl rand -base64 32 | tr -d '/+=' | head -c24)
    warn "Mot de passe généré : ${DB_PASSWORD}"
    warn "Notez-le ! Il sera aussi dans le fichier .env"
fi

info "Création de la base de données et de l'utilisateur..."
mysql <<-EOSQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASSWORD}';
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOSQL
ok "Base de données '${DB_NAME}' et utilisateur '${DB_USER}' créés"

# ─── Installation de PM2 ────────────────────────────────────────────────────
if command -v pm2 >/dev/null 2>&1; then
    ok "PM2 déjà installé : $(pm2 -v)"
else
    info "Installation de PM2..."
    npm install -g pm2 --quiet 2>&1 | tail -3
    ok "PM2 installé : $(pm2 -v)"
fi

# ─── Clone / récupération du repo ────────────────────────────────────────────
echo ""
info "--- Récupération du code source ---"
echo ""

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DASHBOARD_DIR=""

if [ -f "$SCRIPT_DIR/dashboard/server.js" ]; then
    warn "Le script semble déjà être dans le dépôt ZeroHost."
    if confirm "Utiliser le répertoire courant (${SCRIPT_DIR}/dashboard) ?" "y"; then
        DASHBOARD_DIR="$SCRIPT_DIR/dashboard"
        ok "Utilisation de : $DASHBOARD_DIR"
    fi
fi

if [ -z "$DASHBOARD_DIR" ]; then
    get_input_default "URL du dépôt Git" "https://github.com/ddrayko/ZeroHost.git"
    REPO_URL="$input_val"

    get_input_default "Branche" "main"
    BRANCH="$input_val"

    TARGET_DIR="/opt/ZeroHost"

    info "Clonage de ${REPO_URL} (branche: ${BRANCH}) vers ${TARGET_DIR}..."
    if [ -d "$TARGET_DIR" ]; then
        warn "Le répertoire ${TARGET_DIR} existe déjà."
        if confirm "Le supprimer et recloner ?" "n"; then
            rm -rf "$TARGET_DIR"
        fi
    fi
    if [ ! -d "$TARGET_DIR" ]; then
        git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$TARGET_DIR"
        ok "Dépôt cloné"
    fi
    DASHBOARD_DIR="$TARGET_DIR/dashboard"
fi

# Le repo cloné peut avoir server.js à la racine ou dans dashboard/
if [ ! -f "$DASHBOARD_DIR/server.js" ]; then
    if [ -f "${DASHBOARD_DIR%/dashboard}/server.js" ]; then
        DASHBOARD_DIR="${DASHBOARD_DIR%/dashboard}"
    fi
fi
if [ ! -f "$DASHBOARD_DIR/server.js" ]; then
    err "server.js introuvable"
    err "Vérifiez que le dépôt contient bien le dashboard."
    exit 1
fi
ok "Code source prêt dans : $DASHBOARD_DIR"

# ─── Configuration de l'environnement ────────────────────────────────────────
echo ""
info "--- Configuration de l'environnement (.env) ---"
echo ""
info "Variables requises. Laissez vide pour utiliser la valeur par défaut."
echo ""

JWT_SECRET=$(openssl rand -hex 64)
COOKIE_SECRET=$(openssl rand -hex 32)

get_input_default "PORT" "3000"
PORT_VAL="$input_val"

get_input_default "NODE_ENV" "production"
NODE_ENV_VAL="$input_val"

get_input_default "JWT_SECRET" "$JWT_SECRET"
JWT_SECRET_VAL="$input_val"

get_input_default "JWT_EXPIRES_IN" "2h"
JWT_EXPIRES_IN_VAL="$input_val"

get_input_default "DB_HOST" "127.0.0.1"
DB_HOST_VAL="$input_val"

get_input_default "DB_PORT" "3306"
DB_PORT_VAL="$input_val"

get_input_default "DB_USER" "$DB_USER"
DB_USER_VAL="$input_val"

get_input_default "DB_PASSWORD" "$DB_PASSWORD"
DB_PASSWORD_VAL="$input_val"

get_input_default "DB_NAME" "$DB_NAME"
DB_NAME_VAL="$input_val"

get_input_default "PTERO_URL (URL du panel Pyrodactyl)" "https://panel.your-domain.com"
PTERO_URL="$input_val"

get_input_default "PTERO_API_KEY (clé API Application du panel)" ""
PTERO_API_KEY="$input_val"
while [ -z "$PTERO_API_KEY" ]; do
    get_input "PTERO_API_KEY (obligatoire)"
    PTERO_API_KEY="$input_val"
done

get_input_default "PANEL_DB_NAME" "panel"
PANEL_DB_NAME_VAL="$input_val"

get_input_default "CAP_ENDPOINT" "https://cap.zero-host.org/f6c8171b08/"
CAP_ENDPOINT_VAL="$input_val"

get_input_default "CAP_SECRET" ""
CAP_SECRET="$input_val"
while [ -z "$CAP_SECRET" ]; do
    get_input "CAP_SECRET (obligatoire)"
    CAP_SECRET="$input_val"
done

get_input_default "COOKIE_SECRET" "$COOKIE_SECRET"
COOKIE_SECRET_VAL="$input_val"

get_input_default "RESEND_API_KEY" ""
RESEND_API_KEY_VAL="$input_val"

get_input_default "RESEND_FROM_EMAIL" "noreply@your-domain.com"
RESEND_FROM_EMAIL_VAL="$input_val"

get_input_default "LOG_LEVEL" "info"
LOG_LEVEL_VAL="$input_val"

# ─── Écriture du .env ────────────────────────────────────────────────────────
cat > "$DASHBOARD_DIR/.env" <<-EOSQL
# Server
PORT=${PORT_VAL}
NODE_ENV=${NODE_ENV_VAL}

# JWT
JWT_SECRET=${JWT_SECRET_VAL}
JWT_EXPIRES_IN=${JWT_EXPIRES_IN_VAL}

# MariaDB
DB_HOST=${DB_HOST_VAL}
DB_PORT=${DB_PORT_VAL}
DB_USER=${DB_USER_VAL}
DB_PASSWORD=${DB_PASSWORD_VAL}
DB_NAME=${DB_NAME_VAL}

# Pterodactyl Panel (Application API)
PTERO_URL=${PTERO_URL}
PTERO_API_KEY=${PTERO_API_KEY}

# Panel database name (for egg variable lookup)
PANEL_DB_NAME=${PANEL_DB_NAME_VAL}

# Cap CAPTCHA
CAP_ENDPOINT=${CAP_ENDPOINT_VAL}
CAP_SECRET=${CAP_SECRET}

# Session & Cookie
COOKIE_SECRET=${COOKIE_SECRET_VAL}

# Resend (email)
RESEND_API_KEY=${RESEND_API_KEY_VAL}
RESEND_FROM_EMAIL=${RESEND_FROM_EMAIL_VAL}

# Logging
LOG_LEVEL=${LOG_LEVEL_VAL}
EOSQL

ok "Fichier .env créé : $DASHBOARD_DIR/.env"
chmod 600 "$DASHBOARD_DIR/.env"

# ─── Installation des dépendances npm ────────────────────────────────────────
echo ""
info "Installation des dépendances npm..."
cd "$DASHBOARD_DIR"
npm install --omit=dev 2>&1 | tail -5
ok "Dépendances npm installées"

# ─── Configuration du pare-feu (UFW) ─────────────────────────────────────────
echo ""
info "Configuration du pare-feu..."
if command -v ufw >/dev/null 2>&1; then
    ufw --force reset >/dev/null 2>&1 || true
    ufw default deny incoming >/dev/null 2>&1
    ufw default allow outgoing >/dev/null 2>&1
    ufw allow ssh >/dev/null 2>&1
    ufw allow "${PORT_VAL}/tcp" >/dev/null 2>&1
    ufw --force enable >/dev/null 2>&1 || true
    ok "Pare-feu configuré (ports : SSH, ${PORT_VAL})"
else
    warn "UFW non installé — installation..."
    apt-get install -y ufw 2>&1 | tail -3 && {
        ufw --force reset >/dev/null 2>&1 || true
        ufw default deny incoming >/dev/null 2>&1
        ufw default allow outgoing >/dev/null 2>&1
        ufw allow ssh >/dev/null 2>&1
        ufw allow "${PORT_VAL}/tcp" >/dev/null 2>&1
        ufw --force enable >/dev/null 2>&1 || true
        ok "Pare-feu configuré (ports : SSH, ${PORT_VAL})"
    } || warn "Impossible d'installer/configurer UFW."
fi

# ─── Démarrage avec PM2 ─────────────────────────────────────────────────────
echo ""
info "Démarrage du dashboard avec PM2..."

pm2 delete zerohost-dashboard 2>/dev/null || true
pm2 start server.js --name zerohost-dashboard --cwd "$DASHBOARD_DIR"
pm2 save
ok "Dashboard démarré avec PM2"

info "Configuration du démarrage automatique de PM2..."
pm2 startup systemd -u root --hp /root 2>/dev/null | tail -1 | sh 2>/dev/null || true
pm2 save 2>/dev/null
ok "PM2 configuré pour démarrer automatiquement au boot"

# ─── Création du premier admin ───────────────────────────────────────────────
echo ""
info "--- Création du compte administrateur ---"
echo ""

if confirm "Voulez-vous créer un compte administrateur maintenant ?" "y"; then
    get_input_default "Email administrateur" "admin@zerohost.org"
    ADMIN_EMAIL="$input_val"

    get_input_default "Nom d'utilisateur" "admin"
    ADMIN_USERNAME="$input_val"

    while true; do
        read_password "Mot de passe (min 8 caractères) :"
        ADMIN_PASS="$input_val"
        len=$(printf "%s" "$ADMIN_PASS" | wc -c)
        if [ "$len" -lt 8 ]; then
            warn "Le mot de passe doit faire au moins 8 caractères."
            continue
        fi
        read_password "Confirmer le mot de passe :"
        ADMIN_PASS2="$input_val"
        if [ "$ADMIN_PASS" = "$ADMIN_PASS2" ]; then
            break
        fi
        warn "Les mots de passe ne correspondent pas."
    done

    cd "$DASHBOARD_DIR"
    node scripts/admin-cli.js create "$ADMIN_EMAIL" "$ADMIN_USERNAME" "$ADMIN_PASS"
    ok "Compte administrateur créé : $ADMIN_USERNAME ($ADMIN_EMAIL)"
fi

# ─── Résumé final ────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════════"
printf " ${GREEN}Installation terminée avec succès !${NC}\n"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
ip_addr="$(curl -s ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')"
printf "  Dashboard : ${CYAN}http://%s:%s${NC}\n" "$ip_addr" "$PORT_VAL"
echo ""
printf "  Répertoire  : %s\n" "$DASHBOARD_DIR"
printf "  Base de données : %s\n" "$DB_NAME_VAL"
printf "  Utilisateur DB   : %s\n" "$DB_USER_VAL"
echo ""
echo "  Commandes utiles :"
echo "    pm2 status               — Statut des processus"
echo "    pm2 logs zerohost-dashboard  — Logs du dashboard"
echo "    pm2 restart zerohost-dashboard  — Redémarrage"
printf "    cd %s && ./admin.sh — Gestion des admins\n" "$DASHBOARD_DIR"
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo ""
