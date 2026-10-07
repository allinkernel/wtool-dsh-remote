# ADR-011 `relay.sh` 的 stdout 只放 Caddyfile，进度/报告全走 stderr

**状态**：Accepted（随容器化那一轮落地；2026-10-07 补记为 ADR）。

**背景**：`relay.sh` 要干两件都跟"输出"有关的事：① 生成一份 Caddyfile 给人确认
（`--dry-run`）；② 报告它在干什么（渲染、起容器、自检、打印手机地址和密码）。
两者混在一个流里，就没法把 Caddyfile 直接喂给别的命令。

**决策**：`say()` / `warn()` / `die()` 全部 `>&2`；**stdout 只在 `--dry-run` 时输出
渲染好的 Caddyfile**（非 dry-run 时 stdout 是空的，报告、自检、密码都在 stderr）。

**理由**：

- 一条链能用：`sh relay.sh --domain dsh.example.com --dry-run > Caddyfile &&
  docker run --rm -v "$PWD:/c:ro" caddy:2 caddy validate --config /c/Caddyfile --adapter caddyfile`；
- 报告里带着中文进度行，混进 stdout 会让 `caddy validate` 直接失败；
- 云上跑真装时，人看到的东西（`2>&1` 或终端默认）和机器能吃的东西分开，互不干扰。

**判据**：

- 读代码：`cloud/relay.sh:44-49`（三个输出函数都 `>&2`）、`217-233`（dry-run 分支
  `printf '%s\n' "$rendered"` 到 stdout）。
- 想真看：`sh cloud/relay.sh --domain a.com --dry-run 2>/dev/null | head -1`
  应该是 Caddyfile 的第一行而不是进度行。
  ⚠️ **本机装了 docker 时这条会真的跑一次 `docker run … caddy validate`**
  （它顺便做校验），所以别在"禁止碰 docker"的场合敲 —— 见 hazards H8。

**否决**：

- 全部走 stdout（`--dry-run` 的输出没法直接当文件用）；
- 全部走 stderr（`--dry-run > file` 得到空文件，更糟）；
- 加一个 `--output <file>` 参数（多一个要记的参数；重定向已经够了）。

**后果**：`cloud-install` 在云上跑真装时把 stdout+stderr 一起 `tee` 进日志，
再从日志里 grep `https://…` 取地址 —— 因为它知道地址行在 stderr 里、
而且报告里只有那一处是网址形状。这条约定变了要同步改 `cloud-install` 的第 3 步。
