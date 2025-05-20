#!/bin/bash

# Script d'installation automatisé pour OpenStack (Nova), Terraform, Authelia et Nginx
# Basé sur le Document d'Architecture Technique

# Fonction pour afficher les messages d'état
print_status() {
    echo -e "\n\033[1;34m[*] $1\033[0m"
}

# Fonction pour afficher les messages de succès
print_success() {
    echo -e "\033[1;32m[+] $1\033[0m"
}

# Fonction pour afficher les messages d'erreur
print_error() {
    echo -e "\033[1;31m[-] $1\033[0m"
    exit 1
}

# Fonction pour vérifier si une commande existe
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Vérifier si l'utilisateur est root
if [ "$EUID" -ne 0 ]; then
    print_error "Ce script doit être exécuté en tant que root. Utilisez 'sudo'."
fi

# Vérifier si le système est Ubuntu 22.04
if ! grep -q "Ubuntu 22.04" /etc/os-release; then
    print_error "Ce script est conçu pour Ubuntu 22.04 LTS. D'autres versions peuvent ne pas fonctionner correctement."
fi

# Vérifier les prérequis matériels
print_status "Vérification des prérequis matériels..."
cpu_cores=$(grep -c ^processor /proc/cpuinfo)
total_memory=$(free -m | awk '/^Mem:/{print $2}')
free_disk=$(df -h / | awk 'NR==2 {print $4}' | sed 's/G//')

if [ $cpu_cores -lt 4 ]; then
    echo "AVERTISSEMENT: Il est recommandé d'avoir au moins 4 cœurs CPU. Vous avez $cpu_cores cœurs."
fi

if [ $total_memory -lt 16000 ]; then
    echo "AVERTISSEMENT: Il est recommandé d'avoir au moins 16 Go de RAM. Vous avez $total_memory Mo."
fi

if [ $free_disk -lt 100 ]; then
    echo "AVERTISSEMENT: Il est recommandé d'avoir au moins 100 Go d'espace disque libre. Vous avez $free_disk Go."
fi

# Mise à jour du système
print_status "Mise à jour du système..."
apt update && apt upgrade -y || print_error "Impossible de mettre à jour le système"
print_success "Système mis à jour avec succès"

# Installation des dépendances communes
print_status "Installation des dépendances communes..."
apt install -y python3-pip python3-dev libffi-dev gcc libssl-dev git curl wget software-properties-common || print_error "Impossible d'installer les dépendances"
print_success "Dépendances installées avec succès"

# Installation de Docker et Docker Compose
print_status "Installation de Docker et Docker Compose..."
if ! command_exists docker; then
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    systemctl enable docker
    systemctl start docker
    rm get-docker.sh
else
    print_success "Docker est déjà installé"
fi

if ! command_exists docker-compose; then
    apt install -y docker-compose
else
    print_success "Docker Compose est déjà installé"
fi

print_success "Docker et Docker Compose installés avec succès"

# Installation d'OpenStack via DevStack
print_status "Installation d'OpenStack via DevStack..."

# Créer un utilisateur stack
if ! id "stack" >/dev/null 2>&1; then
    useradd -s /bin/bash -d /opt/stack -m stack
    chmod +x /opt/stack
    echo "stack ALL=(ALL) NOPASSWD: ALL" | tee /etc/sudoers.d/stack
    print_success "Utilisateur stack créé avec succès"
else
    print_success "L'utilisateur stack existe déjà"
fi

# Installation de DevStack
print_status "Configuration et installation de DevStack..."
cd /opt/stack
if [ ! -d "devstack" ]; then
    sudo -u stack git clone https://opendev.org/openstack/devstack
    cd devstack
    
    # Création du fichier de configuration
    sudo -u stack bash -c "cat > local.conf << EOF
[[local|localrc]]
ADMIN_PASSWORD=password
DATABASE_PASSWORD=password
RABBIT_PASSWORD=password
SERVICE_PASSWORD=password

# Enable Nova
enable_service n-api
enable_service n-crt
enable_service n-cpu
enable_service n-cond
enable_service n-sch
enable_service n-novnc
enable_service n-api-meta
enable_service placement-api
enable_service placement-client

# Désactiver les services non nécessaires pour cette installation
disable_service horizon
disable_service swift
disable_service cinder

HOST_IP=127.0.0.1
EOF"

    # Lancement de l'installation
    print_status "Lancement de l'installation de DevStack (cela peut prendre 30-45 minutes)..."
    sudo -u stack ./stack.sh || print_error "Échec de l'installation de DevStack"
    print_success "OpenStack installé avec succès via DevStack"
else
    print_success "DevStack est déjà installé"
fi

# Installation de Terraform
print_status "Installation de Terraform..."
if ! command_exists terraform; then
    # Ajouter la clé GPG HashiCorp
    wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
    
    # Ajouter le dépôt HashiCorp
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/hashicorp.list
    
    # Mettre à jour et installer Terraform
    apt update && apt install -y terraform
    print_success "Terraform installé avec succès"
else
    print_success "Terraform est déjà installé"
fi

# Création de la structure pour les projets Terraform
print_status "Configuration de l'environnement Terraform pour OpenStack..."
mkdir -p /home/stack/terraform-openstack
cd /home/stack/terraform-openstack

# Création des fichiers de configuration Terraform
cat > provider.tf << EOF
terraform {
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 1.51.1"
    }
  }
}

provider "openstack" {
  # Les identifiants seront chargés via les variables d'environnement
}
EOF

cat > variables.tf << EOF
variable "image_id" {
  type        = string
  description = "ID de l'image à utiliser pour les instances"
}

variable "flavor_id" {
  type        = string
  description = "ID du type d'instance à utiliser"
}

variable "network_id" {
  type        = string
  description = "ID du réseau à utiliser"
}

variable "keypair_name" {
  type        = string
  description = "Nom de la paire de clés SSH à utiliser"
}
EOF

cat > main.tf << EOF
resource "openstack_compute_instance_v2" "basic" {
  name            = "instance-basic"
  image_id        = var.image_id
  flavor_id       = var.flavor_id
  key_pair        = var.keypair_name
  security_groups = ["default"]

  network {
    uuid = var.network_id
  }
}

output "instance_ip" {
  value = openstack_compute_instance_v2.basic.access_ip_v4
}
EOF

cat > openrc.sh << EOF
#!/bin/bash
export OS_AUTH_URL=http://localhost:5000/v3
export OS_PROJECT_NAME="admin"
export OS_USER_DOMAIN_NAME="Default"
export OS_PROJECT_DOMAIN_ID="default"
export OS_USERNAME="admin"
export OS_PASSWORD="password"
export OS_REGION_NAME="RegionOne"
export OS_INTERFACE=public
export OS_IDENTITY_API_VERSION=3
export TF_VAR_image_id="REMPLACER_PAR_ID_IMAGE"
export TF_VAR_flavor_id="REMPLACER_PAR_ID_FLAVOR"
export TF_VAR_network_id="REMPLACER_PAR_ID_RESEAU"
export TF_VAR_keypair_name="REMPLACER_PAR_NOM_KEYPAIR"
EOF

chmod +x openrc.sh
chown -R stack:stack /home/stack/terraform-openstack

print_success "Configuration Terraform pour OpenStack terminée"

# Installation et configuration d'Authelia avec Docker Compose
print_status "Installation et configuration d'Authelia avec Docker Compose..."
mkdir -p /opt/authelia/config
cd /opt/authelia

# Création du fichier docker-compose.yml
cat > docker-compose.yml << EOF
version: '3.8'

services:
  authelia:
    image: authelia/authelia:latest
    container_name: authelia
    volumes:
      - ./config:/config
    ports:
      - 9091:9091
    environment:
      - TZ=Europe/Paris
    restart: unless-stopped
    networks:
      - proxy
    labels:
      - "com.centurylinklabs.watchtower.enable=true"

  redis:
    image: redis:alpine
    container_name: redis
    volumes:
      - redis_data:/data
    restart: unless-stopped
    networks:
      - proxy
    command: redis-server --requirepass authelia_redis_password

networks:
  proxy:
    external: false
    name: proxy

volumes:
  redis_data:
EOF

# Création du fichier de configuration Authelia
cat > config/configuration.yml << EOF
---
###############################################################################
#                           Authelia Configuration                            #
###############################################################################

server:
  host: 0.0.0.0
  port: 9091

log:
  level: info
  
jwt_secret: a_very_secure_jwt_secret_key_change_me
  
default_redirection_url: https://example.com

totp:
  issuer: authelia.com
  period: 30
  skew: 1

# Configuration de la base de données (fichier local pour la simplicité)
storage:
  local:
    path: /config/db.sqlite3

# Configuration Redis pour les sessions
session:
  name: authelia_session
  domain: example.com
  secret: a_very_secure_session_secret_key_change_me
  expiration: 3600 # 1 heure
  inactivity: 300 # 5 minutes
  redis:
    host: redis
    port: 6379
    password: authelia_redis_password

# Configuration d'authentification
authentication_backend:
  file:
    path: /config/users_database.yml
    password:
      algorithm: argon2id
      iterations: 1
      key_length: 32
      salt_length: 16
      memory: 1024
      parallelism: 8

# Configuration d'accès
access_control:
  default_policy: deny
  rules:
    - domain: public.example.com
      policy: bypass
    - domain: "*.example.com"
      policy: two_factor

# Configuration de notification (exemple avec fichier, à remplacer par SMTP en production)
notifier:
  filesystem:
    filename: /config/notification.txt
EOF

# Création du fichier utilisateurs pour Authelia
cat > config/users_database.yml << EOF
---
users:
  admin:
    displayname: "Admin User"
    password: "$argon2id$v=19$m=65536,t=3,p=4$ZWlCbS9wTlB5aEovb29mSA$gpQlZvsP/uEoJ5/Mp3igdkUAfvKUxaOPEh9c3lPGR4Y"  # mot de passe: admin
    email: admin@example.com
    groups:
      - admins
  user:
    displayname: "Regular User"
    password: "$argon2id$v=19$m=65536,t=3,p=4$cXpuTVpJbmxiWUlLcEtPZw$N/9QOuFzV9KyKLKe0pTt4uu9BHr0v8UwV+XlVyFu/Kg"  # mot de passe: password
    email: user@example.com
    groups:
      - users
EOF

# Créer le réseau Docker
docker network create proxy || true

# Démarrer les conteneurs
docker-compose up -d

print_success "Authelia configuré et démarré avec succès"

# Installation et configuration de Nginx
print_status "Installation et configuration de Nginx..."
apt install -y nginx || print_error "Impossible d'installer Nginx"

# Sauvegarde de la configuration par défaut
cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak

# Créer un répertoire pour les certificats SSL
mkdir -p /etc/nginx/ssl

# Générer des certificats auto-signés (pour le développement)
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/nginx/ssl/nginx.key \
  -out /etc/nginx/ssl/nginx.crt \
  -subj "/C=FR/ST=Paris/L=Paris/O=Organization/CN=example.com"

# Configuration principale de Nginx
cat > /etc/nginx/nginx.conf << EOF
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 1024;
    multi_accept on;
}

http {
    # Configuration de base
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    
    # MIME types
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # Logging
    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;

    # Compression gzip
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_buffers 16 8k;
    gzip_http_version 1.1;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;

    # Inclure les configurations de sites
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF

# Configuration de Nginx pour Authelia
mkdir -p /etc/nginx/snippets

# Snippet pour la location Authelia
cat > /etc/nginx/snippets/authelia-location.conf << EOF
location /authelia {
    internal;
    set \$upstream_authelia http://127.0.0.1:9091/api/verify;
    proxy_pass \$upstream_authelia;
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";
    
    # Paramètres à transmettre à Authelia
    proxy_set_header X-Original-URL \$scheme://\$http_host\$request_uri;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Forwarded-Host \$http_host;
    proxy_set_header X-Forwarded-Uri \$request_uri;
    proxy_set_header X-Forwarded-For \$remote_addr;
    proxy_set_header Remote-User \$remote_user;
    proxy_set_header Remote-Name \$remote_user;
    
    # Configurer le timeout (important pour la validation 2FA)
    proxy_connect_timeout 5s;
    proxy_send_timeout 5s;
    proxy_read_timeout 5s;
}
EOF

# Snippet pour la requête d'authentification
cat > /etc/nginx/snippets/authelia-authrequest.conf << EOF
auth_request /authelia;
auth_request_set \$target_url \$scheme://\$http_host\$request_uri;
auth_request_set \$user \$upstream_http_remote_user;
auth_request_set \$name \$upstream_http_remote_name;
auth_request_set \$groups \$upstream_http_remote_groups;
auth_request_set \$redirect \$upstream_http_location;

error_page 401 =302 https://auth.example.com/?rd=\$target_url;
EOF

# Configuration d'un site protégé par Authelia
cat > /etc/nginx/sites-available/protected.example.com.conf << EOF
server {
    listen 80;
    server_name protected.example.com;
    
    # Redirection HTTP vers HTTPS
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name protected.example.com;
    
    # Certificats SSL
    ssl_certificate /etc/nginx/ssl/nginx.crt;
    ssl_certificate_key /etc/nginx/ssl/nginx.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    
    # Intégration Authelia
    include /etc/nginx/snippets/authelia-authrequest.conf;
    
    # Directives de sécurité
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-XSS-Protection "1; mode=block";

    location / {
        # Intégration avec le service protégé (exemple: OpenStack Horizon)
        proxy_pass http://localhost:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # Variables transmises par Authelia
        proxy_set_header Remote-User \$user;
        proxy_set_header Remote-Name \$name;
        proxy_set_header Remote-Groups \$groups;
    }
    
    # Endpoint d'authentification Authelia
    include /etc/nginx/snippets/authelia-location.conf;
}
EOF

# Configuration du portail Authelia
cat > /etc/nginx/sites-available/auth.example.com.conf << EOF
server {
    listen 80;
    server_name auth.example.com;
    
    # Redirection HTTP vers HTTPS
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name auth.example.com;
    
    # Certificats SSL
    ssl_certificate /etc/nginx/ssl/nginx.crt;
    ssl_certificate_key /etc/nginx/ssl/nginx.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    
    # Directives de sécurité
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-XSS-Protection "1; mode=block";

    # Proxy vers Authelia
    location / {
        proxy_pass http://127.0.0.1:9091;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # Pour WebSocket
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

# Activation des configurations et redémarrage de Nginx
ln -sf /etc/nginx/sites-available/protected.example.com.conf /etc/nginx/sites-enabled/
ln -sf /etc/nginx/sites-available/auth.example.com.conf /etc/nginx/sites-enabled/

# Supprimer la configuration par défaut
rm -f /etc/nginx/sites-enabled/default

# Vérifier la configuration
nginx -t

# Redémarrer Nginx
systemctl restart nginx

print_success "Nginx configuré et démarré avec succès"

# Configuration du fichier hosts pour les tests locaux
print_status "Configuration des entrées hosts pour les tests..."
if ! grep -q "auth.example.com" /etc/hosts; then
    echo "127.0.0.1 auth.example.com protected.example.com" >> /etc/hosts
    print_success "Entrées hosts ajoutées"
else
    print_success "Entrées hosts déjà présentes"
fi

# Instructions finales
print_status "Installation terminée avec succès!"
echo ""
echo "==================================================================="
echo "RÉSUMÉ DE L'INSTALLATION :"
echo "==================================================================="
echo "OpenStack (Nova) : Installé via DevStack"
echo "  - Interface d'administration: http://localhost (port défini dans DevStack)"
echo "  - Identifiants: admin / password"
echo ""
echo "Terraform : Installé et configuré pour OpenStack"
echo "  - Configuration dans: /home/stack/terraform-openstack"
echo "  - Fichier d'environnement: source /home/stack/terraform-openstack/openrc.sh"
echo "  - Vous devez modifier ce fichier avec les bons IDs pour l'utiliser"
echo ""
echo "Authelia : Installé et configuré"
echo "  - URL: https://auth.example.com"
echo "  - Identifiants: admin / admin ou user / password"
echo ""
echo "Nginx : Installé et configuré"
echo "  - Site protégé: https://protected.example.com"
echo "  - Portail d'authentification: https://auth.example.com"
echo ""
echo "REMARQUES IMPORTANTES :"
echo "- Certains certificats auto-signés ont été générés. En production, utilisez Let's Encrypt."
echo "- Changez les mots de passe par défaut pour la sécurité."
echo "- Modifiez les domaines example.com selon vos besoins."
echo "==================================================================="
echo ""

exit 0
