# ADR 索引（`tools/dsh-remote/docs/adr/`）

架构决策记录。**每条：状态 → 背景 → 决策 → 理由 → 否决（+ 判据/后果）。**

规则（同【wsw 文档体系】，见 `~/.dsh/AGENTS.md` §2）：

- 决策一旦 **Accepted 就不再改**；结论变了就**新写一条**，并在新的那条里注明取代了谁。
- 现存实现与某条 ADR 冲突时：**以 `architecture.md`（现状）为准**，并把冲突报给用户，
  别自己脑补。
- 新增决策 → 这里加一个文件，同时在下表加一行。
- **任务不从 ADR 标题来** —— ADR 只说"为什么"；"做什么、做到哪了"看 `BACKLOG.md`。
- **证据不足的不许编**：某条决策当时怎么讨论的没留下记录，就在那条里写
  "决策未记录，代码事实见 X"（本仓库有多条是这样，见下表的"备注"列）。

| # | 标题 | 备注 |
|---|---|---|
| 1 | [云上 Caddy + SSH 反向隧道，而不是直接暴露 `dsh web`](0001-cloud-caddy-plus-ssh-reverse-tunnel.md) | |
| 2 | [中继器跑在容器里，证书/状态放命名卷，云上只要求 docker](0002-caddy-in-container-named-volumes.md) | |
| 3 | [域名模式（443 + Let's Encrypt）与 IP 模式（8443 + 自签）](0003-domain-vs-ip-mode.md) | |
| 4 | [basic auth 挡在最外层；用户名默认固定 `dsh`，密码随机](0004-basic-auth-at-the-edge.md) | "为什么是 `dsh`"未记录，代码事实见 `relay.sh:31` |
| 5 | [`dsh web` 只绑 `127.0.0.1`，绝不开公网](0005-dsh-web-loopback-only.md) | |
| 6 | [推送走 DSH 官方 hook 桥；"尚未被证实会触发"是已记录的现状](0006-push-via-official-hook-bridge.md) | |
| 7 | [`scripts/install.sh` 只认引擎契约变量；源找不到 = 只跳过那一条](0007-install-sh-engine-contract-vars.md) | |
| 8 | [让 Caddy 把 `Host`/`Origin`/`Referer` 改写成回环，而不是加 `--trusted-host`](0008-rewrite-host-origin-instead-of-trusted-host.md) | |
| 9 | [我们自己的配置/日志不放 `~/.dsh`](0009-config-state-not-in-dsh-home.md) | |
| 10 | [`dsh-notify` 的退出码永远是 0](0010-notify-always-exit-zero.md) | |
| 11 | [`relay.sh` 的 stdout 只放 Caddyfile，进度/报告全走 stderr](0011-relay-stdout-is-caddyfile.md) | |
| 12 | [IP 模式在真机上要三处硬化：`default_sni`、钉住的镜像 tag、无 compose 的用户空间模式](0012-ip-mode-hardening-on-real-host.md) | 2026-10-07 第一次真阿里云部署时定 |
| 13 | [隧道常驻用 systemd `--user` 单元 + ssh 自带保活（不用 autossh，也不在云上守）](0013-tunnel-residency-systemd-user-not-autossh.md) | 2026-10-07 U3：含"谁来重启 / 重连耗时期望"与 `tunnel-install` 的顺序 |
| 14 | [手机收藏一个不带 token 的固定地址：家里放一个"只做 302"的 token broker](0014-fixed-phone-url-token-broker.md) | 2026-10-07：含 Caddy 那两条 `not` 为什么缺一不可 |
| 15 | [一条命令装好：`dsh-remote server`（自检 → 部署 → 常驻 → 二维码）](0015-one-command-server-install.md) | 2026-10-07：含为什么自己实现 QR、二维码为什么不带 token |
| 16 | [改密码做成一条命令（`dsh-remote passwd`），而且只换那一行哈希](0016-passwd-one-command-and-single-line-hints.md) | 2026-10-07：用户实测"三步教程"走不通之后；含提示语必须一行能复制 |

> **1–11 是同一条线（2026-09-20 的初版 `13734e3` + 2026-10-04 的修复）**，
> 2026-10-07 补记成 ADR。当时只写了 `README.md` 的"为什么这么设计"一节和代码注释，
> 没有 ADR 文件 —— 所以正文里的"背景/理由"大多是从那两处提炼的，凡提炼不出处的
> 都在该条里显式写了"未记录"。
| 0017 | dsh web 常驻化（开机自启）+ harness 复用 + 起来后重连隧道 | Accepted | 2026-10-07 |
