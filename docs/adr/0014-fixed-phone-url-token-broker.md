# ADR-0014. 手机收藏一个不带 token 的固定地址：家里放一个"只做 302"的 token broker

- 状态：Accepted（2026-10-07）
- 相关：ADR-0001（云上 Caddy + 反向隧道）、ADR-0004（basic auth）、ADR-0008（Host/Origin 改写）、
  ADR-0013（常驻隧道）、`docs/hazards.md` H17、`architecture.md` §3.2、`BACKLOG.md` U10

## 背景

`dsh web` 的访问控制是**进程级一次性 token**：

- 每次启动生成 32 字节随机（`processLaunchToken`，base64url 43 个字符），**只在内存里**；
- 启动时打印一行 `dsh web: http://127.0.0.1:3080/?token=…`；
- 带这个 token 访问 `GET /` 会换一个**30 天有效的签名 cookie**（`dsh-auth-<authority>`）并
  303 到 `./`，之后靠 cookie；
- `dsh web --help` 只有 `--host / --no-open / --port / --trusted-host` —— **没有**
  "固定 token / 指定 token / 关掉鉴权"的开关（2026-10-07 查过 CLI 与
  `dsh-client-connection` 源码，见 hazards H22）。

于是手机上的体验是：**每次家里重启 harness，地址栏里那个带 token 的 URL 就作废**，
人得回到电脑前把新地址抄到手机上 —— 这跟"人在外面"的用途正好相反。

## 决策

**1）token 只有家里知道，所以重定向逻辑放家里；云上只做"按条件转发"。**

- 家里的 `harness` shell 函数（`env.zsh` / `env.bash`，两份等价）包装 `npx @deepseek-ai/dsh web`：
  把 stdout 里那行 `dsh web: http://…/?token=…` 里的 token 写进
  `$STATE_DIR/current-token.txt`（600），完整 URL 另写 `web-url.txt`；**退出时删掉 token 文件**。
- 家里再跑一个极小的 HTTP 服务 `dsh-token-broker`（`bin/dsh-token-broker`，纯 python 标准库），
  只绑 `127.0.0.1:3081`：
  - `GET /`（不带 token 参数）→ **302** `Location: /?token=<当前值>`；
  - `GET /go` → 同样 302（cookie 过期 / 换过 token 之后的"重进一次"入口）；
  - 读不到 token 文件、或 `dsh web` 的端口没在听 → **503 + 一句人话**（**绝不** 302 到空 token）；
  - 别的路径 404、别的办法 405。**它不代理任何应用流量。**
- 隧道多一条 `-R 127.0.0.1:18081:127.0.0.1:3081`（同一条 ssh；ADR-0013 的单元里两个 `-R`）。
- 云上 Caddy 只把**一种**请求交给 broker：

  ```caddyfile
  @entry {
      path /
      not query token=*          # 带 token 的直连 dsh web
      not header Cookie *dsh-auth-*   # 已经换到 cookie 的也直连 dsh web
  }
  reverse_proxy @entry 127.0.0.1:18081
  @go path /go
  reverse_proxy @go 127.0.0.1:18081
  reverse_proxy 127.0.0.1:18080   # 其余一律直连 dsh web（会话/SSE/WebSocket）
  ```

**2）两条 `not` 缺一不可**，否则就是 302 死循环：
`/` → broker → `/?token=X` →（dsh web 303 `./` + Set-Cookie）→ `/` → broker → …
2026-10-07 在本地同构 Caddy（同一份模板、真 caddy:2.11.4 容器）上实测过：
带 cookie 的 `/` 必须回到 dsh web（200，0 次跳转）。

**3）二维码和链接都编码"固定 URL"（不带 token）**：token 是一次性密钥，不该印在
纸上/截图里；固定地址由 broker 补 token，换 token 不用换二维码。

**4）`loginctl enable-linger` 之后 broker 和隧道都做成 systemd `--user` 常驻**
（`dsh-token-broker.service` / `dsh-tunnel.service`，同 ADR-0013 的套路）。

## 理由

- **为什么不给 Caddy 加"固定 token"**：官方没有这个开关，硬造等于自己实现一套鉴权；
  而 dsh web 的 cookie 机制本来就是"一次 token 换长期 cookie"，顺着它走最省。
- **为什么 broker 不做反向代理**：主链路上有 SSE 与 WebSocket，代理一层就得处理
  `flush_interval`、`read_timeout`、Upgrade、连接生命周期 —— 出事的地方都在这些细节里。
  只做 302 的话，broker 挂了最坏是"进不去"，不会把正在用的会话弄坏。
- **为什么用 cookie 那条 `not`**：dsh web 换 cookie 之后会 303 回 `/`，那条请求**没有**
  token 参数；不排除它就必然死循环。
- **为什么 token 从 stdout 抓**：没有 API 能问出运行中进程的 token（内存里的 WeakMap，
  不落盘、不进环境变量 —— 见 hazards H22）；启动那行打印是唯一的口子。
- **为什么退出要删 token 文件**：宁可让手机看到 503「还没起」，也别 302 到一个死 token、
  再被 dsh web 401 一遍 —— 后者会让人以为"密码错了"。

## 否决

| 方案 | 为什么否 |
|---|---|
| 找 `dsh web` 的固定 token / 关鉴权开关 | 不存在（CLI 与源码都查过，H22） |
| 从运行中的进程里"读出"当前 token | 只在内存里、不落盘、不进 environ/cmdline；唯一出现的地方是启动那行 stdout |
| 自己造一个长期 cookie（读 `~/.dsh` 里的签名密钥去签） | 动的是**别人**的凭据与信任根；换个版本就可能失效，而且等于绕开鉴权，不是这个项目该干的事 |
| 让 Caddy 直接把 `/` 代理到 broker，broker 再代理回 dsh web | 把 SSE/WebSocket 拖进 broker，违反上面那条"不代理" |
| 把 `/?token=` 交给 Caddy 做 rewrite | Caddy 不知道当前 token（token 只有家里知道），它没法凭空补 |
| 手机每次重新扫/重新抄新 token 地址 | 这正是要解决的问题 |

## 后果 / 代价（要认）

- **第一次访问（或 cookie 过期后，默认 30 天）必须经过 broker**；broker 没跑 = 手机进不去
  （会看到 503 或 502），但**已经拿到 cookie 的浏览器不受影响**（那条路由直连 dsh web）。
- token 文件是**状态**：`harness` 函数没被用过（比如 harness 是用别的办法起的），
  broker 就一直是 503。`dsh-remote tunnel-status` 会把这件事打出来。
- 会话重放面变了一点点：固定 URL 背后是"谁过了 basic auth 谁就能拿到当前 token" ——
  但 basic auth 本来就是唯一那道门（ADR-0004），没有变弱；变弱的前提是**别人也过了 basic auth**。
- broker 只绑回环 + 只经隧道暴露，安全组里**不能**开 18081（同 18080 的规矩）。
