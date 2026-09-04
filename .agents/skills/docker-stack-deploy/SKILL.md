---
name: docker-stack-deploy
description: Deploy a docker-compose stack (with offline image tarballs) on a Linux/Ubuntu server, including installing Docker on China/domestic servers via mirror, transferring & loading image tars, wiring up host sysctl/permissions/swap, and troubleshooting port/firewall exposure. Use when you need to stand up Docker containers on a remote server, especially Elasticsearch or a multi-service compose stack.
---

# Docker Stack Deploy (with offline image tarballs)

## Overview

A generic playbook for standing up a `docker-compose` stack on a remote Linux server — with emphasis on **domestic/China servers** where `apt` and Docker Hub are slow/blocked. Covers the full chain:

1. Install Docker via a **China mirror** (Aliyun/Tsinghua) using `$VERSION_CODENAME`.
2. Ship pre-downloaded **image tarballs** (only the services you need) and load them offline.
3. Prepare **host prerequisites** (sysctl, volume ownership, swap) that containers quietly fail without.
4. Wire up **port binding** and figure out whether a port is blocked by the **host firewall or the cloud security group**.
5. Verify the stack actually works (health endpoint, plugin load, analyzer smoke-test).

The concrete validated example is **Elasticsearch 7.17.7 + IK + HAO(hanlp) analyzers**, but the steps generalize to any compose stack.

---

## Step 0: Reach the server & inspect it first

Always SSH in and gather the facts before touching anything.

```bash
ssh <host> 'echo CONNECTED as $(whoami); cat /etc/os-release | head -6; uname -m; sudo -n true 2>&1 && echo "sudo OK (passwordless)"; which docker && docker --version || echo "docker not installed"; df -h /; free -h | head -2'
```

Key things to confirm:
- **Distro + codename** (e.g. `Ubuntu 22.04 → jammy`). This drives the mirror repo line.
- **Arch** (`x86_64` vs `arm64`) — drives `[arch=$(dpkg --print-architecture)]`.
- **Passwordless sudo?** Without it, every `sudo` becomes interactive — problematic over non-TTY automation.
- **Disk + RAM** — large image tars and ES heap need headroom.

> **Pitfall:** SSH may already be configured in `~/.ssh/config` — read it (`cat ~/.ssh/config`) so you use the right host/user/port/IdentityFile. Two aliases can point at the same IP:port with different user (e.g. `root@host` and `ubuntu@host`); reusing the same key is fine.

---

## Step 1: Install Docker on a China server (mirror, not the hardcoded Ubuntu method)

The classic official docs hardcode a codename (e.g. `bionic`) and pull `gpg`/packages from `download.docker.com`, which is slow/blocked in China. Instead use an Aliyun or Tsinghua mirror and let the codename resolve automatically.

> **Pitfall (the big one):** Never hardcode the codename — use `$(. /etc/os-release && echo "$VERSION_CODENAME")`. A hardcoded `bionic` on a `jammy` box points apt at the wrong (18.04) repo, and Docker won't install.

### Aliyun mirror (default — most reliable)

```bash
sudo apt-get update
sudo apt-get -y install ca-certificates curl

sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL http://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] http://mirrors.aliyun.com/docker-ce/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

### Tsinghua mirror (fallback)

```bash
sudo apt-get install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

### After install

```bash
sudo systemctl enable docker && sudo systemctl restart docker
sudo usermod -aG docker "$USER"        # avoid `sudo docker` going forward
sudo systemctl is-active docker && sudo systemctl is-enabled docker
```

> **Pitfall:** `usermod -aG docker` only takes effect on the **next login**. The current shell won't have the group — test with `docker ps` (may need `sudo docker ps` until you re-login).

### Registry mirror (so image pulls aren't slow/blocked)

Write a `daemon.json` pointing at China registry mirrors, then restart Docker:

```bash
sudo mkdir -p /etc/docker
cat <<'EOF' | sudo tee /etc/docker/daemon.json
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://docker.1ms.run",
    "https://dockerproxy.com"
  ]
}
EOF
sudo systemctl daemon-reload && sudo systemctl restart docker
sudo docker info | grep -A3 "Registry Mirrors"
```

> **Pitfall (bandwidth):** Aliyun `apt` downloads can be slow (~134 kB/s in one case). If a 100 MB package set takes 10+ minutes, consider the Tsinghua mirror or just be patient — don't mistake slowness for a hang.

---

## Step 2: Ship image tarballs offline (only what you need)

When pre-downloaded images exist (e.g. `es.tar`, `mysql.tar`, `redis.tar`), transfer them and `docker load`. **Load only the services you actually run** to save transfer time.

### 2.1 Know what's inside the archives

Inspect archives before pushing gigabytes:

```bash
unzip -l images.zip          # list; often contains multiple *.tar
unzip -l es.zip              # may wrap a single *.tar inside
tar -tf es.tar | head        # if it's already a docker tar
```

> **Pitfall:** A zip can wrap a **single** `es.tar` (so a 350 MB `es.zip` holds a 622 MB `es.tar`). Transfer the **compressed** zip (smaller) and extract on the server: `unzip -o es.zip && docker load -i es.tar`.

### 2.2 Probe SSH throughput before a big transfer

A 100 MB probe tells you the real rate and whether a multi-hundred-MB push is a minute or an hour:

```bash
dd if=/dev/zero of=/tmp/probe.bin bs=1M count=100 2>/dev/null
time scp /tmp/probe.bin <host>:/tmp/ ; ssh <host> 'rm /tmp/probe.bin'; rm /tmp/probe.bin
# e.g. 100MB / 18s ≈ 5.5 MB/s → 350MB ≈ 60s
```

### 2.3 Transfer + load

```bash
scp <local>/es.zip <host>:~/appdir/
ssh <host> 'cd ~/appdir && unzip -o es.zip && sudo docker load -i es.tar'
sudo docker images        # confirm the tag (e.g. elasticsearch:7.17.7)
```

> **Pitfall:** `docker load` re-creates the image **tag from the tar's manifest**. The loaded tag **must match** the `image:` in your compose file, or `docker compose up` will try to `pull` (and fail/hang on a China server). If tags mismatch, `docker tag` the loaded image to the compose name.

---

## Step 3: Build the compose stack (trim to what you need)

A supplied compose often has services you don't want (e.g. `mysql`, `redis`). Keep only what's needed.

- Create a project dir (e.g. `~/es/`) on the server.
- Copy the compose + config files (**compressed** as one `tgz` for one small transfer).
- Strip unneeded services from `docker-compose.yml`.
- Create any **bind-mount volume dirs** and fix ownership (see Step 4).

```bash
# local: package config once
tar -czf es-config.tgz -C staging docker-compose.yml elasticsearch.yml plugins/
scp es-config.tgz <host>:~/es/
ssh <host> 'cd ~/es && tar -xzf es-config.tgz'
```

> **Pitfall:** `docker compose up` will **auto-create** bind-mount directories it needs — but as **root**. Containers running as a non-root user (uid 1000, e.g. the ES image) then can't write. Create the dir yourself and `chown` it to the container user before first start.

---

## Step 4: Elasticsearch (and similar stateful images) host prerequisites

These are the classic silent killers. Do them **before** the first start.

### 4.1 `vm.max_map_count` (bootstrap check)

ES running with `network.host` non-loopback (production mode) will **refuse to start** if `vm.max_map_count` is too low (default 65530). Set to **262144** and persist:

```bash
sudo sysctl -w vm.max_map_count=262144
echo "vm.max_map_count=262144" | sudo tee /etc/sysctl.d/99-elasticsearch.conf
sysctl vm.max_map_count
```

### 4.2 Data dir ownership (uid 1000)

The `elasticsearch` image runs as **uid 1000**, not root. `es-data` must be writable by it:

```bash
sudo mkdir -p es-data && sudo chown -R 1000:1000 es-data
```

### 4.3 Swap for low-RAM boxes

If RAM is tight (e.g. 3.6 GiB with a 1.2 GiB heap), add swap and lower swappiness so the JVM isn't aggressively swapped:

```bash
sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
echo "/swapfile none swap sw 0 0" | sudo tee -a /etc/fstab     # survive reboot
sudo sysctl -w vm.swappiness=10
echo "vm.swappiness=10" | sudo tee /etc/sysctl.d/99-swappiness.conf
swapon --show; free -h | grep -i swap
```

### 4.4 Single-node ES config

For a standalone node, rely on `discovery.type=single-node` (set via env in compose) and **comment out** the deprecated `discovery.zen.minimum_master_nodes` line — it was removed in ES 7.x and can break startup. Keep `node.master`/`node.data` (deprecated but working in 7.x).

---

## Step 5: Port binding — 0.0.0.0 vs 127.0.0.1, and the firewall problem

### 5.1 Change the bind address

`127.0.0.1:9200:9200` = localhost only; `0.0.0.0:9200:9200` (or `9200:9200`) = all interfaces.

```bash
sed -i "s/127.0.0.1:9200:9200/0.0.0.0:9200:9200/" docker-compose.yml
sudo docker compose up -d        # port changes require RECREATE, not restart
```

> **Pitfall:** A port change does **not** apply with `docker compose restart` — the container must be **recreated** (`up -d`). Bind-mounted data persists across recreation.

### 5.2 Where is the block? Host firewall vs cloud security group

A timeout from a public IP while the container is clearly listening means something is dropping packets.

```bash
# container side: is docker-proxy actually listening on 0.0.0.0?
sudo ss -tlnp | grep 9200

# host firewall? (ufw inactive + INPUT policy ACCEPT ⇒ not the host)
sudo ufw status | head -5
sudo iptables -S | head    # expect only Docker's own NAT/FORWARD rules

# from your local machine, hit the public IP — check HTTP code / exit code
curl -s -m 8 -o /dev/null -w "HTTP_CODE=%{http_code}\n" http://<PUBLIC_IP>:9200/
# 000 + exit 28 (timeout) ⇒ cloud security group is blocking
```

If the host firewall is clean but the public IP times out, the block is the **cloud provider security group** — you cannot fix it from inside the box. Instruct the user to add an inbound rule in the cloud console:

> Security Group → Inbound → **TCP / 9200 / 0.0.0.0/0** (or a trusted IP).

> **Pitfall:** Don't be fooled by `curl` piped through `| head` — the pipeline's exit code is `head`'s (0), so `|| echo "failed"` won't fire. Capture `-w "%{http_code}"` and the **curl exit code** separately.

---

## Step 6: Verify it actually works

Don't just check "up" — prove the service does its job.

```bash
# compose status
cd ~/appdir && sudo docker compose ps

# service health endpoint
curl -s http://127.0.0.1:9200/_cluster/health     # expect "status":"green"

# plugins loaded (ES)
curl -s http://127.0.0.1:9200/_cat/plugins?v

# functional smoke test of the analyzer
curl -s "http://127.0.0.1:9200/_analyze" -H "Content-Type: application/json" \
  -d '{"analyzer":"ik_max_word","text":"中华人民共和国国歌"}'
# expect sensible CN_WORD/CN_CHAR tokens — proves IK/HAO plugins actually tokenize
```

---

## Step 7: Confirm persistence & clean up

```bash
grep swap /etc/fstab                                    # swap survives reboot
grep -E "vm.max_map_count|vm.swappiness" /etc/sysctl.d/*.conf
sudo docker inspect <name> --format "{{.HostConfig.RestartPolicy.Name}}"  # "always"
```

Clean up transfer artifacts to avoid clutter:
- **Remote:** remove `*.zip`, `*.tgz` after extraction. Keep the image tar as a backup if space allows (e.g. `es.tar`).
- **Local:** remove staging dirs (`.tmp_*`, `.staging`, extracted zip trees).

> **Pitfall:** To avoid re-uploading a "complete" bundle, verify whether the server already has it before pushing. Recursively compare content: `find . -type f -print0 | sort -z | xargs -0 sha256sum ...` on both sides and `diff`.

---

## Security reminder

Bound to `0.0.0.0` + public port + **no auth** (ES basic license disables security) means anyone reaching the port can read/write. If exposing publicly, either restrict the security-group source to trusted IPs **or** enable authentication (e.g. `xpack.security.enabled=true` + set passwords with `elasticsearch-setup-passwords`).
