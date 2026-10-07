# ADR-001 云上 Caddy + SSH 反向隧道，而不是直接暴露 `dsh web`

**状态**：Accepted（2026-09-20 随初版 `13734e3` 落地；2026-10-07 补记为 ADR）。

**背景**：出门在外要用手机看/接管家里的 DSH 会话（`dsh web` 在 `127.0.0.1:3080`）。
家里这台机器没有公网 IP，也不该为了这件事去动路由器。而这个界面等于**这台机器的
完全控制权**（能执行任意命令、读写任意文件）。

**决策**：家里主动往云上连一条 SSH 反向隧道：

```
ssh -N -T -R 127.0.0.1:18080:127.0.0.1:3080 root@<云主机>
```

云上只跑 Caddy，做 HTTPS + HTTP basic auth，反代到 `127.0.0.1:18080`；对外只开
443（或 IP 模式的 8443）。隧道口在云上**只绑 127.0.0.1**，安全组里根本没有它。

**理由**：

- 家里是**出站**连接 —— 不需要公网 IP、不需要端口映射、不依赖 IPv6、不用内网穿透服务。
- 云上只有一条入站路径，攻击面 = Caddy + 一道 basic auth + TLS，清楚可审计。
- 只用一条 TCP，断了自己重连（`dsh-remote tunnel` 的 `retry_seconds` 循环），
  对网络环境最不挑。

**否决**：

- 在家开端口 / 端口映射 / 直接暴露 `dsh web` —— 那等于把 RCE 挂到公网，而且家里没公网 IP。
- WireGuard / VPN —— 公司网络常封 UDP，手机上还要常驻一个客户端。
- 第三方内网穿透服务 —— 多一个能看见这条链路的中间人。
- 给 `dsh web` 加 `--trusted-host` 直接对外 —— 要重启 harness，见 ADR-008。

**后果**：远程可用性完全押在"隧道活着"上；隧道常驻/重连今天仍然很薄
（systemd 单元只生成不 enable、本机没有 autossh），见 `BACKLOG.md`。

**证据**：`README.md` §1 的链路图与 §4；`bin/dsh-remote` 的 `cmd_tunnel` / `tunnel_args`；
`cloud/Caddyfile.domain` / `cloud/Caddyfile.ip` 的 `reverse_proxy 127.0.0.1:{{TUNNEL_PORT}}`。
