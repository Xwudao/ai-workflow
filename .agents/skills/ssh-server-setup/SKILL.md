---
name: ssh-server-setup
description: Configure/harden an SSH server from the client — migrate the sshd port, enable pubkey login, disable password auth, and add a user to sudo. Includes safe multi-phase steps to avoid locking yourself out, and the "local transparent proxy ACKs every port" pitfall that makes local nc/port tests lie.
allowed-tools: Bash(*) Bash(scp:*) Bash(expect:*) Bash(ssh:*)
---

# SSH Server Setup / Hardening

Use when you must reconfigure a remote SSH server from this machine: change the
listening port, set up pubkey-only login, disable password auth, or grant sudo
to a user. The goal is to **never lock yourself out**.

## TL;DR recipe

```bash
# 0) confirm connectivity + correct username (check server allows password)
# 1) install pubkey, verify key login works on CURRENT port FIRST
# 2) add NEW port as an ADDITION to current port (keep password auth ON), restart, verify
# 3) ONLY THEN: remove old port, disable password auth, restart, verify
# 4) grant sudo and confirm with sudo -l
```

## Principles (the important part)

- **SSH down = gone.** If you mess up the port and disable password before
  verifying pubkey, and the new port is firewalled/not reachable, you're locked
  out (only cloud console can recover). So: **every change is staged and verified
  before the next is applied.**
- **`sshd_config` uses FIRST value wins** for an option (not last). If an
  uncommented `PasswordAuthentication yes` already exists lower in the file, a
  later `PasswordAuthentication no` will be **silently ignored**. Edit the
  existing active line in place, or insert your directive *above* it.
- **Authoritative ground truth = the server.** `ss -tlnp`, `sshd -T`, and
  `systemctl status ssh` on the box. Never trust a port probe from this laptop.

## Environment notes (this repo)

- macOS client, no `sshpass` → use **`expect`** to supply the password
  (`apple-system` ships `/usr/bin/expect`). `timeout` is NOT available on macOS
  (it's GNU coreutils); use `nc -w N`.
- Put the password in an env var, not the process args, when calling `expect`
  (minimises exposure in `ps`/shell history): `export SSH_PASSWORD='...'`.

## Phase 0 — discover the username & test login

Root login is often denied and the real account is `ubuntu`/`admin`. Probe
before assuming.

```bash
cat > /tmp/ssh_expect.sh <<'EOF'
#!/usr/bin/expect -f
set timeout 20
set host [lindex $argv 0]; set port [lindex $argv 1]
set user [lindex $argv 2]; set cmd [lindex $argv 3]
set pw $env(SSH_PASSWORD)
spawn ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $port $user@$host $cmd
expect {
  "*yes/no*" { send "yes\r"; exp_continue }
  "*password:*" { send "$pw\r"; exp_continue }
  eof
}
EOF
chmod +x /tmp/ssh_expect.sh
export SSH_PASSWORD='...'
for u in root ubuntu admin; do
  echo "== user $u =="; /tmp/ssh_expect.sh HOST 22 "$u" 'whoami'
done
```

Add an `scp` variant if you need to push your pubkey:
```bash
# same expect pattern but: spawn scp -o ... -P $port $local $user@$host:$remote
```

## Phase 1 — install pubkey & prove key login works (on the CURRENT port, before anything else)

```bash
scp ~/.ssh/id_rsa.pub ubuntu@HOST:/tmp/tim_pub.pub   # via expect/scp helper
ssh ubuntu@HOST 'mkdir -p ~/.ssh && chmod 700 ~/.ssh \
  && cp /tmp/tim_pub.pub ~/.ssh/authorized_keys \
  && chmod 600 ~/.ssh/authorized_keys && rm /tmp/tim_pub.pub'

# verify key-only login (BatchMode = no password prompt), on CURRENT port 22:
ssh -i ~/.ssh/id_rsa -o BatchMode=yes -o ConnectTimeout=15 -p 22 ubuntu@HOST 'echo KEY_LOGIN_OK; whoami'
```

Only proceed once this returns `KEY_LOGIN_OK`. Correct perms: `~/.ssh` = 700,
`authorized_keys` = 600, owner = the user.

## Phase 2 — ADD the new port (keep both), restart, verify

`Port` is additive in sshd_config (multiple lines = multiple listeners), but the
*-default* (22) is only used when NO `Port` line exists. So to keep 22 and add
3454 you must state **both**. Also back up the config and validate with
`sshd -t` before restarting.

```bash
ssh ubuntu@HOST '
  sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)
  sudo sed -i "/^#Port 22/a Port 22\nPort 3454" /etc/ssh/sshd_config   # uncomment as active
  sudo /usr/sbin/sshd -t && echo CONFIG_VALID
  sudo systemctl restart ssh && echo RESTARTED'
```

The restart kills the current session (expect will exit) — that's fine. Then test:

```bash
ssh -i ~/.ssh/id_rsa -o BatchMode=yes -p 3454 ubuntu@HOST 'echo PORT3454_OK; whoami'
```

If this works, the new port is reachable (through any cloud security group too)
and pubkey login works on it. If it times out, the cloud security group still
blocks 3454 — **revert the port change** and have the user open it in the console
before proceeding.

## Phase 3 — remove old port + disable password auth (only now)

Edit the **active** lines in place (first-value-wins!):

```bash
ssh ubuntu@HOST '
  sudo sed -i "/^Port 22$/d" /etc/ssh/sshd_config                     # stop listening on 22
  sudo sed -i "s/^PermitRootLogin yes$/PermitRootLogin no/" /etc/ssh/sshd_config
  sudo sed -i "s/^PasswordAuthentication yes$/PasswordAuthentication no/" /etc/ssh/sshd_config
  sudo sed -i "/^Port 3454$/a PubkeyAuthentication yes" /etc/ssh/sshd_config
  sudo /usr/sbin/sshd -t && echo CONFIG_VALID
  sudo systemctl restart ssh && echo RESTARTED'
```

Verify all three at once (connect via pubkey on the new port):
```bash
ssh -i ~/.ssh/id_rsa -o BatchMode=yes -p 3454 ubuntu@HOST 'sudo sshd -T | grep -Ei "^(port|passwordauthentication|pubkeyauthentication|permitrootlogin)"'
# expect: port 3454, passwordauthentication no, pubkeyauthentication yes, permitrootlogin no
```

## Phase 4 — grant sudo (usually already there)

```bash
ssh ubuntu@HOST '
  groups                      # is "sudo" already listed?  (Ubuntu default images usually include it)
  getent group sudo           # echo sudo:x:27:ubuntu if a member
  sudo -n -l                  # show NOPASSWD / ALL
  sudo whoami                 # expect root'
```

If not already a member: `sudo usermod -aG sudo ubuntu` (Ubuntu group is `sudo`;
on some distros it's `wheel`). The new group applies to **new login sessions**.

## Verify state from the server (ground truth)

```bash
ssh -i ~/.ssh/id_rsa -p 3454 ubuntu@HOST 'sudo ss -tlnp | grep -E ":(22|3454)\b"'
# only 3454 should appear; nothing on :22
```

## Pitfalls (learned on this repo)

| Pitfall | What happens | Fix |
|---|---|---|
| **Local transparent proxy ACKs every TCP port** (Surge/Clash 127.0.0.1:1082 in this repo) | `nc -z HOST 22` AND `nc -z HOST 55555` both report `OPEN`; even random closed ports look open | Never trust local port probes. Use `ss -tlnp` / `sshd -T` **on the server** as ground truth. `nmap`/`nc` from this machine are unreliable |
| `timeout` not on macOS | `timeout: command not found` | Use `nc -w N` for read/idle timeouts, or `expect`'s `set timeout` |
| `sshd_config` **first value wins** | Appending `PasswordAuthentication no` after an existing active `PasswordAuthentication yes` is ignored | Edit the active line in place, or insert your directive above it |
| A single `Port 3454` **replaces** the default 22 | You lose port 22 immediately | To keep 22 during migration, write BOTH `Port 22` and `Port 3454` |
| Wrong username | `root` password rejected ("Permission denied") though the password is correct | Probe root/ubuntu/admin; Ubuntu cloud images usually use `ubuntu` |
| Restart drops your session | The command seems to hang / lose output | Run `sshd -t` first; then restart; reconnect on the new port in a fresh command |
| `/etc/profile.d` setenv unknown | (unrelated) | — |

## Cleanup

Delete the temp `/tmp/ssh_expect.sh` / `/tmp/scp_expect.sh` helpers and don't
leave the password in any repo file. The config backup is on the server at
`/etc/ssh/sshd_config.bak.*`; rollback = restore it + `systemctl restart ssh`.
