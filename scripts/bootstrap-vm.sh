#!/usr/bin/env bash
# ============================================================
# bootstrap-vm.sh — preparação one-shot da VM de homolog
# ============================================================
# Execute UMA VEZ na VM (Ubuntu 22.04+ recomendado) como root ou via sudo.
#
#   ssh caio@34.173.88.79
#   wget https://raw.githubusercontent.com/<seu-user>/<repo>/main/scripts/bootstrap-vm.sh
#   chmod +x bootstrap-vm.sh
#   sudo ./bootstrap-vm.sh
#
# Ou copie o arquivo via scp e rode local.
# ============================================================
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "[!] Rode como root (sudo ./bootstrap-vm.sh)" >&2
  exit 1
fi

ADMIN_PUBKEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB6WyIUHd/CyV+6rzUbC/6RbVVengPYwbAT1WetbsO7T caio.sr06@gmail.com'
DEPLOY_USER='deploy'
APP_DIR='/opt/programatico'

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# ---------- 1. Pacotes base ----------
log 'Atualizando apt e instalando pacotes base'
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl gnupg ufw rsync git

# ---------- 2. Docker + Compose plugin ----------
if ! command -v docker >/dev/null 2>&1; then
  log 'Instalando Docker Engine + Compose plugin'
  install -m 0755 -d /etc/apt/keyrings
  . /etc/os-release
  curl -fsSL "https://download.docker.com/linux/${ID}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  chmod a+r /etc/apt/keyrings/docker.gpg
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
else
  log 'Docker já instalado — pulando'
fi

# ---------- 3. Usuário deploy ----------
if ! id -u "$DEPLOY_USER" >/dev/null 2>&1; then
  log "Criando usuário '$DEPLOY_USER'"
  useradd -m -s /bin/bash "$DEPLOY_USER"
fi
usermod -aG docker "$DEPLOY_USER"

# Diretório SSH do deploy user
install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh"
AUTH_KEYS="/home/$DEPLOY_USER/.ssh/authorized_keys"
touch "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"
chown "$DEPLOY_USER:$DEPLOY_USER" "$AUTH_KEYS"

# Adiciona pubkey admin (se ainda não estiver)
if ! grep -qF "$ADMIN_PUBKEY" "$AUTH_KEYS"; then
  echo "$ADMIN_PUBKEY" >> "$AUTH_KEYS"
  log 'Pubkey admin adicionada ao deploy user'
fi

# ---------- 4. Keypair dedicado pro GitHub Actions ----------
GHA_KEY="/home/$DEPLOY_USER/.ssh/gha_deploy"
if [[ ! -f "$GHA_KEY" ]]; then
  log 'Gerando keypair pro GitHub Actions (PRIVATE KEY será impressa no fim)'
  sudo -u "$DEPLOY_USER" ssh-keygen -t ed25519 -N '' -f "$GHA_KEY" -C 'gh-actions@programatico-homolog'
  cat "$GHA_KEY.pub" >> "$AUTH_KEYS"
  chown "$DEPLOY_USER:$DEPLOY_USER" "$AUTH_KEYS"
fi

# ---------- 5. Diretório da aplicação ----------
log "Preparando $APP_DIR"
install -d -m 755 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$APP_DIR"

# ---------- 6. Firewall (UFW) ----------
log 'Configurando UFW (libera 22 e 80)'
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw --force enable

# ---------- 7. Swap (folga em VM de 4GB) ----------
if [[ ! -f /swapfile ]]; then
  log 'Criando swapfile de 2GB'
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  sysctl -w vm.swappiness=10 >/dev/null
  echo 'vm.swappiness=10' > /etc/sysctl.d/99-swap.conf
fi

# ---------- 8. Docker daemon: log rotation ----------
if [[ ! -f /etc/docker/daemon.json ]]; then
  log 'Configurando log rotation do Docker'
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
JSON
  systemctl restart docker
fi

# ---------- Saída ----------
cat <<EOF


================================================================
 BOOTSTRAP CONCLUÍDO
================================================================

 1. NO GCP CONSOLE  abra a porta 80 (TCP) no firewall da VPC
    (a UFW da VM já libera, mas o firewall do GCP é separado):

      gcloud compute firewall-rules create allow-http-homolog \\
        --direction=INGRESS --action=ALLOW --rules=tcp:80 \\
        --source-ranges=0.0.0.0/0 --target-tags=http-server

    e adicione a tag 'http-server' à VM, OU faça pelo console.

 2. COPIE A PRIVATE KEY ABAIXO  e cole em GitHub:
      Settings → Secrets and variables → Actions → New repository secret
      Nome: VM_SSH_KEY

----- BEGIN OPENSSH PRIVATE KEY -----
$(cat "$GHA_KEY")
----- END OPENSSH PRIVATE KEY -----

 3. CRIE OS DEMAIS SECRETS NO GITHUB:
      VM_HOST            = 34.173.88.79
      VM_USER            = deploy
      DB_ROOT_PASSWORD   = (gera com: openssl rand -base64 24)
      DB_PASSWORD        = (gera com: openssl rand -base64 24)
      JWT_SECRET         = (gera com: openssl rand -base64 48)
      ADMIN_EMAIL        = admin@programatico.com
      ADMIN_USERNAME     = admin
      ADMIN_PASSWORD     = (escolhe uma forte)
      MAIL_USERNAME      = seu-gmail@gmail.com
      MAIL_PASSWORD      = (Gmail App Password)

 4. PRIMEIRO DEPLOY: faça push pra branch 'homolog' (ou 'main').
    O workflow .github/workflows/deploy-homolog.yml cuida do resto.

 5. ACESSO:
      Usuário:  http://34.173.88.79
      Admin:    http://34.173.88.79/admin/login

================================================================
EOF
