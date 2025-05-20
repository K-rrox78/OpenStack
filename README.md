# Documentation d'Architecture Technique (DAT)
# Installation d'OpenStack (Nova & Terraform), Authelia, et Nginx

## Table des matières

1. [Introduction](#introduction)
2. [Prérequis](#prérequis)
3. [Installation d'OpenStack (Nova)](#installation-dopenstack-nova)
4. [Configuration de Terraform pour OpenStack](#configuration-de-terraform-pour-openstack)
5. [Installation et configuration d'Authelia avec Docker Compose](#installation-et-configuration-dauthelia-avec-docker-compose)
6. [Installation et configuration de Nginx](#installation-et-configuration-de-nginx)
7. [Intégration d'Authelia avec Nginx](#intégration-dauthelia-avec-nginx)
8. [Validation et tests](#validation-et-tests)
9. [Dépannage](#dépannage)
10. [Références](#références)

## Introduction

Cette documentation technique détaille le processus d'installation et de configuration d'un environnement complet incluant:
- OpenStack avec le service Nova pour la gestion des instances de calcul
- Terraform pour l'Infrastructure as Code (IaC) avec OpenStack
- Authelia pour l'authentification et l'autorisation
- Nginx comme serveur web/proxy inverse

L'objectif est de fournir un guide étape par étape pour configurer un environnement sécurisé et robuste.

## Prérequis

### Matériel recommandé
- CPU: Minimum 4 cœurs (8+ recommandés)
- RAM: Minimum 16 Go (32+ Go recommandés)
- Stockage: Minimum 100 Go d'espace libre

### Logiciels requis
- Système d'exploitation: Ubuntu 22.04 LTS (recommandé)
- Docker et Docker Compose
- Git
- Python 3.8+

### Réseau
- Connexion Internet stable
- Ports à ouvrir:
  - 80/443 (HTTP/HTTPS)
  - 9091 (Authelia)
  - 5000 (Keystone)
  - 8774 (Nova)

## Installation d'OpenStack (Nova)

### Préparation du système

```bash
# Mise à jour du système
sudo apt update && sudo apt upgrade -y

# Installation des dépendances
sudo apt install -y python3-pip python3-dev libffi-dev gcc libssl-dev git
```

### Installation de DevStack

DevStack est la méthode recommandée pour une installation rapide d'OpenStack en environnement de développement.

```bash
# Créer un utilisateur stack
sudo useradd -s /bin/bash -d /opt/stack -m stack
sudo chmod +x /opt/stack
echo "stack ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/stack

# Passer à l'utilisateur stack
sudo su - stack

# Cloner le dépôt DevStack
git clone https://opendev.org/openstack/devstack
cd devstack

# Créer le fichier de configuration local.conf
cat > local.conf << EOF
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
EOF

# Lancer l'installation
./stack.sh
```

L'installation prendra environ 30-45 minutes selon les performances du système.

### Vérification de l'installation

```bash
# Vérifier les services OpenStack
source openrc admin admin
openstack service list
openstack compute service list
```

Vous devriez voir tous les services Nova listés et en état "up".

### Configuration pour la production

Pour un environnement de production, consultez la documentation officielle d'OpenStack pour l'installation manuelle des services: https://docs.openstack.org/nova/latest/install/

## Configuration de Terraform pour OpenStack

### Installation de Terraform

```bash
# Ajouter la clé GPG HashiCorp
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg

# Ajouter le dépôt HashiCorp
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list

# Mettre à jour et installer Terraform
sudo apt update && sudo apt install terraform
```

### Configuration du provider OpenStack

Créez un répertoire pour votre projet Terraform:

```bash
mkdir -p ~/terraform-openstack
cd ~/terraform-openstack
```

Créez un fichier `provider.tf`:

```hcl
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
```

Créez un fichier `variables.tf`:

```hcl
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
```

Créez un fichier `main.tf` pour définir vos ressources:

```hcl
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
```

### Fichier d'environnement pour Terraform

Créez un fichier `openrc.sh` pour stocker les variables d'environnement:

```bash
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
export TF_VAR_image_id="ID_DE_VOTRE_IMAGE"
export TF_VAR_flavor_id="ID_DE_VOTRE_FLAVOR"
export TF_VAR_network_id="ID_DE_VOTRE_RESEAU"
export TF_VAR_keypair_name="NOM_DE_VOTRE_KEYPAIR"
```

### Utilisation de Terraform avec OpenStack

```bash
# Charger les variables d'environnement
source openrc.sh

# Initialiser Terraform
terraform init

# Vérifier le plan d'exécution
terraform plan

# Appliquer la configuration
terraform apply
```

## Installation et configuration d'Authelia avec Docker Compose

### Préparation de l'environnement

```bash
# Créer un répertoire pour Authelia
mkdir -p ~/authelia
cd ~/authelia

# Créer les sous-répertoires nécessaires
mkdir -p config
```

### Configuration Docker Compose

Créez un fichier `docker-compose.yml`:

```yaml
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
    external: true

volumes:
  redis_data:
```

### Configuration d'Authelia

Créez un fichier `config/configuration.yml`:

```yaml
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
```

Créez le fichier `config/users_database.yml`:

```yaml
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
```

### Démarrage d'Authelia

```bash
# Créer le réseau Docker s'il n'existe pas
docker network create proxy

# Démarrer les conteneurs
docker-compose up -d
```

## Installation et configuration de Nginx

### Installation de Nginx

```bash
sudo apt update
sudo apt install -y nginx
```

### Configuration de base de Nginx

```bash
# Sauvegarde de la configuration par défaut
sudo cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak

# Créer un répertoire pour les certificats SSL
sudo mkdir -p /etc/nginx/ssl
```

Générer des certificats auto-signés pour le développement (remplacer par Let's Encrypt en production):

```bash
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/nginx/ssl/nginx.key \
  -out /etc/nginx/ssl/nginx.crt \
  -subj "/C=FR/ST=Paris/L=Paris/O=Organization/CN=example.com"
```

Créez le fichier de configuration principal `/etc/nginx/nginx.conf`:

```nginx
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
```

## Intégration d'Authelia avec Nginx

### Configuration de Nginx pour l'authentification Authelia

Créez un fichier `/etc/nginx/snippets/authelia-location.conf`:

```nginx
location /authelia {
    internal;
    set $upstream_authelia http://127.0.0.1:9091/api/verify;
    proxy_pass $upstream_authelia;
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";
    
    # Paramètres à transmettre à Authelia
    proxy_set_header X-Original-URL $scheme://$http_host$request_uri;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Host $http_host;
    proxy_set_header X-Forwarded-Uri $request_uri;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header Remote-User $remote_user;
    proxy_set_header Remote-Name $remote_user;
    
    # Configurer le timeout (important pour la validation 2FA)
    proxy_connect_timeout 5s;
    proxy_send_timeout 5s;
    proxy_read_timeout 5s;
}
```

Créez un fichier `/etc/nginx/snippets/authelia-authrequest.conf`:

```nginx
auth_request /authelia;
auth_request_set $target_url $scheme://$http_host$request_uri;
auth_request_set $user $upstream_http_remote_user;
auth_request_set $name $upstream_http_remote_name;
auth_request_set $groups $upstream_http_remote_groups;
auth_request_set $redirect $upstream_http_location;

error_page 401 =302 https://auth.example.com/?rd=$target_url;
```

### Configuration d'un site web protégé par Authelia

Créez un fichier `/etc/nginx/sites-available/protected.example.com.conf`:

```nginx
server {
    listen 80;
    server_name protected.example.com;
    
    # Redirection HTTP vers HTTPS
    return 301 https://$host$request_uri;
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
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        # Variables transmises par Authelia
        proxy_set_header Remote-User $user;
        proxy_set_header Remote-Name $name;
        proxy_set_header Remote-Groups $groups;
    }
    
    # Endpoint d'authentification Authelia
    include /etc/nginx/snippets/authelia-location.conf;
}
```

### Configuration du portail Authelia

Créez un fichier `/etc/nginx/sites-available/auth.example.com.conf`:

```nginx
server {
    listen 80;
    server_name auth.example.com;
    
    # Redirection HTTP vers HTTPS
    return 301 https://$host$request_uri;
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
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        # Pour WebSocket
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

### Activation des configurations et redémarrage de Nginx

```bash
# Créer les liens symboliques pour activer les configurations
sudo ln -s /etc/nginx/sites-available/protected.example.com.conf /etc/nginx/sites-enabled/
sudo ln -s /etc/nginx/sites-available/auth.example.com.conf /etc/nginx/sites-enabled/

# Vérifier la configuration
sudo nginx -t

# Redémarrer Nginx
sudo systemctl restart nginx
```

## Validation et tests

### Test d'OpenStack

```bash
# Sourcer les variables d'environnement OpenStack
source ~/devstack/openrc admin admin

# Vérifier que les services fonctionnent
openstack service list
openstack compute service list

# Créer une VM de test
openstack server create --flavor m1.tiny --image cirros --network private test-vm
```

### Test de Terraform

```bash
# Sourcer les variables d'environnement
source ~/terraform-openstack/openrc.sh

# Exécuter Terraform
cd ~/terraform-openstack
terraform apply -auto-approve
```

### Test d'Authelia et Nginx

1. Ajoutez les entrées dans le fichier `/etc/hosts` pour les tests:
   ```
   127.0.0.1 auth.example.com
   127.0.0.1 protected.example.com
   ```

2. Accédez à `https://protected.example.com`
   - Vous devriez être redirigé vers `https://auth.example.com`
   - Connectez-vous avec les identifiants configurés (admin/admin ou user/password)
   - Après authentification réussie, vous devriez accéder au service protégé

## Dépannage

### Problèmes avec OpenStack

1. Vérifiez les journaux:
   ```bash
   sudo journalctl -u devstack@*
   ```

2. Si un service ne démarre pas:
   ```bash
   # Redémarrez le service spécifique (exemple avec Nova API)
   sudo systemctl restart devstack@n-api
   ```

### Problèmes avec Authelia

1. Vérifiez les logs Docker:
   ```bash
   docker logs authelia
   ```

2. Vérifiez la configuration:
   ```bash
   docker exec -it authelia authelia validate-config
   ```

### Problèmes avec Nginx

1. Vérifiez les logs Nginx:
   ```bash
   sudo tail -f /var/log/nginx/error.log
   ```

2. Testez la configuration:
   ```bash
   sudo nginx -t
   ```

## Références

- [Documentation officielle OpenStack](https://docs.openstack.org/)
- [Documentation officielle Terraform](https://registry.terraform.io/providers/terraform-provider-openstack/openstack/latest/docs)
- [Documentation officielle Authelia](https://www.authelia.com/docs/)
- [Documentation officielle Nginx](https://nginx.org/en/docs/)
