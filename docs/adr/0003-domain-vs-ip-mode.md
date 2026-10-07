# ADR-003 域名模式（443 + Let's Encrypt）与 IP 模式（8443 + 自签）两条路

**状态**：Accepted（2026-09-20 随初版 `13734e3` 落地；2026-10-07 补记为 ADR）。

**背景**：中国大陆的机器 80/443 要**备案**才能对外服务；没有域名或没备案时，
Let's Encrypt 的 ACME 验证根本走不通。而手机浏览器遇到自签证书会拦一下。

**决策**：`cloud/relay.sh` 强制且只允许选一条路：

| | 域名模式 | IP 模式 |
|---|---|---|
| 触发 | `--domain dsh.example.com` | `--ip 47.98.1.2` |
| 模板 | `Caddyfile.domain` | `Caddyfile.ip` |
| 默认端口 | 443 | 8443 |
| 证书 | Let's Encrypt（ACME；`--email` 不给我就 `admin@<域名>`） | `tls internal`：Caddy 自己的 CA 签的自签证书 |

两个模板都写了 `auto_https disable_redirects`。

**理由**：

- 能上域名就用真证书：自动续期，手机不用每次点"继续访问"；
- 不能就退到高端口 + 自签：**流量依然是加密的**，basic auth 的密码不会明文过网，
  代价只是第一次要点一次警告；
- 端口可以 `--port` 覆盖（换端口记得同步安全组）。

**否决**：

- 只做 IP 模式 —— 有域名的人每次都要点警告，白白浪费可信证书；
- 只做域名模式 —— 没备案的大陆机器直接不能用；
- 用 http 明文 —— basic auth 的密码会在链路上裸奔；
- 自己写 ACME 客户端 —— Caddy 已经做了，且续期状态就在命名卷里。

**后果**：两条路的差异被压进两个模板 + 一个 `case`，`relay.sh --dry-run` 能把
最终 Caddyfile 打到 stdout（ADR-011）给人看/给 `caddy validate` 验。
`tests/run_tests.sh` D 节对两条路都有断言（含 IP 模式的 `tls internal` 和
`--allow-ip` 的 403 规则）。

**证据**：`README.md` §5.3；`cloud/Caddyfile.ip` 顶部注释（备案、境外机器、
"点继续访问就行"）；`cloud/relay.sh` 的模式选择段。
