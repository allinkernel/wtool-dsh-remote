# ADR-0018：把"cookie 还有效吗"的判断挪进家里的 broker（只代发那一条 `GET /`）

- 状态：Accepted（2026-10-09）
- 相关：ADR-0014（固定手机入口 + token broker）、ADR-0008（改写 Host/Origin 而不是 `--trusted-host`）、ADR-0001（Caddy + 反向隧道）、ADR-0005（`dsh web` 只绑回环）
- 取代：无（新增）。**收窄 ADR-0014 的一句结论**：那条说"两条 `not` 缺一不可"，
  其中 `not header Cookie *dsh-auth-*` 已被本条删掉（它治好了死循环，代价是让
  "带着过期 cookie 的浏览器"永远进不来）；`not query token=*` 仍然必须。

## 背景（用户 2026-10-09 在手机上实测到的缺口）

现象：手机浏览器里存着**过期的**（或写错的）`dsh-auth-*` cookie 时，打开收藏的固定地址
`https://<入口>/` **不是**被 302 到带 token 的地址，而是直接看到 `dsh web` 的 401：

```
dsh web authentication required; reopen the URL printed by dsh web.
```

复现（2026-10-09，家里这台，`eth1` 是出口网卡）：

```sh
NEW='<云上当前密码>'
curl -sk --interface eth1 -u "dsh:$NEW" -o /dev/null -D - https://123.56.158.212:8443/            # → 302 ✓
curl -sk --interface eth1 -u "dsh:$NEW" -H 'Cookie: dsh-auth-stale=x' -o /dev/null -D - \
     https://123.56.158.212:8443/                                                                # → 401 ✗
```

根因在 `cloud/Caddyfile.ip` / `Caddyfile.domain` 的 `@entry`：

```
@entry { path / ; not query token=* ; not header Cookie *dsh-auth-* }
```

`not header Cookie` 是 ADR-0014 为治死循环加的（`/` → broker → `/?token` →
(set-cookie, 303 `./`) → `/` → broker → …）。但 **Caddy 只会看"有没有 `Cookie` 这个头"，
不会验签**：它分不清"有效 cookie"和"过期 cookie"，于是过期 cookie 把请求永久挡在
broker 门外 —— 而那正是手机用户最常见的状态（cookie 默认 30 天、家里换一次 token 就作废，
或者用户手动清过站点数据只清了一半）。

## 决定

**把"这个 cookie 还有效吗"从 Caddy 挪到家里的 broker**（它本来就串在链路里，
而且能直连本地 `dsh web`）：

1. **Caddy**：`@entry` 只留 `path /` + `not query token=*` —— 不带 token 的 `/`
   **一律**交给 broker，不管有没有 cookie。`/go`、其余请求、`{{BROKER_PORT}}`
   这些都不变（只有那一条 `not` 消失）。
2. **broker**（`bin/dsh-token-broker`）对 `GET /`：
   - **没有** `dsh-auth-*` cookie → 老行为不变：`302 Location: /?token=<当前 token>`；
   - **有** → 拿这条 cookie 向 `http://127.0.0.1:<web_port>/` 发一次**轻量探测**
     （`GET`，超时 3s，**只看状态码**，不看 body）：
     - **2xx/3xx**（cookie 有效）→ 把这一条 `GET /` **代发**给 `dsh web`，
       响应原样回给浏览器（逐跳头丢掉、长度重算，**`Set-Cookie` 一条不落**）；
     - **401/403**（过期/不被接受）→ `302 Location: /?token=<当前 token>`，
       并 `Set-Cookie: <名字>=; Max-Age=0; Path=/; …` 把失效的那几条清掉（能清就清，
       属性照抄 `dsh web` 自己那套，见下）；
     - **连不上 / 超时 / 其它状态码** → `503` + 一句人话（**绝不**乱跳：跳转只会把人
       送去一个死 token，或者跟 `dsh web` 转圈）；
   - token 文件读不出来 → **503**（不变）。
3. **最后一道防转圈的闸**：探测/代发拿到的 3xx 如果又指回入口（`Location` 是 `/`
   且不带 token），**不原样转发**，换成 token 跳转。正常链路上不会出现这种情况
   （cookie 有效时 `/` 回 200），它挡的是"上游行为怪掉"时唯一的无限回环。
4. `--probe-timeout`（默认 3s）只为可调/可测，默认值就是上面那个"短超时"。

**为什么这条链路一定终止**（逐步实测见 journal 2026-10-09（cookie 判断挪进 broker）那轮）：

```
① 无 cookie：GET /            → 302 /?token=…            （broker）
② 跟过去：  GET /?token=…     → 303 ./ + Set-Cookie      （dsh web，直连，不经 broker）
③ 带 cookie：GET /            → 探测 200 → 代发首页 200  （broker）→ 不再跳转，循环终止
④ 之后每次 GET /              → 同上，200（0 次跳转）
⑤ cookie 过期后 GET /         → 探测 401 → 302 /?token=… → 回到 ②（一次性，不循环）
```

## 为什么是 broker，不是 Caddy

- **`dsh web` 的 cookie 别人验不了**：名字是 `dsh-auth-` + `base64url(sha256(authority))`
  （authority 还是 `Host` 头算出来的），内容是 HMAC 签名，**密钥只在那个进程里**。
  Caddy 侧没有可用的验签材料。
- **在 Caddy 里"验证"只能验形状**（正则看 `Cookie` 头长什么样），验不了签名和有效期 ——
  过期 cookie 的形状和有效 cookie 一模一样，能验出来的只有"这压根不是我们的 cookie"。
- 真要在 Caddy 侧判，只能上 `forward_auth` 指一个鉴权端点 —— 那等于**再造一个服务**
  （还要能访问 `dsh web`、还要处理 authority 哈希），而 broker 已经在这条路上、
  已经在读 token 文件、已经能连 `127.0.0.1:<local_port>`。**一次本地 `GET` 就是最权威的
  "这 cookie 还有效吗"**（`dsh web` 自己回的 200/401）。

## 为什么只代理那一条 `GET /`

- **会话 / SSE / WebSocket 必须直连**（ADR-0001/0008）：那是长连接、要 `flush_interval -1`
  和 `read_timeout 0`，多一个中间跳就多一份缓冲/超时/重连语义要维护，而且 broker 是
  单进程 python 的 `ThreadingHTTPServer`，不该被推到流式主链路上。
- 首页是一次性的 HTML（实测 34782 字节）、没有流式语义，代理它最便宜。
- 判据（证明"只有那一条"）：带有效 cookie 请求 `/index.html`（`dsh web` 真实 200 的路径）
  → broker 日志行数**不变**（实测：28 → 28，journal 2026-10-09（cookie 判断挪进 broker）那轮）。

## 否决方案

| 方案 | 为什么否 |
|---|---|
| ① 直接删掉 `not header Cookie`，别的都不动 | **死循环**：`/` → broker → `/?token` → 303 `./` → `/` → broker → …（ADR-0014 记录过；本轮又静态推了一遍：`dsh web` 对带 token 的 `/` 一定 303 回 `./`） |
| ② 让 Caddy 自己校验 cookie | 做不到：Caddy 不验签、拿不到签名密钥；`forward_auth` 等于再养一个鉴权服务（见上） |
| ③ Caddy 用头正则区分"有效/过期 cookie" | 过期与有效的形状完全一样，正则只能看形状 |
| ④ 让用户清一次 cookie / 换个地址 | **用户 2026-10-09 明确否决**：固定地址的意义就是"手机收藏一个、永远能用"；这次缺口正是用户手机上撞出来的，不能把运维动作推给用户 |
| ⑤ 让 broker 变成整个应用的反代（省掉"只代一条"的边界） | 破坏 SSE/WebSocket 直连（ADR-0001/0008 的流式路径），并且把所有流量压进单进程 python |
| ⑥ 探测用 `HEAD` 更省 | `dsh web` 的鉴权在 GET/HEAD 上行为不一致的风险没必要去踩（`--help`/实现都按 GET 写的）；而且首页就 34 KB，省不出什么 |

## 后果

- **好处**：固定地址在"cookie 过期 / 家里换过 token / 只清了一半站点数据"三种情况下
  都能一次进去（302 → token → cookie → 200）；用户不用做任何运维动作。
- **代价**：首页那次请求会打到 `dsh web` **两次**（探测 + 代发），多一次本地回环往返；
  broker 从"纯重定向"变成"一个受限于 `GET /` 的小代理"，边界要守着
  （K 节 17 条回归就是守这个边界的）。清 cookie 用的是 `Path=/`，
  万一 `dsh web` 改了 cookie 的 `Path`，清不掉也不致命（下次照样 302 补 token）。
- **风险**：探测"误判"的代价被刻意压到最小 —— 只有 2xx/3xx 才放行、只有 401/403 才跳转，
  别的状态码一律 503（说"判断不出来"），宁可让用户看到一行明确的话，也不进入可能转圈的状态。

## 判据（可原地复现，详见 journal 2026-10-09（cookie 判断挪进 broker）那轮）

```sh
NEW='<云上当前密码>'; U=https://123.56.158.212:8443
C="curl -sk --interface eth1 --max-time 20 -u dsh:$NEW"
$C -D - -o /dev/null -H 'Cookie: dsh-auth-stale=x' "$U/" | head -1        # 302
$C -L -c /tmp/j -b /tmp/j -H 'Cookie: dsh-auth-stale=x' -w '%{http_code}\n' -o /dev/null "$U/"   # 200
$C -o /dev/null -w '%{http_code} %{num_redirects}\n' -b /tmp/j "$U/"      # 200 0（有效 cookie，0 次跳转）
journalctl --user -u dsh-token-broker.service | grep '代发首页'            # broker 侧证据
```
