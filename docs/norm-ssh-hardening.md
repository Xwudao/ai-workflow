# norm (43.142.130.223) SSH 加固

新服务器 `norm`，Ubuntu 22.04.5 LTS（腾讯云，hostname `VM-4-5-ubuntu`），
完成：部署公钥登录、迁移 SSH 端口到 7544、关闭密码认证、本地新增 `norm` 别名。

## 现状（变更后）

| 项 | 值 |
|---|---|
| 主机名（本地别名） | `norm` |
| 公网 IP | `43.142.130.223` |
| 登录用户 | `ubuntu` |
| SSH 端口 | `7544`（22 已关闭） |
| 认证方式 | 仅公钥（`id_ed25519`），`PasswordAuthentication no` |
| root 登录 | `prohibit-password`（不允许密码，仅密钥；未安装 root 公钥） |
| sudo | `ubuntu` 免密 sudo（`sudo -n whoami` → root，无需加入额外组） |

验证：

```bash
ssh norm 'whoami; hostname'
ssh norm 'sudo sshd -T | grep -Ei "^(port|passwordauthentication|pubkeyauthentication|permitrootlogin)"'
ssh norm 'sudo ss -tlnp | grep -E ":(22|7544)\b"'   # 只应看到 7544
```

## 本地 ~/.ssh/config 别名

```sshconfig
Host norm
    HostName 43.142.130.223
    User ubuntu
    Port 7544
    IdentityFile ~/.ssh/id_ed25519
```

> 注意：本仓库运行环境对 `~/.ssh/config` 为 deny-tier 受保护路径，agent 无法写入，
> 该片段需由用户手动追加到 `~/.ssh/config`。

## 变更步骤与备份

1. 用密码首次登录 `ubuntu@43.142.130.223:22`，确认 `sudo -n whoami` 可免密提权。
2. 安装公钥：`~/.ssh/authorized_keys`（700/600 权限，去重写入）。
   - 先用 `ssh -o BatchMode=yes -p 22` 验证密钥登录成功，再动配置。
3. 追加新端口并保留旧端口：

   ```bash
   sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)
   sudo sed -i "s|^#Port 22$|Port 22\nPort 7544|" /etc/ssh/sshd_config
   sudo /usr/sbin/sshd -t && sudo systemctl restart ssh
   ```

   验证 `ssh -p 7544` 可通（同时确认腾讯云安全组已放行 7544），才继续下一步。
4. 收敛配置（就地修改生效行，注意 sshd_config **首个生效值优先**）：

   ```bash
   sudo sed -i "/^Port 22$/d" /etc/ssh/sshd_config
   sudo sed -i "s/^PasswordAuthentication yes$/PasswordAuthentication no/" /etc/ssh/sshd_config
   sudo sed -i "s/^#PubkeyAuthentication yes$/PubkeyAuthentication yes/" /etc/ssh/sshd_config
   sudo sed -i "s/^PermitRootLogin yes$/PermitRootLogin prohibit-password/" /etc/ssh/sshd_config
   sudo /usr/sbin/sshd -t && sudo systemctl restart ssh
   ```

## 关键路径 / 配置

- `/etc/ssh/sshd_config` — 生效项：`Port 7544`(L14)、`PermitRootLogin prohibit-password`(L33)、
  `PubkeyAuthentication yes`(L38)、`PasswordAuthentication no`(L123)
- `/etc/ssh/sshd_config.d/` — 当前为空（`Include` 在 L12，位于生效行之前，优先级更高；
  以后若新增 drop-in，需注意会覆盖主配置）
- `ubuntu:~/.ssh/authorized_keys`

## 回滚

服务器上已备份：`/etc/ssh/sshd_config.bak.20260923195057`

```bash
ssh norm 'sudo cp /etc/ssh/sshd_config.bak.20260923195057 /etc/ssh/sshd_config \
  && sudo sshd -t && sudo systemctl restart ssh'
```

回滚会同时恢复 22 端口与密码认证。恢复后需改用密码登录 `ubuntu@43.142.130.223:22`
（密码见服务器台账/密码管理器，本文不记录凭据）。

> 若 7544 被云安全组拦截导致完全无法登录，只能通过腾讯云控制台 VNC 恢复：
> 重放上述回滚命令，或临时追加 `Port 22` 后重启 sshd。
