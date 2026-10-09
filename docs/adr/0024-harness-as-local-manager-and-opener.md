# ADR-0024：`harness` = 本地管理器（**有则开、无则起**），`harness-remote` = 云上那半

- 状态：Accepted（2026-10-09，用户明确重做）
- 相关：ADR-0017（dsh web 常驻化）、ADR-0020（旧的"输出契约"）、ADR-0021（dsh-web-run 清代理）、
  ADR-0005（`dsh web` 只绑回环）、ADR-0022（force-restart 的安全档）、ADR-0001/0014/0018（云上那条链路）
- **部分取代 ADR-0020**：0020 定的"四态 + 每档带判据、等 systemd 写出地址最多 20 秒"这条
  输出契约，被本条的"有则开、无则起、不等待"收窄。0020 的**精神**（状态要一眼看出来）
  仍然有效，正文与文件名不动（Accepted 不改），冲突处以本条为准。
- 取代：无（新增）

## 背景：用户 2026-10-09 的原话

> 我要的就是在任意时刻我执行 `harness`，它**立刻检查系统有没有启动 `dsh web`，有就立刻打开浏览器**
> （就像 `npx @deepseek-ai/dsh web --port 3082` 这个命令一样）。**如果没有就自己打开一个**。
> 后台的 systemd 维护的自启动服务也是这样，**如果那个服务已经启动了一个 `dsh web`，`harness`
> 命令就不需要再启动了，立刻打开浏览器就好了。就是这么简单。**
> `harness` 是本地管理这些服务。而 `harness-remote` 命令就是管理我的阿里云服务器上 8443 端口的服务。

在这之前，`harness` 是"**起** dsh web 并抓 token"：它盯的是"有没有服务、有没有新 token"，
所以会出现"等 systemd 写出地址（最多 20s）…"这种**沉默等待**，而且它**从来不开浏览器**
（开浏览器是 npx 自己干的，`--no-open` 就没了）。用户要的是相反的重心：
**这个命令的职责是"把浏览器指到已经在跑的那个会话上"**，起服务只是它没有别的选择时的兜底。

## 决定

### 1. `harness` 只有两条路（`env.zsh` / `env.bash`，两份逐字等价）

```
① 127.0.0.1:<端口> 有人听（ss -ltnp） → 打一行状态 → 立刻开浏览器 → return 0
    · 不再起第二个、不等待、不重启、不删/写任何状态文件
    · 那一行说清是 **systemd 托管** 还是 **手工起的**（判据：单元的 MainPID，或
      /proc/<pid>/cgroup 里带 dsh-web.service）
② 没人听 → 起一个：
    · 优先 dsh-web.service（它经 dsh-web-run 抓 token，而且本仓规矩是"常驻归服务"）——
      `start --no-block`，然后最多等 DSH_REMOTE_HARNESS_WAIT 秒（默认 10）看端口出现
    · 没有那个单元、或命令行显式换了端口（≠ remote.conf 的 local_port）→ 前台
      `npx @deepseek-ai/dsh web [原样透传的参数] --port <端口>`：端口一出现就开浏览器，
      npx 继续占着终端；它退出时按标记删掉**自己写的** token（broker 宁可回 503）
```

- **端口优先级**：命令行 `--port` > `remote.conf` 的 `local_port` > `3080`。其余参数原样透传
  （`--no-open`、`--trusted-host x`…）。
- **为什么"命令行换端口"不走服务**：单元的 `ExecStart` 里钉的是**配置文件那个端口**
  （ADR-0017）。拿它去顶 `--port 3082` 只会起在 3080、然后报一个假成功。所以那条路走前台。
  这条**有意**和用户原话（"优先用 dsh-web.service"）分开：原话描述的是**默认端口**那种情况。
- **`DSH_REMOTE_HARNESS_UNIT=<不存在的单元名>`** 是一个逃生阀：给一个不存在的单元名 =
  强制走前台那条路（测试离线验它用；也用于"我就是想手工起"）。
- 退出码：两条路都 **0**（"起来了/已经在跑"都算成功）。等不到端口时才非 0，
  而且**分两种**：服务还在 `activating/active` → 打"还在起…"**返回 0**（那不是失败）；
  其它 → 打实测原因 + 判据，返回 1。

### 2. 开浏览器：**绝不经 shell**，三档退，失败不算失败

用户 2026-10-09 实测踩到的坑：把 URL 拼进 shell 字符串（`cmd /c start "$url"`）会被 WSL
的路径转换糟蹋成 `http \127.0.0.1 3984\token=MTOK`，Windows 弹"找不到文件"框。
**错的不是 opener 选得不对，错在"经 shell"。** 所以照 DSH 自己的做法
（`@deepseek-ai/dsh-web-app`：`spawn(node, […, '--', url])` + npm 的 `open` 包 + 起之前 scrub 代理）：

| 档 | 命令 | 说明 |
|---|---|---|
| ① | `node <临时 .mjs> <url> <open 包根>` | `.mjs` 里动态 `import` npx 缓存里的 `open@11`；`open` 自己按平台/WSL 选 opener 并按 URL 正确传参；起之前清掉 `http_proxy/https_proxy/all_proxy/HTTP(S)_PROXY/ALL_PROXY`（`no_proxy` 保留）。入口走 `pathToFileURL(...).href`（裸路径 import 会被当成协议）。 |
| ② | `explorer.exe <url>` / `wslview <url>` / `xdg-open <url>` | **exec 一个 argv 数组**，不拼字符串 |
| ③ | 什么都不试，只打印 `URL: <地址>` | rc 恒 0 |

- 环境变量：`DSH_HARNESS_OPENER=<命令名>` 覆盖第①②档（**只换命令，URL 仍是 argv** ——
  测试就靠它桩掉）；`quiet` / `none` / 空 = 第③档。`DSH_HARNESS_OPEN_ROOT=<npx 缓存目录>`
  显式指定 `open` 包在哪；`DSH_HARNESS_OPENER_LOG=<文件>` 把"本来要 spawn 什么 argv"记一行
  （现场排障 / 证明 URL 没被转换）。
- **为什么"打不开浏览器"不算失败**：这个命令的职责是"让会话起来 + 把地址给出来"；
  浏览器只是顺手。opener 全缺（服务器、容器、minimal WSL）时因为开不了浏览器而 rc≠0，
  会让 `harness && …` 这种用法莫名其妙地断掉。所以只多打一行提示。
- **打开的地址**：优先 `$DSH_REMOTE_STATE_DIR/web-url.txt` 里那份（带 token，本机可直接用），
  但**只在该文件里的端口 == 本次端口时**才用（不然会拿上一个实例的死 token，H22）；
  否则 `http://127.0.0.1:<端口>/` —— 浏览器通常已经有 30 天 cookie（H22 的实测结论）。

### 3. 输出 ≤3 行（有意的硬限制）

```
harness: dsh web 已在跑 ✓  http://127.0.0.1:3082/（PID 268102，手工起的）
URL: http://127.0.0.1:3082/
harness: 已用 node + open 包 打开浏览器
```

**放弃的东西**（记在这里，免得下一个人以为是漏了）：手机固定地址那一行、token 实测那一行
（原来要 `curl` 打一次看 401/303）、"想让它开机自动起"的提示。这些都是 ADR-0020 那份
契约里的，按用户"就是这么简单"的口径砍掉；**要体检走 `harness-remote status` 或
`dsh-remote tunnel-status --probe`**。

### 4. 新增 `harness-remote`（云上那半；薄封装 + 子命令）

`bin/harness-remote` 是**薄封装，不写第二套逻辑**：每条子命令都转发给已经存在、已经测过的
`dsh-remote` 子命令，只做三件这里才有价值的事：压行、开浏览器（同一套 opener）、
说清云上地址是哪来的。边界就这么大 —— 它**不**管家里那半（那是 `harness`），
**不**直连云上（云上的操作只有 `dsh-remote cloud-install` / `server` 会做），
**不**允许 `reset` 带 `--restart-web`（ADR-0022 的唯一例外必须人在机器上显式敲）。

| 子命令 | 做什么 | 退出码 |
|---|---|---|
| `status` | ≤6 行：隧道(+云上两个 `-R` 口)/broker(+token 新鲜度)/web/入口(+公网 HTTP)/容器(`dsh-relay`)/结论+下一步。数据来自 `dsh-remote tunnel-status --probe` + `dsh-remote force-restart-dsh-remote --json`（**只复用它俩的输出**）+ 一次只读 `ssh … docker ps` | 0 |
| `open` | 打印并打开 `https://<host>:<port>/`（`public_url` 有就用它；否则 `cloud_host` + `public_port`，默认 8443） | 0 |
| `reset` | `exec dsh-remote force-restart-dsh-remote`（**安全档**）。带 `--restart-web`/`--yes` = 直接拒绝并指路 | 0 / 1 |
| `passwd` | `exec dsh-remote passwd "$@"`（**原样转发**，包括 `--dry-run`） | 转发 |
| `url` / `qr` | 只打印固定地址 / 二维码文件路径 | 0 / 1 |

每条子命令都认 `-h` / `--help`（打这一页；`passwd --help` 也不转给下游 ——
`dsh-remote passwd` 自己没有 `--help`）。

`DSH_REMOTE_BIN=<路径>` 指定被转发的 `dsh-remote`（默认兄弟 `bin/dsh-remote`，再退 PATH）——
测试就靠它把真命令换成桩。安装落点：`scripts/install.sh` 把它软链进 `$WTOOL_PREFIX/bin`
（和 `dsh-remote-server` / `dsh-force-restart-dsh-remote` 同一个模式）。

## 否决的方案

- **继续用 ADR-0020 的四态输出 + 等 20 秒**：用户明确说"不许再有等 20 秒那种行为"。
  那套东西的**判断**（先看端口再看 systemd）没丢 —— 它现在活在 `harness-remote status`
  和 `dsh-remote tunnel-status --probe` 里。
- **`harness` 之外再做一个用户可见命令**：用户点名只要两条（`harness` + `harness-remote`）。
  本地那半必须是**函数**（env 里），云上那半是**命令**（bin 里）。
- **opener 用 `cmd.exe /c start "" <url>`**：WSL 下会被路径转换毁掉 URL（上面那段实测）。
- **把 `open` 包 vendor 进仓库**：仓库只放文本（AGENTS.md 的规矩），第三方代码/二进制不进 git；
  所以是"运行时去 npx 缓存里找 `open/index.js`"，找不到就退下一档。
- **`harness` 里保留 `DSH_REMOTE_HARNESS_NO_REUSE=1`**：那个阀的语义是"再起一个"，
  正是这次要禁止的行为。它的测试用途由 `DSH_REMOTE_HARNESS_UNIT=<不存在的单元>` 取代。

## 判据 / 后果

- "有则开、无则起"的判据（3082 真跑，2026-10-09 实测）：端口上那个 PID 前后**同一个**；
  桩 opener 收到的第一个参数**逐字节**等于 `http://127.0.0.1:3082/`（`argc=1`）；
  真 `open` 包那一路开出了 Chrome 新标签（进程表里多一个 renderer）。
- 回归测试在 `tests/run_tests.sh` 的 **O 节**（79 条：六种情形 + opener 三档）与 **Q 节**
  （65 条：`harness-remote` 六个子命令 + 每条 `--help`，全用桩）。整套 **684 通过 0 失败**。
- 代价：`harness` 不再告诉你 token 是否还有效、手机地址是什么。**要知道就再敲一条命令**
  （`harness-remote status`）—— 用户选了"短"。
