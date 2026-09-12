# AI Workflow Skills

从 `ai-helper` 拆分出的通用 AI 工作流技能集合。

## Skills

- **playwright-cli**：使用 Playwright CLI 自动化浏览器操作、页面测试、网络请求检查、会话与存储状态管理，以及追踪、录像和测试生成。
- **ssh-server-setup**：以分阶段、可验证的方式配置和加固远程 SSH 服务，包括密钥登录、端口迁移、禁用密码认证和 sudo 配置，避免失联。
- **docker-stack-deploy**：在 Docker Compose/Stack 环境中部署服务，覆盖镜像构建、环境变量、网络、持久化存储、健康检查和上线验证。
- **mysql-s3-backup**：用 go-sqlvault 把 MySQL/MariaDB 流式备份到 S3 兼容存储（腾讯云 COS），含 COS 内网 endpoint 的坑、配置迁移、替换 gobackup 及其 cron、verify 取舍与实测基线。
- **pm2-logrotate**：在远程 Linux 服务器上安装并配置 PM2 的 pm2-logrotate 模块，按 cron 轮转、压缩、限量保留 stdout/stderr 日志，并持久化、验证与回滚。
- **magnet-safety-rules-merge**：清理合并磁力链内容安全规则 JSON（go-hunhepan 等），去除完整番号/文件名等杂音、去重并把相似词并到同一分组、回填前缀规则，安全备份 + 重启 PM2 生效。

## 使用方式

技能文档位于 `.agents/skills/<skill-name>/SKILL.md`。将本仓库作为 AI 编码工具的 skills 目录使用，或按需复制相应目录到项目中。
