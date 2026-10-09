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
| 13 | [隧道常驻用 systemd `--user` 单元 + ssh 自带保活（不用 autossh，也不在云上守）](0013-tunnel-residency-systemd-user-not-autossh.md) | 2026-10-07 U3：含"谁来重启 / 重连耗时期望"与 `tunnel-install` 的顺序 —— **"无限重试"那半已被 ADR-0019 收窄（改成失败 10 次停下 + 自愈）** |
| 14 | [手机收藏一个不带 token 的固定地址：家里放一个"只做 302"的 token broker](0014-fixed-phone-url-token-broker.md) | 2026-10-07：含 Caddy 那两条 `not` 为什么缺一不可 —— **其中按 cookie 的那条已被 ADR-0018 删掉，以 0018 为准** |
| 15 | [一条命令装好：`dsh-remote server`（自检 → 部署 → 常驻 → 二维码）](0015-one-command-server-install.md) | 2026-10-07：含为什么自己实现 QR、二维码为什么不带 token |
| 16 | [改密码做成一条命令（`dsh-remote passwd`），而且只换那一行哈希](0016-passwd-one-command-and-single-line-hints.md) | 2026-10-07：用户实测"三步教程"走不通之后；含提示语必须一行能复制 |
| 17 | [dsh web 常驻化（开机自启）+ `harness` 复用 + 会话起来后重连隧道](0017-dsh-web-service-boot-autostart-and-reuse.md) | 2026-10-07：`dsh-web.service` / `dsh-web-run` / `harness` 三步；为什么不用 `ExecStartPost` |
| 18 | [把"cookie 还有效吗"的判断挪进家里的 broker（只代发那一条 `GET /`）](0018-cookie-check-moved-into-broker.md) | 2026-10-09：用户手机上实测"过期 cookie 只看得到 401"之后；含否决方案（删 `not` 会死循环 / Caddy 验不了签 / 让用户清 cookie） |
| 19 | [隧道"失败 10 次就停下" + 家里一个 5 分钟一次的自愈检查（不再无限重试）](0019-tunnel-storm-guard-and-self-heal.md) | 2026-10-09：`RestartSec=3` + `StartLimitIntervalSec=0` 在对端持续掐连接时自我维持成 **1708 次**风暴之后；含"为什么自愈放家里不放云上"与否决方案 |
| 20 | [`harness` 的输出契约：第一行永远是"状态 + 为什么"，原因必须实测](0020-harness-status-output-contract.md) | 2026-10-09 用户："废话太多，明确地指出服务到底起来没有、没起来的原因是什么"；含四态判据、为什么"地址是不是刚写的"不能只比 mtime |
| 21 | [`dsh-web-run` 起 npx 前默认清空代理（要代理就显式配）](0021-dsh-web-run-clears-proxy.md) | 2026-10-09：WSL autoProxy 注入的坏代理被开机时的 `systemd --user` 抓到 → 服务里的 npx 永久卡住、永不写 token；`harness` 那边表现为"等 20s 没等到地址" |
| 22 | [`force-restart-dsh-remote`：一键兜底，以及"绝不重启 `dsh web`"的唯一例外](0022-force-restart-command-and-restart-web-exception.md) | 2026-10-09 用户批准"要有强制重置按钮"：当天实测三类故障（隧道风暴停下 / 手工实例的 token 抓不到 / 服务被端口占着 activating）都要人回家敲命令。**限定 ADR-0005**：默认档绝不碰 `dsh web`，`--restart-web --yes` 是显式例外（只 SIGTERM 占着端口的那一个 PID + 用服务起回来） |
| 24 | [`harness` = 本地管理器（**有则开、无则起**），`harness-remote` = 云上那半](0024-harness-as-local-manager-and-opener.md) | 2026-10-09 用户重做："任意时刻执行 `harness`，有 dsh web 就立刻开浏览器，没有就自己起一个；**不许再有等 20 秒**"。**部分取代 ADR-0020**（输出契约收窄成 ≤3 行、不再等待）；含"opener 绝不经 shell"的实测坑（`cmd /c start` 把 URL 转成 `http \127.0.0.1 …`）与三档退、为什么 opener 失败不算失败、`harness-remote` 的边界 |
| 23 | [手机上的"重置按钮"走云上 `/reset` → 家里 token broker，而不是直连 `dsh web`](0023-reset-button-through-token-broker.md) | 2026-10-09：broker 已经在家、已经有隧道、和命令同一个 `bin/`，所以由它代跑安全档（只跑命令、不重写逻辑）；POST 先回 202 再动隧道（实测 0.126s）、一次性 nonce 挡 CSRF、云上永不允许 `--restart-web` |

> **1–11 是同一条线（2026-09-20 的初版 `13734e3` + 2026-10-04 的修复）**，
> 2026-10-07 补记成 ADR。当时只写了 `README.md` 的"为什么这么设计"一节和代码注释，
> 没有 ADR 文件 —— 所以正文里的"背景/理由"大多是从那两处提炼的，凡提炼不出处的
> 都在该条里显式写了"未记录"。
>
> 17/18 两行原来不在表里（上一轮 0017 只写成了表外的一行），2026-10-09 顺手并回表内。
