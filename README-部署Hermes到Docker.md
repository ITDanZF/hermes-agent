# Hermes Docker 部署操作文档

本文档基于 Hermes 中文文档：https://hermesagent.org.cn/docs

## 1. 文件说明

当前目录提供 3 个文件：

- `deploy-hermes.ps1`：部署脚本
- `hermes.config.env`：用户填写的部署和运行配置
- `.env.example`：配置模板备份

脚本会创建：

- Hermes 容器：`hermes-agent`
- Redis 容器：`hermes-redis`
- Docker 网络：`hermesagent_hermes-net`
- Hermes 数据卷：`hermesagent_hermes_data`
- Redis 数据卷：`hermesagent_redis_data`

默认配置适合接入已有 Nginx：

- Nginx 代理 Gateway：`http://hermes-agent:8642`
- Nginx 代理 Dashboard：`http://hermes-agent:9119`
- `HERMES_EXPOSE_HOST_PORTS=false` 时，宿主机不会直接暴露 `8642` 和 `9119`

如果要本机直接访问，可以把 `HERMES_EXPOSE_HOST_PORTS=true`，然后使用：

- Gateway：`http://localhost:8642`
- Dashboard：`http://localhost:9119`

## 2. 填写配置文件

打开 `hermes.config.env`，先确认 Docker 镜像配置。

如果可以正常访问 Docker Hub，使用：

```env
HERMES_IMAGE=nousresearch/hermes-agent:latest
HERMES_SKIP_PULL=false
```

如果 Docker Hub 较慢，且本机已经有国内镜像，使用：

```env
HERMES_IMAGE=swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io/nousresearch/hermes-agent:latest
HERMES_SKIP_PULL=true
```

然后至少填写一个模型/API Key，示例：

```env
OPENROUTER_API_KEY=你的 OpenRouter Key
```

或：

```env
OPENAI_API_KEY=你的 OpenAI Key
```

或：

```env
ANTHROPIC_API_KEY=你的 Anthropic Key
```

如果只是本地测试，可以临时允许所有用户：

```env
GATEWAY_ALLOW_ALL_USERS=true
```

如果要正式使用，建议保持：

```env
GATEWAY_ALLOW_ALL_USERS=false
```

然后配置具体平台的 allowlist，例如 Telegram：

```env
TELEGRAM_BOT_TOKEN=你的 Telegram Bot Token
TELEGRAM_ALLOWED_USERS=你的 Telegram 用户 ID
```

如果部署到已有 Nginx 后面，请确认：

```env
HERMES_CONTAINER_NAME=hermes-agent
HERMES_NETWORK_NAME=你的线上 Nginx 所在 Docker network 名称
HERMES_EXPOSE_HOST_PORTS=false
```

对应 Nginx 代理配置中的 Hermes 入口应使用容器内部端口 `8642`：

```nginx
location /hermes/ {
	proxy_pass http://hermes-agent:8642/;
	proxy_http_version 1.1;
	proxy_set_header Host $host;
	proxy_set_header X-Real-IP $remote_addr;
	proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
	proxy_set_header X-Forwarded-Proto $scheme;
	proxy_set_header Upgrade $http_upgrade;
	proxy_set_header Connection "upgrade";
	proxy_connect_timeout 10s;
	proxy_send_timeout 300s;
	proxy_read_timeout 300s;
}
```

## 3. 一条命令部署

在 PowerShell 中进入目录：

```powershell
cd E:\hermesAgent
```

执行重建部署：

```powershell
.\deploy-hermes.ps1 recreate
```

这个命令会：

- 读取 `hermes.config.env`
- 创建 Docker 网络
- 创建 Docker 数据卷
- 删除旧的 `hermes-agent` 和 `hermes-redis` 容器
- 重新创建 Redis 容器
- 重新创建 Hermes 容器
- 根据 `HERMES_EXPOSE_HOST_PORTS` 决定是否映射 `8642` 和 `9119` 端口

注意：`recreate` 不会删除 Docker volume，所以已有 Hermes 配置和状态会保留。

## 4. 验证部署

查看容器状态：

```powershell
.\deploy-hermes.ps1 status
```

期望看到：

```text
hermes-agent  Up
hermes-redis  Up
```

如果 `HERMES_EXPOSE_HOST_PORTS=true`，查看端口：

```powershell
docker port hermes-agent
```

期望看到：

```text
8642/tcp -> 0.0.0.0:8642
9119/tcp -> 0.0.0.0:9119
```

如果 `HERMES_EXPOSE_HOST_PORTS=false`，`docker port hermes-agent` 可以没有输出；这表示 Hermes 只允许同一 Docker network 内的 Nginx 访问。

可以从 Nginx 容器内验证：

```powershell
docker exec -it 你的nginx容器名 sh
wget -O- http://hermes-agent:8642/
```

查看日志：

```powershell
.\deploy-hermes.ps1 logs
```

如果日志里只有下面这类 warning，说明 Docker 启动成功，但 Hermes 业务配置还没填完整：

```text
No user allowlists configured
No messaging platforms enabled
```

## 5. 继续配置 Hermes

如果你想使用 Hermes 交互式配置模型：

```powershell
docker exec -it hermes-agent hermes model
```

如果你想使用 Hermes 交互式配置消息平台：

```powershell
docker exec -it hermes-agent hermes gateway setup
```

配置完成后重启：

```powershell
.\deploy-hermes.ps1 restart
```

## 6. 常用命令

启动：

```powershell
.\deploy-hermes.ps1 start
```

删除旧容器并重建：

```powershell
.\deploy-hermes.ps1 recreate
```

停止：

```powershell
.\deploy-hermes.ps1 stop
```

重启：

```powershell
.\deploy-hermes.ps1 restart
```

看日志：

```powershell
.\deploy-hermes.ps1 logs
```

进入容器：

```powershell
.\deploy-hermes.ps1 shell
```

删除容器但保留数据卷：

```powershell
.\deploy-hermes.ps1 remove
```

## 7. 今天部署中已处理的坑

脚本已经内置处理以下问题：

- Docker Desktop 的 `docker info` warning 不会再导致脚本误判失败
- PowerShell 会把 `gateway run` 正确拆成两个参数，避免 Hermes 容器重启循环
- 默认按 Hermes + Redis + Docker network + Docker volume 的方式部署
- 默认使用 `hermes.config.env` 作为配置文件，并传给容器
- 支持 `HERMES_SKIP_PULL=true`，本机已有镜像时不再卡在 `docker pull`
- `recreate` 会删除旧容器后重新新建，但保留数据卷

## 8. 故障排查

确认 Docker 可用：

```powershell
docker version
docker ps
```

确认 Hermes 进程状态：

```powershell
docker exec hermes-agent sh -lc "cat /opt/data/gateway_state.json"
```

确认 Hermes 配置状态：

```powershell
docker exec -it hermes-agent hermes status
```

说明：`hermes gateway status` 在 Docker 容器里可能会检查 `systemctl` 用户服务，不适合作为本部署方式的唯一判断标准。请以 Docker 容器状态、日志和 `/opt/data/gateway_state.json` 为准。
