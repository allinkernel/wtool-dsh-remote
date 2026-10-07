# ADR-002 中继器跑在容器里，证书/状态放命名卷，云上只要求 docker

**状态**：Accepted（早于初版提交 `13734e3` —— 那个提交里 `cloud/docker-compose.yml`
就在；`tests/run_tests.sh` 有一条断言写着"relay.sh 不再 apt 装 caddy"，
说明容器化之前有过 apt 装宿主包的版本。2026-10-07 补记为 ADR）。

**背景**：云上那台需要一个 HTTPS + basic auth 的反代（ADR-001）。装法有几条路：
宿主 `apt install caddy`、宿主上放官方二进制自己管 systemd、或者跑容器。

**决策**：用官方镜像 + `docker compose` 起一个容器（`cloud/docker-compose.yml`）：

- `image: caddy:2`、`container_name: dsh-relay`、`restart: unless-stopped`；
- **`network_mode: host`**，**不加 `ports:` 映射**；
- `./Caddyfile:ro` 挂进去、`./logs:/var/log/caddy` 收日志；
- 两个**命名卷**：`caddy-data:/data`（证书 + ACME 续期状态）、`caddy-config:/config`。

密码哈希也在容器里算：`docker run --rm caddy:2 caddy hash-password --plaintext …`。

**理由**：

- 换一台机器只要有 docker，`scp cloud/` + `sh relay.sh …` 就装好，**宿主干净**；
- 配置全在 `Caddyfile` + 两个命名卷里，`docker compose down` 就撤（卷留着证书不丢）；
- 不挑发行版（Ubuntu / Debian / Alibaba Cloud Linux 都一样）；
- 宿主的 caddy 版本不用管，哈希和运行用的是同一个镜像，不会版本打架。

**为什么必须 `network_mode: host`（两个原因，缺一不可）**：

1. 要连宿主 `127.0.0.1:18080` 上的隧道出口 —— 桥接网络里的 `127.0.0.1` 是容器自己；
2. 要直接占用宿主的 443/8443（安全组只放这两个端口）。

**否决**：

- `apt install caddy` —— 宿主脏、发行版差异、升级/卸载要另写一套。
  `tests/run_tests.sh` 有一条断言守着 `relay.sh` 里不再出现
  `apt-get install … caddy`；
- 宿主上放官方二进制 —— 要自己写 systemd 单元、自己管升级；
- 桥接网络 + `ports:` 映射 —— 连不到宿主的隧道口，`ports` 在 host 网络下也无效。

**后果 / 证据**：云上唯一的宿主依赖是 docker（+ compose 插件），`relay.sh --install-docker`
才顺手 apt 装 docker 自己；没有 `caddy.service` 可 `systemctl`（见 hazards H7）。
`cloud/docker-compose.yml` 的注释里写着上面这两条理由。
