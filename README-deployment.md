# Deploying the Coming Soon site

This repo is a FastAPI "coming soon" page, packaged with Docker Compose and
fronted by Nginx. A GitHub Actions workflow tests every pull request and,
on a push to `main` (or a manual `workflow_dispatch`), SSHes into an AWS EC2
Amazon Linux 2023 instance and runs `scripts/deploy.sh`.

## One-time EC2 setup

1. Launch an **Amazon Linux 2023** EC2 instance (x86_64 or ARM is fine).
   The default SSH login user is `ec2-user`, not `ubuntu`.

2. In the instance's **security group**, allow inbound TCP:

   | Port | Why |
   | --- | --- |
   | 22 | SSH for bootstrap and CI deploys |
   | 80 | HTTP (Nginx) |
   | 443 | HTTPS, once you enable TLS |

   Restrict port 22 to your IP and to GitHub Actions (or a self-hosted
   runner) if you can. Ports 80 and 443 need to be reachable by visitors.

3. Copy `scripts/bootstrap_ec2.sh` onto the instance and run it as
   `ec2-user`, passing the Git repo URL. For this public repository,
   HTTPS is the simplest remote (no deploy key required for `git fetch`):

   ```bash
   ssh -i your-key.pem ec2-user@<ELASTIC_IP>
   # copy the script up, or:
   curl -fsSL https://raw.githubusercontent.com/nerdish05/comingSoon/main/scripts/bootstrap_ec2.sh -o bootstrap_ec2.sh
   chmod +x bootstrap_ec2.sh
   ./bootstrap_ec2.sh https://github.com/nerdish05/comingSoon.git
   ```

   The script installs Docker and the Compose plugin, creates a low-privilege
   `deploy` user (in the `docker` group), and clones the repo into
   `/opt/coming-soon-site`. It does **not** start the containers; the first
   successful Actions deploy (or a manual `docker compose up -d` from
   `APP_DIR`) does that.

4. Create an SSH key pair **for the deploy user** (do not reuse your
   personal `ec2-user` key). On your laptop:

   ```bash
   ssh-keygen -t ed25519 -f comingsoon-deploy -C "github-actions-deploy" -N ""
   ```

   Add the **public** key to the deploy user's `authorized_keys` on the
   instance:

   ```bash
   # from your laptop
   ssh -i your-key.pem ec2-user@<ELASTIC_IP>
   sudo tee -a /home/deploy/.ssh/authorized_keys < comingsoon-deploy.pub
   # or, after copying the .pub file up:
   sudo sh -c 'cat comingsoon-deploy.pub >> /home/deploy/.ssh/authorized_keys'
   sudo chown deploy:deploy /home/deploy/.ssh/authorized_keys
   sudo chmod 600 /home/deploy/.ssh/authorized_keys
   ```

   Confirm you can log in as `deploy` with the **private** key before
   wiring up CI:

   ```bash
   ssh -i comingsoon-deploy deploy@<ELASTIC_IP> 'whoami && docker compose version'
   ```

   Keep the private key only in a password manager and in the
   `EC2_SSH_KEY` GitHub Actions secret. Never commit it.

## GitHub Actions secrets

Create these four repository secrets (Settings → Secrets and variables →
Actions, or `gh secret set` as shown below):

| Secret | Value |
| --- | --- |
| `EC2_HOST` | Public IPv4 address or DNS name of the instance |
| `EC2_USER` | `deploy` |
| `EC2_SSH_KEY` | The full private key PEM for the deploy user (including the `BEGIN`/`END` lines) |
| `APP_DIR` | `/opt/coming-soon-site` (optional; the workflow defaults to this if the secret is empty) |

With the [GitHub CLI](https://cli.github.com/), from a checkout of this
repo (or with `-R nerdish05/comingSoon`):

```bash
gh secret set EC2_HOST          # paste the host, then Ctrl-D
gh secret set EC2_USER          # paste: deploy
gh secret set EC2_SSH_KEY < comingsoon-deploy
gh secret set APP_DIR           # paste: /opt/coming-soon-site
```

`gh secret set EC2_SSH_KEY` can also read the key from a file as shown, which
avoids pasting it into the terminal.

Do not put these values in the workflow file or in the repo.

## How deploys work

The workflow in `.github/workflows/deploy.yml` does the following:

1. On every **push** to `main`, **pull request** targeting `main`, and
   **manual run** (`workflow_dispatch`), the `test` job:

   - installs Python 3.11, `requirements.txt`, `pytest`, and `httpx`
   - runs `pytest`
   - builds the Docker image, starts the container, and `curl`s
     `http://127.0.0.1:8000/` expecting HTTP 200

2. The `deploy` job runs only after `test` succeeds, and only on a
   **push to `main`** or **`workflow_dispatch`**. It does not deploy from
   pull requests. A concurrency group (`deploy-coming-soon`) ensures
   two deploys never run at the same time; an in-flight deploy is not
   cancelled.

3. `appleboy/ssh-action` logs in as `EC2_USER` at `EC2_HOST` with
   `EC2_SSH_KEY` and runs:

   ```bash
   APP_DIR=${APP_DIR} bash ${APP_DIR}/scripts/deploy.sh
   ```

   `APP_DIR` comes from the secret, or `/opt/coming-soon-site` if the
   secret is empty.

4. `scripts/deploy.sh` `git fetch`es, hard-resets to `origin/main`,
   rebuilds the `web` image, and runs `docker compose up -d` for `web`
   and `nginx`. Because of the hard reset, any uncommitted edits on the
   server (for example a local change to `nginx/coming-soon.conf`) will
   be overwritten — commit those changes instead.

After the first successful deploy, the page is served on port 80 of the
instance. Point a domain at the Elastic IP (or use the IP directly for
a smoke check).

## Optional: TLS with Certbot

Nginx and Compose ship with HTTPS commented out until certificates exist.
The placeholders use `your-domain.com` — replace that with your real
domain in `nginx/coming-soon.conf` (and in the commands below) and
commit the change before issuing certs.

1. Point DNS at the instance and wait for it to resolve.

2. On the instance, create the webroot and cert directories that the
   commented Compose volumes expect, then uncomment these pieces:

   - In `docker-compose.yml`, the `443:443` port mapping and the two
     `certbot` volumes on the `nginx` service:

     ```yaml
     ports:
       - "80:80"
       - "443:443"
     volumes:
       - ./nginx/coming-soon.conf:/etc/nginx/conf.d/default.conf:ro
       - ./certbot/conf:/etc/letsencrypt:ro
       - ./certbot/www:/var/www/certbot:ro
     ```

   - In `nginx/coming-soon.conf`, the ACME challenge location inside the
     port-80 server:

     ```nginx
     location /.well-known/acme-challenge/ {
         root /var/www/certbot;
     }
     ```

3. Recreate Nginx so it is listening with the webroot mounted, then
   issue the certificate (the `certbot` dirs live under `APP_DIR` and
   are gitignored):

   ```bash
   cd /opt/coming-soon-site
   mkdir -p certbot/conf certbot/www
   docker compose up -d nginx
   docker run --rm \
     -v "$(pwd)/certbot/conf:/etc/letsencrypt" \
     -v "$(pwd)/certbot/www:/var/www/certbot" \
     certbot/certbot certonly --webroot \
     -w /var/www/certbot \
     -d your-domain.com \
     --email you@example.com \
     --agree-tos --no-eff-email
   ```

4. Uncomment the HTTPS `server` block in `nginx/coming-soon.conf`
   (the one that `listen 443 ssl` and points at
   `/etc/letsencrypt/live/your-domain.com/fullchain.pem` and
   `privkey.pem`). Reload Nginx:

   ```bash
   docker compose exec nginx nginx -s reload
   ```

5. Commit the Nginx and Compose uncommented config so the next
   `deploy.sh` run does not revert them. Renewals can be a cron or
   systemd timer that re-runs `certbot renew` with the same volume
   mounts and then reloads Nginx.

## Troubleshooting

**The page is not loading**

- Confirm the security group allows inbound TCP **port 80** (and 443
  if you enabled TLS) from your client. A timeout with no response is
  often a security-group miss, not an application bug.
- On the instance, from `APP_DIR`:

  ```bash
  docker compose ps
  docker compose logs web nginx
  ```

  Both `coming-soon-web` and `coming-soon-nginx` should be up. If `web`
  is restarting, the app logs usually say why. If `nginx` is up but
  you get 502, `web` is not reachable on the `app-net` network.

- `nginx/coming-soon.conf` still has `server_name your-domain.com`.
  With only that one server block, Nginx will use it as the default
  and a request to the Elastic IP should still work. After you add
  more server blocks, or if something else is bound to port 80, set
  `server_name` to your real domain (or `_`) and redeploy.

**`deploy` user cannot run Docker**

- `bootstrap_ec2.sh` adds `deploy` to the `docker` group, but group
  membership is applied at login. The user needs a **fresh SSH
  session** after being added to the group (or `newgrp docker`). If
  the user already existed when you re-ran bootstrap, the script
  skips user setup — add the group yourself with
  `sudo usermod -aG docker deploy` and reconnect.

**`deploy.sh` fails on `git fetch` or `git reset`**

- The repo must already be cloned at `APP_DIR` (that is what
  bootstrap does). `deploy.sh` does not clone from scratch.
- The `deploy` user must be able to `git fetch` from `origin`. The
  simplest setup for this public repo is an **HTTPS** remote:

  ```bash
  sudo -u deploy git -C /opt/coming-soon-site remote -v
  # if it is an SSH URL and fetch fails, switch it:
  sudo -u deploy git -C /opt/coming-soon-site remote set-url origin https://github.com/nerdish05/comingSoon.git
  ```

  An SSH remote (`git@github.com:...`) also works, but then the
  deploy user needs a GitHub deploy key (read-only) in
  `~/.ssh` and a working `known_hosts` entry.

**GitHub Actions deploy fails to SSH**

- Recheck `EC2_HOST`, `EC2_USER=deploy`, and that `EC2_SSH_KEY` is the
  private key matching the public key in
  `/home/deploy/.ssh/authorized_keys`.
- Confirm port 22 is open to GitHub-hosted runners (or temporarily
  `0.0.0.0/0` while you test).
- `APP_DIR` must match the clone path, usually `/opt/coming-soon-site`.
