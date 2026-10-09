# journal —— 操作流水（tools/dsh-remote）

追加式：**新的记录加在文件末尾**，不改写历史条目。
每条只记"谁在哪一轮做了什么、怎么验证的、剩下什么"——
**决策走 `docs/adr/`、待办走 `BACKLOG.md`、现状走 `architecture.md`**，这里都不重复。

---

## 2026-09-20 / 初版（`13734e3`）

**做了什么**：`tools/dsh-remote` 从零落地：手机 → 云上 Caddy（HTTPS + basic auth）→
SSH 反向隧道 → 家里 `127.0.0.1:3080` 这条链路，外加 `dsh-notify` 推送和 hook 桥。
一个提交 18 个文件、2543 行（`git show --stat 13734e3`）：`bin/dsh-remote` 616 行、
`bin/dsh-notify` 236 行、`scripts/install.sh` 130 行、`cloud/relay.sh` 301 行、
两个 Caddyfile 模板 + `docker-compose.yml`、`tests/run_tests.sh` 475 行（当时）。

**怎么验证的**：提交信息与文件头只记了"能跑"；当时的测试规模见
`tests/run_tests.sh` 的文件头，没有留下独立的验证记录。

**遗留**：`scripts/install.sh` 的"源"写死在引擎内部布局上（见 2026-10-04 那条）；
真阿里云 / 真手机从未跑过。

---

## 2026-09-23 / 路径规范：中转软链挪窝（`7388984`）

**做了什么**：引擎把中转软链从 `~/.wtool/links/<项目>` 挪到
`~/.wtool/wtool-work-dir/links/<项目>`；跟着改 `env.zsh` / `env.bash` /
`scripts/install.sh` 各一行（`git show --stat 7388984`：3 文件 3 行）。

**怎么验证的**：当时只做了语法层面；**这次挪动正是 `tools/android_repack` 坏掉的
原因**（源写死旧布局 → 静默什么都没装），而本项目也埋着同一颗雷 —— 见下一条。

**遗留**：`install.sh` 仍然写死"引擎内部布局 + 字面量 `$HOME`"。

---

## 2026-10-04 / 修 `install.sh`："报成功却什么都没装"（`f8da57c`）

**做了什么**：源改用引擎契约变量 `WTOOL_PROJECT_DIR`（手跑按 `$0` 自推），
落点从 `WTOOL_HOME` / `WTOOL_PREFIX` 推，XDG 默认值也跟着 `WTOOL_HOME`；
"某条源找不到"改成只跳过那一条 + 说清去哪儿找 + 末尾交代跳过了几条，
**只有真要装才 `mkdir`**；`env.zsh`/`env.bash` 的兜底同改；
新增 `tests/run_tests.sh` **I 节**（53 条，五个场景）；新建本仓库的
`AGENTS.md` / `BACKLOG.md`，README 的相关段落重写
（`git show --stat f8da57c`：7 文件 +637/-42）。

**怎么验证的**（数字都来自 BACKLOG 与实测复跑）：

- `sh tests/run_tests.sh` → **179 通过 0 失败**（改前基线 126）；
- **反证**：拿改前的脚本跑同一份用例 → **148 通过 31 失败**；
- 跑完比对真 `$HOME` 指纹（`.zshrc` / `.bashrc` / `.config/dsh-remote` /
  `.local/state/dsh-remote`）**逐字不变**；
- `grep -F '$HOME/.wtool'` 在 `scripts/install.sh` / `env.zsh` / `env.bash` 里无输出。

**遗留**：真 `$HOME` 里那两条 2026-09-20 的老软链还在（要用户自己重跑一次
`wtool install` 才会纠正）；"源找不到要不要改成 `exit 1`"待决定。

---

## 2026-10-04 / `wtool.xml` 跟上引擎：删 `id=`、换 `<zshrc>`/`<bashrc>`（`b68e491`）

**做了什么**：删掉 `id="tools/dsh-remote"`（引擎硬报错，留着 `wtool install` 直接
exit 2、`install.sh` 根本没机会跑），旧标签 `<env src= shells=>` 换成
`<zshrc src="env.zsh"/>` + `<bashrc src="env.bash"/>`（`git show --stat b68e491`：
1 文件 4 行改）。

**怎么验证的**：`wtool validate tools/dsh-remote` 改前 `error: … id=… 已经取消`
（exit 1），改后 `ok: tools/dsh-remote`（exit 0、无告警）；随后上面那套
引擎端到端（全临时环境）跑通。

**遗留**：`terminal/tmux/wtool.xml` 有一模一样的两个问题（另一个仓库，没动）。

---

## 2026-10-05 / 文档核对（`bc5c797`）

**做了什么**：README / AGENTS 补"容器/真机安装规矩"，测试条数改成"以输出为准"，
把 `caddy-validate.sh` 的 3 条写清（`git show --stat bc5c797`：2 文件 +14/-3）。

**怎么验证的**：把条数从"写死的数字"改成"以跑出来的 PASS 行为准"——
本轮 2026-10-07 复跑确认 **179** 这个数字仍然对得上。

**遗留**：那时还没有 wsw 文档体系（没有 `architecture.md` / ADR / hazards / journal）。

---

## 2026-10-07 / 建立 wsw 文档体系（本轮）

**做了什么**（全部在 `tools/dsh-remote/` 内，只改这一个仓）：

- 新建 `architecture.md`：逐行核对 `bin/dsh-remote`（14 个子命令）、`bin/dsh-notify`
  （三种模式 + provider 表）、`scripts/install.sh`（契约变量与两种语义）、
  `cloud/relay.sh`（两种模式 + 7 步流程）、两个 Caddyfile、`docker-compose.yml`、
  `hooks/claude-hooks.json`、`env.*`、`wtool.xml`、四个测试文件，**只写现状**。
- 新建 `docs/adr/`：索引 + **ADR-001…011**（云上 Caddy+隧道、容器化、域名/IP 两种模式、
  basic auth、`dsh web` 只绑回环、hook 桥与"未证实"的记录方式、
  `install.sh` 的契约变量、Host/Origin 改写、配置不放 `~/.dsh`、
  推送恒 0 退出、`relay.sh` 的 stdout 约定）。
- 新建 `docs/hazards.md`：**H1…H12**（每条：现象 → 根因 → 修法 → 判据/复现 + 验证程度）。
- 新建 `journal.md`（本文）；更新 `BACKLOG.md`（把"仍未做/未验证"写全并标状态）、
  `AGENTS.md`（文档地图 + 交付方式 + 本项目硬规矩）、`README.md`（订正与代码不符处）。
- 全程**没有**跑 docker 测试、没有联网、没有碰云上、没有在真 `$HOME` 上装东西。

**怎么验证的（判据）**：

- `sh tests/run_tests.sh` → **179 通过 0 失败**（第一次；写文档期间又复跑一次同样 179/0）。
  逐节条数：A 10 / B 6 / C 20 / D 21 / E 41 / F 14 / G 8 / H 6 / I 53。
- `T=$(mktemp -d); DSH_REMOTE_HOME=$T sh bin/dsh-remote status` → 退出 0，
  输出里那行"推送 还没配（照 notify.conf.example 写 **~/.dsh/notify.conf**）"
  就是 hazards H9（代码里的过期提示）。
- `sh bin/dsh-remote help | tail -4` → 多打 `set -u` 和两行注释（hazards H10）。
- 用 shim 目录挡住 docker 跑两条 e2e：
  `PATH="$d" /bin/sh tests/caddy-validate.sh` → `没有 docker，跳过` / **rc 0**；
  `PATH="$d" /bin/sh tests/relay-e2e.sh` → `没有 docker，跳过（这条是人工跑的 e2e）` / **rc 0**
  —— 即 hazards H8 的"假绿"。
- `grep -Fn '$HOME/.wtool' scripts/install.sh env.zsh env.bash` → **无输出**。
- 只读确认（不是跑容器）：`docker images` 里 `caddy:2` 已在本地（两周前）、
  `docker ps -a` 里没有 `dsh-relay`、`cloud/` 里没有残留 `Caddyfile.dryrun`。

**两条要如实记账的事**：

1. `tests/run_tests.sh` 的文件头写着"不碰 docker"，但本机装了 docker，它的 D 节
   会经 `cloud/relay.sh --dry-run` 真跑 `docker run --rm caddy:2 caddy validate`
   —— 本轮因此实际调了 **10 次**（每轮 5 次：第 235/245/252/256/265 行；同一节里
   第 259/262 行那两次在参数校验就退出了）。**没有拉镜像**（镜像早就在本地）、
   **没有留下容器**。口径已按事实改进 README / AGENTS / architecture（hazards H8）。
   —— 这是"文档与代码不一致 → 改文档"的一例（代码没动）。
2. `check-hooks`（会真调一次模型）**本轮没有复跑**，钩子桥"未证实会触发"的现状
   照 2026-09-21 的结论记（`architecture.md` §9、hazards H3）。

**遗留（都在 `BACKLOG.md` 里，用户最关心的那几条）**：真阿里云 + 真手机的端到端
从未跑过；云端落地步骤（`relay.sh --domain/--ip`、安全组、备案）没做；
隧道常驻/断线重连缺实测（本机没 autossh、systemd 只生成不 enable）；
钩子桥未证实；`tests/relay-e2e.sh` / `caddy-validate.sh` 要 docker、只能人工跑；
三个代码小瑕疵（status 文案 / help 越界 / docker 测试假绿）待用户决定要不要改代码。

---

## 2026-10-07（第二轮）—— 修 U6 三个代码小瑕疵（用户批准"按建议改"）

**谁**：助手（用户在同一轮里还派了另外两件事：往 `harness/dsh-conf/AGENTS.md` 记阿里云服务器信息、
在真阿里云上把中继部署起来；那两件不记在这个仓的流水里）。

**改了什么**（全部在 `ds_dev`，`bin/` 与 `tests/` 与文档同一个提交）：

1. `bin/dsh-remote` 的 `status`：推送那行提示 `~/.dsh/notify.conf` → `$CONF_DIR/notify.conf`（H9）。
2. 两处 `usage()`（`bin/dsh-remote` / `bin/dsh-notify`）改成**算范围**：
   `awk 'NR == 1 { next } /^#/ { print; next } { exit }' "$0" | sed 's/^# \{0,1\}//'`（H10）。
3. `tests/caddy-validate.sh` / `tests/relay-e2e.sh`：没 docker 时 `exit 0` → **`exit 77`**（H8）。
4. `tests/run_tests.sh` 文件头"不碰 docker"改成事实（另起一段声明 D 节会真跑 `caddy validate`）。

**怎么验证的**：

- `sh tests/run_tests.sh` → **185 通过 0 失败**（比改前 +6 条，全是新加的回归断言；
  逐节 A 10 / B 6 / C 22 / D 21 / E 45 / F 14 / G 8 / H 6 / I 53）。
- `PATH=<shim，挡掉 docker>` `/bin/sh tests/caddy-validate.sh` → rc **77**；
  同法 `tests/relay-e2e.sh` → rc **77**（改前两个都是 rc 0）。
- `sh bin/dsh-remote help | tail -1` → `安全边界、威胁模型、为什么这么设计：见同目录 README.md。`
  （不再多打 `set -u`）；`sh bin/dsh-notify --help | tail -1` → `只依赖 curl；…"只发事件名"。`
  （"退出码永远是 0"那段完整了）。
- 真 `$HOME` 指纹断言（I 节最后一条）仍然是绿的。

**如实记账：第一版修法写错过一次**。`sed -n '2,/^[^#]/p' "$0" | sed -e '$d' …` 里
`^[^#]` 要求"有一个不是 # 的字符"，**空行不匹配** → 范围多吃一行正文，
`$d` 又把那行删掉、只剩空行 → `help` 末尾多一个空行。是同一轮新加的
"help 最后一行就是注释块末行"那条断言抓出来的（第一次跑 183 通过 2 失败）。
改用 awk 后 185 全绿；教训写进 hazards H10 的订正段（含"别用 `sed -n '2,/^[^#]/p'`"）。

**没做的**：D 节要不要显式挡 docker（仍留 U5）；`main` 没动、没有 push。

---

## 2026-10-07（第三轮）—— 中继第一次真装到阿里云（IP 模式）

**谁**：助手。用户在同一轮里派了三件事（① 修 U6 四个小瑕疵 → 提交 `7e85e1b`；
② 把服务器信息记进 `harness/dsh-conf/AGENTS.md` → 提交 `0406ddd`；③ 就是本条）。

**在哪台、按什么约束**：`ssh mindul@123.56.158.212`（Ubuntu 26.04、`sudo -n` 免密、
docker 有但**不在 docker 组**、**没有 compose 插件**、80 被 nginx 占着、8443 空着）。
用户三条硬约束照原话记在 `harness/dsh-conf/AGENTS.md`；本轮**只写 `/home/mindul/dsh-relay/**`、
只用 `sudo docker` 启停那个容器**，没碰 apt / `/etc` / nginx / 防火墙 / 安全组。

**做了什么（按时间顺序，含两次失败）**：

1. 本机用项目自己的渲染器出 Caddyfile：
   `sh cloud/relay.sh --ip 123.56.158.212 --port 8443 --password <20位> --dry-run`（本机镜像里 validate 通过）。
2. `scp` 到 `/home/mindul/dsh-relay/`，`sudo docker run -d --name dsh-relay --network=host … caddy:2`
   → **容器无限重启**：`unrecognized directive: basic_auth`。查出那台的 mirror 把 `caddy:2`
   兑成 **v2.4.6（4 年前）**；本机同一 tag 是 v2.11.4 —— 也就是说 `--dry-run` 的
   "本机验证通过"是**假的**。
3. 换成 `caddy:2.11.4` 再起 → 这次容器活了，但 `curl -sk https://127.0.0.1:8443/`
   还是失败：`openssl` 报 `tlsv1 alert internal error`。用 `-servername` 手动塞 SNI 就正常
   → 根因是**连 IP 不发 SNI**（RFC 6066），Caddy 选不出证书。也就是说 **IP 模式的模板
   设计上就跑不通**，此前只是从没真装过。
4. 改代码（同一个提交里）：`Caddyfile.ip` 全局块加 `default_sni {{IP}}`；镜像 tag 钉成
   `caddy:2.11.4`（relay.sh / compose / 两个测试脚本）+ relay.sh 加版本自检；
   relay.sh 加 `--no-compose` / `--dir` / `--docker-cmd` 用户空间模式；顺手把它的
   `--help` 也改成"打到注释块结束"（同 H10 那个坑）。ADR-012 + hazards H13 +
   architecture/README/BACKLOG 同步。
5. 把改完的 `cloud/` 传上去，**用项目自己的脚本重装**：
   `sh relay.sh --ip 123.56.158.212 --port 8443 --no-compose --dir /home/mindul/dsh-relay --docker-cmd 'sudo docker'`
   → 装成。容器 `dsh-relay`（`caddy:2.11.4`、`--restart unless-stopped`），
   脚本自检：`https 入口：401（basic auth 在挡着）✓`、`隧道出口：401 ✓`。
6. 家里在 tmux（会话 `dsh-tunnel`）起 `ssh -N -T -R 127.0.0.1:18080:127.0.0.1:3080`；
   云上 `127.0.0.1:18080` 开始听，经 Caddy 带密码访问回的是**家里 dsh web 的 401 原文**
   （`dsh web authentication required; reopen the URL printed by dsh web.`）。
7. 从家里打公网 8443 → **超时**。判据：① 用 `--interface eth1`（SO_BINDTODEVICE）
   绕开本机 Clash TUN 后，打 80 端口 0.03s 拿到 nginx 的 200，打 8443 是 40s 无连接；
   ② 同时在那台上 `ss -tn "( sport = :8443 or dport = :8443 )"` 连采 10 秒，**一条都没有**，
   Caddy 日志也没有新行 → 包没到机器。**结论：安全组没放行 8443**（用户自己去控制台点）。

**怎么验证的（判据汇总）**：

- 无 SNI 握手：`openssl s_client -connect 127.0.0.1:8443 </dev/null` →
  改之前 `alert internal error`，改之后拿到 `issuer=CN=Caddy Local Authority - ECC Intermediate`。
- 中继本身：不带密码 401 + `www-authenticate: Basic realm="restricted"`；密码错 401；
  密码对且隧道没起时 502（`dial tcp 127.0.0.1:18080: connect: connection refused`）。
- 打到家里：带密码时 body 是 `dsh web authentication required; …`（dsh web 的原文），
  另有 `via: 1.1 Caddy` + `cache-control: no-store` —— 与家里 `curl 127.0.0.1:3080/` 逐字一致。
- 本机测试：`sh tests/run_tests.sh` → **199 通过 0 失败**（比上一轮 +14：
  `default_sni`、钉住的 tag、`--no-compose` 的 dry-run 与静态断言等）。

**没做的**：安全组放行（不归助手）；真手机打开；`--domain` 模式；隧道常驻（现在只是 tmux，
本机没 autossh）；`ufw` 在那台到底是 active 还是没生效（非特权读不出来，如实记着）。

**如实记账**：`/home/mindul/dsh-relay/Caddyfile.bak-20261007-115442` 是第 5 步之前那份
（同密码、旧哈希），留着没删；试验用的 `Caddyfile.try-default-sni` / `watch8443.txt` 已删。

**补记（2026-10-07 12:03，同一轮）**：交出报告之前又测了一次公网入口 —— **通了**。
同一条命令、同一条路径（`curl -sk --interface eth1 -u dsh:<pw> https://123.56.158.212:8443/`）
连打 3 次都是 `connect≈0.02s → 401`，带密码拿到的 body 是**家里 dsh web 的 401 原文**；
11:52 那次是 40s 超时、服务器侧看不到任何入站连接。两次观测之间助手**没有动过安全组/防火墙**
（那是禁区），所以只能记到"**11:52 连不上、12:03 能连上**"这个事实，谁在中间改的没见证
（大概率是用户自己在控制台放行了 8443）。BACKLOG 那节的第 8/9 步、U1/U2 的状态已按此更新，
hazards H13 不受影响（它讲的是镜像 tag、无 SNI、没有 compose 三个坑）。
**还没验的**：真手机 + 带 token 的地址（token 只在用户浏览器里）；安全组规则原文。

---

## 2026-10-07（下午）U3 收尾：隧道常驻 + 断线重连实测（12:00–12:12）

**这一轮的起点**：用户 2026-10-07 拍板"加上吧"（U3）。做之前先只读侦察，
侦察出来的三条事实改写了原本的计划：

1. 云上 basic auth **用 `relay-password.txt` 里的密码过不去**（不带密码和带密码都是
   Caddy 的同一个 401、body 0 字节）。`Caddyfile` mtime 12:00:42、文件 mtime 11:47:05。
   **我先误判成"12:00 换过密码"**（依据是哈希不同）—— 错：bcrypt 每次 salt 不同，
   同一密码哈希也不同。见 hazards H17。
2. `remote.conf` 里 `cloud_user=root` 登不上（`Permission denied (publickey,password)`）；
   `identity=~/.ssh/id_rsa` **也没被云上授权**，能用的是 `~/.ssh/id_ed25519`
   （旧 tmux 隧道不带 `-i` 才碰巧一直能连）。见 hazards H16。
3. `systemctl --user` **根本连不上 bus**（`/run/user/1000` 不存在、`loginctl list-sessions`
   空）—— 用户提示里说的"systemd --user 可用"当时并不成立。见 hazards H15。

**做过的事（都留了判据）**：

- 12:01 `loginctl enable-linger mindul` → **不需要 sudo**、rc=0；
  logind 当场起 `user@1000.service`（active），`/run/user/1000/bus` 出现，
  `systemctl --user is-system-running` 从 `Failed to connect to bus` 变 `running`。
- 12:04 把仓库里的 `cloud/relay.sh` 同步上云（只差 H12→H13 两处注释）；
  12:05 用**显式密码**重渲染中继（`relay.sh --password <文件里的值> --no-compose …`），
  `sudo docker` 重建容器。**复验**：不带密码 401（Caddy 挡）；带密码 → **68 字节**
  `dsh web authentication required; reopen the URL printed by dsh web.`（反代到了家里）。
- 12:05 订正 `~/.config/dsh-remote/remote.conf`（两次改动各留了 `.bak-<时间戳>`）：
  `cloud_user=mindul`、`identity=~/.ssh/id_ed25519`、`public_url=https://123.56.158.212:8443`。
- 写代码：`tunnel-install` / `tunnel-uninstall` / `tunnel-status`（`systemd` 旧名字保留成
  `--no-enable` 同义词）；ssh 参数收进 `tunnel_conf` + `tunnel_argv` 一处；
  单元渲染 `Restart=always` / `RestartSec=3` / `StartLimitIntervalSec=0`（**[Unit] 段**，
  写 [Service] 里会被 systemd 忽略 —— 是 `systemd-analyze --user verify` 抓出来的）/
  journald / `BatchMode=yes`。测试加 J 节 69 条（单元落点、systemctl、tmux 全是桩）。
- 12:09:37 第一次真装：**停掉了旧 tmux 会话 `dsh-tunnel`**（它占着云上 18080）。
  结果 ssh 起不来：`Permission denied` —— 就是上面第 2 条那个 `id_rsa` 坑；
  它**每 3 秒重启一次**（35 秒 10 次，`NRestarts` 12），`StartLimitIntervalSec=0` 让它不放弃。
- 12:10:20 改完 identity 重装 → `active (running)`，本机 `ss -ltn` 没有 18080（正常）、
  云上 `ss -ltn` 看到 `127.0.0.1:18080`。
- 12:10:51 / 12:10:56 **两次 `kill -9 <MainPID>`**：
  `3199ms` / `3207ms` 拉起新进程，公网 `curl -sk --interface eth1 …:8443/` 恢复 401 用
  `3276ms` / `3305ms`（journal 里是 `Main process exited, code=killed, status=9/KILL`
  → `Scheduled restart job` → `Started`）。
- 12:11 **故意造端口冲突**：停服务 → 自己起一条占 18080 的 ssh → 起服务 →
  journal 里 `Error: remote port forwarding failed for listen port 18080`，
  12 秒 4 次重试；**杀掉占端口的那条 → 760ms 服务接上**，公网 401 恢复。
- 12:11:37 `tunnel-status --probe --interface eth1` 全绿（含云上 `ss` + `curl` 401 判据）。

**测试**：`sh tests/run_tests.sh` → **268 通过 0 失败**（A10/B6/C22/D27/E53/F14/G8/H6/I53/**J69**）。

**文档**：ADR-0013（常驻用 systemd --user + ssh 保活，不用 autossh、不在云上守）、
architecture §2/§3/§3.1/§10/§11/§12、hazards **H14/H15/H16/H17**、BACKLOG U3 ✅、
README §2/§3/§6/§7、本项目 AGENTS.md 条数与缺口。
`harness/dsh-conf/AGENTS.md` 的"阿里云那台"一节也在同一轮订正（id_ed25519 / linger /
密码会漂移）。

**没做的（如实记）**：真手机带 token 打开；"网络真断"（ServerAlive 那条路）的重连；
重启机器后服务会不会自己起来（linger 已开、单元已 enable，但没重启过机器）；
真 Let's Encrypt；安全组规则原文。

---

## 2026-10-07（下午，续）手机固定地址：token broker + `harness` 函数（ADR-0014）

**要解决**：`dsh web` 的 token 每个进程随机、只在内存里（查过 CLI 与源码：没有固定 token /
关鉴权的开关，也不落盘 —— hazards H22），家里一重启 harness，手机上带 token 的地址就作废。

**做了什么**（都在这条流水里，代码现状见 `architecture.md` §3.2）：

- `env.zsh` / `env.bash` 各加一个**逐字等价**的 `harness` 函数：包装
  `npx @deepseek-ai/dsh web "$@"`，把启动那行 `dsh web: http://…/?token=…` 的 token
  写进 `$STATE_DIR/current-token.txt`、完整 URL 写进 `web-url.txt`（都 600），
  并把 `public_url` 打出来；退出时删掉 token 文件。source 时 `unalias harness`
  （别名优先于函数，用户原来那条 alias 会盖住它）。
  测试里先用假 `npx` 跑通 bash/zsh 两份，再拿**真实例**验：token 抓对了。
- `bin/dsh-token-broker`（172 行，纯 python 标准库）：只绑 `127.0.0.1:3081`，
  `GET /`（不带 token）与 `/go` → 302 `/?token=<当前值>`；没 token / dsh web 没在听 → 503；
  别的一律 404/405。**不代理任何应用流量**。
- `bin/dsh-remote` 加 `token-broker` / `broker-install` / `broker-uninstall`；
  `tunnel_argv` 多一条 `-R 127.0.0.1:18081:127.0.0.1:3081`；`tunnel-status` 增 broker 段。
- 两份 Caddyfile 加 `@entry`（`path /` + `not query token=*` + `not header Cookie *dsh-auth-*`
  → broker）与 `@go`；`relay.sh` 加 `--broker-port`（默认 18081）/`{{BROKER_PORT}}`，
  自检多打一行 broker。

**怎么验的（判据）**：

- **本机同构 Caddy**：`sh cloud/relay.sh --ip 127.0.0.1 --port 9443 --tunnel-port 3090
  --broker-port 3082 --local-port 3090 --password testpw-e2e --no-compose --dir /tmp/e2e/relay
  --docker-cmd docker` 起真 `caddy:2.11.4` 容器（同一份模板渲染出来的配置），
  家里用 `harness` 函数起自己的实例（3090，独立 `DSH_HOME=/tmp/e2e/dsh`）+ 真 broker（3082）：
  - `curl -sk -u dsh:testpw-e2e -D - https://127.0.0.1:9443/` → **302**
    `location: /?token=flsx0…`、`server: dsh-token-broker`；
  - 跟随（新 cookie jar）→ `final=200 redirects=2` + `<title>DeepSeek Harness</title>`；
  - 带 cookie 再打 `/` → **200、0 次跳转**（证明 `not header Cookie` 那条真的防住了死循环）；
  - 带 token 直连（老用法）→ `303 ./` + `Set-Cookie: dsh-auth-…`；
  - `/go` → 302；把 token 文件挪走 → **503**（经 Caddy，body 是 broker 那句人话）。
- **换 token 后固定 URL 仍可用**（核心判据）：杀掉我的实例、用 `harness` 函数重启 →
  token `flsx0…` → `ibxqL…` → 同一固定 URL **302 指到新 token** → 跟随 → 200 + 标题；
  旧 token 直连 → **401**；**旧 cookie 仍然有效**（签名密钥存在 DSH_HOME 里，跨重启不变）。
- **真公网**（`curl -sk --interface eth1 -u dsh:<pw> https://123.56.158.212:8443/`）：
  不带 token → **302**（`server: dsh-token-broker`，真的穿过了云上 Caddy + 新隧道到家里；
  用临时占位 token 验的，验完删掉）；`/go` 同样 302；删掉 token 文件 → **503**；
  `/?token=…` 仍直连 dsh web（401 + 家里原文）。
- 家里两个单元：`dsh-token-broker.service` + `dsh-tunnel.service`（含两条 `-R`）都
  `active`/`enabled`；云上 `ss -ltn` 看到 `127.0.0.1:18081`，云上直接 `curl` 它 →
  **503**（broker 手里还没 token：用户那个实例是 10-05 起的，token 读不出来）。

**没做的**：拿**真 token** 从公网走一遍 302→200 —— 得等用户用新的 `harness` 函数重启一次
harness（不能动他正在用的那个进程）；真手机扫码。

**顺带修/记的坑**：H22（没有固定 token 开关、token 读不出来）、H17 的加强（`relay.sh`
现在自己写 `relay-password.txt`；`--password ""` 会静默走随机分支）。

---

## 2026-10-07（下午，续二）一条命令装好：`dsh-remote server` + 自绘二维码（ADR-0015）

**用户要的**：一条命令问清信息 → 说明要什么权限 + 给教程 → 自己部署 → 配账号密码 →
起 harness → 给链接/二维码 → 扫码就能用。

**做了什么**：`bin/dsh-remote` 加 `server`（`bin/dsh-remote-server` 是等价的薄封装）；
`bin/dsh-qr` 是自带的二维码实现（纯 python：字节模式、版本 1–40、纠错 L/M/Q/H、
8 种掩码按标准罚分挑；终端半块画 / 1 位灰度 PNG / SVG）；`relay.sh` 自己写密码文件、
`--dir` 不存在时先建目录；`scripts/install.sh` 把 `dsh-token-broker` 和
`dsh-remote-server` 也铺进 `$WTOOL_PREFIX/bin`。

**怎么验的**：

- `bin/dsh-qr`：跟 npm 自带 `qrcode-terminal` 里那份 Kazuhiko Arase 的 JS 实现**逐模块对账**
  （同一版本 + 同一掩码下矩阵逐字一致；向量进了 L 节）。对账过程抓出我自己两个 bug：
  ① 预留格式位时把 (8,6)/(6,8) 两个定位模块抹了；② 挑掩码时没把格式位画上去就打罚分。
  另外确认那份 JS 实现对**非 ASCII 是坏的**（`charCodeAt` 截 8 位），我们按 UTF-8 走
  （用"把 UTF-8 字节伪装成 latin-1 喂给它"的办法对上了账）。
- `server`：M 节 46 条离线用例（假 ssh/scp/curl）覆盖四类自检失败的指引、`--dry-run`
  一个字节不写、`--yes` 全参跑通、部署失败必须非 0、薄封装等价。
- **真机幂等跑通**（那台已经在跑的阿里云）：自检 → scp → `relay.sh`（重渲染 + 重启容器，
  rc=0）→ 回写 `remote.conf` → 两个单元 → 打印固定地址 + 二维码（PNG 落在
  `~/.local/state/dsh-remote/phone-qr.png`；解回来与终端矩阵逐位一致）。
  入口判据：不带密码 401；带密码不带 token 503（broker 还没 token）；
  带密码带 token 401 + 家里 dsh web 原文。
- **真机抓出两个 bug**（都修了 + 加了回归）：① 把"能免密 sudo"当成"能直接用 docker"，
  而那台 `mindul` 不在 docker 组 → 误报"daemon 没反应"（H18）；
  ② `ssh … | tee` 拿的是 tee 的退出码 → 云上 `relay.sh` rc=2 被吞、密码文件被截成 0
  字节而我以为成了（H20/H21）。修完重跑：`relay-password.txt` 601 字节、600、
  内容与 Caddyfile 一致。

**没做的**：从**一台全新机器**从零跑一遍（只验了"已装好之后的幂等重跑"）；
`--domain`（域名 + Let's Encrypt）没跑过；真手机扫码没验（要用户拿手机）。

**补记（2026-10-07 12:55，同一轮收尾）**：

- 上级反馈两条，其中一条是真 bug：`harness` 函数原来**退出时无条件**
  `rm -f current-token.txt` —— 如果有人在"已经有一个实例在跑"时误跑一次（什么都没抓到），
  会把**别人**写的 token 删掉，broker 又变 503。改成：抓取时写一个
  `.harness-wrote-token` 标记（内容 = 那一刻的 token），退出时 `cmp` 相等才删；
  **没抓到就什么都不动** + 打一行说明。K 节加了 3 条回归（366 通过 0 失败）。
- 另一条是"别误判"：`curl -L "https://<入口>/?token=…"` **不带 cookie jar** 会 303 打转，
  真浏览器有 cookie 不会 —— 写进 hazards H22 的补记（附"像浏览器那样"的两条命令）。
- **真公网完整链路终于验全了**：用户在跑的那个实例的 token 被写进
  `~/.local/state/dsh-remote/current-token.txt`（设计里的数据源）之后，
  `curl -skL --interface eth1 -u dsh:<pw> -c/-b jar https://123.56.158.212:8443/`
  → **302 → `/?token=6b15Sb…` → 303 + Set-Cookie → 200，body 34674 字节、
  `<title>DeepSeek Harness</title>`**；带 cookie 再打 `/` → 200、0 次跳转；
  `/go` → 302；老 token 地址照旧。U10 那条"没验的"到此闭合（真手机扫码仍没验）。

---

## 2026-10-07（下午，续三）用户实测两条反馈：二维码放大 + `passwd` 一条命令（ADR-0016）

**反馈 1（二维码太小）**：`phone-qr.png` 原来是 1 模块 1 像素，29 模块就 29px，手机得放大才认。
改了 `bin/dsh-qr`：加 `--scale N`（每模块几个像素）与 `--target-px`（默认 1024），
`--png/--svg` 时默认自动 `scale = ceil(1024/模块数)`、不做插值；SVG 的 width/height 同步；
`server` 用 `--border 4`（静默区 4 模块）。**实测**：重新生成的
`~/.local/state/dsh-remote/phone-qr.png` = **1036×1036（37 模块 × 28 px，1 位灰度）**，
SVG `width/height=1036`、`viewBox="0 0 37 37"`。测试 L 节 +5 条（尺寸/整数倍/≥1024/SVG/显式 scale）。

**反馈 2（改密码教程看不懂 —— 这是我们的缺陷）**：用户照 `relay-password.txt` 的三步走，
先被要 root、加 sudo 又被说"没有 docker compose"，而且那条命令是折行的，他只复制了半行。
- 新增 `dsh-remote passwd`（ADR-0016）：云上探 docker 用法 → `sudo docker run --rm
  caddy:2.11.4 caddy hash-password` 算哈希 → 远端脚本（`ssh … sh -s`）**只把 `basic_auth`
  里那一行的 bcrypt 换成新的**（awk 精确匹配；找不到就 exit 3，**不整份重渲染**）→
  `restart dsh-relay`（轮询到回 401，最多 20s）→ 只改 `relay-password.txt` 的 `PASSWORD=` 行
  （600）→ **从家里验"新密码 200/302、旧密码 401"** → 打印手机怎么用新密码。
- `relay.sh`：提示语改成 `mode_cmd()` **一行给全**（模式/端口/用户/--tunnel-port/--local-port/
  --broker-port/--allow-ip/--no-compose/--dir/--docker-cmd），**dry-run 也打成 `HINT-CMD: …`**；
  `relay-password.txt` 里的"三步"改成首选 `dsh-remote passwd` + 一行手工等价命令。
- **真机实测两次**（`DSH_REMOTE_IFACE=eth1`）：改成临时密码 → **新 302 ✓ / 旧 401 ✓**；
  再改回 `pELX…` → **新 302 ✓ / 旧 401 ✓**；改完固定地址跟随后 **200 + `<title>DeepSeek
  Harness</title>`**、带 token 老地址 303、带 cookie 的 `/` 200/0 跳转；临时密码现在 401。
  云上 `relay-password.txt` = 601 字节 / 600 / `PASSWORD=` 一行；Caddyfile 留了
  `Caddyfile.bak-20261007-131656`、`…-131709` 两个备份（改密码两次）。
- **踩到的坑（H23）**：dry-run 里那条 `HINT-CMD` 一开始是**空的** —— `mode_cmd()` 定义在
  文件后半段，而 dry-run 在前面就 exit 了（函数要执行到定义处才存在）。把定义挪到 `dk()`
  旁边就好了；测试正是抽这一行去复跑，所以第一次跑就抓出来了。
- 测试：D 节 +7（抽 `HINT-CMD` 复跑 `--dry-run`，验参数没掉、上游端口一致）、L 节 +5、
  **新 N 节 22**（passwd 正常路径 + docker 不可用 / 哈希算不出 / 密码带单引号 三条失败路径）。
  全量 **400 通过 0 失败**。

## 2026-10-07（下午，续）：dsh web 常驻化 + harness 复用 + 起来后重连隧道

- 用户要求：开机自动开会话、后续 `harness` 复用老会话、harness 起来后自动重连阿里云转发。
- 新增 `bin/dsh-web-run`、`dsh-remote serve-install|serve-status|serve-uninstall`；
  `harness` 改三步（复用 / 交给服务 / 回退前台）+ 逃生阀 `DSH_REMOTE_HARNESS_NO_REUSE`。
- **实测教训（H24）**：重连不能放 `ExecStartPost`（失败重试里也会跑 → 隧道每 30 秒被重启）；
  改到 `dsh-web-run` 抓 token 之后，并加 O 节回归守卫。
- 老 K 节 7 条用例被这次改动暴露：它们**碰巧**依赖"本机 3080 没人听"；夹具改到 3085 + 显式逃生阀。
- 测试 400 → **420 通过 0 失败**。真机验证：复用分支 rc=0 不起新进程；服务 enable 后在
  `activating` 等端口；活会话与隧道均未被打断（`NRestarts=0`）。

## 2026-10-09（cookie 判断挪进 broker）—— 用户手机实测的"固定地址 401"缺口（ADR-0018）

**谁**：助手（用户 2026-10-09 在手机上实测撞到并给出复现命令；方案由用户定，助手实现 + 真机复验）。
**背景**：上一轮收尾时写的是"固定地址这条链路已经验通"—— 那是因为**测的时候 jar 是干净的**。
用户手机上存着过期的 `dsh-auth-*` cookie，于是 `/` 被 Caddy 的
`not header Cookie *dsh-auth-*` 直接推给 `dsh web`，看到的是 401 原文而不是跳转。

**改了什么**（代码 + 文档在同一个提交里）：

1. `cloud/Caddyfile.ip` / `Caddyfile.domain`：`@entry` **删掉** `not header Cookie *dsh-auth-*`，
   只留 `path /` + `not query token=*`；注释里写清"为什么不能按 cookie 排"（Caddy 不验签）。
   顺手把"其余请求"那条注释里"带 cookie 的 /"去掉（它现在一定走 broker）。
2. `bin/dsh-token-broker`（172 → 386 行）：带 `dsh-auth-*` cookie 的 `GET /` →
   先探测（`GET` / 3s / 只看状态码）→ 2xx/3xx 就**把这一条首页代发**（响应原样、
   `Set-Cookie` 透传、body 上限 8MB）；401/403 → 302 补 token + `Set-Cookie` 清掉失效 cookie；
   连不上/超时/别的状态码 → 503。另加：`redirects_to_entry()` 这道防转圈闸、
   `--probe-timeout`（默认 3s）、启动行与每条判定的日志。
   `POST` 仍然 405、`/go` 仍然无条件 302、没有 token 文件仍然 503。
3. `tests/fake_dsh_web.py`（新，194 行）：假 `dsh web` 夹具 —— `?token=` 换 cookie、
   按 `dsh-auth-*` cookie 的**值**回 200 首页 / 401 / 303 回入口 / 500 / 拖过超时，
   `--log` 记每条请求。K 节用它把三条行为**离线**测出来。
4. K 节 38 → **55 条**：模板断言改成"**不许**有 `not header Cookie`"（针带缩进 ——
   注释里解释了"为什么不能写"，第一次就是被自己的注释误报红的）；
   broker 那截加了过期/有效/回环/500/超时/别家 cookie/没有 token 文件等 17 条。
5. 文档：ADR-**0018**（用户说的"ADR-0017"已被上一轮的 dsh web 常驻占用 → 顺延，
   并把上一轮漏在表外的 0017 行并回索引表）、hazards **H25**（这个缺口）与 **H26**
   （`passwd` 拒 `#`：只记现状 + 两条待决定，**没改行为**）、`architecture.md` §1/§2/§3.2/§6/§10、
   `BACKLOG.md`（U13 ✅ / U14 ⏸ / U15 ⏸）、`README.md`。

**本机验证**：

- `sh tests/run_tests.sh` → **437 通过 0 失败**（K 55 / O 20；上一轮 420）。
- `python3 -m py_compile bin/dsh-token-broker tests/fake_dsh_web.py` → 通过。
- 新 broker 先在**真 `dsh web`**（用户正在跑的那个实例，没重启）上试：
  有效 cookie（从真实例换来的）→ 200 / 34782 字节 / `<title>DeepSeek Harness</title>`；
  乱写 cookie → 302 + 清 cookie；带 token 的请求打 broker → 400（那条本来就该去 dsh web）。

**真机验证**（家里 → 公网，`curl -sk --interface eth1 -u dsh:<当前密码>`；用户指定的密码没换）：

| # | 判据 | 实测 |
|---|---|---|
| 1 | 过期/乱写 cookie：`/` → 302 → 200 + title | **302**（`set-cookie: dsh-auth-stale=; Max-Age=0`）→ 跟随 **200**、34782 B、`<title>DeepSeek Harness</title>` |
| 2 | 有效 cookie：`/` → 200、**0 次跳转** | **200 0**（broker 日志：`cookie 有效（探测 200）→ 代发首页 200（34782 字节）`） |
| 3 | 不带 cookie：`/` → 302 → 200 | **200**（2 跳）、34782 B |
| 4 | `/?token=…` → 200 | 第一跳 **303** `location: ./` + `set-cookie: dsh-auth-<authority>=…` → 跟随 **200** |
| 5 | `/go` 302；`/` 之外的路径不经 broker | `/go` **302**；`/index.html` **200**（34782 B）且 broker 日志 **28 → 28 行**（diff=0） |
| 6 | 测试全绿 | **437 / 0** |
| 7 | 语法检查 | `py_compile` 通过 |

- **链路逐步实测**（就是"为什么不会转圈"的证据）：
  ① 无 cookie `GET /` → broker **302** `/?token=6b15Sb…`；
  ② `GET /?token=6b15Sb…` → **dsh web 303** `./` + `set-cookie: dsh-auth-VPhEE…`（直连，不经 broker）；
  ③ 带那条 cookie `GET /` → broker 探测 200 → **代发 200、0 次跳转** → 循环终止。
- **密码**：重渲染时显式带当前密码；改完复验 `doublemindul@200w` → **302**、
  `doublemindul#300w` → **401**（旧的那个 `pELX…` 更早那轮已验过 401）。

**云上同步**（写只限 `~/dsh-relay/**` + `sudo docker`，全程没碰 nginx/80/443/安全组/apt/`/etc`）：

1. `~/dsh-relay/cloud` → 备份成 `cloud.bak-20261009-cookie`；`scp -r cloud/` 传新的模板与脚本；
2. 先在云上 `--dry-run` 渲染 + `caddy validate` → `Valid configuration`（无残留占位符）；
3. 真跑 `sh cloud/relay.sh --ip 123.56.158.212 --port 8443 --user dsh --password '<当前密码>'
   --tunnel-port 18080 --local-port 3080 --broker-port 18081 --no-compose
   --dir /home/mindul/dsh-relay --docker-cmd 'sudo docker'`
   → Caddyfile 备份 `Caddyfile.bak-20261009-134xxx`、容器 `dsh-relay` 重建（`Up`）、
   自检 **401 / 401 / broker 302** 全绿；
4. 家里 `systemctl --user restart dsh-token-broker.service`（**只重启 broker，绝不碰 `dsh web`**）。

**踩到的坑**：`check_not_contains "not header Cookie"` 被**模板注释**里的同一串文字误报
（注释正是在解释"为什么不能写这条"）；断言改成带两行缩进的针
（`printf '\t\tnot header Cookie'`）才对准真实指令。

**没验 / 风险**：真手机浏览器（仍是 curl 在验）；"上游回 500 / 探测超时"两条只在夹具上验；
首页那次会打到 `dsh web` 两次（探测 + 代发，多一次本地回环）。

## 2026-10-09（隧道防风暴 + 自愈件）—— 从"无限重试"改成"失败 10 次停下 + 每 5 分钟看一眼"（ADR-0019）

**谁**：用户 2026-10-09 说"改"；上一轮已在本机**手工**把三处加固 + 一个自愈件做上并演练过，
本轮的任务是把它**变成项目能力**（`tunnel-install` 渲染 + 卸载路径 + 测试 + 文档）。

**背景（2026-10-08 现场）**：对端持续掐连接 → `RestartSec=3` + `StartLimitIntervalSec=0`
（无限重试）自我维持成风暴，单元 `NRestarts` 累计 **1708**；而 `is-active` 一路回 `active`
（`Type=simple` 只看 fork），看起来"隧道是好的"。以后果最隐蔽的一条记进 hazards **H27**。

**改了什么**（代码 + 文档同一个提交）：

1. `bin/dsh-remote` 的 `unit_body` 加两个键、改一个默认值：
   `StartLimitIntervalSec=300`（`--start-limit-interval`）、`StartLimitBurst=10`
   （`--start-limit-burst`）、`RestartSec` 默认 **3 → 5**（`--restart-sec`）。
   不带参数就是加固后的值；`--restart-sec 3 --start-limit-interval 0 --no-watch`
   能整条退回旧行为（留给"复现 hazard"用）。
2. **自愈件（内部件）**：新增 `watch_script_body` / `watch_unit_body` / `watch_timer_body`
   三个渲染函数 + `lib_dir()` / `watch_*_file()` 落点函数；`tunnel-install` 顺手写
   `~/.local/lib/dsh-remote/tunnel-watch.sh`（0755）+ `dsh-tunnel-watch.service`（oneshot）
   + `dsh-tunnel-watch.timer`（`OnBootSec=2min` / `OnUnitActiveSec=5min` / `AccuracySec=30s`）
   并 `enable --now` 那个 timer；`--no-watch` 跳过、`--watch-sec` 改周期（<30s 直接拒）。
   `tunnel-uninstall` 里**先停 timer**（不停它过 5 分钟又把隧道拉起来）再撤三件、空目录 `rmdir`。
   按用户 2026-10-09 的规矩：**不进 `PATH`、没有子命令**，只在 install 输出、代码注释和
   `architecture.md` §3.1.1（标明"内部件"）里出现。
3. 测试 J 节 69 → **100 条**：三个键的默认值 / 可覆盖 / 不许落在 `[Service]` 段；
   自愈脚本落点与可执行与 `sh -n`、内容（主机/端口/`-p`/restart/logger）、
   service/timer 内容、timer 被 `enable --now`、**拿假端口真跑一遍渲染出来的脚本**
   （rc=1、调用了 restart、写了 journal）、`--no-watch` 不写、卸载撤三件。
   自愈脚本的落点也钉到 `DSH_REMOTE_LIB_DIR`（**不钉就会写到真 `~/.local/lib`**），
   并把这三个文件加进"真 `$HOME` 指纹"那两条断言。
4. 文档：**ADR-0019**、hazards **H27**、`architecture.md` §3.1（表格三行 + 单元现状 + 新
   §3.1.1 内部件）、§3 子命令表、§10/§11/§12、`BACKLOG.md` U16 ✅（U14/U15 两条待决定）、
   `README.md`（`RestartSec` 默认 5 + "一直失败会停下"；**不写内部件的文件与命令**）。

**验证**：

- 本机离线：`sh tests/run_tests.sh` → **468 通过 0 失败**（J 100 / K 55 / O 20）。
- **渲染产物 vs 线上单元逐键比对**（只读）：
  `dsh-remote tunnel-install --dry-run` 出来的 `StartLimitIntervalSec=300`、
  `StartLimitBurst=10`、`RestartSec=5`、`ExecStart=…` 与线上
  `~/.config/systemd/user/dsh-tunnel.service` **逐个相同**（线上是上一轮手工写的，
  只有注释措辞不同）；`systemd-analyze verify` 三个单元（隧道 + 自愈 service/timer）
  都不报 Unknown key。
- 线上状态复核（只读）：`StartLimitIntervalUSec=5min` / `StartLimitBurst=10` /
  `RestartUSec=5s` / `NRestarts=0`；`dsh-tunnel-watch.timer` `is-active=active`、
  `list-timers` 的 NEXT 在 5 分钟以内；13:39 那次真演练的两行 journal 还在。
- **没动生产隧道**：本轮**没有**再跑一次真演练，也**没有**在真机上重跑 `tunnel-install`
  —— 线上已经是想要的状态（上一轮手工做的），重跑只会白断一次手机链路。
  代价是线上那份 `tunnel-watch.sh` 仍是上一轮手写的版本（少一个 `-p <ssh_port>`），
  下次跑 `dsh-remote tunnel-install` 会把它换成项目渲染的版本（那时会 restart 一次隧道）。
- **踩到的小坑（诚实记一笔）**：助手在沙箱里手工跑渲染出来的自愈脚本时**只桩了 `ssh`、
  没桩 `logger`**，于是真 journal 里多了两行 `dsh-tunnel-watch`（13:49，端口 19999）——
  那次 `systemctl` 是桩、**没有真重启**（隧道 `ExecMainStartTimestamp` 仍是 13:39:12）。
  `run_tests.sh` 的 J 节把 `logger` 也桩掉了，所以跑测试不会写真 journal。

**没验 / 风险**：1708 那次风暴没有复现（只量了修完的状态）；"timer 在真机上自己触发并恢复"
仍是上一轮 13:39 那次的观察；自愈脚本用 `PATH` 里的 `ssh`（systemd oneshot 有正常 `PATH`）。
