# ADR-0023：手机上的"重置按钮"走云上 `/reset` → 家里 token broker，而不是直连 `dsh web`

- 状态：Accepted（2026-10-09，用户批准："要有强制重置按钮"）
- 相关：ADR-0022（`force-restart-dsh-remote` 本体与 `--restart-web` 例外）、
  ADR-0014（固定地址 token broker）、ADR-0018（cookie 判断挪进 broker）、
  ADR-0004（basic auth 在最外层）、ADR-0001（只有一条 Caddy 入口）
- 取代：无（新增）。**扩大一点 ADR-0014 的范围**：broker 从"只做 `/` 和 `/go` 的 302"
  变成"再加一条 `/reset`（一个确认页 + 一个 POST）"，但它**仍然只绑回环、
  仍然不代理任何应用流量**（SSE / WebSocket 照旧 Caddy 直连 `dsh web`）。

## 背景

ADR-0022 给了命令行一条兜底命令，但用户当时的处境是"人在外面、只有手机"。
所以要一个**手机上的按钮**。有三个候选位置：

1. **云上 Caddy 直接做**（比如 Caddy 的某个 handler 触发一个脚本）：云上够不着家里的
   systemd 单元，也拿不到家里的 SSH 私钥方向（ADR-0001 是"家里主动连出去"）。
2. **云上另起一个小服务**：多一个要装、要守、要同步的东西，还要给它一条能进家门的路。
3. **家里那个 token broker 顺手做**：它已经跑在家里那台机器上、只绑回环、
   已经有一条从云上通到它的隧道（`18081 → 3081`，ADR-0014），而且**就在同一个 bin/ 目录里**
   —— 命令本体伸手可及。

## 决定

### 1. Caddy 加第四条路由，**放在 basic auth 之后**

```
@reset path /reset
reverse_proxy @reset 127.0.0.1:{{BROKER_PORT}} { header_up Host 127.0.0.1:{{LOCAL_PORT}} }
```

和 `/go` 共用那条隧道与那个 broker 端口。这一段落**在站点块内部**（`{{IP}}:{{PORT}} { … }`），
所以 `basic_auth` 天然先过关 —— **没有加任何新的鉴权方式**。
`@reset` 必须排在兜底那条 `reverse_proxy 127.0.0.1:{{TUNNEL_PORT}}` **之前**
（P 节有回归断言：`basic_auth` 行号 < `@reset` 行号 < 兜底行号）。

### 2. broker 加两条：`GET /reset`（确认页）和 `POST /reset`（真跑）

- `GET /reset`：极简中文页面（无外部资源、无 JS），说明"会重置隧道/broker、
  **不会**打断当前会话"，一个"确认重置"按钮 → `POST /reset`；
  顺带把**上一次的结果**（每步 ✓/✗ + 判据命令）渲染在下面。
- `POST /reset`：让**家里**跑一遍 ADR-0022 的**安全档**，结果渲染成同一个页面。
  **逻辑不重写**：直接跑 `/bin/sh <同目录>/dsh-remote force-restart-dsh-remote --json`，
  把 JSON 行渲染成 HTML（`head` / `step` / `summary` 三种）。
- **云上永远不许 `--restart-web`**：broker 起子进程时带 `DSH_REMOTE_FROM_BROKER=1`，
  命令那边看到它就 `die`（"会把自己踢掉"）。页面里明确写：
  要重启 `dsh web` 请在机器上跑 `force-restart-dsh-remote --restart-web --yes`。

### 3. 安全边界（四道，都不新加鉴权方式）

| 闸 | 做法 | 挡什么 |
|---|---|---|
| 来源 | `/reset` 只认 `client_address` 是回环 | "万一有人把 broker 绑到别处"（broker 默认只绑 `127.0.0.1`，云上那条经 SSH 隧道进来，家里这侧看也是回环） |
| 认证 | 沿用 Caddy 的 `basic_auth` | 陌生人（**不新增** token/密码/新 header） |
| CSRF | `GET` 发一次性 nonce（`secrets.token_urlsafe(18)`，10 分钟过期、用一次即废），`POST` 必须带回来 | basic auth 挡不住的"带着浏览器缓存凭据的跨站表单" |
| 回显 | 页面只渲染 `detail`/`evidence`，**token 与密码从不进页面**；判据命令里的 token 写成占位符 `<状态文件里的 token>` | 截图/转发页面时泄密 |

所有 `/reset` 响应都带 `Cache-Control: no-store`（和 broker 其它响应一致）。

### 4. 异步：先把响应发出去，再去动隧道

POST 不能同步跑完再回响应 —— 安全档**第一步就是重启隧道**，而这条 HTTP 请求正走在
那条隧道上（Caddy → `18081` → 家里 `3081`）。所以 broker 把 run 起成
**detached 子进程**（`start_new_session=True`，`sleep <DSH_REMOTE_RESET_DELAY=2>` 之后才
`exec`），立刻回 `202` + "已开始（隧道会断几秒）"，页面带 10 秒自动刷新。
**实测**：POST 从公网回 202 只用了 **0.13 秒**，隧道随后才断。

**从手机触发时 broker 不重启自己**（`--from-broker`）：run 是 broker 的子进程
（同一个 cgroup），`systemctl --user restart dsh-token-broker.service` 会把正在写这份报告的
进程一起杀掉。而且"能答 `/reset` 的 broker 显然是活的"，跳过它没有风险。
**这条差异只在 `/reset` 这条路出现**，命令行那条仍然老老实实重启 broker。

### 5. 结果落哪

`$STATE_DIR/reset-last.jsonl`（JSON 行）、`reset-last.err`（stderr）、
`reset-run.pid`（pid + 起始时间，判"还在跑"）。它们**只是这次运行的输出**，
不是第二套状态（token 仍然只有 `current-token.txt` 一份）。
`reset_running()` 先看 jsonl 里有没有 `summary` 再看 pid：跑完的子进程可能还是个僵尸
（broker 不 `wait` 它），只看 pid 会永远显示"还在跑"（沙箱里真踩到过）。

## 理由

- **够得着**：要重启的单元在家里，broker 就在家里；云上做这件事需要另一把进家门的钥匙。
- **只有一份逻辑**：命令 + `--json` 被 `/reset` 直接复用；将来改安全档，
  命令行和手机按钮一起变（不会出现"手机上修法不一样"）。
- **链路已经在了**：`/go` 早就在用这条隧道和这个 broker，加一条路由的成本是 6 行 Caddyfile。
- **不动主链路**：带 token 的 `/`、会话界面、SSE、WebSocket 仍然 Caddy 直连 `dsh web`。

## 否决方案

| 方案 | 为什么否 |
|---|---|
| ① 把复位做成一个 cloud-init / 云上 cron 的接口 | 云上够不着家里 systemd；还要在云上放能进家门的东西（与 ADR-0001 反向） |
| ② 让 `/reset` 直连 `dsh web` 的某个接口 | `dsh web` 的界面等于这台机器的完全控制权（ADR-0005），给它加"重启自己"的入口 = 把 RCE 变成自杀开关；而且它没有这种接口 |
| ③ 同步跑完再回响应 | 第一步就重启隧道 → 响应永远发不出去，浏览器看到 502，用户以为没生效（然后连点几次 → 隧道反复重启） |
| ④ 加一个新的鉴权方式（token / IP 白名单 / 新 header） | 用户明确要求"**沿用现有 `basic_auth`，不加新的鉴权方式**"；多一种鉴权就多一处会漂移的东西 |
| ⑤ 不做 nonce（只靠 basic auth） | 跨站表单能带着浏览器缓存的 basic auth 凭据打进来 —— 一个恶意页面就能让家里隧道反复重启（H27 的方向）。nonce 只有从我们页面里才拿得到，成本 20 行 |
| ⑥ 从云上允许 `--restart-web` | 重启 `dsh web` 会换 token、掐断浏览器那条链路 —— 云上发起等于把自己踢掉，而且用户看不到结果 |

## 后果

- **好处**：手机上一个按钮能兜住 ADR-0022 的三类故障；输出与命令行逐字同源；
  没有新增鉴权方式、没有新增公网端口、没有新增云上服务。
- **代价**：broker 不再只是"302 小服务"（多了一个页面 + 一个 detached 子进程）；
  `/reset` 会**主动断掉隧道几秒**（这是它的目的，但要写清楚 —— 页面里写了）。
- **有意的行为**：`/reset` 从手机触发时 broker 不重启自己（上面 §4）；
  结果页面显示"上一次"，`GET /reset` 在任何时候都能看。
- **可回退**：撤掉 Caddyfile 里那 6 行 + broker 里那两条路由即可，
  命令行 `force-restart-dsh-remote` 不受影响（两者只共享命令本体）。

## 判据（可原地复现）

```sh
# ① 云上路由在，且在 basic auth 之后
curl -sk -o /dev/null -w '%{http_code}\n' https://<入口>:8443/reset            # → 401（Caddy 先挡）
curl -sk -u dsh:<密码> -o /dev/null -w '%{http_code}\n' https://<入口>:8443/reset   # → 200（确认页）

# ② 页面里没有密钥、带 no-store
curl -sk -u dsh:<密码> -D - https://<入口>:8443/reset | grep -i cache-control  # → no-store
curl -sk -u dsh:<密码> https://<入口>:8443/reset | grep -c "$(cat ~/.local/state/dsh-remote/current-token.txt)"  # → 0

# ③ 没 nonce / nonce 重放 → 403；带 nonce → 202（毫秒级，隧道随后才断）
curl -sk -u dsh:<密码> -o /dev/null -w '%{http_code}\n' -X POST https://<入口>:8443/reset   # → 403
#   带 nonce 的那条见 tests/run_tests.sh 的 P 节（先从 GET 页面里取出 nonce）

# ④ 结果（家里）
cat ~/.local/state/dsh-remote/reset-last.jsonl | head -3    # head + step 行
journalctl --user -u dsh-token-broker -n 20                 # "已开始重置（pid …）"
```
