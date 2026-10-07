# hazards —— tools/dsh-remote 踩过的坑与禁区

> **每条都有：现象 → 根因 → 修法 → 判据/复现命令**，并标注验证程度
> （"实测复现 N 次" / "本轮跑过" / "只读代码"）。
> 写不出复现命令的结论只能写成"我这次观察到 X、没定位到原因"，**不许写成规律**
> （`~/.dsh/AGENTS.md` §4.5）。
>
> **编号只增不改、不重排**；订正要显式写"以本条为准"，并点出原来的错话在哪。
> 这里只记这个项目的坑；工作区通用的坑在 `~/self/wtool/harness/docs/hazards.md`。

---

## H1. profile patch 必须写 `- insert:`；写 `- id:` 会静默失效

**现象**：`dsh-remote notify-enable` 说"已把 hooks 桥写进 …"，但钩子就是不工作。
boot 时只打印一行 `patch: entry "hooks-claude-code" not found`，然后什么都不发生；
`dsh --profile web --dump-config` 里也未必看得见那一段。

**根因**：profile 的 patch 层语义是"**按 id 覆盖已有的行** + `insert` 列表"。
直接写 `- id: hooks-claude-code` 会被当成"替换一个叫这个名字的**已有**条目"，
而它本来不存在 —— 于是静默无事发生。

**修法**：必须写成 `- insert:`，`id:` 缩进在它下面（`bin/dsh-remote` 的
`patch_block()` 生成的就是这个形状）；`notify-enable` 的幂等判断靠
`# >>> dsh-remote notify` / `# <<< dsh-remote notify` 这对标记注释，
`notify-disable` 用 `awk` 精确删这一段。

**判据 / 复现**：

```sh
dsh --profile web --dump-config | grep -A5 hooks-claude-code   # 要能打印出整段
sh tests/run_tests.sh -v | grep 'insert'                       # E 节断言"用 insert 插入（不是 id 覆盖）"
```

**验证程度**：上游实测踩过一次（README §4 原文）；本项目测试守着（E 节）。

---

## H2. 钩子里的 `--async` 不重定向 fd 就等于没异步

**现象**：`dsh-notify --hook --async` 明明 fork 到后台了，agent 还是被拖住，
像没加 `--async` 一样。

**根因**：后台子进程继承了 hook runner 的 stdout/stderr 管道；runner 要等管道
**EOF** 才继续，而管道还开在孙进程手里。

**修法**：子 shell 里三个 fd 全部重定向走再 `&`：

```sh
( push "$TITLE" "$BODY" >>"$LOG" 2>&1 ) </dev/null >>"$LOG" 2>&1 &
exit 0
```

**判据 / 复现**（`tests/run_tests.sh` C 节，真跑）：

```sh
printf '{"hook_event_name":"Stop","cwd":"/tmp"}' | dsh-notify --hook --async; echo $?
# 期望：立刻返回 0（测试断言 ≤2s），随后消息仍然到达本地接收端
```

**验证程度**：测试实测（"`--async` 立刻返回（≤2s）"+"消息最后还是到了"两条断言）。

---

## H3. 钩子桥"挂上了" ≠ "会触发"（到今天仍未证实）

**现象**：`notify-enable` 写了 patch、`dump-config` 里也有 `hooks-claude-code`，但：

- 把 `configPath` 故意指到一个**不存在**的文件，harness 不报任何错；
- 一次性 `dsh --profile headless --patch <同一个 insert 行>` 跑真实任务，
  `SessionStart` / `Stop` / `PreToolUse` **一个都没触发**（本地接收端一条没收到、
  `notify.log` 空的）；
- 正在跑的 web 实例十几轮也没写过一行日志。

**根因（假设，未坐实）**：profile 的 `dependencies` 为空 + 本机没有 `pnpm`
（2026-10-07 实测 `command -v pnpm` 仍然没有），插入的那一行**解析不到包**；
或者这类事件必须作为 bundle 的一部分（`dsh plugin add`）才算正式挂载。
**已排除**：插件能解析（`require.resolve` 通）；加载失败会大声报错
（故意插重名条目会 `duplicate loader entry id` 起不来）；它 inject 的两个服务
在 profile 里都有提供者；配置两种形状（`{"hooks":{…}}` 与扁平 `{"Stop":[…]}`）都试过。

**修法 / 复查**：`dsh-remote check-hooks` —— 一次性进程做对照实验（起本地接收端 →
渲染临时 patch → 跑一次 headless 任务 → 看有没有收到），**不动正在跑的会话**：

```sh
dsh-remote check-hooks    # 触发 → 0；没触发 → 1，并打印两条出路
```

两条出路（都要用户定）：A) `npm i -g pnpm && dsh plugin --profile web add
@deepseek-ai/dsh-hooks-claude-code`，然后**重启** `dsh web`（会打断会话）再复查；
B) 先不靠钩子，需要提醒时手动 `dsh-notify`。

**规矩**：在证实之前，**不许把"会话卡住会推手机"写成已有能力**（ADR-006）。

**验证程度**：2026-09-21 两轮实验实测（细节在 README §4 与 `architecture.md` §9）；
**本轮（2026-10-07）没有复跑** check-hooks（它会真调一次模型、几十秒，属于"会碰外部"的动作）。

---

## H4. `dsh web` 不许重启、不许暴露

**现象**：想改 harness 参数（加 `--trusted-host`）就得重启它 —— **会打断正在跑的会话**；
想把端口放出去就得绑 `0.0.0.0` —— 用户级规则里明确禁止（那个界面 = 这台机器的完全控制权）。

**根因 / 事实**：`dsh web` 默认只绑回环，自己也会拒绝 `0.0.0.0`；是不是有会话在跑，
从外面看不出来。

**修法**：

- 要远程访问 → 走隧道 + Caddy（ADR-001），**完全不碰 harness**；
- 要新地址 → `dsh-remote serve`：它先看端口，**已经有人在听就拒绝启动**
  （警告"别在会话里重启它"，并把上次记的带 token 地址打印出来），返回 1；
- 真要重启也是**用户自己**的事，助手不代跑。

**判据 / 复现**（只读代码，不需要真跑）：`bin/dsh-remote` 的 `cmd_serve`
开头那段端口检查与警告；`ss -ltn | grep ':3080'` 期望是 `127.0.0.1:3080`。

**验证程度**：代码事实 + 用户级规矩；本轮没有在真机上跑 `serve`（它可能起进程）。

---

## H5. `scripts/install.sh` 曾经"报成功却什么都没装"（`f8da57c`）

**现象**（2026-10-04 临时环境实测复现，改前的脚本）：

```
tools/dsh-remote: 警告：找不到 …/home/.wtool/wtool-work-dir/links/tools/dsh-remote/bin/dsh-remote（…）
tools/dsh-remote: 软链 …/xdg-conf/dsh-remote -> …/prefix/etc/dsh-remote
tools/dsh-remote: 布局：
…
（exit 0）
$ ls -l …/prefix/bin
total 0                                  ← 一条命令都没有
```

装完看起来和装好了一模一样（配置/日志软链都铺了、打了布局总结），
`wtool` 那边照样报 `install 完成`，敲 `dsh-remote` 是 command not found。

**根因**：源写死成引擎的内部布局
`$HOME/.wtool/wtool-work-dir/links/tools/dsh-remote`（`WORK_DIR_NAME`，而且用了
字面量 `$HOME`）：换 `WTOOL_HOME` 装（影子家/临时家/测试）或引擎再挪一次布局
就指丢，而检查是"源不存在就 `continue`" → 整轮静默跳过。

**修法**：见 ADR-007（源问 `WTOOL_PROJECT_DIR` 要、落点从 `WTOOL_HOME`/`WTOOL_PREFIX` 推、
某条源找不到只跳过那一条并说清去哪儿找、只有真要装才 `mkdir`）。

**判据 / 复现**：

```sh
sh tests/run_tests.sh                       # I 节 53 条，五个场景；本轮 179 通过 0 失败
grep -Fn '$HOME/.wtool' scripts/install.sh env.zsh env.bash   # 期望：无输出
```

反证（证明这 53 条不是摆设）：拿改前的脚本跑同一份用例 = **148 通过 31 失败**。

**验证程度**：2026-10-04 实测复现并修复（`f8da57c`）；**本轮 2026-10-07 复跑 179/0**。

---

## H6. Caddy 默认要占宿主 `:80` → 容器 restart 循环

**现象**：云上（或本机 e2e）容器起不来 / 反复重启，日志里
`listen tcp :80: bind: address already in use`。80 被别的服务占着、
或者大陆机器没备案根本用不了 80 时都会撞上。

**根因**：Caddy 默认为了 **http→https 跳转**额外监听 `:80`。我们手机收藏的是
https 地址，根本不需要这个跳转。

**修法**：两个模板都在全局段加 `auto_https disable_redirects`
（`cloud/Caddyfile.domain`、`cloud/Caddyfile.ip`）。

**判据 / 复现**：

```sh
grep -n 'auto_https disable_redirects' cloud/Caddyfile.domain cloud/Caddyfile.ip   # 两个模板各一行
```

要真复现"不加就起不来"得有 docker：`tests/relay-e2e.sh`（人工跑）就是写这条测试时
**当场抓到这个真 bug** 的。

**验证程度**：写 e2e 那次实测（README §4）；本轮的自动测试只到渲染层面，没起容器。

---

## H7. 云上是容器：没有 `caddy.service` 可以 `systemctl stop`

**现象**：手机丢了或想掐断入口，照 README §5.6 敲 `systemctl stop caddy` →
`Unit caddy.service not found`，而入口还开着。

**根因**：中继器是 `docker compose` 起的容器（ADR-002），宿主上**没装 caddy 包**。

**修法**：

```sh
docker compose -f /opt/dsh-relay/docker-compose.yml down      # 或 docker stop dsh-relay
```

要彻底断，再把安全组那个端口关掉。

**判据 / 复现**：`relay.sh` 结尾打印的就是 `docker compose … ps/logs/down` 三条命令；
`tests/run_tests.sh` E 节有断言守着 `relay.sh` 里不再出现 `apt-get install … caddy`。

**订正记录**：`README.md` §5.6 原来写的是 `systemctl stop caddy`（**过期的错话**），
2026-10-07 已改成 compose 命令 —— **以本条为准**。

**验证程度**：代码/测试静态事实（本轮没上云）。

---

## H8. 要 docker 的测试在没 docker 时**退出码 0**（假绿）；`run_tests.sh` 的"不碰 docker"也不成立

**现象（两个，都是 2026-10-07 实测）**：

1. `tests/caddy-validate.sh` 和 `tests/relay-e2e.sh` 在没有 docker 时打印一句"跳过"
   就 **exit 0** —— 放进 CI 或 `&&` 链里会被当成"通过"，其实一条都没测。
2. `tests/run_tests.sh` 文件头写着"**不联网、不碰 docker、不碰真 `$HOME`**"，
   但它的 D 节调 `cloud/relay.sh --dry-run`，而 `relay.sh` 在**本机有 docker 时**
   会真的跑一次 `docker run --rm caddy:2 caddy validate`。

**根因**：两处都把"这台机器有没有 docker"当成环境事实，但没有把
"没有 docker = 没测"变成失败码；`run_tests.sh` 的自我描述也只考虑了"通常没有 docker"。

**修法（本次只改了文档口径）**：

- README §6 / `AGENTS.md` / `architecture.md` §10 现在写的是：
  "`run_tests.sh` 不联网、不碰真 `$HOME`；但**装了 docker 的机器上**，
  D 节会经 `relay.sh --dry-run` 调一次 `docker run --rm caddy:2 caddy validate`
  （要求 `caddy:2` 镜像已在本地，否则会去拉）"；
- 两个 docker 测试的跑法写成"人工、要 docker"。
- **要不要**把这两个脚本改成"没 docker 就 `exit 77`（跳过码）"、或者让 D 节显式
  挡住 docker，是**代码行为改动** → 超出本次授权，记在 `BACKLOG.md` 里等用户拍。

**判据 / 复现**（安全：用 shim 目录挡住 docker，不碰真的 docker）：

```sh
d=$(mktemp -d)
for t in mktemp rm sed cat grep printf echo pwd dirname id cut; do ln -sf "$(command -v $t)" "$d/$t"; done
PATH="$d" /bin/sh tests/caddy-validate.sh; echo $?   # → 没有 docker，跳过 / 0
PATH="$d" /bin/sh tests/relay-e2e.sh;     echo $?   # → 没有 docker，跳过（这条是人工跑的 e2e）/ 0
rm -rf "$d"
```

⚠️ **不要在装了 docker 的机器上直接敲这两个脚本**（会起容器 / 拉镜像）。
本机 2026-10-07 的实测细节：`/usr/bin/docker` 存在、`caddy:2` 镜像**两周前已在本地**、
`run_tests.sh` 跑了两轮（每轮 D 节 5 次走到 dry-run 的渲染，第 259/262 行那两次
在参数校验就退出了）→ 一共 `docker run` 了 10 次，**没有拉镜像、没有留下容器**
（`docker ps -a` 里没有 `dsh-relay`、`cloud/` 里没有残留 `Caddyfile.dryrun`）。

**验证程度**：本轮实测（PATH shim 复现 + 只读的 `docker images` / `docker ps -a` 确认）。

**✅ 订正（2026-10-07，用户批准"按建议改" → 代码已改，以本段为准）**：

上面「现象 / 根因 / 修法」是当时的记录，**现在两句都不成立了**：

1. 两个 docker 脚本的"没 docker"分支已改成 **`exit 77`**（跳过码）：
   `tests/caddy-validate.sh`、`tests/relay-e2e.sh`。77 是 autotools 的老约定，
   放进 CI / `&&` 链里不会被当成通过。
2. `tests/run_tests.sh` 文件头已改成"**不联网、不碰真 `$HOME`**"，另起一段明说
   "**它会碰 docker**：装了 docker 时 D 节经 `relay.sh --dry-run` 真跑
   `docker run --rm caddy:2 caddy validate`"。D 节的行为**没变**（仍然是本机有 docker
   就会跑，没有就跳过校验），只是把话说明白了 —— 要不要让 D 节显式挡 docker，
   归 `BACKLOG.md` U5 里那条"要不要"继续待定。

**订正后的判据 / 复现**（同一条 shim，rc 从 0 变 77）：

```sh
d=$(mktemp -d)
for t in mktemp rm sed cat grep printf echo pwd dirname id cut awk; do ln -sf "$(command -v $t)" "$d/$t"; done
PATH="$d" /bin/sh tests/caddy-validate.sh; echo $?   # → 没有 docker，跳过 / 77（2026-10-07 实测）
PATH="$d" /bin/sh tests/relay-e2e.sh;     echo $?   # → 没有 docker，跳过 / 77（2026-10-07 实测）
rm -rf "$d"
```

**验证程度**：2026-10-07 实测 1 次（两个脚本都 rc=77）；`sh tests/run_tests.sh` → 185 通过 0 失败。

---

## H9. `dsh-remote status` 的"推送还没配"提示指向旧路径

**现象**：没配 `notify.conf` 时，`status` 打印：

```
推送       还没配（照 notify.conf.example 写 ~/.dsh/notify.conf）
```

而项目现在的落点是 `~/.config/dsh-remote/notify.conf`（ADR-009）。
照它写的文件没人读（只有 `dsh-remote migrate` 会去 `~/.dsh` 搬）。

**根因**：`bin/dsh-remote:121` 的提示字符串是初版的话，后来把配置从 `~/.dsh`
收拢到自己目录时**漏改了这句**。

**修法**：**代码改动**（把这句改成 `$CONF_DIR/notify.conf`）—— 超出本次文档任务的
授权范围，记在 `BACKLOG.md` 待用户决定。

**判据 / 复现**（本轮实测，只读）：

```sh
T=$(mktemp -d); DSH_REMOTE_HOME=$T sh bin/dsh-remote status | grep 推送; rm -rf "$T"
# 实测输出：推送       还没配（照 notify.conf.example 写 ~/.dsh/notify.conf）
```

**验证程度**：本轮实测 1 次。

**✅ 订正（2026-10-07，用户批准"按建议改" → 代码已改，以本段为准）**：
提示已改成 `$CONF_DIR/notify.conf`（即远端解析出来的落点，默认
`~/.config/dsh-remote/notify.conf`），不再写死 `~/.dsh/notify.conf`。

```sh
T=$(mktemp -d); DSH_REMOTE_HOME=$T sh bin/dsh-remote status | grep 推送; rm -rf "$T"
# 现在输出：推送       还没配（照 notify.conf.example 写 <$CONF_DIR>/notify.conf）
```

回归测试加在 `tests/run_tests.sh` E 节两条：提示里要出现 `$DSH_REMOTE_HOME/notify.conf`、
且**不许**再出现 `~/.dsh/notify.conf`。

---

## H10. `dsh-remote help` 的输出越界（多打 `set -u` 和两行注释）

**现象**：`dsh-remote help` 的用法列表后面跟着：

```
set -u

自己是谁：先解掉软链。~/.local/bin/dsh-remote 是软链，不解的话
```

**根因**：`usage()` 是 `sed -n '2,25p' "$0"`，而脚本头部注释块只到第 **21** 行，
第 23 行是 `set -u`、第 25 行是下一段注释的第一行。

**修法**：**代码改动**（把范围收成 `2,21p`，或在注释块末尾放一个结束标记）——
超出本次授权，记在 `BACKLOG.md` 待用户决定。

**判据 / 复现**（本轮实测）：

```sh
sh bin/dsh-remote help | tail -4
```

同类小瑕疵：`dsh-notify --help` 打的是 `sed -n '2,20p'`，把"退出码永远是 0"那段的
后半句截断了（**不越界**，但少两行说明）。

**验证程度**：本轮实测 1 次。

**✅ 订正（2026-10-07，用户批准"按建议改" → 代码已改，以本段为准）**：

两处 `usage()` 都改成**算范围**，不再写死行号：

```sh
awk 'NR == 1 { next } /^#/ { print; next } { exit }' "$0" | sed 's/^# \{0,1\}//'
```

跳过 shebang，从第 2 行起**连着**以 `#` 开头的都打，碰到第一条正文就停。
`dsh-remote help` 现在正好停在注释块末行（`安全边界、威胁模型、…见同目录 README.md。`），
`dsh-notify --help` 现在带到"退出码永远是 0"那段的末句（`失败只写一行到 …notify.log。`）。

⚠️ **订正过程中踩到的新坑（同一条 H10 的补记，别重犯）**：第一版修法写成
`sed -n '2,/^[^#]/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'`，**是错的** ——
`^[^#]` 要求"有一个不是 `#` 的字符"，**空行一个字符都没有、不匹配**，于是范围多吃了
一行正文（`set -u`），`$d` 又把 `set -u` 删掉、只留下那个空行 → help 末尾多一个空行。
是同一轮新加的断言（"help 最后一行就是注释块末行"）把它抓出来的。
**判据**：`sh bin/dsh-remote help | tail -1` 必须直接是注释块末行，不能是空行。

回归测试（`tests/run_tests.sh`，4 条）：
C 节 `dsh-notify --help` 要含"失败只写一行到"、且不含 `set -u`；
E 节 `dsh-remote help` 不含 `set -u`、且 `tail -1` 就是注释块末行。

---

## H11. SSH 隧道 / 安全组 / 证书的已知限制（有"未验证"的，别当成已验证）

**代码事实（只读代码，2026-10-07）**：

- 隧道是**前台**循环：`dsh-remote tunnel` 断了自动重连（`retry_seconds` 默认 10s），
  **没有指数退避、没有 daemon 化**。
- `dsh-remote systemd` **只生成** `~/.config/systemd/user/dsh-remote-tunnel.service`
  （`Restart=always`、`RestartSec=10`），**不 enable、不 start**；要常驻得自己
  `systemctl --user enable --now dsh-remote-tunnel`（可选 `loginctl enable-linger $USER`）。
- `autossh` 是**可选**的：PATH 里有它且配置 `autossh != off` 才用
  （`AUTOSSH_GATETIME=0 autossh -M 0`），否则裸 `ssh`。
  **本机 2026-10-07 实测没有 autossh**（`command -v autossh` 无输出）。
- `-o ExitOnForwardFailure=yes`：云上 18080 被占时**直接失败退出**（然后进重连循环），
  不会"假装连着"。
- `ServerAliveInterval=30` + `ServerAliveCountMax=3`：对端静默死亡最多约 **90s**
  才被发现。
- 安全组只放 **22**（限家里出口 IP）+ **443/8443**；**18080 和 3080 绝对不放**（ADR-005）。
- 建议给隧道专用一把钥匙，并在云上 `authorized_keys` 里限制成只能转发
  （`remote.conf.example` 里有原样）：
  `restrict,port-forwarding,permitlisten="127.0.0.1:18080" ssh-ed25519 AAAA… dsh-remote`。
- `--allow-ip` 是按**出口 IP** 挡的：家里出口 IP 一变就会 403，得重跑 `relay.sh`。
- 证书：域名模式 Let's Encrypt（状态在 `caddy-data` 卷里，自动续期）；
  IP 模式 `tls internal` 自签，浏览器第一次要点一次警告；
  大陆机器的 80/443 要**备案**。

**未验证（不许当成已验证）**：真阿里云上的安全组/防火墙、真实 ACME 签发与续期、
手机浏览器上的实际体验、**隧道断线重连的真实时长**。
README §6 和 `BACKLOG.md` 都写着"没有自动测"。

**判据 / 复现**：

```sh
command -v autossh                       # 本轮实测：无输出（没装）
sh bin/dsh-remote systemd                # 只写单元文件；本轮没跑（会在真 $HOME 写文件）
systemctl --user is-enabled dsh-remote-tunnel   # 生成之后期望还是 disabled
```

**验证程度**：代码事实（本轮只读核对）；`autossh` 缺失是本轮实测；
真机重连时长**从未测过**。

---

## H12. 禁区清单（做任何事之前先过一遍）

| 禁区 | 为什么 |
|---|---|
| 助手自行 `wtool install tools/dsh-remote`（真机安装） | 用户级规矩：wtool 项目只在容器/影子家装；真机安装要用户明确同意 |
| 在真 `$HOME` 上跑 `scripts/install.sh` 或测试 | 会往真家目录铺软链/覆盖文件；测试一律用临时 `HOME`/`WTOOL_HOME`/`WTOOL_PREFIX`/`DSH_HOME`/`XDG_*` |
| 重启 `dsh web`、改它的绑定 / 加 `--trusted-host` | 打断正在跑的会话；绑 `0.0.0.0` = 把 RCE 挂公网（ADR-005、H4） |
| 碰云上任何东西（`relay.sh` 真跑、改安全组、动容器） | 云上操作要用户同意；`relay.sh` 在云上要 **root + docker** |
| `git push`（任何 remote）、动 `main`、`reset --hard` | 工作区通用硬规矩；改动只提交到 `ds_dev` |
| 往仓库里塞证书 / 密码 / 日志 / 二进制 | 仓库里只有文本（`git ls-files` 可验） |

**判据（怎么证明没碰真 `$HOME`）**：`tests/run_tests.sh` I 节末尾比对
`.zshrc` / `.bashrc` / `.config/dsh-remote` / `.local/state/dsh-remote` 的指纹
（软链比 `readlink`+`stat -c %Y`，实体比 `%F|%s|%Y`），要求**逐字不变**。
本轮跑了两轮 179 条，两条都是"真 `$HOME` 的指纹跑完逐字不变"。
