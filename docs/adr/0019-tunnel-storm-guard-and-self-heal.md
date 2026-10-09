# ADR-0019：隧道"失败 10 次就停下" + 家里一个 5 分钟一次的自愈检查（不再无限重试）

- 状态：Accepted（2026-10-09）
- 相关：ADR-0013（隧道常驻用 systemd `--user` + ssh 自带保活）、ADR-0014/0018（固定地址那条链路）
- 取代：无（新增）。**收窄 ADR-0013 的一句**：那条把"谁来重启"整个交给 `Restart=always`
  **无限**重试（`StartLimitIntervalSec=0`）；本条给它加上限，并补一个"停下之后来看一眼"的自愈件。

## 背景（2026-10-08 现场：对端持续掐连接 → 自我维持成风暴）

`RestartSec=3` + `StartLimitIntervalSec=0`（= 无限重试）碰上"起来就被掐"的对端，
会变成一个**自我维持**的循环：ssh 起来 → 被掐 / 秒退 → 3 秒后 systemd 再拉起 → 再被掐……
现场记录的单元 `NRestarts` 累计到 **1708**（那一轮之后才停）。

三个代价，一个比一个隐蔽：

1. **每 3 秒锤一次对端** —— 云上留下大量 ssh/auth/连接日志，而且这正是"看起来像爆破"的流量
   （自己锤自己）；
2. **journald 被刷**：一天几万行，真出事时翻不到东西；
3. **"服务在跑"的假象**：`systemctl --user is-active dsh-tunnel.service` 回 **active**
   （`Type=simple` 只看 fork 成没成），手机那头却一次也没连上 —— 出问题时人会先去看
   `is-active` 然后得出"隧道好的、是手机的锅"。

## 决定

1. **`RestartSec` 默认 3 → 5**（`--restart-sec` 可覆盖）：给对端一点喘息，别 3 秒一锤。
2. **加失败上限**：`StartLimitIntervalSec=300` + `StartLimitBurst=10`（`--start-limit-interval`
   / `--start-limit-burst` 可覆盖）—— 300 秒内失败 10 次就**停下并标 failed**。
   这两个键**属于 `[Unit]`**（写 `[Service]` 里 systemd 只警告 `Unknown key name` 然后忽略；
   J 节有回归断言）。
3. **补一个自愈件**（内部件，§3.1.1）：`dsh-tunnel-watch.timer` 每 5 分钟跑一次
   `~/.local/lib/dsh-remote/tunnel-watch.sh` —— 上云做一次**只读**探测
   （`ss -ltn | grep -c '127.0.0.1:<remote_port>'`，`ConnectTimeout=8`）：
   - 回 `1`（口在听）→ 什么都不做，退出 0；
   - 不是 `1` → `systemctl --user restart dsh-tunnel.service` → `sleep 6` → 再探一次 →
     还是不行就**退出 1**（systemd 记一笔，`journalctl -t dsh-tunnel-watch` 看得到原因）。
   自测口：`WATCH_PORT=<假端口>`（拿一个没人听的端口跑一遍，应该 rc=1 并去重启一次）。
4. 装/卸都跟着隧道走：`tunnel-install` 顺手装它（`--no-watch` 跳过、`--watch-sec` 改周期），
   `tunnel-uninstall` 顺手撤它，**并且先停 timer 再停服务**（不然 timer 过 5 分钟又把隧道拉起来）。
   **它不进 `PATH`、没有子命令、不写进 `README.md`** —— 用户视角只有"隧道会自己回来"这一条。

## 为什么"停下"比"永远重试"好

无限重试只对**暂时性**故障有用（网络抖一下、对端重启一次）。对**持续性**拒绝
（云上端口被别的隧道占着、密钥被换、账号/IP 被限）它一点用没有，纯粹是自伤，
而且把问题藏起来。停下之后：状态是 `failed`（一眼看得出），日志只留 10 条
（翻得到原因），自愈件用**低频**探测继续尝试 —— 恢复能力和可观察性都在，
"每 3 秒锤一次"没有了。

## 为什么自愈**放家里**、不放云上

- **判据必须在云上取**："这个口还有没有人听"只有云上知道（家里 `ss` 看不到反向端口）。
- **动作必须在家里做**：重启隧道要私钥、要碰 systemd `--user` 单元、要看本地日志 ——
  云上要做这件事就得在家这套东西之外，再放一把能进家门的钥匙（`ssh` 回家 + 有 sudo 的账号）。
  这与 ADR-0001/0005 的方向相反（"家里主动连出去"是这套设计的根）。
- 折中就是现在这样：**家里每 5 分钟主动上云做一次只读探测**。成本是一条短 ssh（约百毫秒），
  不引入任何反向权限。

**为什么是 5 分钟**：这是"最坏多久恢复"和"拿 ssh 打对端的频率"之间的取舍 ——
5 分钟粒度对手机（人要拿起手机、打开页面）足够；再密就是拿 ssh 打对端，
反而回到"锤对端"的老问题上。`--watch-sec` 可调，但 `tunnel-install` 拦下了 <30s 的值。

## 否决方案

| 方案 | 为什么否 |
|---|---|
| ① 只靠 ssh 的 `ServerAlive*`（维持 `StartLimitIntervalSec=0`） | `ServerAlive` 治的是"连接僵着不退"；对"起来就秒退"（端口被占 / auth 失败）一点用没有 —— 那正是 1708 次那次的形态 |
| ② 云上放个守护进程，发现端口没了就 ssh 回家重启 | 在云上多放一把进家门的钥匙（见上）；而且云上看不出家里"为什么"退（可能用户正手起着一条） |
| ③ 云上上 fail2ban / 防火墙规则 | 方向反了：那是挡**别人**爆破的，这里是**自己**锤自己；上了它只会把自家的 ssh 一起挡掉 |
| ④ 云上 cron + `ssh` 回来重启 | 同 ②，还多一份要同步的配置 |
| ⑤ 把 `RestartSec` 调大（比如 60s）就算了 | 治不了"停下"：故障持续时它仍然是无限循环，只是慢一点；而且把正常恢复也拖慢到 60s |
| ⑥ 什么都不做（现状） | 2026-10-08 用户实测就是风暴；`is-active=active` 还会骗人 |

## 后果

- **好处**：不会再有"自我维持的风暴"；停下之后状态和日志都诚实（`failed` + 10 条原因）；
  恢复有两条粒度 —— 进程被杀 ~5 秒（`RestartSec`），持续失败 ≤5 分钟 + 6 秒（自愈件）。
- **代价**：多一个 timer + 一个脚本（都在 `tunnel-install` 里，`--no-watch` 可退）；
  `RestartSec` 3→5 让"进程被杀"那次恢复慢 2 秒（换来的是别 3 秒锤对端）。
- **有意的行为**：探测**失败也算失败**（`ssh` 连不上、超时 → `probe=ERR` → 重启一次隧道）。
  宁可多重启一次，也别让手机一直连不上；代价是家里断网时每 5 分钟白重启一次（无害，不打断
  已经在跑的会话 —— 隧道和 `dsh web` 是两件事）。
- **可回退**：`tunnel-install --restart-sec 3 --start-limit-interval 0 --no-watch`
  就退回 2026-10-09 之前那套（`StartLimitIntervalSec=0` = 无限重试）。

## 判据（可原地复现）

```sh
# ① 单元里三个键都在（默认值）
dsh-remote tunnel-install --dry-run | grep -E 'StartLimitIntervalSec|StartLimitBurst|RestartSec'
#    → StartLimitIntervalSec=300 / StartLimitBurst=10 / RestartSec=5

# ② 自愈件活着
systemctl --user list-timers dsh-tunnel-watch.timer     # NEXT 在 5 分钟以内
systemctl --user is-enabled dsh-tunnel-watch.timer      # enabled

# ③ 演练：拿一个没人听的端口跑一遍 → 非 0，且真的去重启了一次隧道
WATCH_PORT=19999 ~/.local/lib/dsh-remote/tunnel-watch.sh; echo $?     # → 1
journalctl -t dsh-tunnel-watch --since -5min                          # → "…不在听（probe='0'）→ 重启…"
systemctl --user show dsh-tunnel.service -p NRestarts                 # 隧道确实被重启过（时间戳/计数变了）

# ④ 风暴不再自我维持（反例怎么造：把上限去掉）
systemctl --user show dsh-tunnel.service -p StartLimitIntervalUSec -p StartLimitBurst
#    → 5min / 10（不再是 infinity / 0）
```
