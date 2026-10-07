# ADR-0013. 隧道常驻用 systemd `--user` 单元 + ssh 自带保活（不用 autossh，也不在云上守）

- 状态：Accepted（2026-10-07）
- 相关：ADR-0001（云上 Caddy + SSH 反向隧道）、ADR-0012（真机硬化）、
  `docs/hazards.md` H14 / H15 / H16、`architecture.md` §3.1、`BACKLOG.md` U3

## 背景

反向隧道（家里 → 云上）原来靠**一个一次性 tmux 会话**里的 `ssh -N -T -R …`：
在家里机器上手工起一次，**断了不会自己回来**，机器重启更不会。U3 的判据是
"断线重连的真实时长"，而当时连"常驻"都没有。

几个当时成立的事实：

- 家里这台（WSL2 + Ubuntu 26.04）**没有 autossh**（`command -v autossh` 无输出），
  云上那台也没有 —— 要用它就得装包，而"装包"在云上属于越界（用户三条硬约束：
  只在 `/home/mindul` 下操作 / 不做可能让服务器出故障的事 / 不做违法的事），
  在家里也属于"改系统"。
- 云上那台对我们是**只读**边界：唯一允许的特权动作是 `sudo docker` 启停中继容器。
  所以"在云上跑个守护进程看隧道"这条路直接排除。
- 反向隧道本身**由家里主动连出去**，云上不需要为它开任何端口（只在 `127.0.0.1`
  上有一个 `-R` 监听口）—— 这是 ADR-0001 的前提，不能为了"守护"把它破坏掉。
- 家里 `systemd --user` 能不能用，取决于**用户管理器在不在**：没有 logind 会话
  也没开 linger 时 `systemctl --user` 连 bus 都连不上（H15）。

## 决策

**1）常驻 = `~/.config/systemd/user/dsh-tunnel.service`，`enable --now`。**

- 单元名固定 `dsh-tunnel.service`；落点 `${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user`
  （systemd 自己只认这里，**不能**放进 `$WTOOL_PREFIX`）。
- `ExecStart` 是**一行绝对路径的 `ssh`**（不是 `dsh-remote tunnel` 那种前台循环）：
  `ssh -N -T -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=15
  -o ServerAliveCountMax=3 -o TCPKeepAlive=yes -o StrictHostKeyChecking=accept-new
  -p <port> [-i <identity>] -R 127.0.0.1:<rp>:127.0.0.1:<lp> <user>@<host>`。
  参数和前台 `dsh-remote tunnel` 由**同一个函数**（`tunnel_conf` + `tunnel_argv`）拼出来，
  只多一个 `BatchMode=yes`；`tunnel-status` 拿它做"配置漂移"对比。
- `Restart=always` + `RestartSec=3`（`--restart-sec` 可调）+ `StartLimitIntervalSec=0`
  （在 `[Unit]` 段）：**永远重试，不因短时间失败次数多被判 failed**。
- 日志 `StandardOutput=journal` / `StandardError=journal`，
  `journalctl --user -u dsh-tunnel.service` 一条命令看全。

**2）"谁来重启"分两层，各管一段：**

| 断成什么样 | 谁发现 | 期望恢复时间 |
|---|---|---|
| ssh 进程**退了** | systemd `Restart=always` | `RestartSec` + ssh 握手 |
| 网络断了但 ssh **僵着不退** | ssh 自己 `ServerAliveInterval=15 × ServerAliveCountMax=3` | ≤45s 被发现，再按上一行 |

**期望值**：≈ `RestartSec` 秒 + ~0.2s 握手。**实测**（2026-10-07，`kill -9`，
两次）3199ms / 3207ms 拉起进程、3276ms / 3305ms 公网恢复 —— 见 `journal.md`。
**只测了"进程被杀"**；"网络真断 → ServerAlive 踢死"这条路**没测过**。

**3）`tunnel-install` 的顺序（先探、再停、再装）：**

先探 `systemctl --user` 能不能用（不能就打印 `loginctl enable-linger` 的出路并退出，
**什么都不动**）→ 检测旧的一次性 tmux 会话（`tmux_session`，默认 `dsh-tunnel`）并
`kill-session`（不然两条隧道抢云上同一个端口，新的那条会无限重启，H14）→ 检测旧版
单元 `dsh-remote-tunnel.service`（有就 `disable --now`）→ 渲染落盘（内容不变就不动、
变了先备份）→ `daemon-reload` + `enable --now`；**内容变了且原本 active** 才补一次
`restart`（`enable --now` 不会重启已在跑的单元）→ 停 3 秒看 `NRestarts` 有没有涨，
涨了就把"端口被占 / 认证失败"和 journal 尾巴打出来。

**4）linger 不替用户开，只报状态。** 单元活着的前提是用户管理器活着：
`loginctl enable-linger <用户>`（本机实测**不需要 sudo**）。`tunnel-install` /
`tunnel-status` 打印 `Linger=`，但**不代跑** —— 那是"让服务在你没登录时也活着"的
一个明确开关，用户该知道它开没开。

## 理由

- **systemd 已经把"进程没了就拉起来"这件事做完了**，而且是我要的那一种：可配间隔、
  可无限重试、有 journal、有 `systemctl status`。再叠一层 autossh 是两套重启机制打架
  （autossh 自己会重连，systemd 看到的永远是"进程还活着"）。
- **`ServerAlive*` 必须是 ssh 自己的**：systemd 只能看见"进程退没退"，TCP 层半死不活
  （NAT 超时、对端静默丢包）时 ssh 会一直挂着，只有它能把这个连接判死。
- **不在云上守**：云上是只读边界；反向隧道由家里主动发起本来就是"不用在云上开端口"
  的设计；真要在云上守护，就得在云上装东西、写 unit、动 `/etc`，三条硬约束全踩。
- **不用 tmux 常驻**：没有开机自启，会话是人搓的；`tmux kill-server`、误关窗口、
  机器重启都会让它消失，而且"有没有在跑"要靠人 `tmux ls`。

## 否决

| 方案 | 为什么否 |
|---|---|
| autossh（家里 + 云上都没有） | 要装包（改系统）；它的 `-M` 监控口还得多开一个端口；systemd 已经能做同样的事 |
| 云上起守护/定时任务看隧道 | 云上是只读边界；要在云上装/写 unit/动 `/etc`；反向隧道本来不需要云上参与 |
| tmux 里跑 `dsh-remote tunnel` 前台循环 | 没有开机自启、没人重新拉起、状态靠人看；`retry_seconds`（10s）也比 `RestartSec=3` 慢 |
| 单元 `ExecStart` 直接调 `dsh-remote tunnel` | 那是**前台循环**：systemd 永远看不到"断线"，`Restart` 就没意义了；日志也会被循环里的 `say` 搅浑 |
| 在单元里运行时读 `remote.conf` | 单元要能在最小环境里起来（systemd 的环境变量和登录 shell 不一样）；改成"装的时候把值嵌进去"，代价是**改了配置要重装** —— 用 `tunnel-status` 的漂移检测兜住 |
| `After=network-online.target`（旧半成品里有） | 用户管理器里**没有**这个 target（那是系统级的），写了只是好看 |

## 后果 / 代价（要认）

- 改了 `remote.conf`（host / 用户 / 端口 / identity）**必须重跑 `tunnel-install`**，
  否则跑的还是旧参数。判据：`dsh-remote tunnel-status` 会逐字比 `ExecStart` 并提示。
- `StartLimitIntervalSec=0` = 认证失败/端口被占时**每 3 秒一次、永远试下去**
  （实测 35 秒 10 次）。好处是"环境一好就自己接上"（实测：抢占端口的进程一被杀，
  **760ms** 就接上了），坏处是日志会一直长；所以安装前的冲突检测（H14）是必需的。
- 跨"登录会话结束"和"开机"要 `loginctl enable-linger`；本机 2026-10-07 已开
  （**不需要 sudo**）。**"重启机器后是否自动恢复"没有实测过**（没人重启这台机器）。
- 单元文件是**生成物**：手改会被下次 `tunnel-install` 覆盖（改之前会留 `.bak-<时间戳>`）。
