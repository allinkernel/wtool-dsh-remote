# ADR-012 IP 模式在真机上要三处硬化：`default_sni`、钉住的镜像 tag、无 compose 的用户空间模式

**状态**：Accepted（2026-10-07，第一次真阿里云部署时定；`architecture.md` §7 是改了之后的现状）。

**背景**：2026-10-07 第一次把中继真装到阿里云那台（Ubuntu 26.04、无 compose 插件、
`mindul` 不在 docker 组、80 被 nginx 占着）。三件事在真机上暴露出来，都是"本机测试
永远测不到"的那一类：

1. **IP 模式握手直接失败**。浏览器访问 `https://<IP>:8443` 时**不发 SNI**
   （RFC 6066 不允许 SNI 里放 IP 字面量），Caddy 没有 SNI 就选不出证书，
   TLS 握手返回 `internal error`（curl → `SSL_ERROR_SYSCALL`，openssl → alert 80）。
   `Caddyfile.ip` 是 **IP 模式**的模板，却没有给"没有 SNI"留退路 —— 也就是说
   **这份模板设计上就跑不通**，只是此前从没真装过（BACKLOG U1）所以没人发现。
2. **`caddy:2` 这个浮动 tag 在阿里云上兑成了 4 年前的 `v2.4.6`**（`/etc/docker/daemon.json`
   里配了 5 个国内 mirror，其中一个的缓存停在 2021 年）。v2.4.6 没有 `basic_auth`
   指令（那会儿叫 `basicauth`）→ 容器起来就崩、无限重启
   （`run: adapting config using caddyfile: /etc/caddy/Caddyfile:22: unrecognized directive: basic_auth`）。
   更麻烦的是：`relay.sh --dry-run` 的 `caddy validate` 用的是**本机**镜像（v2.11.4，
   验得过），于是"本机验证通过"完全掩盖了云上那份配置根本没被同一个 Caddy 读过。
3. **云上没有 compose 插件、docker 还要 sudo**。`relay.sh` 却同时硬要求
   root（`id -u = 0`）和 `docker compose`（`compose up -d`）—— 在这台机器上
   **一条路都走不通**；而用户给的硬约束是"唯一允许的特权动作是 `sudo docker`
   启停中继容器"，所以也不能 `sudo sh relay.sh`。

**决策**：

1. `cloud/Caddyfile.ip` 的全局块加 **`default_sni {{IP}}`** —— 没有 SNI 时用它兜底，
   Caddy 就能选到那张 IP 证书。（域名模式不加：域名本来就会进 SNI。）
2. 所有地方的默认镜像 tag **从浮动的 `caddy:2` 改成钉住的 `caddy:2.11.4`**
   （`relay.sh` 的 `CADDY_IMAGE` 默认值、`docker-compose.yml` 的 `image:`
   、两个测试脚本的 `IMG` 默认值），并在 `relay.sh` 里加**版本自检**：
   真跑时如果镜像里的 caddy < 2.8（没有 `basic_auth`），直接 `die` 并告诉你
   该换哪个镜像，而不是让它去无限重启。
3. `relay.sh` 新增**用户空间模式**：`--no-compose`（不用 compose，直接
   `docker run -d --name dsh-relay`，容器名与 compose 模式一致）、
   `--dir <目录>`（数据落宿主目录，而不是命名卷）、
   `--docker-cmd '<命令>'`（默认 `docker`，本机要提权就 `'sudo docker'`）。
   用了 `--no-compose` 就不再要求 root；compose 模式的行为保持不变。

**理由**：

- `default_sni` 是 Caddy 为"ClientHello 没有 SNI"准备的官方开关，一行就够；
  备选是"让用户上域名"（用户没有域名）或"自己签一张证书用 `tls <cert> <key>` 挂上"
  （多一份要维护、要续期的文件）。
- **钉住 tag 是"本机 validate 过的配置 = 云上真跑的那份"这条链的前提**：
  浮动 tag 意味着两端可能不是同一个 Caddy，验证就是假的。
  版本自检是第二道闸：镜像旧到没有 `basic_auth` 时给一句人话，而不是崩溃循环。
- 用户空间模式把"要 root + 要 compose"降成"只要能跑 `docker run`"，
  正好对上那台机器的真实约束（用 `sudo docker` 提权，且不许装东西）。
  它同时让"数据在哪"变得可见：`$DIR/{Caddyfile,logs,data,config}` 都是普通目录，
  用户 `ls` 得到、备份得了，不用去碰命名卷。

**否决**：

- **把 `basic_auth` 降级成 `basicauth` 去迁就 v2.4.6**：等于让一台公网入口跑
  4 年前的软件；而且 v2.8+ 里 `basicauth` 是废弃别名，等于把技术债写进模板。
- **只改云上那份 Caddyfile（不改模板）**：仓库和真机就分家了，下一个人照仓库
  再装一次还是撞同一个坑。
- **`--no-compose` 用 `docker create` + `docker start` 两步**：比 `run -d` 多一步，
  没有额外好处；重复跑靠 `rm -f` 再 `run` 就够了。
- **让 relay.sh 自己 `sudo`**：脚本自己提权会绕过用户的 sudo 策略，
  也超出"用户只授权 `sudo docker`"的边界。改成用户显式传 `--docker-cmd 'sudo docker'`。

**判据**（2026-10-07 在真阿里云上实测，逐条可复现）：

- 无 SNI 也握手：`openssl s_client -connect 127.0.0.1:8443 </dev/null`
  在加 `default_sni` 前 → `tlsv1 alert internal error`；加了之后 → 拿到
  `issuer=CN=Caddy Local Authority - ECC Intermediate`。
- 镜像版本：`sudo docker run --rm caddy:2 caddy version` → `v2.4.6`（那台 mirror 的缓存）；
  同一台 `sudo docker run --rm caddy:2.11.4 caddy version` → `v2.11.4`。
- 版本自检的 `case` 分支：`v2.4.6`/`v1.9.9` → 拦下；`v2.8.0`/`v2.10.0`/`v2.11.4`/`v3.0.0` → 放行；
  空 → 只 warn。（这段是纯文本判断，本地跑一遍就知道，见 `tests/run_tests.sh` D 节。）
- 用户空间模式真装成了：在云上跑
  `sh relay.sh --ip 123.56.158.212 --port 8443 --no-compose --dir ~/dsh-relay --docker-cmd 'sudo docker'`
  → 自检打印 `https 入口：401（basic auth 在挡着）✓` 和 `隧道出口：401 ✓`。

**后果**：

- `relay.sh --help` 的范围也从写死的 `sed -n '2,26p'` 改成"打到注释块结束"
  （头部一加行就会多打/少打，同 hazards H10 那个坑）。
- `relay.sh` 里的 docker 调用统一走 `dk()`/`$DOCKER`（`--docker-cmd` 可能带空格）；
  `relay.sh` 在 `set -e` 下新增的循环条件写成 `if/then` 而不是 `… && break`
  （`&&` 在 `set -e` 下没命中会直接退出脚本）。
- README「3. 命令」/「4. 为什么这么设计」、`architecture.md` §7 要跟着写清两种跑法；
  云上那份的实际状态记在 `BACKLOG.md`（U1/U2）。
