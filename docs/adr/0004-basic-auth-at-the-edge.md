# ADR-004 basic auth 挡在最外层；用户名默认固定 `dsh`，密码随机

**状态**：Accepted（2026-09-20 随初版 `13734e3` 落地；2026-10-07 补记为 ADR）。

**背景**：Caddy 之外没有任何身份校验。而且因为 ADR-008 把 `Host`/`Origin` 改写成了回环，
harness 那一侧**分不清**请求来自本地还是远程 —— 也就是说，这道门前没有人替我们挡。

**决策**：Caddyfile 里用 HTTP basic auth：

```
basic_auth {
    {{USER}} {{HASH}}
}
```

- 用户名默认 `dsh`（`relay.sh --user` 可换）；
- 密码：不给 `--password` 就**每次随机生成 20 位**
  （`openssl rand -base64 24 | tr -d '/+=' | cut -c1-20`，没有 `openssl` 就 `/dev/urandom`）；
- Caddyfile 里放的是 **bcrypt 哈希**（`$2a$…`），不是明文；
- 哈希在容器里算：`docker run --rm caddy:2 caddy hash-password --plaintext <密码>`。

**理由**：

- TLS + 一道长口令就能把入口关死，实现最小、没有自研认证代码；
- 哈希进配置（`relay.sh` 最后打印的才是明文密码）；
- 随机密码避免"人选一个弱的"；重跑脚本 recreate 容器时不用人记密码
  —— 除非显式 `--password` 把它固定下来。

**关于"用户名为什么是 `dsh`"**：**决策当时的讨论没有留下记录**。
代码事实：`cloud/relay.sh:31 CADDY_USER=dsh`；`README.md` §5.6 和 `relay.sh` 结尾
打印的就是这一对用户名/密码；`--user` 可覆盖。不想用这个名字就 `--user <别的>`。

**否决**：

- 把 token 藏在 URL 里（会进浏览器历史、日志、Referer）；
- 只靠 `--allow-ip` 限制来源（家里出口 IP 会变，变了就得重跑脚本）；
- 不要认证 —— 那等于把一台机器的控制权公开。

**后果**：密码泄露 = 整台家里机器的控制权；`--allow-ip` 只是加分项，**不能替代密码**。
`relay.sh` 每次重跑都会换新密码（不给 `--password` 时），手机上要重新输一次。
