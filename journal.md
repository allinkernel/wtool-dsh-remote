# journal —— 操作流水（tools/dsh-remote）

追加式：**新的记录加在文件末尾**，不改写历史条目。
每条只记"谁在哪一轮做了什么、怎么验证的、剩下什么"——
**决策走 `docs/adr/`、待办走 `BACKLOG.md`、现状走 `architecture.md`**，这里都不重复。

---

## 2026-09-20 / 初版（`13734e3`）

**做了什么**：`tools/dsh-remote` 从零落地：手机 → 云上 Caddy（HTTPS + basic auth）→
SSH 反向隧道 → 家里 `127.0.0.1:3080` 这条链路，外加 `dsh-notify` 推送和 hook 桥。
一个提交 18 个文件、2543 行（`git show --stat 13734e3`）：`bin/dsh-remote` 616 行、
`bin/dsh-notify` 236 行、`scripts/install.sh` 130 行、`cloud/relay.sh` 301 行、
两个 Caddyfile 模板 + `docker-compose.yml`、`tests/run_tests.sh` 475 行（当时）。

**怎么验证的**：提交信息与文件头只记了"能跑"；当时的测试规模见
`tests/run_tests.sh` 的文件头，没有留下独立的验证记录。

**遗留**：`scripts/install.sh` 的"源"写死在引擎内部布局上（见 2026-10-04 那条）；
真阿里云 / 真手机从未跑过。

---

## 2026-09-23 / 路径规范：中转软链挪窝（`7388984`）

**做了什么**：引擎把中转软链从 `~/.wtool/links/<项目>` 挪到
`~/.wtool/wtool-work-dir/links/<项目>`；跟着改 `env.zsh` / `env.bash` /
`scripts/install.sh` 各一行（`git show --stat 7388984`：3 文件 3 行）。

**怎么验证的**：当时只做了语法层面；**这次挪动正是 `tools/android_repack` 坏掉的
原因**（源写死旧布局 → 静默什么都没装），而本项目也埋着同一颗雷 —— 见下一条。

**遗留**：`install.sh` 仍然写死"引擎内部布局 + 字面量 `$HOME`"。

---

## 2026-10-04 / 修 `install.sh`："报成功却什么都没装"（`f8da57c`）

**做了什么**：源改用引擎契约变量 `WTOOL_PROJECT_DIR`（手跑按 `$0` 自推），
落点从 `WTOOL_HOME` / `WTOOL_PREFIX` 推，XDG 默认值也跟着 `WTOOL_HOME`；
"某条源找不到"改成只跳过那一条 + 说清去哪儿找 + 末尾交代跳过了几条，
**只有真要装才 `mkdir`**；`env.zsh`/`env.bash` 的兜底同改；
新增 `tests/run_tests.sh` **I 节**（53 条，五个场景）；新建本仓库的
`AGENTS.md` / `BACKLOG.md`，README 的相关段落重写
（`git show --stat f8da57c`：7 文件 +637/-42）。

**怎么验证的**（数字都来自 BACKLOG 与实测复跑）：

- `sh tests/run_tests.sh` → **179 通过 0 失败**（改前基线 126）；
- **反证**：拿改前的脚本跑同一份用例 → **148 通过 31 失败**；
- 跑完比对真 `$HOME` 指纹（`.zshrc` / `.bashrc` / `.config/dsh-remote` /
  `.local/state/dsh-remote`）**逐字不变**；
- `grep -F '$HOME/.wtool'` 在 `scripts/install.sh` / `env.zsh` / `env.bash` 里无输出。

**遗留**：真 `$HOME` 里那两条 2026-09-20 的老软链还在（要用户自己重跑一次
`wtool install` 才会纠正）；"源找不到要不要改成 `exit 1`"待决定。

---

## 2026-10-04 / `wtool.xml` 跟上引擎：删 `id=`、换 `<zshrc>`/`<bashrc>`（`b68e491`）

**做了什么**：删掉 `id="tools/dsh-remote"`（引擎硬报错，留着 `wtool install` 直接
exit 2、`install.sh` 根本没机会跑），旧标签 `<env src= shells=>` 换成
`<zshrc src="env.zsh"/>` + `<bashrc src="env.bash"/>`（`git show --stat b68e491`：
1 文件 4 行改）。

**怎么验证的**：`wtool validate tools/dsh-remote` 改前 `error: … id=… 已经取消`
（exit 1），改后 `ok: tools/dsh-remote`（exit 0、无告警）；随后上面那套
引擎端到端（全临时环境）跑通。

**遗留**：`terminal/tmux/wtool.xml` 有一模一样的两个问题（另一个仓库，没动）。

---

## 2026-10-05 / 文档核对（`bc5c797`）

**做了什么**：README / AGENTS 补"容器/真机安装规矩"，测试条数改成"以输出为准"，
把 `caddy-validate.sh` 的 3 条写清（`git show --stat bc5c797`：2 文件 +14/-3）。

**怎么验证的**：把条数从"写死的数字"改成"以跑出来的 PASS 行为准"——
本轮 2026-10-07 复跑确认 **179** 这个数字仍然对得上。

**遗留**：那时还没有 wsw 文档体系（没有 `architecture.md` / ADR / hazards / journal）。

---

## 2026-10-07 / 建立 wsw 文档体系（本轮）

**做了什么**（全部在 `tools/dsh-remote/` 内，只改这一个仓）：

- 新建 `architecture.md`：逐行核对 `bin/dsh-remote`（14 个子命令）、`bin/dsh-notify`
  （三种模式 + provider 表）、`scripts/install.sh`（契约变量与两种语义）、
  `cloud/relay.sh`（两种模式 + 7 步流程）、两个 Caddyfile、`docker-compose.yml`、
  `hooks/claude-hooks.json`、`env.*`、`wtool.xml`、四个测试文件，**只写现状**。
- 新建 `docs/adr/`：索引 + **ADR-001…011**（云上 Caddy+隧道、容器化、域名/IP 两种模式、
  basic auth、`dsh web` 只绑回环、hook 桥与"未证实"的记录方式、
  `install.sh` 的契约变量、Host/Origin 改写、配置不放 `~/.dsh`、
  推送恒 0 退出、`relay.sh` 的 stdout 约定）。
- 新建 `docs/hazards.md`：**H1…H12**（每条：现象 → 根因 → 修法 → 判据/复现 + 验证程度）。
- 新建 `journal.md`（本文）；更新 `BACKLOG.md`（把"仍未做/未验证"写全并标状态）、
  `AGENTS.md`（文档地图 + 交付方式 + 本项目硬规矩）、`README.md`（订正与代码不符处）。
- 全程**没有**跑 docker 测试、没有联网、没有碰云上、没有在真 `$HOME` 上装东西。

**怎么验证的（判据）**：

- `sh tests/run_tests.sh` → **179 通过 0 失败**（第一次；写文档期间又复跑一次同样 179/0）。
  逐节条数：A 10 / B 6 / C 20 / D 21 / E 41 / F 14 / G 8 / H 6 / I 53。
- `T=$(mktemp -d); DSH_REMOTE_HOME=$T sh bin/dsh-remote status` → 退出 0，
  输出里那行"推送 还没配（照 notify.conf.example 写 **~/.dsh/notify.conf**）"
  就是 hazards H9（代码里的过期提示）。
- `sh bin/dsh-remote help | tail -4` → 多打 `set -u` 和两行注释（hazards H10）。
- 用 shim 目录挡住 docker 跑两条 e2e：
  `PATH="$d" /bin/sh tests/caddy-validate.sh` → `没有 docker，跳过` / **rc 0**；
  `PATH="$d" /bin/sh tests/relay-e2e.sh` → `没有 docker，跳过（这条是人工跑的 e2e）` / **rc 0**
  —— 即 hazards H8 的"假绿"。
- `grep -Fn '$HOME/.wtool' scripts/install.sh env.zsh env.bash` → **无输出**。
- 只读确认（不是跑容器）：`docker images` 里 `caddy:2` 已在本地（两周前）、
  `docker ps -a` 里没有 `dsh-relay`、`cloud/` 里没有残留 `Caddyfile.dryrun`。

**两条要如实记账的事**：

1. `tests/run_tests.sh` 的文件头写着"不碰 docker"，但本机装了 docker，它的 D 节
   会经 `cloud/relay.sh --dry-run` 真跑 `docker run --rm caddy:2 caddy validate`
   —— 本轮因此实际调了 **10 次**（每轮 5 次：第 235/245/252/256/265 行；同一节里
   第 259/262 行那两次在参数校验就退出了）。**没有拉镜像**（镜像早就在本地）、
   **没有留下容器**。口径已按事实改进 README / AGENTS / architecture（hazards H8）。
   —— 这是"文档与代码不一致 → 改文档"的一例（代码没动）。
2. `check-hooks`（会真调一次模型）**本轮没有复跑**，钩子桥"未证实会触发"的现状
   照 2026-09-21 的结论记（`architecture.md` §9、hazards H3）。

**遗留（都在 `BACKLOG.md` 里，用户最关心的那几条）**：真阿里云 + 真手机的端到端
从未跑过；云端落地步骤（`relay.sh --domain/--ip`、安全组、备案）没做；
隧道常驻/断线重连缺实测（本机没 autossh、systemd 只生成不 enable）；
钩子桥未证实；`tests/relay-e2e.sh` / `caddy-validate.sh` 要 docker、只能人工跑；
三个代码小瑕疵（status 文案 / help 越界 / docker 测试假绿）待用户决定要不要改代码。
