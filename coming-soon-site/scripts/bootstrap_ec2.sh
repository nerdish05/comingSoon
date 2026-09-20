#!/usr/bin/env bash
# Run ONCE on a fresh EC2 instance (Amazon Linux 2023) to prepare it for deployments.
# Usage: ./bootstrap_ec2.sh git@github.com:your-org/your-repo.git
#
# What this does:
#   1. Installs Docker + Docker Compose plugin
#   2. Creates a dedicated, low-privilege "deploy" user that CI will SSH in as
#   3. Clones the repo into /opt/coming-soon-site
#   4. Relies on the EC2 security group for port filtering (see note below)
#
# After running this, add the EC2 host, the deploy user, and an SSH private key
# for the deploy user as GitHub Actions secrets (see README-deployment.md).
#
# Login user note: Amazon Linux's default login is "ec2-user", not "ubuntu".
# Run this script logged in as ec2-user, e.g.:
#   ssh -i your-key.pem ec2-user@<ELASTIC_IP>

set -euo pipefail

REPO_URL="${1:?Usage: ./bootstrap_ec2.sh <git-repo-url>}"
APP_DIR="/opt/coming-soon-site"
DEPLOY_USER="deploy"

echo "==> Updating packages"
sudo dnf update -y

echo "==> Installing Docker and git"
sudo dnf install -y docker git
sudo systemctl enable --now docker

echo "==> Installing Docker Compose plugin"
if sudo dnf install -y docker-compose-plugin 2>/dev/null; then
  echo "    Installed docker-compose-plugin via dnf"
else
  echo "    Not available via dnf on this image — installing the CLI plugin manually"
  DOCKER_PLUGIN_DIR="/usr/local/lib/docker/cli-plugins"
  sudo mkdir -p "$DOCKER_PLUGIN_DIR"
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64) COMPOSE_ARCH="x86_64" ;;
    aarch64) COMPOSE_ARCH="aarch64" ;;
    *) echo "Unrecognized architecture: $ARCH — install docker compose manually"; COMPOSE_ARCH="x86_64" ;;
  esac
  sudo curl -fsSL \
    "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${COMPOSE_ARCH}" \
    -o "$DOCKER_PLUGIN_DIR/docker-compose"
  sudo chmod +x "$DOCKER_PLUGIN_DIR/docker-compose"
fi

echo "==> Creating deploy user"
if ! id -u "$DEPLOY_USER" >/dev/null 2>&1; then
  sudo useradd -m -s /bin/bash "$DEPLOY_USER"
  sudo usermod -aG docker "$DEPLOY_USER"
  sudo mkdir -p "/home/$DEPLOY_USER/.ssh"
  sudo touch "/home/$DEPLOY_USER/.ssh/authorized_keys"
  sudo chown -R "$DEPLOY_USER:$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh"
  sudo chmod 700 "/home/$DEPLOY_USER/.ssh"
  sudo chmod 600 "/home/$DEPLOY_USER/.ssh/authorized_keys"
  echo "   Created user '$DEPLOY_USER'. Add CI's public key to /home/$DEPLOY_USER/.ssh/authorized_keys"
fi

echo "==> Cloning repository into $APP_DIR"
sudo mkdir -p "$APP_DIR"
sudo chown "$DEPLOY_USER:$DEPLOY_USER" "$APP_DIR"
if [ ! -d "$APP_DIR/.git" ]; then
  sudo -u "$DEPLOY_USER" git clone "$REPO_URL" "$APP_DIR"
fi

echo "==> Firewall note"
echo "    Amazon Linux does not run ufw. Network filtering here is handled by"
echo "    the EC2 security group instead — confirm it allows inbound TCP 22,"
echo "    80, and 443. (Amazon Linux ships without firewalld enabled by"
echo "    default; this script does not turn it on. Add it yourself with"
echo "    'sudo dnf install -y firewalld' if you also want host-level rules.)"

echo "==> Bootstrap complete."
echo "    Next steps:"
echo "    1. Add your CI's public SSH key to /home/$DEPLOY_USER/.ssh/authorized_keys"
echo "    2. In the EC2 security group, allow inbound TCP 22, 80, 443"
echo "    3. Set GitHub Actions secrets: EC2_HOST, EC2_USER=$DEPLOY_USER, EC2_SSH_KEY, APP_DIR=$APP_DIR"
echo "    4. Push to main — the deploy workflow will take it from here"
