# ADR-008 让 Caddy 把 `Host`/`Origin`/`Referer` 改写成回环，而不是加 `--trusted-host`

**状态**：Accepted（2026-09-20 随初版 `13734e3` 落地；2026-10-07 补记为 ADR）。

**背景**：`dsh web` 有一道"浏览器信任围栏"：默认只认回环地址 / 本机 LAN /
`--trusted-host` 里列出的主机。手机从 `https://dsh.example.com` 访问时，
`Host` 和 `Origin` 都是那个域名，会被围栏挡掉。

**决策**：不改 harness，改请求头 —— 在 Caddy 的 `reverse_proxy` 里写：

```
header_up Host    127.0.0.1:{{LOCAL_PORT}}
header_up Origin  http://127.0.0.1:{{LOCAL_PORT}}
header_up Referer http://127.0.0.1:{{LOCAL_PORT}}/
```

**理由**：

- `--trusted-host` 要改 harness 的启动参数 → 要重启 `dsh web` → **会打断正在跑的会话**
  （历史不丢、能 resume，但对正在干活的人是实打实的中断）；
- 改头不用重启，`patchReload`/热加载那套都不用碰；
- 反代改写上游请求头是标准做法，配置就三行。

**代价（必须一起记住）**：harness 从此**分不清**请求来自本地还是远程 ——
对外的全部安全性都压在 Caddy 那一层的 basic auth + TLS 上（ADR-004）。
所以密码必须长且随机，443/8443 之外的端口一个都不能开（ADR-005）。

**判据**：`tests/relay-e2e.sh` 真起 Caddy 容器 + 一个假后端，断言后端收到的
`Host` 就是 `127.0.0.1:3080`（`body=… host=127.0.0.1:3080`）。
`tests/run_tests.sh` D 节对两个模板都有 `header_up Host 127.0.0.1:3080` 的断言。

**否决**：

- `--trusted-host dsh.example.com` + 重启（打断会话；而且多一个要跟着域名变的东西）；
- 给 harness 打补丁放宽围栏（改别人的代码，升级就丢）；
- 不用围栏（那是 DSH 自己的安全设计，动它风险更大）。
