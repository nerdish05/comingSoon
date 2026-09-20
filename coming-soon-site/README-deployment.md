# Deploying to AWS EC2 — Setup Guide

This pipeline works like this, going forward:

```
git push origin main
      │
      ▼
GitHub Actions (test-build job)
  - installs deps, sanity-checks the app, builds the Docker image
      │
      ▼
GitHub Actions (deploy job)
  - SSHes into your EC2 box as the "deploy" user
  - runs scripts/deploy.sh on the instance
      │
      ▼
EC2 instance
  - git pulls latest code
  - docker compose rebuilds the "web" image
  - swaps the running container, Nginx keeps serving traffic
```

You do this AWS setup **once**. After that, every `git push` to `main` ships automatically.

---

## 1. Push this code to a GitHub repo

```bash
git init
git add .
git commit -m "Initial commit: coming soon site + deploy pipeline"
git branch -M main
git remote add origin git@github.com:<your-org>/<your-repo>.git
git push -u origin main
```

## 2. Launch the EC2 instance

In the AWS Console (or CLI):

- **AMI**: Ubuntu Server 22.04 LTS
- **Instance type**: `t3.micro` is plenty for a static/coming-soon page
- **Key pair**: create or reuse one (you'll use this once, for the bootstrap step — CI uses its own key, see step 4)
- **Security group inbound rules**:
  | Type  | Port | Source          |
  |-------|------|-----------------|
  | SSH   | 22   | your IP only    |
  | HTTP  | 80   | 0.0.0.0/0       |
  | HTTPS | 443  | 0.0.0.0/0       |
- **Storage**: default 8–20 GB gp3 is fine

Note the instance's public IP or, better, allocate an **Elastic IP** so it doesn't change on reboot.

## 3. Bootstrap the instance (one time)

SSH in with your key pair and run the bootstrap script:

```bash
ssh -i your-key.pem ubuntu@<EC2_PUBLIC_IP>

# on the instance:
curl -O https://raw.githubusercontent.com/<your-org>/<your-repo>/main/scripts/bootstrap_ec2.sh
chmod +x bootstrap_ec2.sh
./bootstrap_ec2.sh git@github.com:<your-org>/<your-repo>.git
```

This installs Docker, creates a dedicated `deploy` user, clones your repo into `/opt/coming-soon-site`, and opens ports 80/443 via `ufw`.

> If your repo is private, either use an HTTPS URL with a personal access token, or add a deploy key to the repo before cloning.

## 4. Give GitHub Actions SSH access

On your local machine, generate a dedicated key pair **for CI only** (don't reuse your personal one):

```bash
ssh-keygen -t ed25519 -f ci_deploy_key -N ""
```

- Copy `ci_deploy_key.pub` into the EC2 instance's deploy user:
  ```bash
  ssh -i your-key.pem ubuntu@<EC2_PUBLIC_IP> \
    "sudo tee -a /home/deploy/.ssh/authorized_keys" < ci_deploy_key.pub
  ```
- In your GitHub repo: **Settings → Secrets and variables → Actions → New repository secret**, add:
  | Secret name    | Value                                  |
  |----------------|-----------------------------------------|
  | `EC2_HOST`     | Your EC2 public IP or Elastic IP        |
  | `EC2_USER`     | `deploy`                                |
  | `EC2_SSH_KEY`  | Contents of `ci_deploy_key` (private key) |
  | `APP_DIR`      | `/opt/coming-soon-site`                 |

## 5. Ship it

```bash
git push origin main
```

Watch the run under the **Actions** tab. Once it's green, visit `http://<EC2_PUBLIC_IP>` — you should see the flashing coming-soon page.

---

## Optional: point a real domain + HTTPS at it

1. In your DNS provider, add an **A record** for `your-domain.com` → your EC2 Elastic IP.
2. Update `nginx/coming-soon.conf`: replace `your-domain.com` with your real domain, commit, push.
3. On the EC2 instance, get a free cert with Certbot:
   ```bash
   cd /opt/coming-soon-site
   sudo apt-get install -y certbot
   sudo certbot certonly --standalone -d your-domain.com --pre-hook "docker compose stop nginx" --post-hook "docker compose start nginx"
   ```
4. In `docker-compose.yml`, uncomment the `443:443` port and the certbot volume mounts.
5. In `nginx/coming-soon.conf`, uncomment the HTTPS `server` block and the ACME-challenge `location` block.
6. Push — the next deploy picks up the new config. Certs auto-renew via `certbot renew` (add a cron job or systemd timer on the instance for this).

## Day-to-day workflow going forward

- Edit `static/index.html` (or add real routes/logic to `main.py`) locally.
- Test locally: `docker compose up --build` then visit `http://localhost`.
- `git push origin main` — the pipeline handles the rest.
- To roll back, `git revert` the bad commit and push again; the same pipeline redeploys the previous version.
- To deploy manually without a new commit, use the **Run workflow** button on the `Deploy to EC2` workflow in the Actions tab (this is what `workflow_dispatch` enables).

## Troubleshooting

- **Actions job fails at the SSH step**: check the security group allows inbound 22 from GitHub's runners (or leave it open to your IP and self-host a runner — public runners have rotating IPs, so if you lock SSH down tightly you may need a self-hosted runner or a bastion approach).
- **Site unreachable after deploy**: `ssh` in and run `docker compose logs -f` in `/opt/coming-soon-site` to see container logs.
- **Out of disk from old images**: `deploy.sh` already runs `docker image prune -f` after each deploy; for a deeper clean run `docker system prune -af` manually.
