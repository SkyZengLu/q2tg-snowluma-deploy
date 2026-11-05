# Q2TG + SnowLuma 搭建教程（QQ ↔ Telegram 双向转发）

> 2026/11/5 · 教程 · QQ · Telegram · Docker · Ubuntu

本文记录一次完整的 Q2TG 部署过程：用 **SnowLuma** 登录 QQ 并提供 OneBot 接口，用 **Q2TG v4** 把 QQ 群和 Telegram 群双向打通。

所有命令都在 Ubuntu 22.04 上实测过，包括踩过的坑和最终解决办法。

---

> **提示**
>
> - 本文面向国内服务器（阿里云/腾讯云等），网络部分会涉及代理和镜像加速
> - QQ 建议用**小号**，向 QQ 客户端注入 hook 有封号风险
> - 只需要文字/图片转发的话，**不需要域名**；RichHeader 头像卡片和合并转发查看器才需要 HTTPS 域名

---

## 目录

- [一、架构说明](#一架构说明)
- [二、前期准备](#二前期准备)
- [三、注意事项](#三注意事项)
- [四、环境部署](#四环境部署)
- [五、部署 SnowLuma（QQ 侧）](#五部署-snowlumaqq-侧)
- [六、部署 Q2TG（Telegram 侧）](#六部署-q2tgtelegram-侧)
- [七、初始化配置](#七初始化配置)
- [八、踩坑记录（15 条）](#八踩坑记录15-条)
- [九、镜像补丁说明](#九镜像补丁说明)
- [十、公网访问与安全](#十公网访问与安全)
- [十一、日常维护与排障](#十一日常维护与排障)
- [十二、验收清单](#十二验收清单)

---

## 一、架构说明

### 1.1 组件

| 组件 | 作用 |
| :---: | --- |
| **SnowLuma** | 登录 QQ，暴露 OneBot v11 HTTP/WS 接口 |
| **Q2TG v4** | 消费 OneBot 消息 → 转发到 Telegram，反之亦然 |
| **PostgreSQL 14** | Q2TG 数据库 |
| **SOCKS5 代理** | 国内服务器访问 Telegram（Q2TG 只支持 SOCKS5） |

### 1.2 链路

```
QQ 号 ──(Linux QQ + Xvfb + hook)── SnowLuma ──OneBot WS:3001──┐
                                                               │
                                              Q2TG ────────────┘
                                                │
                                     SOCKS5 ── Telegram API
                                                │
                                          PostgreSQL
```

### 1.3 为什么不用 NapCat / icqq

Q2TG 的 NapCat 模式本质是 **标准 OneBot 11 WebSocket 客户端**：

```ts
// Q2TG 源码
this.ws = new ReconnectingWebSocket(wsUrl);
this.ws.send(JSON.stringify({ action, params, echo }));
```

SnowLuma 正好提供 OneBot v11 WS，并且实现了 115 个 NapCat 兼容动作，所以可以：

- 不用装 icqq + qsign（少两个容器）
- 不用装 NapCat
- QQ 只登录一次，不会被两个框架互踢

代价是个别接口字段不一致，需要打补丁（见第九节）。

---

## 二、前期准备

### 2.1 服务器

| 项目 | 最低配置 | 实测配置 |
| :---: | :---: | :---: |
| 系统 | Ubuntu 22.04 / Debian 12 | Ubuntu 22.04 LTS |
| CPU | 2 vCPU | 2 vCPU |
| 内存 | 4 GB | 8 GB（够用） |
| 磁盘 | 20 GB | 30 GB 以上 |
| 网络 | 公网 IP | 国内云服务器 |

### 2.2 需要的账号

1. **QQ 号**（建议小号）
2. **Telegram 账号**
   - 能登录 https://my.telegram.org/apps 申请 API
   - 能接收验证码（Q2TG 需要登录一个个人账号作为 UserBot）
3. **Telegram Bot**
   - [@BotFather](https://t.me/botfather) → `/newbot`
   - 建完后 `/setprivacy` → 选中 bot → **Disable**（否则群里收不到消息）

### 2.3 代理

国内服务器访问 Telegram 必须用代理，Q2TG **只支持 SOCKS5**：

```ini
PROXY_IP=1.2.3.4
PROXY_PORT=1080
PROXY_USERNAME=user
PROXY_PASSWORD=pass
```

> **提示**
>
> 代理**只给 Q2TG 访问 Telegram 用**，不要设成服务器全局代理，否则装包、拉镜像、系统更新都会绕一圈，既慢又不安全。

---

## 三、注意事项

1. 需要 **root 或 sudo**，Docker 安装、apt 依赖、nginx 配置都要 root
2. 云服务器要同时考虑**安全组**和**系统防火墙（ufw）**，两边都要放行
3. noVNC / VNC / OneBot 端口**不要直接公网暴露**
4. 升级 Q2TG 镜像后，本文的补丁要重新评估（见第九节）
5. 本文所有 token / 密码请替换成你自己的，不要照抄

---

## 四、环境部署

### 4.1 系统更新

```bash
apt-get update -y
apt-get upgrade -y
```

### 4.2 安装 Docker

国内用阿里云源：

```bash
apt-get install -y ca-certificates curl gnupg

# 添加阿里云 docker-ce 源
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg \
  | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://mirrors.aliyun.com/docker-ce/linux/ubuntu ${VERSION_CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

# 验证：两条都能正常输出版本号即可
docker --version
docker compose version
```

### 4.3 配置镜像加速

国内直连 Docker Hub 基本不通，必须配加速：

```bash
cat > /etc/docker/daemon.json <<'JSON'
{
  "registry-mirrors": [
    "https://docker.1ms.run",
    "https://docker.m.daocloud.io",
    "https://docker.xuanyuan.me"
  ],
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "3" }
}
JSON
systemctl restart docker
sleep 3
```

> **注意**
>
> `docker.1ms.run` 拉小镜像是没问题的，但拉 1GB 以上的大镜像时，它的 blob 会 307 跳到 `cloudfront-docker-cf.mrs.1ms.run`，实测大层会卡死。
> 拉大镜像时请直接指定 `docker.m.daocloud.io` 前缀，或者逐个镜像站试，观察 `/var/lib/containerd` 的体积是否在增长。

### 4.4 防火墙（ufw）

```bash
ufw status          # 确认是否 active
ufw allow 22/tcp
ufw allow 8443/tcp  # 按需
```

> **提示**
>
> 如果云控制台安全组放行了端口，外部还是连不上，先查 `ufw status`。
> 判断方法：找一个安全组放行、但本机没有监听的端口去外部探测，如果也超时，就是 ufw 拦的。

---

## 五、部署 SnowLuma（QQ 侧）

> 官方文档：https://snowluma.github.io/zh/docs/guide/deploy/docker

### 5.1 拉取镜像

```bash
# 推荐：显式走 daocloud 镜像站（实测 366 KB/s）
docker pull docker.m.daocloud.io/motricseven7/snowluma:latest
docker tag docker.m.daocloud.io/motricseven7/snowluma:latest motricseven7/snowluma:latest

# 备选镜像站：docker.1ms.run / docker.xuanyuan.me / docker.1panel.live
```

> **注意**
>
> 拉取卡住时会出现僵尸 `docker pull` 进程，用 `pkill -x docker` 清理。
> **不要**用 `pkill -f 'docker pull'`，它会匹配到当前命令行把自己杀掉。

### 5.2 配置文件

```yaml
# /opt/snowluma/docker-compose.yml
services:
  snowluma:
    image: motricseven7/snowluma:latest
    container_name: snowluma
    restart: unless-stopped
    shm_size: 1gb
    ulimits:
      nofile:
        soft: 65536
        hard: 1048576
    cap_add:
      - SYS_PTRACE              # 必须：ptrace 注入 QQ
    security_opt:
      - seccomp=unconfined      # 必须：默认 seccomp 会拦 ptrace
    environment:
      TZ: Asia/Shanghai
      VNC_PASSWD: "换成强密码"
      SNOWLUMA_UID: 1000
      SNOWLUMA_GID: 1000
      SNOWLUMA_WEBUI_HOST: 0.0.0.0
      SNOWLUMA_WEBUI_PORT: 5099
      SNOWLUMA_LOG_LEVEL: info
      SNOWLUMA_SCREEN: 1920x1080x24
      SNOWLUMA_HOOK_AUTOLOAD: "1"
      SNOWLUMA_QQ_FLAGS: "--disable-gpu --disable-software-rasterizer --disable-gpu-compositing"
    ports:
      # 全部只绑本机，公网统一走反代
      - "127.0.0.1:6081:6081"   # noVNC
      - "127.0.0.1:5099:5099"   # WebUI
      - "127.0.0.1:3000:3000"   # OneBot HTTP
      - "127.0.0.1:3001:3001"   # OneBot WS
    networks:
      - default
      - qq-bridge               # 与 Q2TG 互通
    volumes:
      - qq-gateway-data:/app/data
      - qq-client-config:/app/.config
      - qq-client-data:/app/.local/share
      # 与 Q2TG 共享临时目录（发图片/表情包必需）
      - q2tg-cache:/app/.config/QQ/NapCat/temp

volumes:
  qq-gateway-data:
    name: qq-gateway-data
  qq-client-config:
    name: qq-client-config
  qq-client-data:
    name: qq-client-data
  q2tg-cache:
    external: true              # 由 Q2TG 的 compose 创建
    name: q2tg-cache

networks:
  qq-bridge:
    external: true
    name: qq-bridge
```

### 5.3 启动

```bash
cd /opt/snowluma
docker compose up -d
sleep 25

docker compose ps
ss -tln | grep -E ':(5099|6081|3000|3001)'

# 验证 ptrace 权限
docker exec snowluma getcap /usr/local/bin/node
# 期望：/usr/local/bin/node cap_sys_ptrace=ep

# 进程状态
docker exec snowluma supervisorctl status
# 期望：qq RUNNING、snowluma RUNNING
```

### 5.4 登录 QQ（扫码）

**方式 A：直接截二维码（最快）**

```bash
docker exec snowluma sh -c \
  'DISPLAY=:1 ffmpeg -y -loglevel error -f x11grab -video_size 1920x1080 -i :1 -frames:v 1 /tmp/qr.jpg'
docker cp snowluma:/tmp/qr.jpg ./qr.jpg

# 裁剪二维码区域（1920x1080，窗口位置不同要微调）
docker exec snowluma sh -c \
  'ffmpeg -y -loglevel error -i /tmp/qr.jpg -vf "crop=230:230:845:425,scale=690:690:flags=lanczos" /tmp/qr-crop.png'
docker cp snowluma:/tmp/qr-crop.png ./qq-login-qr.png
```

手机 QQ → **+** → **扫一扫** → 右上角 **相册** → 选二维码图片 → 确认登录。

> **注意**
>
> QQ 二维码只有几分钟有效期。过期了就在界面点「刷新」重新生成。
> 可以用 XTest 远程点刷新：
>
> ```bash
> docker exec -i snowluma python3 - <<'PY'
> import ctypes, time
> x11 = ctypes.CDLL("libX11.so.6"); xtst = ctypes.CDLL("libXtst.so.6")
> x11.XOpenDisplay.restype = ctypes.c_void_p
> x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
> d = x11.XOpenDisplay(b":1")
> xtst.XTestFakeMotionEvent.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_ulong]
> xtst.XTestFakeButtonEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
> x11.XFlush.argtypes = [ctypes.c_void_p]
> def click(x, y):
>     xtst.XTestFakeMotionEvent(d, -1, x, y, 0); x11.XFlush(d); time.sleep(0.3)
>     xtst.XTestFakeButtonEvent(d, 1, 1, 0); xtst.XTestFakeButtonEvent(d, 1, 0, 0)
>     x11.XFlush(d); time.sleep(0.8)
> click(943, 579)   # 「刷新」按钮坐标
> PY
> ```

**方式 B：noVNC 网页**

```bash
# SSH 隧道（最安全，不用公网暴露 6081）
ssh -L 6081:127.0.0.1:6081 user@服务器IP
# 浏览器打开 http://127.0.0.1:6081/vnc.html
# 密码 = compose 里的 VNC_PASSWD
```

> **注意**
>
> noVNC 连上立刻"已断开（正常关闭）"？
> x11vnc 默认**非共享模式**，同一时间只允许一个客户端。有残留连接时新连接会被拒绝，日志：
>
> ```
> -dontdisconnect: Not shared & existing client
> refusing new client 127.0.0.1
> ```
>
> 解决：重启 x11vnc 清掉占位。
>
> ```bash
> docker exec snowluma sh -c 'pkill -f "x11vnc -display :1"; sleep 2'
> docker exec -d snowluma sh -c 'DISPLAY=:1 x11vnc -display :1 -noxrecord -noxfixes -noxdamage -forever -threads -rfbauth /root/.vnc/passwd -o /tmp/x11vnc.log'
> ```

登录成功后：

- 建议勾选「**自动登录**」，容器重建后大概率能自动恢复
- SnowLuma 会自动 hook（`SNOWLUMA_HOOK_AUTOLOAD=1`）
- **OneBot 实例只在 QQ 登录后才真正启动**

### 5.5 获取 OneBot 令牌

SnowLuma 有**两套独立令牌**（HTTP 和 WS 不同）：

```bash
docker exec snowluma cat /app/data/config/onebot.json
docker exec snowluma cat /app/data/config/onebot_<QQ号>.json
```

```json
{
  "networks": {
    "httpServers": [{ "name": "http-default", "port": 3000, "accessToken": "<HTTP_TOKEN>" }],
    "wsServers":   [{ "name": "ws-default",   "port": 3001, "accessToken": "<WS_TOKEN>",
                      "role": "Universal" }]
  }
}
```

验证：

```bash
curl -s -H "Authorization: Bearer <HTTP_TOKEN>" \
     -H 'Content-Type: application/json' -X POST -d '{}' \
     http://127.0.0.1:3000/get_login_info
# 期望：{"status":"ok","retcode":0,"data":{"user_id":...,"nickname":"..."}}
```

---

## 六、部署 Q2TG（Telegram 侧）

> 官方文档：https://kb.0w.al/文档/Q2TG/安装部署

### 6.1 申请 Telegram 凭据

1. https://my.telegram.org/apps
   - **App title**：≥5 字符，不能含 "Telegram"（如 `q2tg bridge`）
   - **Short name**：字母数字 5-32 位（如 `q2tgbridge`）
   - **URL**：留空
   - **Platform**：Bot / Server
   - 提交后得到 `api_id`、`api_hash`
2. BotFather 建 bot，`/setprivacy` → Disable

### 6.2 配置文件

```bash
mkdir -p /opt/q2tg && cd /opt/q2tg
```

`.env`（权限 600）：

```ini
# Telegram
TG_API_ID=12345678
TG_API_HASH=0123456789abcdef0123456789abcdef
TG_BOT_TOKEN=123456789:AAxxxxxxxxxxxxxxxxxxxx

# 数据库
POSTGRES_DB=q2tg
POSTGRES_USER=q2tg
POSTGRES_PASSWORD=换成随机强密码

# SOCKS5 代理（只给 Q2TG 连 Telegram）
PROXY_IP=1.2.3.4
PROXY_PORT=1080
PROXY_USERNAME=user
PROXY_PASSWORD=pass

# 接 SnowLuma 的 OneBot WS（snowluma 是容器名）
ONEBOT_WS_TOKEN=<第五节的 WS_TOKEN>
NAPCAT_WS_URL=ws://snowluma:3001/?access_token=<第五节的 WS_TOKEN>

# 其他
TG_CONNECTION=tcp
TZ=Asia/Shanghai
# 没有域名也要填一个合法 URL，否则转发全挂（见踩坑 8）
WEB_ENDPOINT=http://你的服务器IP:8443
```

### 6.3 docker-compose.yaml

```yaml
services:
  postgres:
    image: postgres:14-alpine
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${POSTGRES_DB:-q2tg}
      POSTGRES_USER: ${POSTGRES_USER:-q2tg}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?请在 .env 设置}
    volumes:
      - postgresql:/var/lib/postgresql/data

  q2tg:
    image: ghcr.io/clansty/q2tg:sleepyfox
    restart: unless-stopped
    depends_on:
      - postgres
    ports:
      - "127.0.0.1:8080:8080"          # RichHeader / 合并转发查看器
    volumes:
      - q2tg:/app/data
      - cache:/app/.config/QQ/NapCat/temp   # 与 SnowLuma 共享
      - ./patched/index.js:/app/build/index.js   # 补丁（见第九节）
    networks:
      - default
      - qq-bridge
    env_file:
      - .env
    environment:
      - DATABASE_URL=postgres://${POSTGRES_USER:-q2tg}:${POSTGRES_PASSWORD}@postgres/${POSTGRES_DB:-q2tg}
      - NAPCAT_WS_URL=ws://snowluma:3001/?access_token=${ONEBOT_WS_TOKEN}
      - TG_CONNECTION=${TG_CONNECTION:-tcp}
      - TZ=${TZ:-Asia/Shanghai}

volumes:
  postgresql:
    name: q2tg-postgresql
  q2tg:
    name: q2tg-data
  cache:
    name: q2tg-cache

networks:
  default:
  qq-bridge:
    external: true
    name: qq-bridge
```

> **提示**
>
> 官方 icqq 示例里的 `sign` 服务（qsign）和 `/var/run/docker.sock` 挂载，在 SnowLuma 模式下都不需要。

### 6.4 创建网络并按顺序启动

```bash
# 1) 创建共享网络
docker network create qq-bridge

# 2) 先起 Q2TG 的 postgres（创建 q2tg-cache 卷）
cd /opt/q2tg && docker compose up -d postgres

# 3) 再起 SnowLuma（它引用 external 的 q2tg-cache 和 qq-bridge）
cd /opt/snowluma && docker compose up -d

# 4) 起 Q2TG
cd /opt/q2tg && docker compose up -d
```

### 6.5 检查

```bash
cd /opt/q2tg
docker compose logs --tail=40 q2tg
```

期望：

```
✔ Prisma schema loaded ...
✔ Web Api - Listening on 8080
✔ [Running gramJS version 2.26.7]
✔ TG Bot 登录完成
✔ 当前服务器未配置，请向 Bot 发送 /setup 来设置
```

确认连上 SnowLuma：

```bash
docker compose logs q2tg | grep "WS 连接成功"
```

---

## 七、初始化配置

在 Telegram 给 bot 私聊发：

```
/setup
```

流程：

1. **选择模式**
   - 群组模式：1 个 QQ 群 ↔ 1 个 TG 群（简单，推荐先用）
   - 个人模式：QQ 好友/群自动映射到 TG（需要登录 Telegram 个人账号）
2. **登录 UserBot**
   - 输入手机号（带区号，如 `+86`）
   - 验证码**必须点内联数字键盘按钮输入**，直接打字会失效
3. **QQ 侧**
   - 自动用 `.env` 的 `NAPCAT_WS_URL` 连 SnowLuma
4. **绑定**
   - 群组模式：填 QQ 群号 + TG 群
   - 个人模式：用 `/addfriend` 选好友自动建群

常用命令：

| 命令 | 作用 |
| :---: | --- |
| `/setup` | 首次配置 / 重新配置 |
| `/addfriend` | 个人模式：选择 QQ 好友关联 |
| `/flags` | 设置实例开关（如 `DISABLE_RICH_HEADER`） |

---

## 八、踩坑记录（15 条）

### 坑 1：没有 root 权限

**现象**：sudo 要密码，Docker/apt 全部失败。

**解决**：配置免密 sudo 或用 root 执行。

```bash
echo '用户名 ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/90-temp
```

### 坑 2：Docker Hub 被墙 / 镜像站卡死

**现象**：`docker pull` 卡住，`/var/lib/containerd` 不增长。

**原因**：

- 国内直连 `registry-1.docker.io` 不通
- `docker.1ms.run` 的大 blob 会 307 到 `cloudfront-docker-cf.mrs.1ms.run`，实测卡死

**解决**：换 `docker.m.daocloud.io`（实测 366 KB/s）。

### 坑 3：pkill 把自己杀了

**现象**：执行清理命令后当前命令也被杀。

**原因**：`pkill -f 'docker pull'` 会匹配当前 shell 的命令行。

**解决**：用 `pkill -x docker`。

### 坑 4：二维码过期

**现象**：扫码提示"二维码已过期"。

**解决**：点界面「刷新」重新生成，或用 5.4 节的 XTest 脚本远程点。

### 坑 5：设备确认收不到 / 超时

**现象**：提示"请在手机QQ上确认登录"，手机没反应，约 8 分钟后提示失败。

**解决**：改用**扫码登录**（界面底部「账户登录」切换）。

### 坑 6：noVNC 连上就断开

**现象**：点连接秒断，显示"已断开（正常关闭）"。

**原因**：x11vnc 非共享模式，残留客户端占位。

**解决**：重启 x11vnc（命令见 5.4 节）。

### 坑 7：HTTPS 端口收到 HTTP → 400

**现象**：`400 Bad Request: The plain HTTP request was sent to HTTPS port`。

**原因**：nginx 配了 `listen 8443 ssl;`，浏览器发了明文 HTTP。

**解决**：访问时写 `https://`，或把 nginx 改成纯 HTTP。

### 坑 8：Q2TG 转发全部失败 `Invalid URL`

**现象**：

```
[ERROR] ForwardService - 从 QQ 到 TG 的消息转发失败 TypeError: Invalid URL
    at generateRichHeaderUrl (forwardHelper.ts:241)
```

**原因**：Q2TG 的 bug，`WEB_ENDPOINT` 为空时 `new URL("undefined/richHeader/...")` 抛异常，而调用处没判空。

**解决**：`.env` 里设置任意合法 URL：

```ini
WEB_ENDPOINT=http://你的服务器IP:8443
```

### 坑 9：表情包/图片转发失败 `ENOENT`

**现象**：

```
[WARN] send_group_msg failed: ENOENT: no such file or directory,
stat '/app/.config/QQ/NapCat/temp/tmp-51-xxx.tmp'
```

**原因**：Q2TG 发图时先写临时文件，让 OneBot 服务端去读。官方 NapCat 部署两个容器共享该目录，换成 SnowLuma 后没共享。

**解决**：两个容器挂同一个卷到 `/app/.config/QQ/NapCat/temp`。

### 坑 10：安全组放行了还连不上

**原因**：服务器 ufw 默认 deny。

**解决**：`ufw allow <端口>/tcp`。

### 坑 11：SnowLuma 重建后 Q2TG 连不上

**原因**：`qq-bridge` 网络是手动 `docker network connect` 加的，重建后丢失。

**解决**：重新 connect，并把网络写进 compose：

```bash
docker network connect qq-bridge snowluma
```

### 坑 12：/setup 验证码崩溃

**现象**：

```
ReferenceError: length is not defined
    at getDisplay (/app/src/utils/inlineDigitInput.ts:13)
```

**原因**：镜像 bundle 比上游源码旧。

**解决**：打补丁 A（见第九节）。

### 坑 13：RichHeader 报 `WEBPAGE_URL_INVALID`

**原因**：Telegram 服务器访问不了 `http://IP:非标端口`，无法生成网页预览。

**解决**：

- 要 RichHeader → 必须 HTTPS 域名
- 否则关掉：

```sql
UPDATE "Instance" SET flags = flags | 16384 WHERE id = 0;
```

### 坑 14：/addfriend 显示 `undefined (NaN)`

**原因**：Q2TG 按 NapCat 字段解析（`friend.nick` / `friend.uin`），SnowLuma 返回的是 OneBot 标准字段（`nickname` / `user_id`）。

**解决**：打补丁 B。

### 坑 15：创建群邀请 bot 失败

**现象**：

```
创建群组并关联失败
Error: Could not find the input entity for {"userId":"<BOT_USER_ID>","className":"PeerUser"}
```

**原因**：用 bot 的数字 ID 邀请，userbot 实体缓存里没有它。

**解决**：改用 bot 的 username 邀请（补丁 C）。

---

## 九、镜像补丁说明

Q2TG 镜像 `ghcr.io/clansty/q2tg:sleepyfox` 的 bundle 比上游源码旧，在 SnowLuma 组合下有 3 个必现 bug。做法：**导出 bundle → 打补丁 → volume 挂载覆盖**。

### 9.1 三个补丁

| 补丁 | 位置 | 改动 | 解决 |
| :---: | --- | --- | --- |
| A | `getDisplay()` | 去掉 `length` 变量引用 | /setup 崩溃 |
| B | `getFriendsWithCluster()` | `friend.uin ?? friend.user_id`、`friend.nick ?? friend.nickname` | /addfriend NaN |
| C | `createGroupAndLink()` | `inviteMember(me.username \|\| me.id)` | 邀请 bot 失败 |

### 9.2 打补丁

```bash
cd /opt/q2tg
mkdir -p patched
docker cp "$(docker compose ps -q q2tg):/app/build/index.js" patched/index.js.orig
cp patched/index.js.orig patched/index.js

python3 - <<'PY'
p = 'patched/index.js'
s = open(p, encoding='utf-8').read()

# A：修复 inlineDigitInput
s = s.replace(
"""    function getDisplay() {
      const leftLength = length - input.length;
      let display = Array.from(input);
      leftLength > 0 && display.push(SYMBOL_INPUT);
      leftLength > 1 && display.push(...SYMBOL_EMPTY.repeat(leftLength - 1));
      return `>>>  ${display.join(SYMBOL_SPACE)}  <<<`;
    }""",
"""    function getDisplay() {
      let display = Array.from(input);
      display.push(SYMBOL_INPUT);
      return `>>>  ${display.join(SYMBOL_SPACE)}  <<<`;
    }""")

# B：好友字段兼容
s = s.replace("""            nickname: friend.nick,
            uid: parseInt(friend.uin),""",
"""            nickname: friend.nick ?? friend.nickname,
            uid: parseInt(friend.uin ?? friend.user_id),""")
s = s.replace("""              uid: parseInt(it.uin),""",
"""              uid: parseInt(it.uin ?? it.user_id),""")

# C：邀请 bot 用 username
s = s.replace("await chat.inviteMember(this.tgBot.me.id);",
              "await chat.inviteMember(this.tgBot.me.username || this.tgBot.me.id);")

open(p, 'w', encoding='utf-8').write(s)
print("patched")
PY

# 校验
node --check patched/index.js
grep -c "friend.uin ?? friend.user_id" patched/index.js
```

### 9.3 挂载生效

compose 里已有：

```yaml
volumes:
  - ./patched/index.js:/app/build/index.js
```

```bash
docker compose up -d q2tg
```

### 9.4 升级镜像时 ⚠️

1. `docker compose pull`
2. 确认上游是否已修复
3. 已修复 → 删掉挂载行
4. 未修复 → 重新导出新 bundle 再按 9.2 打补丁（**不能复用旧文件**）

---

## 十、公网访问与安全

### 10.1 方案对比

| 方案 | 需要的条件 | 安全性 | 推荐 |
| :---: | --- | :---: | :---: |
| SSH 隧道 | 无 | 高 | ⭐⭐⭐⭐⭐ |
| nginx + HTTPS + Basic Auth | 域名、证书 | 中高 | ⭐⭐⭐⭐ |
| nginx + HTTP + Basic Auth | 无 | 低 | ⭐⭐ |
| nginx + HTTP 无认证 | 无 | 低 | ⭐ |
| 直接暴露 noVNC/VNC/OneBot | 无 | 极低 | ❌ |

### 10.2 不要公网暴露

- noVNC(6081) / VNC(5900)：等于把 QQ 桌面挂公网
- OneBot(3000/3001)：拿到 token 就能用你的 QQ 发消息
- PostgreSQL(5432)

### 10.3 nginx 反代示例

有域名和证书时用这一份，对应 10.1 里推荐的 **HTTPS + Basic Auth**：

```nginx
server {
    listen 8443 ssl;
    # 需要 HTTP/2 就写 listen 8443 ssl http2;（nginx 1.25.1 起改为单独一行 http2 on;）
    server_name 你的域名;

    ssl_certificate     /etc/nginx/ssl/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;

    client_max_body_size 100m;
    server_tokens off;

    # 生成密码文件：htpasswd -c /etc/nginx/.htpasswd 你的用户名
    auth_basic           "restricted";
    auth_basic_user_file /etc/nginx/.htpasswd;

    location / {
        proxy_pass http://127.0.0.1:5099;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
        proxy_buffering off;
    }

    # RichHeader 卡片：Telegram 服务器会主动来抓图，这里**不能**加 auth_basic，
    # 否则抓取拿到 401，预览图全部失效（见坑 13）
    location /richHeader/ {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # 合并转发查看器：给自己看的，可以加认证
    location /ui/ {
        auth_basic           "restricted";
        auth_basic_user_file /etc/nginx/.htpasswd;
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

> **注意**
>
> - 这份配置是 **HTTPS**（`listen 8443 ssl;`）。收明文 HTTP 会直接 400，见坑 7。
> - `/richHeader/` 必须放开认证：那是 telegram 服务器来抓的，不是给你浏览器看的。
> - 没有域名就别降级用 HTTP 明文反代，走 SSH 隧道（10.1 里安全等级最高的那个）。
> - 上了 Basic Auth 后，`WEB_ENDPOINT` 仍要写成 `https://你的域名:8443`，TG 抓图走的是无认证路径。

### 10.4 其他建议

- 安全组只开必要端口，SSH 限制来源 IP
- 别对 `0.0.0.0/0` 开 RDP(3389)/WinRM(5985)
- API Hash / Bot Token / 代理凭据放 `.env`（600），别外传
- 定时备份数据卷

---

## 十一、日常维护与排障

### 11.1 保活

| 项 | 状态 |
| :---: | --- |
| 容器自动重启 | `restart: unless-stopped` |
| Docker 开机自启 | `systemctl enable docker` |
| Telegram 断线 | gramJS 自动重连 |
| QQ 掉线 | 需重新扫码（协议限制） |

### 11.2 常用排障命令

```bash
# 容器状态
docker ps -a --format 'table {{.Names}}\t{{.Status}}'

# SnowLuma 日志
docker logs snowluma --tail=100

# Q2TG 日志
cd /opt/q2tg && docker compose logs --tail=100 q2tg
docker compose logs q2tg 2>&1 | grep -iE 'error|fail|WS 连接'

# QQ 是否在线
curl -s -H "Authorization: Bearer <HTTP_TOKEN>" \
  -H 'Content-Type: application/json' -X POST -d '{}' \
  http://127.0.0.1:3000/get_login_info

# 端口
ss -tln | grep -E ':(3000|3001|5099|6081|8080)'

# 容器网络
docker inspect snowluma --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}'
docker run --rm --network qq-bridge busybox nc -zv snowluma 3001

# 数据库
cd /opt/q2tg
docker compose exec -T postgres psql -U q2tg -d q2tg -c \
  'select id, owner, "workMode", "isSetup" from "Instance";'
```

### 11.3 故障速查

| 现象 | 先看 | 原因 |
| :---: | --- | --- |
| QQ 掉线 | `get_login_info` | 重扫码 |
| QQ→TG 不转发 | Q2TG 日志 `Invalid URL` | WEB_ENDPOINT 没配 |
| 图片不转发 | SnowLuma 日志 `ENOENT` | 共享卷没挂 |
| Q2TG 连不上 OneBot | 是否有 `WS 连接成功` | qq-bridge 网络 |
| /setup 崩溃 | `ReferenceError` | 补丁没打 |
| 外部连不上 | `ufw status` | 防火墙/安全组 |

### 11.4 备份

```bash
# 数据卷
for v in qq-gateway-data qq-client-config qq-client-data q2tg-data q2tg-postgresql; do
  docker run --rm -v $v:/data -v $(pwd):/backup alpine \
    tar czf /backup/$v.tgz -C /data .
done

# 配置
tar czf configs.tgz /opt/snowluma /opt/q2tg
```

---

## 十二、验收清单

- [ ] 三个容器 Up
- [ ] `getcap` 有 `cap_sys_ptrace=ep`
- [ ] `get_login_info` 返回正常
- [ ] `qq-bridge` 里同时有 snowluma 和 q2tg
- [ ] 两个容器都挂载了 `q2tg-cache` 到 NapCat temp
- [ ] Q2TG 日志有 `TG Bot 登录完成`
- [ ] Q2TG 日志有 `WS 连接成功`
- [ ] `Instance.isSetup = true`
- [ ] QQ 群发文字 → TG 收到
- [ ] QQ 群发图片/表情包 → TG 收到
- [ ] TG 群发消息 → QQ 收到
- [ ] noVNC / VNC / OneBot **没有**公网暴露

---

## 参考链接

- [SnowLuma 仓库](https://github.com/SnowLuma/SnowLuma)
- [SnowLuma Docker 部署](https://snowluma.github.io/zh/docs/guide/deploy/docker)
- [SnowLuma 配置参考](https://snowluma.github.io/zh/docs/guide/configuration)
- [SnowLuma 国内网络](https://snowluma.github.io/zh/docs/guide/china-network)
- [Q2TG 仓库](https://github.com/clansty/Q2TG)
- [Q2TG 安装部署](https://kb.0w.al/文档/Q2TG/安装部署)
- [Q2TG 常见问题](https://kb.0w.al/文档/Q2TG/常见问题)
- [Telegram API ID](https://my.telegram.org/apps)
- [BotFather](https://t.me/botfather)

---

> **一句话总结**
>
> SnowLuma 登录 QQ 并提供 OneBot WS；Q2TG 用 NapCat 模式连它做转发；两个容器必须共享临时目录和 docker 网络；Q2TG 镜像有 3 个 bug 要打补丁；`WEB_ENDPOINT` 必须填，否则转发全挂。

*最近更新：2026/11/5*
