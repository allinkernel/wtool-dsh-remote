# ADR-0022：`force-restart-dsh-remote` —— 一键兜底，以及"绝不重启 `dsh web`"的唯一例外

- 状态：Accepted（2026-10-09，用户批准："要有强制重置按钮"）
- 相关：ADR-0019（隧道失败 10 次就停下 + 自愈件）、ADR-0014/0018（固定地址那条链路）、
  hazards H22（token 读不出来）、H27（隧道风暴）、H29（手工实例导致 token 抓不到）
- **限定 ADR-0005**：那条写的是"绝不重启 `dsh web`"。本条**默认档一个字都不改它**
  （安全档绝不碰 `dsh web`），只给出一个**用户显式批准、必须同时满足三个条件**的例外
  （`--restart-web --yes`）。ADR-0005 的正文与文件名不动（Accepted 不改），冲突之处以本条为准。
- 取代：无（新增）。

## 背景：2026-10-09 一天里实测到的三类故障

用户手机上看到的都是"连不上"，但根因是三个不同的东西，而且**没有一个会自己好**：

| # | 现场判据（当天实测） | 为什么不会自己恢复 |
|---|---|---|
| ① 隧道死 | `systemctl --user show -p NRestarts --value dsh-tunnel.service` = **10**、`is-active` = **failed** | 云上僵尸会话占着 `18080/18081` → 家里隧道每次起来就被掐 → ADR-0019 的 `StartLimitBurst=10` **按设计停下**、标 failed。自愈 timer 每 5 分钟才看一眼；用户不想等的时候没有任何一条命令能"立刻重来一次" |
| ② token 过期（H22） | `current-token.txt` **43 字节**，但拿它打 `http://127.0.0.1:3080/?token=…` 回 **401** | `dsh web` 是**手工**起的（`npx … --port 3080`），token 只在它内存里；状态文件里那份是**上一个实例**的。不重启 `dsh web` 拿不到新 token，而重启它就是"打断会话" —— 用户当时没有第三条路 |
| ③ 服务被占 | `dsh-web.service` `is-active` = **activating**、`NRestarts` = **108**（后来 124/143 还在涨） | 手工实例占着 3080，`dsh-web-run` 按设计 **exit 1** 不抢端口，systemd 每 30 秒重试一次。看起来像"服务卡住"，实际上是在**正确**地等 |

①②③ 的共同点：**每一件都需要有人在家里那台机器上敲几条命令**，而用户当时在手机上。

## 决定

### 1. 加一条用户可见命令 `force-restart-dsh-remote`（薄封装 + 子命令）

`bin/dsh-force-restart-dsh-remote` 是薄封装（照 `bin/dsh-remote-server` 的样子：
`sleep 0`、解软链、`exec … dsh-remote force-restart-dsh-remote "$@"`），
真正干活的是 `bin/dsh-remote` 里的 `cmd_force_restart`。**只有一份逻辑**：
手机上的 `/reset`（ADR-0023）也调它，不另写一套。

### 2. 默认是**安全档**：绝不碰 `dsh web`

按顺序做六步，每步两行（`状态 + 原因` / `判据 <可复现命令>`），最后 3–5 行结论：

1. `systemctl --user reset-failed dsh-tunnel.service` → 重启 `dsh-tunnel` + `dsh-token-broker`；
2. **云上只读**复验：`ss -ltn | grep -cE '127.0.0.1:(18080|18081)'` 必须是 **2**，
   否则明说"隧道没绑上"、点名"可能是云上僵尸会话占着、**要用户同意才能杀**"；
3. 本地 `local_port` 是谁在听：`dsh-web.service` 托管（MainPID 或 cgroup 判）还是**手工 PID**；
4. token 新鲜度：拿状态文件里的 token 真打一次本地 `dsh web` —— **401 就明说
   "token 过期，需要 `--restart-web` 才能拿到新的"**；2xx/3xx 再说"有效"（并跟随跳转确认 200）；
5. 公网固定地址：`401`（Caddy 的 basic auth 在挡）/ `302`（broker 在补 token）/
   `200`（带 cookie 一路通到底）/ `000`（连不上）四种含义都写进输出；
6. 结论 + 下一步（只给一条最该做的）。

**为什么 `reset-failed` 必须单独先做**：连续失败 10 次之后单元停在 `failed`，
`StartLimitBurst` 会把后面的 `restart` 一起挡掉 —— 这正是 ADR-0019 有意设计的
"停下、别再锤对端"。这条命令是**人来拍板**"现在重来一次"，所以由它清掉那个状态。

### 3. `--restart-web` 是例外，而且必须同时满足三个条件

```
① 显式给了 --restart-web              （默认档永远不会走到这里）
② 交互终端里敲 yes，**或者**非交互时显式给了 --yes
③ 不是云上 /reset 触发的（DSH_REMOTE_FROM_BROKER=1 直接 die）
```

动作**只有两个**，而且都不许扩大：

1. 用 `ss -ltnp` 找出占着 `local_port` 的**那一个** PID，**只对它** `kill -TERM`；
   - **不许** `pkill -f dsh`、不许杀别的进程、不许 `-9`（它不响应 TERM 就如实报 ✗ 并停手）；
   - 多一道闸：那个 PID 的 `/proc/<pid>/cmdline` 里**必须有 `dsh`**，否则**不杀**并打印它是什么
     （防"3080 上其实是别的开发服务器"这种误杀）。
2. 用 `systemctl --user start dsh-web.service` 起回来（**用服务起**，这样 `dsh-web-run`
   才会把新 token 抓进状态文件 —— 这才是修 stale token 的正路）。服务停在
   `activating/auto-restart` 时 `start` 是空操作（30 秒的计时器还挂着），这时改用 `restart`
   立刻起，并把这件事打印出来。然后最多等 30 秒轮询 `current-token.txt` / `web-url.txt`，
   报**新 token 的存在性（值不打印）**；最后复验本地 200 + 公网 200。

### 4. 输出契约：状态 + 原因 + 判据，别啰嗦

照 ADR-0020 的路子：每步 `[n/N] 标题 ✓/✗/! 实测到的状态与原因` + `判据 <一条能原地复现的命令>`。
`✓/✗/!` 三态：`ok` / `fail` / `warn`（"手工实例占着 3080"是 warn —— 它本身不是故障，
它是 token 会过期的**原因**）。退出码：有 `fail` 步就是 1，否则 0。
`--json` 时改成一行一条 JSON（`head` / `step` / `summary`），给手机页面渲染用。

## 理由

- **"重置"这件事是幂等的、可重复的**：重启隧道和 broker 不破坏任何持久状态
  （token 文件由 `dsh-web-run` 重写、单元由 systemd 管），所以敢做成一条命令、
  也敢做成手机上的一个按钮。
- **只有人能判断"现在能不能打断会话"**：所以默认档永远不碰 `dsh web`，
  例外必须由人显式给出。把判断权留在人手里，是这条命令唯一的安全边界。
- **判据命令要打出来**：用户/下一个助手在手机或另一台机器上时，能照着复现同一结论
  （这也是 hazards 的纪律：结论必须配可检验的判据）。

## 否决方案

| 方案 | 为什么否 |
|---|---|
| ① 默认档也顺手重启 `dsh web`（"反正都是修"） | 直接违背 ADR-0005 与用户级规则；它会打断正在跑的会话（**包括用户正在看的那个**）。修 token 是"需要"时才做的事，不是"重置"的默认动作 |
| ② 只做 `systemctl --user restart dsh-tunnel.service`（不加 `reset-failed`） | 连续失败 10 次后单元是 `failed`，`StartLimitBurst` 会挡住 restart —— 命令会"什么都没做成"却看起来跑了（H27 的正面用例） |
| ③ 用 `pkill -f dsh` 一把清掉 | 会杀掉别的东西（`dsh-notify` 的 hook、别的 dsh 进程、甚至调用者自己）；而且"只杀占着端口那一个"是可验证的，`pkill` 不是 |
| ④ 直接把 `dsh-web.service` 改成 `ExecStartPre` 里 `fuser -k 3080/tcp` 自动抢端口 | 那就变成"服务会自己打断用户的会话"——比 ① 更坏：无人值守也会发生。R 之前 `dsh-web-run` 特意**不抢**端口，是有意的（2026-10-07 实测教训） |
| ⑤ 云上放一条命令替用户重启 | 云上够不着家里的 systemd；而且重启 `dsh web` 会把云上这条链路自己掐断（见 ADR-0023） |
| ⑥ 什么都不做，让用户自己记住那几条命令 | 三类故障当天都发生了，而且用户当时在手机上（这正是这个项目存在的理由） |

## 后果

- **好处**：三类故障各有一条"一眼看得出修没修好"的路径；手机上有按钮（ADR-0023）；
  输出里带判据，下一步不用猜。
- **代价**：多一个用户可见命令（`README.md` 要跟上）；`--restart-web` 是一条真实的
  "会打断会话"的路（靠三个条件 + cmdline 闸 + 只 SIGTERM 一个 PID 收窄）。
- **有意的行为**：`--restart-web` **不**清理 3080 上"不像 dsh"的进程（宁可报错也不误杀）；
  新 token **只报存在性**、绝不打印值（token 是密钥）。
- **可回退**：不用它就行（它不改任何配置、不装任何单元）；`--restart-web` 是显式选项，
  默认档与之前"手工敲几条命令"完全等价。

## 判据（可原地复现）

```sh
# ① 命令在，且默认档不碰 dsh web
force-restart-dsh-remote --help | grep -c '绝不碰 dsh web'      # → 1
force-restart-dsh-remote | grep -c 'SIGTERM'                    # → 0（安全档不出现这个词）

# ② 安全档在一台真机器上跑一遍（会重启隧道 + broker，几秒）
force-restart-dsh-remote; echo $?                               # 全绿 → 0；有 ✗ → 1
#   每步都带判据行；结论里有 隧道/broker/云上/token/公网 五个状态

# ③ 隧道 failed 之后能靠它恢复（H27 的正面用例）
systemctl --user show -p NRestarts --value dsh-tunnel.service  # 之前：10 且 is-active=failed
force-restart-dsh-remote | head -3                             # reset-failed + restart
systemctl --user is-active dsh-tunnel.service                  # → active

# ④ --restart-web 的三个条件（少一个都不动）
force-restart-dsh-remote --restart-web </dev/null; echo $?     # → 1，且说"必须显式加 --yes"
DSH_REMOTE_FROM_BROKER=1 force-restart-dsh-remote --restart-web --yes; echo $?   # → 1，云上不许

# ⑤ 误杀闸：让别的进程占着 local_port，再跑 --restart-web --yes
#    → 输出"命令行里没有 dsh …**不杀**"，那个进程还活着
```
