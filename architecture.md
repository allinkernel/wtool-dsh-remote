# tools/dsh-remote 架构（现状）

> 这份文档**只讲现在**：命令、参数、路径、文件的真实行为，全部以代码为准
> （写这份时逐行核对过 `bin/dsh-remote` / `bin/dsh-notify` / `cloud/relay.sh` /
> `scripts/install.sh` / 三个测试脚本，日期 2026-10-07）。
>
> 别的东西去哪看：
>
> | 想知道 | 看 |
> |---|---|
> | 为什么这么决策、否决了什么 | `docs/adr/`（索引在 `docs/adr/README.md`） |
> | 接下来做什么、做到哪了 | `BACKLOG.md` |
> | 踩过哪些坑 / 禁区 | `docs/hazards.md` |
> | 操作这个项目必须遵守的事 | `AGENTS.md` |
> | 给用户的说明书（装法、安全边界） | `README.md` |
> | 按日期的操作流水 | `journal.md` |
>
> **代码与本文不一致时以代码为准**，并回头改本文。

---

## 0. 一分钟看懂

**它是什么**：出门在外用手机浏览器看着/接着指挥家里这台机器上的 DSH 会话 ——
看某个会话是不是卡在等人回答、答它、或者派新活。**手机上不装任何东西**。

**链路**（端口都是 `remote.conf` 里可改的默认值）：

```
  📱 手机浏览器
       │  https（Let's Encrypt 或 Caddy 自签）+ HTTP basic auth
       ▼
  云上一台机器（今天指阿里云）             ← 对外唯一入口，安全组只开 443 或 8443
       │  Caddy 容器（network_mode: host）
       │  reverse_proxy → 127.0.0.1:18080   （顺便把 Host/Origin/Referer 改写成回环）
       ▼
  云上 sshd 的反向隧道端（只绑 127.0.0.1）  ← 云上不为隧道开任何端口
       ▲
       │  ssh -N -T -R 127.0.0.1:18080:127.0.0.1:3080  （家里主动连出去）
       │
  家里这台机器                              ← 不需要公网 IP、不动路由器
       │  127.0.0.1:3080 = 正在跑的 `dsh web`
       ▼
  DSH 会话（就是你现在用的这个界面）
```

外加一条**推送**：`dsh-notify` 把消息推到手机（Server酱 / 钉钉 / Telegram / Bark /
任意 webhook）。理论上挂在 DSH 官方 hook 桥的 `PreToolUse`（等用户回答）和 `Stop`
（一轮跑完）上；**这条链路到今天为止还没被证实会触发**（见 §9）。

**仓库里只有文本**：脚本 + 两个 Caddyfile 模板 + `docker-compose.yml` + 文档。
证书 / 密码 / 密钥 / 日志一律在安装落点和云上的命名卷里，不进 git（`git ls-files` 可验）。

---

## 1. 仓库里有什么（文件清单）

| 文件 | 行数 | 是什么 |
|---|---|---|
| `bin/dsh-remote` | 616 | 家里这头的主命令（14 个子命令） |
| `bin/dsh-notify` | 236 | 推送脚本；也是 hook 桥调用的那个命令 |
| `scripts/install.sh` | 210 | `wtool install` 调它：铺命令软链 + 配置/日志软链 |
| `cloud/relay.sh` | 301 | **在云上跑**：渲染 Caddyfile → 起 Caddy 容器 → 自检 |
| `cloud/Caddyfile.domain` | 47 | 域名模式模板（占位符 `{{...}}`） |
| `cloud/Caddyfile.ip` | 44 | IP 模式模板（`tls internal` 自签） |
| `cloud/docker-compose.yml` | 38 | 中继器：一个 `caddy:2` 容器（host 网络）+ 两个命名卷 |
| `hooks/claude-hooks.json` | 27 | hook 桥模板（`__DSH_NOTIFY__` 由 `notify-enable` 替换成实际命令） |
| `env.zsh` / `env.bash` | 24 / 24 | shell 集成：只导出三个目录变量；两份必须同改 |
| `wtool.xml` | 33 | 服务清单：`<zshrc>` / `<bashrc>` / `<publish kind="source"/>` |
| `remote.conf.example` | 31 | 隧道配置样板 |
| `notify.conf.example` | 44 | 推送配置样板 |
| `tests/run_tests.sh` | 700 | 179 条，不联网 / 不碰 docker / 不碰真 `$HOME` |
| `tests/caddy-validate.sh` | 70 | 3 条，用 `caddy:2` 真校验 Caddyfile（要 docker） |
| `tests/relay-e2e.sh` | 138 | 9 条，真起 Caddy 容器验 HTTPS+basic auth+反代（要 docker） |
| `tests/http_sink.py` | 40 | 测试零件：把每次 POST 的 body 追加写进文件的本地接收端 |
| `README.md` / `AGENTS.md` / `BACKLOG.md` / `architecture.md` / `journal.md` / `docs/` | — | 文档 |

`wtool.xml` 的实质内容（无 `id=`，项目身份 = 路径 `tools/dsh-remote`）：

```xml
<wtool schema="1" priority="47">
  <zshrc  src="env.zsh"/>
  <bashrc src="env.bash"/>
  <publish kind="source"/>
</wtool>
```

没有 `<build>` / 构建步骤：`publish kind="source"` 表示源码包就是产物。
`scripts/install.sh` 是"文件存在即能力声明"，引擎看它在不在。

---

## 2. 数据流（一次手机访问经过了什么）

1. 手机打开 `public_url`（`remote.conf` 里那行，云端 `relay.sh` 最后打印的那个地址）。
2. 云上 Caddy（容器、host 网络）在 443（域名模式）或 8443（IP 模式）收 TLS。
   - 域名模式：证书是 Let's Encrypt 签的（`{ email {{EMAIL}} }` + 站点名是域名）。
   - IP 模式：`tls internal`，Caddy 自己 CA 签的自签证书，浏览器第一次会警告一次。
3. Caddy 先过 `basic_auth`：用户名默认 `dsh`，密码是 relay.sh 生成/传入的那个
   （`docker run --rm caddy:2 caddy hash-password` 算出的 bcrypt 哈希写在 Caddyfile 里）。
   `--allow-ip` 给了的话前面还有一条 `@notme not remote_ip …` → 403。
4. Caddy `reverse_proxy 127.0.0.1:18080`，并把请求头改写成
   `Host: 127.0.0.1:3080`、`Origin: http://127.0.0.1:3080`、
   `Referer: http://127.0.0.1:3080/` —— 这样 `dsh web` 的"浏览器信任围栏"
   （默认只认回环 / 本机 LAN / `--trusted-host`）就认这个请求，**不用重启 harness**。
   会话界面是流式的：`flush_interval -1` + `read_timeout 0`。
5. 18080 是**云上 sshd 的 `-R` 监听口**，只绑 `127.0.0.1`（安全组里没有它）。
6. 隧道另一头是家里的 `ssh -N -T -R 127.0.0.1:18080:127.0.0.1:3080`，
   由 `dsh-remote tunnel` 起、`retry_seconds` 秒一轮地保活。
7. 家里 `127.0.0.1:3080` 是 `dsh web`。手机第一次还要贴一次带 token 的地址
   （`dsh-remote serve` 会把它存到 `$STATE_DIR/web-url.txt`），之后浏览器记住。

**信任边界只有一道**：Caddy 的 basic auth + TLS。因为第 4 步把来源伪装成了回环，
harness 分不清请求来自本地还是远程 —— 所以 basic auth 的密码必须长且随机，
443/8443 之外的端口（18080、3080）绝对不能在安全组里开。

---

## 3. `bin/dsh-remote`：14 个子命令的真实行为

`SELF` 先 `readlink -f` 解软链，`PROJ_DIR` = 解出来的脚本的上一级
（踩过：不解软链会把项目目录算成 `~/.local`，`hooks/` 就找不到了）。

路径变量（默认值，全部可被环境变量覆盖）：

```
DSH_HOME    = ${DSH_HOME:-$HOME/.dsh}                          ← DSH 自己的目录，我们只放 profile patch
CONF_DIR    = ${DSH_REMOTE_CONF_DIR:-${DSH_REMOTE_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/dsh-remote}}
STATE_DIR   = ${DSH_REMOTE_STATE_DIR:-${DSH_REMOTE_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/dsh-remote}}
CONF        = ${DSH_REMOTE_CONF:-$CONF_DIR/remote.conf}
NOTIFY      = ${DSH_NOTIFY_BIN:-$(command -v dsh-notify || $SELF_DIR/dsh-notify)}
```

配置文件读取：`conf <键>` 用 `sed` 取**最后一个**匹配行，去掉首尾空白和成对引号；
取不到返回 1。`conf_any A B` 按顺序试多个名字（所以 `local_port` 和 `LOCAL_PORT` 都认）。
脚本是 `set -u`（不是 `-e`）：出错靠显式 `die`（打印后 `exit 1`）。

| 子命令 | 实际行为 | 退出码 |
|---|---|---|
| `status` | 打印 7 行体检。①配置路径（不存在时提示照样板抄）②`$PROJ_DIR` ③harness：`ss -ltn`（没有 `ss` 用 `netstat -ltn`）看 `local_port`（默认 3080）是否在听；没在听但有 `dsh .*web` 进程则提示"端口对不对"；否则提示没在跑 ④隧道：只有 `cloud_host` 有值时才查 `pgrep -f 'ssh .*-R .*127\.0\.0\.1'` ⑤手机地址 `public_url` ⑥推送：`$CONF_DIR/notify.conf` 的 `provider`（读不到就说 `serverchan`）⑦hook 推送：`$CONF_DIR/hooks.json` 在**且** `$DSH_HOME/profiles/web/cordis.patch.yml` 里 grep 得到 `dsh-remote notify` 才算"已开启"。**只读，不写任何文件**（实测在临时 `DSH_REMOTE_HOME` 里跑过） | 恒 0 |
| `serve` | 在**后台**起 `dsh web --no-open --port <local_port>`：有 `setsid` 就 `setsid nohup`，否则 `nohup`；stdout/stderr 进 `$STATE_DIR/web.log`。然后最多 40×0.5s=20s 轮询日志里的 `http://127.0.0.1:<端口>/…token=…`，抓到就写 `$STATE_DIR/web-url.txt` 并打印。**端口已经有人在听时拒绝启动**（警告 + 打印上次记的地址），因为重启会打断正在跑的会话 | 0 / 1 |
| `tunnel` | **前台**死循环保活一条反向隧道。ssh 参数：`-N -T -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o TCPKeepAlive=yes -o StrictHostKeyChecking=accept-new -p <cloud_ssh_port>`（默认 22），有 `identity` 就加 `-i`（`~/` 开头会展开成 `$HOME/`），最后是 `-R 127.0.0.1:<remote_port>:127.0.0.1:<local_port> <cloud_user>@<cloud_host>`（默认 `18080:127.0.0.1:3080`、`root`）。配置 `autossh` 不是 `off` **且** PATH 里有 `autossh` 时用 `AUTOSSH_GATETIME=0 autossh -M 0 <同样的参数>`，否则用裸 `ssh`。每断一次打印退出码，睡 `retry_seconds`（默认 10）再连。**没有 daemon 化、没有指数退避** | 循环 / `cloud_host` 缺失时 1 |
| `systemd` | **只写文件**：`$HOME/.config/systemd/user/dsh-remote-tunnel.service`（`ExecStart=$SELF_DIR/dsh-remote tunnel`、`Restart=always`、`RestartSec=10`、`After=network-online.target`、`WantedBy=default.target`），然后打印要人自己敲的 `systemctl --user enable --now` 和 `loginctl enable-linger`。**不 enable、不 start、不 reload** | 0 |
| `url` | 打印 `public_url`；没配就 `die` | 0 / 1 |
| `notify-test` | 调 `dsh-notify --test`，再提示失败细节看 `$STATE_DIR/notify.log` | 0 |
| `notify-enable` | ①`mkdir -p $CONF_DIR $DSH_HOME/profiles/web` ②把 `hooks/claude-hooks.json` 里的 `__DSH_NOTIFY__` 换成 `$NOTIFY` 写进 `$CONF_DIR/hooks.json`（模板不在就 `die`）③`$DSH_HOME/profiles/web/cordis.patch.yml` 不存在就先建一个 `# 注释` + `[]` ④里面没有 `# >>> dsh-remote notify` 标记时：先备份成 `$pf.bak-dsh-remote`，文件里**整行是 `[]`** 就把 `[]` 换成那段块（YAML 里两个顶层值会打架），否则直接追加 ⑤打印验证命令 `dsh --profile web --dump-config \| grep -A3 hooks-claude-code`。**幂等**（标记在就跳过） | 0 / 1 |
| `notify-disable` | 用 `awk` 把 `# >>> dsh-remote notify` 到 `# <<< dsh-remote notify` 之间那段删掉；删完如果只剩注释/空行，补回一行 `[]`（profile 的空 patch 层会让 boot 失败）。`hooks.json` 留着不删 | 0 / 1 |
| `cloud-setup` | **只打印**要人在云上敲的 scp / ssh 命令（值从 `remote.conf` 取，缺的用 `<你的阿里云公网 IP>` / `root` / `18080` / `3080` 占位），末尾提醒安全组只开 22 + 443/8443，**绝不要开 18080 和 3080** | 0 |
| `cloud-install` | 见 §4（这是唯一会碰云上那台机器的子命令） | 0 / 1 |
| `migrate` | 把旧版放在 `$DSH_HOME` 下的 `remote.conf` / `notify.conf` / `hooks.json` 搬到 `$CONF_DIR`，`notify.log` / `web.log` / `web-url.txt` 搬到 `$STATE_DIR`（目标已存在就不覆盖），顺手删掉 `$DSH_HOME/*.example`；搬了东西就提醒重跑 `notify-enable` 更新 patch 里的路径 | 0 |
| `check-hooks` | 见 §9（一次性进程做对照实验，不动正在跑的实例） | 0 / 1 |
| `log` | 把 `$STATE_DIR/notify.log` 和 `$STATE_DIR/web.log` 各 `tail -n 20`（有哪个看哪个）。**没有隧道日志** —— 隧道跑在 tmux/systemd 里，日志在那边 | 0 |
| `help` / `--help` / `-h` / 无参数 | `sed -n '2,25p' "$0"` 打印脚本头部注释。**现状瑕疵**：第 23 行是 `set -u`，所以用法后面会多打印 `set -u` 和两行无关注释（见 hazards H10） | 0 |
| 其它 | `die "不认识的命令：$1（dsh-remote help）"` | 1 |

### `notify-enable` 写进 profile patch 的那段（原文）

```yaml
# >>> dsh-remote notify（这一段由 dsh-remote notify-enable 生成，notify-disable 删；别手改）
- insert:
    - id: hooks-claude-code
      name: '@deepseek-ai/dsh-hooks-claude-code'
      config:
        configPath: <CONF_DIR>/hooks.json
        defaultTimeoutMs: 20000
# <<< dsh-remote notify
```

必须是 `- insert:`。写 `- id: hooks-claude-code` 会被 patch 层当成
"覆盖一个已有的行"，boot 时只警告 `patch: entry "hooks-claude-code" not found`，
然后什么都不发生 —— 这个坑踩过一次（hazards H1）。

---

## 4. `cloud-install`：会碰云上那台机器的唯一子命令

```
dsh-remote cloud-install [--domain D] [--ip I] [--email E] [--port P]
                         [--user U] [--allow-ip CIDR]... [--ssh-user S] [--dry-run]
```

1. 参数进 `ci_*`；`--allow-ip` 可以给多次（拼成一串）。
2. `cloud_host` 从 `remote.conf` 读（没有就 `die`）。ssh 用户 = `--ssh-user` >
   `cloud_user` > `root`；端口 = `cloud_ssh_port`（默认 22）；隧道/本地端口 =
   `remote_port` / `local_port`（默认 18080 / 3080）；`identity` 有就 `-i`。
3. 没给 `--domain` / `--ip` 时：`cloud_host` 是**纯数字加点**就自动当 `--ip`；
   否则 `die`（不瞎猜）。
4. 拼出远端参数串：`--tunnel-port <rp> --local-port <lp>` + 用户给的那些。
   **不给 `--password`** —— 密码由云上 `relay.sh` 每次随机生成。
5. `--dry-run`：只打印 `scp -r …` 和 `ssh -t …` 两条命令，**一个字节都不传**
   （测试 F 节用假的 ssh/scp 断言过）。
6. 真跑三步：
   - `scp -r <PROJ_DIR>/cloud <ssh_user>@<host>:/opt/dsh-relay`
     （失败 → `die`，提示查 ssh/密钥）；
   - `ssh -t <opts> <user>@<host> 'cd /opt/dsh-relay && if [ "$(id -u)" = 0 ]; then sh relay.sh …; else sudo sh relay.sh …; fi'`
     输出 `tee` 到 `$STATE_DIR/cloud-install.log`（失败 → 警告 + `return 1`）；
   - 从日志里 grep 第一个 `https://…` 写进 `$CONF` 的 `public_url`（有那行就
     `sed -i` 替换，没有就追加）。认不出来就警告让人自己填。
7. ssh/scp 都带 `-o StrictHostKeyChecking=accept-new -o LogLevel=ERROR`。

---

## 5. `cloud/relay.sh`：云上那一半

**在云上跑，要 root**（`--dry-run` 除外，脚本自己检查 `id -u` 并 `die`）。
它和 `Caddyfile.domain` / `Caddyfile.ip` / `docker-compose.yml` 必须放在同一个目录
（脚本用 `$0` 的目录找它们，找不到就 `die`）。

两种模式（**必须给且只能给一个** `--domain` / `--ip`）：

| | 域名模式 | IP 模式 |
|---|---|---|
| 触发 | `--domain dsh.example.com` | `--ip 47.98.1.2` |
| 对外端口默认 | `443` | `8443` |
| 模板 | `Caddyfile.domain` | `Caddyfile.ip` |
| 证书 | Let's Encrypt（ACME；`--email` 不给我就默认 `admin@<域名>`） | `tls internal` 自签（Caddy 自己的 CA） |
| 适用 | 有域名且**大陆机器已备案** | 没域名 / 没备案（或机器在境外） |

参数：`--email` `--port` `--tunnel-port`（默认 18080）`--local-port`（默认 3080）
`--user`（basic auth 用户名，默认 `dsh`）`--password`（不给就每次随机 20 位）
`--allow-ip`（可多次）`--install-docker` `--dry-run` `-h`。

它做的事，按顺序：

1. **docker 探测**：`docker compose version` 通就用 `docker compose`，否则退到
   `docker-compose`，都没有就 `die`。`--install-docker` 才会 apt 装
   （`docker.io` + `docker-compose-v2`，老发行版退 `docker-compose`）+ `systemctl enable --now docker`；
   非 apt 系统直接 `die`。
2. **密码哈希**：`docker run --rm <CADDY_IMAGE> caddy hash-password --plaintext <密码>`
   （`CADDY_IMAGE` 可换镜像，默认 `caddy:2`）。没有 docker 或是 dry-run 时用占位哈希
   `$2a$14$DRYRUNPLACEHOLDER…`。
3. **渲染**：`sed` 把 `{{DOMAIN}} {{EMAIL}} {{IP}} {{PORT}} {{USER}} {{HASH}}
   {{TUNNEL_PORT}} {{LOCAL_PORT}}` 替换掉；`{{ALLOW_BLOCK}}` 那一行换成
   一个临时文件的内容（两行：`@notme not remote_ip <一串>` + `respond @notme "forbidden" 403`）。
   渲染完还要 `grep -E '\{\{[A-Z_]+\}\}'` 兜底：有没替换的占位符就列出**行号**并 `die`。
4. **dry-run**：把 Caddyfile 打到 **stdout**（进度/报告全走 stderr，见 ADR-0011），
   有 docker 时写一份 `Caddyfile.dryrun` 用 `caddy validate` 真验一遍再删掉，然后 exit 0。
5. **真跑**：旧的 `Caddyfile` 备份成 `Caddyfile.bak-<时间戳>` → 落盘新的 →
   `mkdir logs` → `docker compose up -d` → 最多 20s 等 `compose ps` 里出现 `dsh-relay`
   → `sleep 2` 打一次 `compose ps`；`ufw` 处于 active 才 `ufw allow <PORT>/tcp`。
6. **自检**：域名模式 `curl -sk --resolve <域名>:<PORT>:127.0.0.1 https://<域名>:<PORT>/`，
   IP 模式 `curl -sk -H "Host: <IP>:<PORT>" https://127.0.0.1:<PORT>/`；
   **401 = 对**（basic auth 在挡），000 = 连不上，其它码 = basic_auth 没生效。
   再探一下 `http://127.0.0.1:18080/`：000 就是"家里的隧道还没起"（第一次跑正常）。
7. **结尾打印**（stderr）：手机地址、用户名、密码，`docker compose -f … ps/logs/down`
   三条命令，以及脚本做不了的两件事（安全组只放 22 + 对外端口；手机第一次要
   basic auth 一次 + 贴一次带 token 的地址）。

**可重复跑**：每次重新渲染（旧 Caddyfile 留备份）、recreate 容器、重新自检。
密码不给 `--password` 就每次换新的（这也意味着重跑一次要重新在手机上输密码）。

---

## 6. 云端两个模板与 compose 的实质内容

`cloud/Caddyfile.domain`（`{{...}}` 由 relay.sh 填）：

```
{ email {{EMAIL}}; admin 127.0.0.1:2019; auto_https disable_redirects }
{{DOMAIN}} {
    encode zstd gzip
    basic_auth { {{USER}} {{HASH}} }
    {{ALLOW_BLOCK}}                      # 没给 --allow-ip 时整行消失
    reverse_proxy 127.0.0.1:{{TUNNEL_PORT}} {
        header_up Host   127.0.0.1:{{LOCAL_PORT}}
        header_up Origin http://127.0.0.1:{{LOCAL_PORT}}
        header_up Referer http://127.0.0.1:{{LOCAL_PORT}}/
        flush_interval -1
        transport http { read_timeout 0 }
    }
    log { output file /var/log/caddy/dsh-access.log; format console }
}
```

`cloud/Caddyfile.ip` 只有三处不同：没有全局 `email`、站点名是 `{{IP}}:{{PORT}}`、
多一行 `tls internal`。两个模板都写了 `auto_https disable_redirects` ——
Caddy 默认会为了 http→https 跳转去占宿主 `:80`，80 被占或没备案时容器会
restart 循环（实测，hazards H6）。

`cloud/docker-compose.yml`：服务名 `relay`，`image: caddy:2`，
`container_name: dsh-relay`，**`network_mode: host`**（两个原因缺一不可：要连宿主
`127.0.0.1:18080` 的隧道口；要直接占用宿主 443/8443），`restart: unless-stopped`，
挂载 `./Caddyfile:ro`、`./logs:/var/log/caddy`、命名卷 `caddy-data:/data`
（证书 + 续期状态）、`caddy-config:/config`；healthcheck 每 60s 跑一次
`caddy validate`。**没有 `ports:` 映射**（host 网络下无效，加了只会误导）。

---

## 7. `bin/dsh-notify`：推送脚本

三种模式（选项顺序随便，`--hook` / `--async` / `--test` 可组合）：

```
dsh-notify "标题" "正文"        # 直接推；标题默认为 "DSH 消息"
dsh-notify --test              # 推一条测试消息（带主机名/时间/配置路径）
dsh-notify --hook [--async]    # 从 stdin 读 Claude Code 格式的 hook JSON
```

- 不认识的 `-*` 参数：打印一行到 stderr，**仍然 `exit 0`**。
- 配置 `$DSH_NOTIFY_CONF`（默认 `$CONF_DIR/notify.conf`），
  日志 `$DSH_NOTIFY_LOG`（默认 `$STATE_DIR/notify.log`）。
- **退出码永远是 0**：它挂在 `PreToolUse` 上，而 Claude Code 钩子协议里退出码 2 =
  阻止这次工具调用 —— 推送失败绝不能拦工具或卡住 agent。失败只写一行日志（ADR-0010）。

`provider` 与所需键（大小写两种写法都认，`conf_any` 依次试）：

| provider | 别名 | 需要的键 | 请求 |
|---|---|---|---|
| （缺省）`serverchan` | `serverchan-*` / `sct` | `SENDKEY` | `POST https://sctapi.ftqq.com/<key>.send`，`title`/`desp` |
| `dingtalk` | `ding` | `WEBHOOK` | POST JSON `{"msgtype":"text",…}`（要求机器人安全设置里有自定义关键词） |
| `telegram` | `tg` | `BOT_TOKEN` + `CHAT_ID` | `POST https://api.telegram.org/bot<tok>/sendMessage`（国内要代理，curl 认 `https_proxy`） |
| `bark` | — | `BARK_KEY`（可选 `BARK_SERVER`，默认 `https://api.day.app`） | `POST <server>/<key>` |
| `generic` | `webhook` / `http` | `URL` | `POST`，正文 `text/plain`，格式是"标题\n正文" |
| `none` | `off` | — | 什么都不发，写一行日志 |

其它：`on_stop`（默认 `1`）= 0/off/no/false/none 时 `Stop` 事件不推；
非 `--test` 的推送会把 `public_url` 附在正文最后；标题 `cut -c 1-60` 截断；
所有请求 `curl -fsS -m 20`。

`--hook` 的消息拼装（`hook_message`）：优先 `python3` 解析 stdin 的 JSON；
没有 `python3` 就退化成固定的"DSH 有事找你"。

| `hook_event_name` | 标题 | 正文 |
|---|---|---|
| `PreToolUse` + `tool_name=ask_user_question` | `❓ 会话在等你回答` | 每个问题（带 `header`）逐条列出，选项加 `· ` 前缀；解析不出内容就写"去界面上看" |
| `PreToolUse` + 别的工具 | `🔧 要用工具：<名字>` | `tool_input` 的 JSON，截 300 字符 |
| `Stop` | `✅ 这一轮跑完了` | 工作区名 |
| `SessionStart` | `▶️ 新会话开始了` | 工作区名 |
| 其它 / 解析不出事件名 | `DSH hook：<事件>` | 工作区名 |

`--async` 的实现：`( push … ) </dev/null >>"$LOG" 2>&1 &` 然后父进程立刻 `exit 0`。
**三个 fd 都要重定向走**，否则钩子 runner 会一直等管道 EOF，`--async` 就成了摆设（hazards H2）。

`hooks/claude-hooks.json`（模板；`__DSH_NOTIFY__` 被 `notify-enable` 换成实际命令路径）：

```json
{"hooks": {
  "PreToolUse": [{"matcher": "ask_user_question",
                  "hooks": [{"type": "command", "command": "__DSH_NOTIFY__ --hook --async", "timeout": 20}]}],
  "Stop": [{"hooks": [{"type": "command", "command": "__DSH_NOTIFY__ --hook --async", "timeout": 20}]}]}}
```

---

## 8. `scripts/install.sh`（`wtool install` 调它）

`set -eu`。**只有两种用法**：不带参数安装、`--uninstall` 卸载。
不碰网络、不碰 docker、不碰 systemd；stdin 当 `/dev/null` 用（不提问）；可重入。

源与落点（**全部问引擎要，不写死影子 HOME 的内部布局**，ADR-0007）：

```
proj   = ${WTOOL_PROJECT_DIR:-<按 $0 自推的项目目录>}      # 源
home   = ${WTOOL_HOME:-$HOME}                              # 被管理的家目录
prefix = ${WTOOL_PREFIX:-$home/.wtool/usr}                 # 命令落点
bin_dir   = $prefix/bin
etc_dir   = $prefix/etc/dsh-remote    # 配置实体
var_dir   = $prefix/var/dsh-remote    # 日志/运行期实体
conf_link = ${XDG_CONFIG_HOME:-$home/.config}/dsh-remote         # $home 里的软链
state_link= ${XDG_STATE_HOME:-$home/.local/state}/dsh-remote     # $home 里的软链
```

落点**只看家目录 / XDG**：故意不认 `DSH_REMOTE_CONF_DIR` / `DSH_REMOTE_STATE_DIR`
（那是运行期变量，装过一遍的人 shell 里一定有，会把软链铺到别处）。

安装动作：

1. `dsh-remote` / `dsh-notify`：源可执行才 `ln -sfn` 到 `$bin_dir`；已经是同一条软链就跳过
   （幂等）；目标存在且**不是**软链 → 警告跳过，不覆盖。
2. 两份样板 `notify.conf.example` / `remote.conf.example`：源在就 `cp -f` 进 `$etc_dir`
   （已存在就不重拷）。**两张样板一个都找不到 = 这一摊整段跳过**（连目录都不建）。
3. 有样板时：`link_dir_out` 把 `$conf_link` / `$state_link` 变成指向 `$etc_dir` /
   `$var_dir` 的软链。老布局（实体真在 `~/.config/dsh-remote` 下）会先把里面的东西
   **搬进前缀**、再换软链；搬不干净就保留原样并警告。

**"源找不到"的语义**（脚本头两条硬规矩）：只跳过那一条 + 打印"找的地方：…（来自
WTOOL_PROJECT_DIR / 按脚本位置自推）"，末尾交代跳过了几条；**整脚本仍然 exit 0**
（不能把一个项目的问题变成整个 `wtool install` 失败），但**一个字节都不写** ——
不留空目录、不留悬空软链。`--uninstall` 只撤两条命令软链和两条目录软链，
`etc/` / `var/` 里的实体（用户的配置和日志）留着，并提醒用 `notify-disable` 关钩子。

`env.zsh` / `env.bash`（两份内容等价，只有标题的 shell 名不同）导出三个变量：

```
DSH_REMOTE_DIR       = ${WTOOL_PROJECT_DIR:-${WTOOL_HOME:-$HOME}/.wtool/wtool-work-dir/links/tools/dsh-remote}
DSH_REMOTE_CONF_DIR  = ${DSH_REMOTE_CONF_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/dsh-remote}
DSH_REMOTE_STATE_DIR = ${DSH_REMOTE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dsh-remote}
```

---

## 9. 钩子桥的现状（**未证实会触发**）

`notify-enable` 能让 `dsh --profile web --dump-config` 里出现 `hooks-claude-code`
这一行，但 2026-09-21 的对照实验证明**插件并没有真的加载**：

- 把 `configPath` 指到一个**不存在**的文件，harness 不报任何错（静默跳过）；
- 一次性 `dsh --profile headless --patch <同一个 insert 行>` 跑真实任务，
  `SessionStart` / `Stop` / `PreToolUse` **一个都没触发**（本地接收端一条没收到、
  `notify.log` 是空的）；
- 正在跑的 web 实例十几轮也没写过一行日志；
- 插件**能解析**（`require.resolve` 通）、**加载失败会大声报错**（故意插重名条目会
  `duplicate loader entry id` 起不来），所以"没声音"不是"被静默跳过"；
- 已经排除了配置形状问题（`{"hooks":{…}}` 和扁平的 `{"Stop":[…]}` 都试过）。
- 剩下的嫌疑：profile 的 `dependencies` 为空 + 本机没有 `pnpm`（2026-10-07 实测
  `command -v pnpm` 仍然没有），插入的那一行解析不到包；或者这类事件需要作为
  bundle 的一部分（`dsh plugin add`）才算正式挂载。

**复查命令**（一次性进程、不动正在跑的会话、会真调一次模型、几十秒）：

```sh
dsh-remote check-hooks     # 触发 → 退出码 0；没触发 → 1，并打印两条出路
```

它做的事：起 `tests/http_sink.py`（本地接收端，只绑 127.0.0.1）→ 渲染一份临时
`notify.conf`（`provider=generic`、`URL=http://127.0.0.1:<随机口>/hook`、`on_stop=1`）
和一份临时 patch（`- insert:` + `configPath: $CONF_DIR/hooks.json`，**没有**
`defaultTimeoutMs`）→ 用 `timeout 300 dsh --profile headless --patch <临时 patch>
"只回答一个字：好"` 跑一次 → 看接收端文件有没有内容。没触发时把临时目录
（`out` / `err` / `notify.log` / `notify.conf`）留着给人看。

**规矩**：在证实之前，**不许把"会话卡住会推手机"写成已有能力**（ADR-0006）。

---

## 10. 测试（现状）

| 脚本 | 条数（2026-10-07 实测 / 静态数） | 要什么 | 覆盖 |
|---|---|---|---|
| `tests/run_tests.sh` | **179 通过 0 失败**（A 10 / B 6 / C 20 / D 21 / E 41 / F 14 / G 8 / H 6 / I 53） | `sh`、`python3`；B 节要 `zsh`，没有就打印 skip | 语法（dash+bash）、`env.*` 等价、推送真发到本地接收端、Caddyfile 渲染、子命令、`cloud-install` 参数拼装（假 ssh/scp）、`~/.dsh` 边界、`check-hooks` 两条路、安装脚本五大场景 |
| `tests/caddy-validate.sh` | **3 条**（ok 调用点 2 个模板 + 1 条反证） | **docker**（`caddy:2`）；没有 docker 时打印"跳过"并 **exit 0** | 用真 `caddy validate` 验两份渲染结果；再故意塞坏配置确认这个测试**能失败** |
| `tests/relay-e2e.sh` | **9 条**（数 ok 调用点；中途失败会提前 exit 1） | **docker** + `python3`；没有 docker 时打印跳过并 exit 0 | 真起 `caddy` 容器（host 网络）+ 假后端：渲染成功、`compose up` 成功、没密码 401、密码对 200、body 真的来自后端、`Host` 被改写成 `127.0.0.1:3080`、密码错 401、`compose down -v` 干净、容器撤掉 |
| `tests/http_sink.py` | — | `python3` | 测试零件：POST 的 body 追加写进文件（换行转义成 `\n`），只绑 127.0.0.1 |

⚠️ **两处跟 docker 有关的事实**（2026-10-07 实测，细节在 hazards H8）：

- `run_tests.sh` 在**装了 docker 的机器上**，D 节会经 `relay.sh --dry-run` 真跑
  `docker run --rm caddy:2 caddy validate`（每轮 5 次；`caddy:2` 不在本地会去拉镜像）
  —— 它的文件头写着"不碰 docker"，那句只在"机器上没有 docker"时成立；
- 两个 docker 脚本**没有 docker 时打印"跳过"就 `exit 0`**（空跑也算通过）。

`run_tests.sh` 的 I 节（53 条）是 2026-10-04 那次修复的回归测试，五个场景：
①引擎调用（`WTOOL_PROJECT_DIR`，引擎内部那格故意埋一份假的可执行文件）
②手工跑按 `$0` 自推（cwd 在别处 / 相对路径）
③换 `WTOOL_HOME`（落点跟它走，真 `$HOME` 一个东西都不多）
④源找不到（只跳过、说清去哪找、**一个字节都不写**）
⑤`--uninstall` 撤软链、留实体。
跑完比对真 `$HOME` 的指纹（`.zshrc` / `.bashrc` / `.config/dsh-remote` /
`.local/state/dsh-remote`）**逐字不变**；另有 `grep -F` 断言守着
`install.sh` / `env.zsh` / `env.bash` 里不出现 `$HOME/.wtool/...` 字面量。

**没被自动测的部分**（都在 `BACKLOG.md` 的"仍未做/未验证"里）：真阿里云上的
安全组/防火墙、真实 Let's Encrypt 签发与续期、手机浏览器上的实际体验、
隧道断线重连的真实时长、hook 桥真的会触发。

---

## 11. 环境变量总表

| 变量 | 谁用 | 作用 / 默认 |
|---|---|---|
| `WTOOL_PROJECT_DIR` | install.sh、env.* | 引擎导出的**源**目录；手跑时按 `$0` 自推 |
| `WTOOL_HOME` | install.sh、env.* | 被管理的家目录，默认 `$HOME` |
| `WTOOL_PREFIX` | install.sh | 命令落点，默认 `$WTOOL_HOME/.wtool/usr` |
| `DSH_HOME` | dsh-remote | DSH 自己的目录，默认 `$HOME/.dsh`（只往 `profiles/web/` 写 patch） |
| `DSH_REMOTE_HOME` | dsh-remote、dsh-notify、测试 | "伞"覆盖：设了它，配置和状态目录都在它下面 |
| `DSH_REMOTE_CONF_DIR` | dsh-remote、dsh-notify、env.* | 配置目录，默认 `${XDG_CONFIG_HOME:-$HOME/.config}/dsh-remote` |
| `DSH_REMOTE_STATE_DIR` | dsh-remote、dsh-notify、env.* | 日志/运行期目录，默认 `${XDG_STATE_HOME:-$HOME/.local/state}/dsh-remote` |
| `DSH_REMOTE_CONF` | dsh-remote | `remote.conf` 的完整路径 |
| `DSH_NOTIFY_BIN` | dsh-remote | hook/patch 里要写的 `dsh-notify` 路径（测试用来钉住） |
| `DSH_NOTIFY_CONF` | dsh-notify | 换 `notify.conf` 路径 |
| `DSH_NOTIFY_LOG` | dsh-notify | 换日志路径 |
| `XDG_CONFIG_HOME` / `XDG_STATE_HOME` | 上述全部 | 标准 XDG 覆盖 |
| `CADDY_IMAGE` | relay.sh、两个 docker 测试 | Caddy 镜像，默认 `caddy:2` |
| `AUTOSSH_GATETIME` | dsh-remote tunnel | 用 autossh 时置 0（第一次连不上也继续重试） |

---

## 12. 装完在磁盘上长什么样

`wtool install tools/dsh-remote` 之后（`$WTOOL_HOME` 默认就是 `$HOME`，
`$WTOOL_PREFIX` 默认 `$WTOOL_HOME/.wtool/usr`）：

| 落点 | 是什么 |
|---|---|
| `$WTOOL_PREFIX/bin/dsh-remote`、`dsh-notify` | 软链 → 项目检出目录的 `bin/` |
| `$WTOOL_PREFIX/etc/dsh-remote/` | 配置**实体**：install 只放两份 `*.example`；`remote.conf` / `notify.conf` / `hooks.json` 是之后由人和 `notify-enable` 写进去的 |
| `$WTOOL_PREFIX/var/dsh-remote/` | 日志/运行期**实体**：`notify.log`（推送）、`web.log`（harness 输出）、`web-url.txt`（带 token 的地址）、`cloud-install.log` |
| `~/.config/dsh-remote` | 软链 → `$WTOOL_PREFIX/etc/dsh-remote` |
| `~/.local/state/dsh-remote` | 软链 → `$WTOOL_PREFIX/var/dsh-remote` |
| `~/.dsh/profiles/web/cordis.patch.yml` | **唯一**必须待在 `~/.dsh` 的东西（profile patch 只能放那儿），由 `notify-enable` 写 |

云上（`relay.sh` 装出来的）：`/opt/dsh-relay/`（脚本 + 两个模板 + `docker-compose.yml`
+ 渲染好的 `Caddyfile` + `Caddyfile.bak-*` + `logs/`）、一个叫 `dsh-relay` 的容器、
两个命名卷 `caddy-data` / `caddy-config`。宿主上**没有** caddy 包、没有 `caddy.service`。
