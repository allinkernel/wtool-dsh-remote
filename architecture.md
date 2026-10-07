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
| `bin/dsh-remote` | 1673 | 家里这头的主命令（22 个子命令） |
| `bin/dsh-token-broker` | 172 | **token 重定向小服务**（纯 python 标准库；只做 302，不代理，见 §3.2） |
| `bin/dsh-qr` | 549 | **自带二维码**（纯 python；字节模式 + RS 纠错 + 标准罚分挑掩码；终端/PNG/SVG，见 §3.3） |
| `bin/dsh-remote-server` | 8 | `dsh-remote server` 的薄封装（用户先说的是这个名字，两个入口等价） |
| `bin/dsh-notify` | 238 | 推送脚本；也是 hook 桥调用的那个命令 |
| `scripts/install.sh` | 210 | `wtool install` 调它：铺命令软链 + 配置/日志软链 |
| `cloud/relay.sh` | 412 | **在云上跑**：渲染 Caddyfile → 起 Caddy 容器 → 自检（compose / 用户空间两种模式） |
| `cloud/Caddyfile.domain` | 47 | 域名模式模板（占位符 `{{...}}`） |
| `cloud/Caddyfile.ip` | 50 | IP 模式模板（`tls internal` 自签 + `default_sni`） |
| `cloud/docker-compose.yml` | 41 | 中继器：一个 `caddy:2.11.4` 容器（host 网络）+ 两个命名卷 |
| `hooks/claude-hooks.json` | 27 | hook 桥模板（`__DSH_NOTIFY__` 由 `notify-enable` 替换成实际命令） |
| `env.zsh` / `env.bash` | 24 / 24 | shell 集成：只导出三个目录变量；两份必须同改 |
| `wtool.xml` | 33 | 服务清单：`<zshrc>` / `<bashrc>` / `<publish kind="source"/>` |
| `remote.conf.example` | 31 | 隧道配置样板 |
| `notify.conf.example` | 44 | 推送配置样板 |
| `tests/run_tests.sh` | 1271 | **362 条**（2026-10-07 实测），不联网 / 不碰真 `$HOME` / 不碰真 `~/.config/systemd/user` 与真 tmux / 不碰真云；**装了 docker 的机器上 D 节会真跑** `docker run --rm caddy:2.11.4 caddy hash-password / version / validate` |
| `tests/caddy-validate.sh` | 73 | 3 条，用 `caddy:2.11.4` 真校验 Caddyfile（要 docker；没 docker 时 **`exit 77`**） |
| `tests/relay-e2e.sh` | 139 | 9 条，真起 Caddy 容器验 HTTPS+basic auth+反代（要 docker；没 docker 时 **`exit 77`**） |
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
   （`docker run --rm caddy:2.11.4 caddy hash-password` 算出的 bcrypt 哈希写在 Caddyfile 里）。
   `--allow-ip` 给了的话前面还有一条 `@notme not remote_ip …` → 403。
4. Caddy `reverse_proxy 127.0.0.1:18080`，并把请求头改写成
   `Host: 127.0.0.1:3080`、`Origin: http://127.0.0.1:3080`、
   `Referer: http://127.0.0.1:3080/` —— 这样 `dsh web` 的"浏览器信任围栏"
   （默认只认回环 / 本机 LAN / `--trusted-host`）就认这个请求，**不用重启 harness**。
   会话界面是流式的：`flush_interval -1` + `read_timeout 0`。
5. 18080 是**云上 sshd 的 `-R` 监听口**，只绑 `127.0.0.1`（安全组里没有它）。
   同一条 ssh 上还有 18081 → 家里的 **token broker**（只做 302，见 §3.2）：
   `dsh web` 的 token 每个进程随机、只在内存里，所以手机收藏的固定地址
   `https://<入口>/`（不带 token）由 Caddy 交给 broker，broker 302 到
   `/?token=<当前值>`；拿 token 换到 30 天的签名 cookie 之后，`/` 就直连 dsh web 了。
6. 隧道另一头是家里的一条 **systemd `--user` 常驻服务** `dsh-tunnel.service`：
   `ssh -N -T … -R 127.0.0.1:18080:127.0.0.1:3080 <云上用户>@<云上主机>`
   （由 `dsh-remote tunnel-install` 渲染 + `enable --now`，见 §3.1）。
   `Restart=always` 负责把退出的 ssh 拉起来，ssh 自己的 `ServerAlive*` 负责把
   "网络断了但没退"的连接踢死；`dsh-remote tunnel` 是同一个 ssh 参数的前台版本，
   留给调试用（不再需要 tmux 手工保活）。
7. 家里 `127.0.0.1:3080` 是 `dsh web`。手机第一次还要贴一次带 token 的地址
   （`dsh-remote serve` 会把它存到 `$STATE_DIR/web-url.txt`），之后浏览器记住。

**信任边界只有一道**：Caddy 的 basic auth + TLS。因为第 4 步把来源伪装成了回环，
harness 分不清请求来自本地还是远程 —— 所以 basic auth 的密码必须长且随机，
443/8443 之外的端口（18080、3080）绝对不能在安全组里开。

---

## 3. `bin/dsh-remote`：22 个子命令的真实行为

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
| `tunnel` | **前台**死循环保活一条反向隧道（调试用；常驻走 `tunnel-install`）。ssh 参数由 `tunnel_conf`（读配置）+ `tunnel_argv` 一处拼出，三处共用（本命令 / 单元渲染 / `tunnel-status` 的漂移对比）：`-N -T -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o TCPKeepAlive=yes -o StrictHostKeyChecking=accept-new -p <cloud_ssh_port>`（默认 22），有 `identity` 就加 `-i`（`~/` 开头会展开成 `$HOME/`），最后是 `-R 127.0.0.1:<remote_port>:127.0.0.1:<local_port> <cloud_user>@<cloud_host>`（默认 `18080:127.0.0.1:3080`、`root`）。配置 `autossh` 不是 `off` **且** PATH 里有 `autossh` 时用 `AUTOSSH_GATETIME=0 autossh -M 0 <同样的参数>`，否则用裸 `ssh`。每断一次打印退出码，睡 `retry_seconds`（默认 10）再连。**没有 daemon 化、没有指数退避**；单元那条路额外加 `-o BatchMode=yes`（服务里没终端，别等密码提示） | 循环 / `cloud_host` 缺失时 1 |
| `tunnel-install` | **装常驻隧道**（2026-10-07 加，ADR-0013）：先探 `systemctl --user`（连不上用户管理器 → 打印 `loginctl enable-linger` 两条出路后 `die`，**先探再动旧的**，什么都不碰）→ 检测旧的一次性 tmux 会话（`tmux_session`，默认 `dsh-tunnel`）：在就 `kill-session`（除非 `--keep-tmux`）→ 检测旧版单元 `dsh-remote-tunnel.service`：在就 `disable --now` → 渲染 `~/.config/systemd/user/dsh-tunnel.service` 落盘（内容一样就不动；不一样先备份 `$uf.bak-<时间戳>`）→ `daemon-reload` + `enable --now`；**内容变了且原本 active** 时再补一次 `restart`（`enable --now` 不会重启已在跑的单元）→ 停 3 秒看 `is-active`/`MainPID`/`NRestarts`，涨了就警告（端口被占/认证失败）→ 打印判据（云上 `ss`、公网 curl、`tunnel-status`、linger）。选项：`--restart-sec`（默认 3）`--remote-port` `--local-port` `--ssh-user`（覆盖 `cloud_user`）`--no-enable` `--keep-tmux` `--dry-run` | 0 / 1 |
| `tunnel-uninstall` | `disable --now dsh-tunnel.service`（旧版单元在也一起）→ `daemon-reload` → 删单元文件（两个名字都删）。`systemctl --user` 不可用时只删文件并警告。`--dry-run` 只打印 | 0 |
| `tunnel-status` | 只读体检：单元路径 + `is-active`/`is-enabled`/`MainPID`/`NRestarts`/`RestartSec`；**漂移检测**——拿单元里那行 `ExecStart` 和"用现在的 remote.conf 重新渲染会得到什么"逐字比（不一致就提示重装）；`pgrep` 看占着远程端口的 `ssh -R`；旧 tmux 会话在不在；本地远程端口不该在听、`local_port` 该在听；`linger` 状态。`--probe` 再上云跑**只读**命令（`ss -ltn | grep <rp>` + `curl 127.0.0.1:<rp>/`，401 = 请求穿到了家里的 dsh web），`--interface IF` 给 curl 绑网卡（绕开本机 Clash 用，见 hazards H11） | 0 / 1 |
| `systemd` | **旧名字，保留**：打印一行"= `tunnel-install --no-enable`"后走同一条路（只渲染落盘，不 `daemon-reload` / 不 enable）。单元名从旧版的 `dsh-remote-tunnel.service` **换成 `dsh-tunnel.service`** | 0 / 1 |
| `url` | 打印 `public_url`；没配就 `die` | 0 / 1 |
| `notify-test` | 调 `dsh-notify --test`，再提示失败细节看 `$STATE_DIR/notify.log` | 0 |
| `notify-enable` | ①`mkdir -p $CONF_DIR $DSH_HOME/profiles/web` ②把 `hooks/claude-hooks.json` 里的 `__DSH_NOTIFY__` 换成 `$NOTIFY` 写进 `$CONF_DIR/hooks.json`（模板不在就 `die`）③`$DSH_HOME/profiles/web/cordis.patch.yml` 不存在就先建一个 `# 注释` + `[]` ④里面没有 `# >>> dsh-remote notify` 标记时：先备份成 `$pf.bak-dsh-remote`，文件里**整行是 `[]`** 就把 `[]` 换成那段块（YAML 里两个顶层值会打架），否则直接追加 ⑤打印验证命令 `dsh --profile web --dump-config \| grep -A3 hooks-claude-code`。**幂等**（标记在就跳过） | 0 / 1 |
| `notify-disable` | 用 `awk` 把 `# >>> dsh-remote notify` 到 `# <<< dsh-remote notify` 之间那段删掉；删完如果只剩注释/空行，补回一行 `[]`（profile 的空 patch 层会让 boot 失败）。`hooks.json` 留着不删 | 0 / 1 |
| `server` | **一条命令装好**（2026-10-07 加，ADR-0015）：问/收参数（`--host` `--ssh-user` `--ssh-port` `--port` `--web-user` `--password` `--dir` `--docker-cmd` `--tunnel-port` `--broker-port` `--local-port` `--broker-local-port`；`--yes` 全默认、`--dry-run` 只打印、`--skip-deploy` / `--skip-local` / `--no-harness` 分段跑）→ **自检**（免密 ssh + 远端 `id -un` 必须等于 `--ssh-user`；`docker info` 与 `sudo -n docker info` **分开探**；对外端口没被别人占；从家里 `curl` 看安全组；认出已装的 `dsh-relay`）→ **云上部署**（`scp -r cloud/` + `relay.sh --no-compose` 用户空间模式，失败**不再被管道吞掉**）→ 写回 `remote.conf` → 家里 `broker-install` + `tunnel-install` → `local_port` 没人听才用 `harness` 函数起 harness → 打印固定地址 + 二维码 + 改密码/停/看日志三条命令 | 0 / 1 |
| `token-broker` | **前台**跑 broker（`--port` / `--web-port` / `--token-file` 可覆盖）；常驻用 `broker-install`。它自己 `exec python3 bin/dsh-token-broker` | 循环 / 1 |
| `broker-install` | 渲染并装 `~/.config/systemd/user/dsh-token-broker.service`（`ExecStart=<python3> <PROJ_DIR>/bin/dsh-token-broker --port <broker_local_port> --web-port <local_port> --token-file <token_file>`；`Restart=always` / `RestartSec=3` / `StartLimitIntervalSec=0` / journald）→ `daemon-reload` → `enable --now` → 停 2 秒打印判据（含 `curl http://127.0.0.1:<port>/` 的 302/503 判读）。`--no-enable` / `--dry-run` | 0 / 1 |
| `broker-uninstall` | `disable --now` + 删单元 + `daemon-reload`；token 文件留着（`harness` 函数还在写） | 0 |
| `cloud-setup` | **只打印**要人在云上敲的 scp / ssh 命令（值从 `remote.conf` 取，缺的用 `<你的阿里云公网 IP>` / `root` / `18080` / `3080` 占位），末尾提醒安全组只开 22 + 443/8443，**绝不要开 18080 和 3080** | 0 |
| `cloud-install` | 见 §4（这是唯一会碰云上那台机器的子命令） | 0 / 1 |
| `migrate` | 把旧版放在 `$DSH_HOME` 下的 `remote.conf` / `notify.conf` / `hooks.json` 搬到 `$CONF_DIR`，`notify.log` / `web.log` / `web-url.txt` 搬到 `$STATE_DIR`（目标已存在就不覆盖），顺手删掉 `$DSH_HOME/*.example`；搬了东西就提醒重跑 `notify-enable` 更新 patch 里的路径 | 0 |
| `check-hooks` | 见 §9（一次性进程做对照实验，不动正在跑的实例） | 0 / 1 |
| `log` | 把 `$STATE_DIR/notify.log` 和 `$STATE_DIR/web.log` 各 `tail -n 20`（有哪个看哪个）。**没有隧道日志** —— 隧道跑在 tmux/systemd 里，日志在那边 | 0 |
| `help` / `--help` / `-h` / 无参数 | 打印脚本头部注释块：`awk 'NR == 1 { next } /^#/ { print; next } { exit }' "$0" \| sed 's/^# \{0,1\}//'` —— 跳过 shebang，从第 2 行起**连着**以 `#` 开头的都打，碰到第一条正文（**空行也算**）就停。范围是算出来的，往头部加/删注释行都不用改代码（2026-10-07 修 H10；此前写死 `sed -n '2,25p'`，越界多打了 `set -u` 和两行无关注释） | 0 |
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

### 3.1 常驻隧道：`~/.config/systemd/user/dsh-tunnel.service`（2026-10-07 加）

**为什么要它**：原来靠一个一次性 tmux 会话里的 `ssh -N -R` 保活，**断了不会自己回来**
（U3）。现在由 `tunnel-install` 渲染成 systemd `--user` 单元并 `enable --now`；
重连分两层，各管一段（ADR-0013）：

| 断成什么样 | 谁发现 | 多久回来 |
|---|---|---|
| ssh 进程**退了**（对端重启、认证失败、被 kill） | systemd `Restart=always` | `RestartSec`（默认 3s）+ ssh 握手 |
| 网络断了但 ssh **僵着不退** | ssh 自己 `ServerAliveInterval=15 × ServerAliveCountMax=3` | ≤45s 被发现，再按上一行回来 |

**实测**（2026-10-07 12:10，`kill -9 <MainPID>`，见 `journal.md` 同日条目）：
两次分别 **3199ms / 3207ms** 拉起新进程，公网 401 恢复 **3276ms / 3305ms**。
⚠️ 只测了"进程被杀"这一条路；**"网络真断（ServerAlive 那条路）"没测过**。

渲染出来的单元（现状，`#` 注释是单元里就有的）：

```ini
[Unit]
Description=DSH 反向隧道（手机远程接管家里这台机器）
Documentation=file:<PROJ_DIR>/README.md
# 断了就无限重试：0 = 关掉"短时间失败太多次就判 failed"（默认 10s 内 5 次）。
StartLimitIntervalSec=0

[Service]
Type=simple
# BatchMode：服务里没有终端，别让它停在那儿等密码/host key 提问
ExecStart=/usr/bin/ssh -N -T -o BatchMode=yes -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o TCPKeepAlive=yes \
  -o StrictHostKeyChecking=accept-new -p <cloud_ssh_port> [-i <identity>] \
  -R 127.0.0.1:<remote_port>:127.0.0.1:<local_port> <cloud_user>@<cloud_host>
Restart=always
RestartSec=<--restart-sec，默认 3>
# 日志走 journald：journalctl --user -u dsh-tunnel.service
StandardOutput=journal
StandardError=journal
SyslogIdentifier=dsh-tunnel

[Install]
WantedBy=default.target
```

**几个键为什么必须这样**（踩过，别改回去）：

- `StartLimitIntervalSec=0` **属于 `[Unit]`** —— 写到 `[Service]` 里 systemd 只警告
  `Unknown key name` 然后忽略（`systemd-analyze --user verify` 抓出来的）。
  置 0 = 无限重试：实测认证失败时它会 **每 3 秒一次一直试**（12:09 那次 35 秒里 10 次），
  不会自己停下 —— 所以 `tunnel-install` 才要"先探用户管理器、再停旧隧道"。
- `ExitOnForwardFailure=yes` + `Restart=always` 合起来有个坑：云上端口被别的隧道占着时
  ssh **秒退**，于是变成"每 3 秒重试一次"的死循环（hazards H14）。
- `ExecStart` 是**一行**、参数由 `sd_quote` 逐个转义（含空格/`$`/`%` 的参数会被引起来、
  `$`→`$$`、`%`→`%%`）。`ssh` 写绝对路径（`command -v ssh` 的结果）。
- 单元里**嵌了** host / 用户 / 端口 / identity（不是运行时读 `remote.conf`）——
  所以改了 `remote.conf` 要重跑 `tunnel-install`；`tunnel-status` 会把
  "单元里的 ExecStart" 和 "现在渲染会得到什么" 逐字比，不一致就提示（漂移检测）。

**linger**：用户管理器默认只在"有登录会话"时活着。`loginctl enable-linger <用户>`
之后 logind 会在开机时就把 `user@<uid>.service` 拉起来，服务才谈得上常驻 ——
本机 2026-10-07 实测**不需要 sudo**（polkit 允许 self-linger），回退 `disable-linger`。
`tunnel-install` / `tunnel-status` 都会把 `Linger=` 打出来，但**不替你开**。

**装/卸的边界**：只写 `~/.config/systemd/user/dsh-tunnel.service`（+ `.bak-<时间戳>`）
和它自己的 `enable` 软链；`systemctl --user daemon-reload` / `enable --now` /
`disable --now` / `restart`。**不碰 `/etc/systemd`**、不碰系统级 unit。

### 3.2 手机固定地址：`harness` 函数 + token broker + Caddy 两条路由（2026-10-07 加）

**要解决的问题**：`dsh web` 的 token 是**每个进程随机、只在内存里**的
（`processLaunchToken`，32 字节 base64url；`dsh web --help` 里没有固定 token / 关鉴权的开关 ——
hazards H22），所以"家里重启一次 harness，手机上的地址就作废"。做法见 ADR-0014：

```
手机 → https://<入口>/（不带 token，Caddy 先过 basic auth）
        │  Caddy @entry：path / 且没有 token 参数 且 没有 dsh-auth-* cookie
        ▼
      云上 127.0.0.1:18081 ──（同一条 ssh 的第二条 -R）──▶ 家里 127.0.0.1:3081
        │                                                     dsh-token-broker
        │  302 Location: /?token=<当前值>                      读 current-token.txt
        ▼
      再打 https://<入口>/?token=… → Caddy 直连 18080 → 家里 dsh web
        │  303 ./  +  Set-Cookie: dsh-auth-<authority>=…（30 天）
        ▼
      之后 / 带 cookie → Caddy 的 @entry 不匹配 → 直连 dsh web → 200（0 次跳转）
```

- **`harness` 函数**（`env.zsh` / `env.bash`，两份逐字等价）：包装
  `npx @deepseek-ai/dsh web "$@"`，把 stdout 里 `dsh web: http://…/?token=…` 的
  token 写进 `$STATE_DIR/current-token.txt`、完整 URL 写进 `web-url.txt`（都 600），
  并把 `remote.conf` 里的 `public_url` 打出来提示"收藏这个"；**退出时删掉 token 文件**。
  文件在 source 时还会 `unalias harness`（别名优先于函数，用户原来那条 alias 会盖住它）。
- **`bin/dsh-token-broker`**（`dsh-remote broker-install` 装成 `dsh-token-broker.service`）：
  只绑 `127.0.0.1:3081`；`GET /`（不带 token）与 `GET /go` → 302 `/?token=<当前值>`；
  读不到 token 文件、或 `dsh web` 端口没在听 → **503 + 一句人话**；别的路径 404 / 方法 405。
  **不代理任何应用流量**（SSE/WebSocket 走 Caddy 直连那条路）。
- **Caddy 那两条 `not` 缺一不可**（`path /` + `not query token=*` +
  `not header Cookie *dsh-auth-*`）：少第一条，带 token 的请求会被反复 302；
  少第二条就是死循环（`/` → broker → `/?token` → 303 `./` → `/` → broker → …）。
  两条路由的原文见 §6。
- `tunnel-status` 会把 broker 单元状态、token 文件有没有、`127.0.0.1:3081` 在不在听
  一起打出来；`--probe` 还会在云上只读地打一次 `127.0.0.1:18081/`（302 = 好、503 = 没 token）。

### 3.3 一条命令装好：`dsh-remote server`（2026-10-07 加）

`dsh-remote server` = **自检 → 云上部署 → 家里常驻 → 起 harness → 打印地址和二维码**，
决策与否决见 ADR-0015。实际行为：

- **问什么**：`--host`（云上 IP/域名）、`--ssh-user`、`--ssh-port`、`--port`（对外）、
  `--web-user`、`--password`（回车 = 随机 20 位字母数字）；命令行给了就不问，
  `--yes` 或"stdin 不是终端"时全用默认值（默认值优先取 `remote.conf`，`ssh_user` 缺省 `$USER`）。
  密码里出现引号/空格会**直接拒**（要塞进远程命令行）。
- **自检**（任一条不过就打印"怎么修"并停）：免密 ssh + 远端 `id -un` 必须等于 `--ssh-user`；
  `docker info` 与 `sudo -n docker info` **分开探**（H18）；对外端口没被别人的东西占；
  从家里 `curl -sk https://<host>:<port>/` 看安全组（401/302 = 通，000 = 大概没放行）；
  `sudo docker ps --filter name=dsh-relay` 认出"已经装过"。
- **部署**：`scp -r cloud/ → ssh 'cd <dir> && sh cloud/relay.sh --no-compose …'`；
  远程输出**先落文件再判 rc**（管道 + `tee` 会把失败吞掉，H20）。装完立刻再打一次入口
  （401 = basic auth 在挡 / 302 = broker 在补 token）。
- **家里**：`broker-install` + `tunnel-install`（两个 systemd 单元；ADR-0013/0014）。
- **harness**：`local_port` 上已经有人在听 → **不动它**，只报告"token 有没有被捕获"；
  否则 `exec <shell> -c ". env.<shell>; harness --no-open --port <local_port>"`
  （用 `env.*` 里那个函数，token 才会被 broker 看见）。
- **二维码**：有 `qrencode` 就用它，否则 `python3 bin/dsh-qr --ecc M --border 2
  --png $STATE_DIR/phone-qr.png --svg $STATE_DIR/phone-qr.svg <固定 URL>`；
  码里编的**永远是不带 token 的固定地址**。
- `bin/dsh-remote-server` 是它的薄封装（三行 `exec`），两个名字等价。

`bin/dsh-qr` 是**自带**的二维码实现（纯 python，不依赖 qrencode / PIL / pip）：
字节模式、版本 1–40 自动挑、纠错 L/M/Q/H、8 种掩码按 ISO/IEC 18004 §8.8.2 的罚分挑，
输出终端半块字符画（自带前景/背景色）、1 位灰度 PNG（`zlib`+`struct` 手写）、纯文本 SVG。
规格表（纠错分块、对齐图案位置）是标准常数；**正确性拿一份独立实现逐模块对过账**
（npm 自带 `qrcode-terminal` 里 Kazuhiko Arase 的 JS 实现，MIT），回归向量在 §10 的 L 节。

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

**两种跑法**（2026-10-07 加了第二种，ADR-012）：

| | compose 模式（默认） | **用户空间模式**（`--no-compose`） |
|---|---|---|
| 要什么 | **root**（`id -u != 0` 直接 `die`）+ `docker compose` 插件（退 `docker-compose`） | 不要求 root；只要能跑 `docker run` |
| 落盘 | 脚本自己所在目录（`$SELF_DIR`，要和 `docker-compose.yml` 放一起） | `--dir <目录>`（默认也是 `$SELF_DIR`）|
| 数据 | 命名卷 `caddy-data` / `caddy-config` | 宿主目录 `$DIR/{data,config,logs}` |
| 起容器 | `docker compose up -d` | `docker rm -f dsh-relay` → `docker run -d --name dsh-relay --restart unless-stopped --network=host -v …` |
| docker 命令 | 写死 `docker` | `--docker-cmd '<命令>'`（默认 `docker`；要提权就 `'sudo docker'`）|

`--dry-run` 两种模式都不要 root。它和 `Caddyfile.domain` / `Caddyfile.ip` /
`docker-compose.yml` 必须放在同一个目录（脚本用 `$0` 的目录找它们，找不到就 `die`；
**用户空间模式不再要求 `docker-compose.yml` 存在**）。

两种模式（**必须给且只能给一个** `--domain` / `--ip`）：

| | 域名模式 | IP 模式 |
|---|---|---|
| 触发 | `--domain dsh.example.com` | `--ip 47.98.1.2` |
| 对外端口默认 | `443` | `8443` |
| 模板 | `Caddyfile.domain` | `Caddyfile.ip` |
| 证书 | Let's Encrypt（ACME；`--email` 不给我就默认 `admin@<域名>`） | `tls internal` 自签（Caddy 自己的 CA） |
| 适用 | 有域名且**大陆机器已备案** | 没域名 / 没备案（或机器在境外） |

参数：`--email` `--port` `--tunnel-port`（默认 18080）`--broker-port`（默认 18081，token broker 那条，ADR-0014）`--local-port`（默认 3080）
`--user`（basic auth 用户名，默认 `dsh`）`--password`（不给就每次随机 20 位）
`--allow-ip`（可多次）`--install-docker` `--no-compose` `--dir` `--docker-cmd`
`--dry-run` `-h`（`--help` 用 awk 打到头部注释块结束，**不写死行号**）。

它做的事，按顺序：

1. **docker 探测**：按 `$DOCKER`（`--docker-cmd`，默认 `docker`）查那条命令在不在；
   compose 模式下 `docker compose version` 通就用 `docker compose`，否则退到
   `docker-compose`，都没有就 `die`（并提示可以改用 `--no-compose`）。
   `--install-docker` 才会 apt 装（`docker.io` + `docker-compose-v2`，老发行版退
   `docker-compose`）+ `systemctl enable --now docker`；非 apt 系统直接 `die`。
2. **密码哈希**：`$DOCKER run --rm <CADDY_IMAGE> caddy hash-password --plaintext <密码>`
   （`CADDY_IMAGE` 可换镜像，**默认钉住的 `caddy:2.11.4`** —— 浮动 tag 会被国内
   mirror 兑成旧镜像，hazards H13）。没有 docker 或是 dry-run 时用占位哈希
   `$2a$14$DRYRUNPLACEHOLDER…`。
   **紧跟一道版本自检**：`$DOCKER run --rm <CADDY_IMAGE> caddy version` ——
   真跑时 < 2.8 就 `die`（`basic_auth` 指令要 ≥ 2.8），dry-run 时只 `warn`，
   认不出（空串）也只 `warn`。
3. **渲染**：`sed` 把 `{{DOMAIN}} {{EMAIL}} {{IP}} {{PORT}} {{USER}} {{HASH}}
   {{TUNNEL_PORT}} {{BROKER_PORT}} {{LOCAL_PORT}}` 替换掉；`{{ALLOW_BLOCK}}` 那一行换成
   一个临时文件的内容（两行：`@notme not remote_ip <一串>` + `respond @notme "forbidden" 403`）。
   渲染完还要 `grep -E '\{\{[A-Z_]+\}\}'` 兜底：有没替换的占位符就列出**行号**并 `die`。
4. **dry-run**：把 Caddyfile 打到 **stdout**（进度/报告全走 stderr，见 ADR-0011），
   有 docker 时 `mkdir -p $DIR` 后写一份 `Caddyfile.dryrun` 用 `caddy validate` 真验一遍
   再删掉；用户空间模式还会把"真跑时会执行的那条 `docker run …`"打到 stderr，然后 exit 0。
5. **真跑**：`mkdir -p -- "$DIR"`（**不存在的 `--dir` 也能用** —— 以前不建，
   `set -eu` 下一行 "cannot create …Caddyfile: Directory nonexistent" 就退出，
   hazards H19）→ 旧的 `$DIR/Caddyfile` 备份成 `Caddyfile.bak-<时间戳>` → 落盘新的 →
   `mkdir -p $DIR/{logs,data,config}` → 起容器（compose 模式 `docker compose up -d`；
   用户空间模式 `rm -f` 再 `docker run -d`）→ 最多 20s 等 `dsh-relay` 出现在 `ps` 里
   → `sleep 2` 再打一次 ps；`ufw` 处于 active 才 `ufw allow <PORT>/tcp`
   （非 root 跑时 `ufw status` 本来就失败 → 这一步自然跳过）。
6. **自检**：域名模式 `curl -sk --resolve <域名>:<PORT>:127.0.0.1 https://<域名>:<PORT>/`，
   IP 模式 `curl -sk -H "Host: <IP>:<PORT>" https://127.0.0.1:<PORT>/`；
   **401 = 对**（basic auth 在挡），000 = 连不上，其它码 = basic_auth 没生效。
   再探 `http://127.0.0.1:<TUNNEL_PORT>/`（000 = 家里的隧道还没起，第一次跑正常）
   和 `http://127.0.0.1:<BROKER_PORT>/`（**302 = broker 好、503 = 家里还没有 token**、
   000 = broker 那条隧道没起）。
7. **写 `$DIR/relay-password.txt`（600）**：`URL=` / `USER=` / `PASSWORD=` + "改密码三步"。
   **脚本自己写**，谁重渲染谁负责 —— 以前是人手写、脚本不更新，重跑一次就漂移
   （hazards H17；加强说明也在那一条）。
8. **结尾打印**（stderr）：手机地址、用户名、密码（并说清三样也写在那个 600 的文件里），看状态/看日志/撤掉三条命令
   （按模式给 `docker compose -f …` 或 `$DOCKER …`），以及脚本做不了的两件事
   （安全组只放 22 + 对外端口；手机第一次要 basic auth 一次 + 贴一次带 token 的地址）。

**可重复跑**：每次重新渲染（旧 Caddyfile 留备份）、recreate 容器（用户空间模式靠
`rm -f` 再 `run`）、重新自检。密码不给 `--password` 就每次换新的
（这也意味着重跑一次要重新在手机上输密码）。

---

## 6. 云端两个模板与 compose 的实质内容

`cloud/Caddyfile.domain`（`{{...}}` 由 relay.sh 填）：

```
{ email {{EMAIL}}; admin 127.0.0.1:2019; auto_https disable_redirects }
{{DOMAIN}} {
    encode zstd gzip
    basic_auth { {{USER}} {{HASH}} }
    {{ALLOW_BLOCK}}                      # 没给 --allow-ip 时整行消失
    # ① 不带 token 的入口 → 家里的 token broker（它 302 到 /?token=<当前值>）
    #    两条 not 缺一不可，少一条就是 302 死循环（ADR-0014）
    @entry {
        path /
        not query token=*
        not header Cookie *dsh-auth-*
    }
    reverse_proxy @entry 127.0.0.1:{{BROKER_PORT}} {
        header_up Host 127.0.0.1:{{LOCAL_PORT}}
    }
    # ② /go = 重进入口（cookie 过期 / 换过 token 之后点一下）
    @go path /go
    reverse_proxy @go 127.0.0.1:{{BROKER_PORT}} {
        header_up Host 127.0.0.1:{{LOCAL_PORT}}
    }
    # ③ 其余（带 token / 带 cookie 的 /、会话、SSE、WebSocket）直连 dsh web
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

两条模板的站点块**逐字一样**（都用 `{{BROKER_PORT}}`；broker 那条是 2026-10-07 加的，
ADR-0014）；`cloud/Caddyfile.ip` 只有四处不同：没有全局 `email`、站点名是 `{{IP}}:{{PORT}}`、
多一行 `tls internal`，以及全局块里多一行 **`default_sni {{IP}}`**。
最后这行是**必须的**：浏览器连 `https://<IP>:8443` 时**不发 SNI**
（RFC 6066 不允许 SNI 放 IP 字面量），没有它 Caddy 选不出证书、握手直接
`internal error`（2026-10-07 真机实测，ADR-012 / hazards H13）。
两个模板都写了 `auto_https disable_redirects` ——
Caddy 默认会为了 http→https 跳转去占宿主 `:80`，80 被占或没备案时容器会
restart 循环（实测，hazards H6）。

`cloud/docker-compose.yml`：服务名 `relay`，**`image: caddy:2.11.4`**（钉住的 tag，
不是浮动的 `caddy:2` —— 国内 mirror 会把浮动 tag 兑成旧镜像，hazards H13），
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
| `tests/run_tests.sh` | **363 通过 0 失败**（A 10 / B 6 / C 22 / D 27 / E 53 / F 14 / G 8 / H 6 / I 55 / J 69 / **K 35** / **L 12** / **M 46**；2026-10-07 实测） | `sh`、`python3`；B 节要 `zsh`，没有就打印 skip；**装了 docker 时 D 节要 docker**（镜像不在本地会去拉） | 语法（dash+bash）、`env.*` 等价、推送真发到本地接收端、Caddyfile 渲染（含 IP 模式 `default_sni`、用户空间模式）、子命令、`cloud-install` 参数拼装（假 ssh/scp）、`~/.dsh` 边界、`check-hooks` 两条路、安装脚本五大场景、常驻隧道的单元渲染/幂等/冲突/卸载（J 节，单元落点与 systemctl/tmux 全是桩）、**token 固定地址（K 节：harness 函数两个 shell 各抓一次 token / broker 的 302 与 503 反例 / Caddyfile 的两条 `not`）**、**自带二维码（L 节：矩阵 sha256 与独立实现对过账、PNG/SVG/终端画、太长要报错）**、**`server` 一条命令（M 节：四类自检失败的指引、`--dry-run` 不写、全参非交互跑通、部署失败不能被吞、薄封装走同一条路）** |
| `tests/caddy-validate.sh` | **3 条**（ok 调用点 2 个模板 + 1 条反证） | **docker**（`caddy:2.11.4`）；没有 docker 时打印"跳过"并 **exit 77** | 用真 `caddy validate` 验两份渲染结果；再故意塞坏配置确认这个测试**能失败** |
| `tests/relay-e2e.sh` | **9 条**（数 ok 调用点；中途失败会提前 exit 1） | **docker** + `python3`；没有 docker 时打印跳过并 **exit 77** | 真起 `caddy` 容器（host 网络）+ 假后端：渲染成功、`compose up` 成功、没密码 401、密码对 200、body 真的来自后端、`Host` 被改写成 `127.0.0.1:3080`、密码错 401、`compose down -v` 干净、容器撤掉 |
| `tests/http_sink.py` | — | `python3` | 测试零件：POST 的 body 追加写进文件（换行转义成 `\n`），只绑 127.0.0.1 |

⚠️ **跟 docker 有关的两件事**（2026-10-07 实测 + 当天修掉，细节在 hazards H8）：

- `run_tests.sh` 在**装了 docker 的机器上**，D 节会经 `relay.sh --dry-run` 真跑
  `docker run --rm caddy:2.11.4 caddy hash-password / caddy version / caddy validate`
  （一轮十几次容器启动；镜像不在本地会去拉一次，约 50MB）
  —— 所以它的文件头现在写的是"**不联网、不碰真 `$HOME`**"，另起一段声明 D 节会碰 docker
  （此前写"不碰 docker"，那句只在"机器上没有 docker"时成立）；
- 两个 docker 脚本**没有 docker 时打印"跳过"并 `exit 77`**（跳过码，不是通过）。
  此前是 `exit 0` —— 放进 CI / `&&` 链里空跑也算绿，属于假绿。

`run_tests.sh` 的 **K / L / M 三节（2026-10-07 加，共 93 条）**：

- **K（token 重定向）**：Caddyfile 两份模板都必须有 `path /` + `not query token=*` +
  `not header Cookie *dsh-auth-*` + `{{BROKER_PORT}}` + `@go`；`relay.sh` 里的
  `{{BROKER_PORT}}` 替换与 `--broker-port`；`harness` 函数在 **bash 和 zsh 两份**里
  各用假 `npx` 抓一次 token（写文件 → 退出时删掉，抓的是行首那个不是 LAN 那个）；
  **broker 起真进程**（python3）验 302/404/405/503 与"只绑回环"。
- **L（二维码）**：`dsh-qr` 的矩阵 sha256 与独立实现（npm 那份 JS）对过账的向量、
  中文/emoji 能编、太长必须报错、终端半块画、PNG 头与尺寸、SVG 文本。
- **M（`server`）**：假 ssh/scp/curl + 临时 unit 目录，验"四类自检失败都给指引"、
  `--dry-run` 一个字节不写、`--yes` 全参跑通（部署命令拼装 / 回写 conf / 装两个单元 /
  打印地址）、**部署失败必须非 0**（H20 的回归）、`dsh-remote-server` 薄封装等价。

`run_tests.sh` 的 I 节（55 条）是 2026-10-04 那次修复的回归测试，五个场景：
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
**"网络真断"时 ServerAlive 那条重连路、重启机器后服务会不会自己起来**（linger 已开、单元已
`enable`，但没重启过）、hook 桥真的会触发。

`run_tests.sh` 的 **J 节（69 条，2026-10-07 加）** 守的是常驻隧道：单元渲染里
`Restart=always` / `RestartSec` / `ExitOnForwardFailure` / 三个 `ServerAlive*` /
journald / `WantedBy` / `BatchMode` / 端口与 identity 替换；`StartLimitIntervalSec`
**在 `[Unit]` 段**（写 `[Service]` 会被 systemd 忽略 —— 真被忽略过一次）；
`systemd-analyze verify` 没有 `Unknown key`；`daemon-reload` + `enable --now` 的调用；
重复 install 幂等（内容不变不备份、不 restart）、改配置后内容变化 + `restart`；
旧 tmux 会话被 `kill-session`（`--keep-tmux` 时不杀）；用户管理器不可用时
**在碰旧隧道之前就停手且一个字节都不写**；`tunnel-status` 的漂移检测与旧会话点名；
`--probe` 只发只读命令；卸载 `disable --now` + 删文件。
它**全程用 `DSH_REMOTE_UNIT_DIR` 指向临时目录、`systemctl`/`tmux` 都是桩**，
跑完还要比一次真 `~/.config/systemd/user` 的指纹（真 tmux 上可能正跑着生产隧道）。

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
| `CADDY_IMAGE` | relay.sh、两个 docker 测试 | Caddy 镜像，**默认钉住的 `caddy:2.11.4`**（换版本用环境变量覆盖；别用浮动 tag，hazards H13） |
| `AUTOSSH_GATETIME` | dsh-remote tunnel | 用 autossh 时置 0（第一次连不上也继续重试） |
| `DSH_REMOTE_UNIT_DIR` | dsh-remote | systemd 单元落点，默认 `${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user`（测试用来钉到临时目录） |
| `DSH_REMOTE_SYSTEMCTL` | dsh-remote | 换 `systemctl`（默认 `systemctl`，调用时永远带 `--user`；测试用桩） |
| `DSH_REMOTE_TMUX` | dsh-remote | 换 `tmux`（默认 `tmux`；只在检测/停旧会话时用 —— 测试用桩，**别拿真 tmux 试**） |
| `DSH_REMOTE_SSH` | dsh-remote | 换写进单元 `ExecStart` 的 ssh 绝对路径（默认 `command -v ssh`） |
| `DSH_REMOTE_TOKEN_FILE` | dsh-remote、broker | token 文件路径，默认 `$STATE_DIR/current-token.txt` |
| `DSH_REMOTE_PYTHON` | dsh-remote | 写进 broker 单元的 python3 绝对路径（默认 `command -v python3`） |
| `DSH_REMOTE_BROKER_PORT` | dsh-token-broker | broker 监听端口（默认 3081；一般由 `broker-install` 用 `--port` 传） |

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
| `~/.config/systemd/user/dsh-tunnel.service` | **常驻隧道单元**（`tunnel-install` 渲染；旁边可能留 `.bak-<时间戳>`）。由 systemd 自己读，**不在** `$WTOOL_PREFIX` 里 —— systemd 只认 `$XDG_CONFIG_HOME/systemd/user` |
| `~/.config/systemd/user/default.target.wants/dsh-tunnel.service` | `enable` 建的软链（`disable` 会撤） |
| `~/.config/systemd/user/dsh-token-broker.service` | **token broker 单元**（`broker-install` 渲染；同目录可能留 `.bak-<时间戳>`） |
| `$WTOOL_PREFIX/var/dsh-remote/current-token.txt` | **当前 token**（`harness` 函数写，broker 读；只存 token 一行，600，harness 退出即删） |
| `$WTOOL_PREFIX/var/dsh-remote/web-url.txt` | 带 token 的完整地址（`harness` 函数 / `dsh-remote serve` 都写这一份） |
| `$WTOOL_PREFIX/var/dsh-remote/phone-qr.png` / `.svg` | `server` 打出来的二维码图片（没装 `qrencode` 时用 `dsh-qr` 生成） |
| `~/.dsh/profiles/web/cordis.patch.yml` | **唯一**必须待在 `~/.dsh` 的东西（profile patch 只能放那儿），由 `notify-enable` 写 |

云上（`relay.sh` 装出来的）：`/opt/dsh-relay/`（脚本 + 两个模板 + `docker-compose.yml`
+ 渲染好的 `Caddyfile` + `Caddyfile.bak-*` + `logs/`）、一个叫 `dsh-relay` 的容器、
两个命名卷 `caddy-data` / `caddy-config`。宿主上**没有** caddy 包、没有 `caddy.service`。
