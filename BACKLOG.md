# BACKLOG —— tools/dsh-remote

> 这个文件是这个项目"接下来做什么、做到哪了"的**唯一权威**。
> 引擎/跨项目的事在 `~/self/wtool/harness/BACKLOG.md`，别混。
>
> 状态：⬜ 待做 · 🔄 在做 · ✅ 做完（写清怎么做的、验证到什么程度）· ⏸ 待决定（要人来拍）
>
> 任务**从这个文件来**，不从 ADR 标题来。现状看 `architecture.md`，
> 决策理由看 `docs/adr/`，踩过的坑看 `docs/hazards.md`，流水看 `journal.md`。

---

## 🔴 仍未做 / 未验证（一览，2026-10-07 盘点）

> 用户 2026-10-07 原话："之前写了一半，我没有做任何测试。"
> ——**本机自动测试是跑过的**（`sh tests/run_tests.sh` → **268 通过 0 失败**，2026-10-07 实跑），
> 真机端到端也在 2026-10-07 当天走通了（中继 + 公网 + 常驻隧道）。
> 下表是"还剩什么"的全集，展开在后面的小节里。

| # | 状态 | 事项 | 一句话 |
|---|---|---|---|
| U1 | 🟢 | **真机端到端**（往下拆成 U2/U3/U5） | 2026-10-07 中继在真阿里云上装成，**从家里经公网 8443 已经走通到家里的 dsh web**；还差真手机打开（带 token） |
| U2 | 🟢 | **云端落地步骤** | IP 模式已在真机跑通（`--no-compose` 用户空间模式）；**8443 从外面已经能连**（11:52 还连不上、12:03 通了，见下面那节） |
| U3 | ✅ | **隧道常驻 / 断线重连** | 2026-10-07 做完：`dsh-tunnel.service`（systemd `--user`，`Restart=always` + `ServerAlive*`）替掉一次性 tmux；**实测 `kill -9` 之后 3199ms / 3207ms 拉起进程、3276ms / 3305ms 公网恢复**（两次）；详见下面 U3 那节 |
| U4 | ⏸ | **钩子桥未证实会触发** | `check-hooks` 复查：触发 → 0，没触发 → 1；两条出路要用户选 |
| U5 | ⬜ | **要 docker 的测试只能人工跑** | `caddy-validate.sh`（3 条）、`relay-e2e.sh`（9 条）；**假绿已修**（没 docker → `exit 77`），但"要不要让 D 节也显式挡 docker"仍待定 |
| U6 | ✅ | **三个代码小瑕疵**（2026-10-07 已修） | `status` 提示指错路径 / `help` 输出越界 / docker 测试假绿 —— 三条都改完，见下面 U6 那一节 |
| U7 | ⏸ | 真 `$HOME` 里两条 2026-09-20 的老软链 | 要用户自己重跑一次 `wtool install` 才会纠正 |
| U8 | ⏸ | "源找不到"要不要从警告改成 `exit 1` | 现在选的是"警告 + 继续"，三个仓库口径一致 |
| U9 | ⏸ | `main` 与 `ds_dev` 的差距要不要合 | 助手不合并、不推送，由用户定 |

**明确"没有"的能力**（别当成已有）：会话卡住自动推手机（钩子桥未证实）；
**"网络真断"（ServerAlive 那条路）的重连、重启机器后服务会不会自己起来**（linger 已开、
单元已 `enable`，但没重启过机器）；真机上的安全组/防火墙/证书续期的任何验证。

---

## 🟡 2026-10-07 中继第一次真装到阿里云（装成了；安全组还差一步）

**在哪台**：`ssh mindul@123.56.158.212`（Ubuntu 26.04、`sudo -n` 免密、docker 有但要 `sudo`、
**没有 compose 插件**、80 被 nginx 占着）。服务器事实与用户三条硬约束记在
`harness/dsh-conf/AGENTS.md` 的「阿里云中继服务器」一节（提交 `0406ddd`）。

**怎么装的**（每一步都是在真机上跑的）：

| # | 做了什么 | 结果 |
|---|---|---|
| 1 | `mkdir -p /home/mindul/dsh-relay/{data,config,logs}`（700） | 文件只在 `/home/mindul/dsh-relay/`，符合用户约束 |
| 2 | 本机 `sh cloud/relay.sh --ip 123.56.158.212 --port 8443 --password <20位> --dry-run` | 渲染 + **本机镜像里 `caddy validate` 通过**；stdout 就是 Caddyfile |
| 3 | `sudo docker run -d --name dsh-relay --network=host … caddy:2` | ❌ **失败**：mirror 给的 `caddy:2` 是 v2.4.6，`unrecognized directive: basic_auth`，容器无限重启 |
| 4 | 查出根因（镜像 4 年前）→ 改代码：钉 `caddy:2.11.4` + `Caddyfile.ip` 加 `default_sni` + `relay.sh` 加 `--no-compose/--dir/--docker-cmd` | 见 ADR-012、hazards H13；本机 `sh tests/run_tests.sh` → **199 通过 0 失败** |
| 5 | 再试 `caddy:2.11.4` | ❌ **还是失败**：不是配置错，是**没有 SNI 就选不出证书**（`internal error`）→ 第 4 步的 `default_sni` 修的就是这个 |
| 6 | 把改完的 `cloud/` 传上去，用**项目自己的脚本**重装：<br>`sh relay.sh --ip 123.56.158.212 --port 8443 --no-compose --dir /home/mindul/dsh-relay --docker-cmd 'sudo docker'` | ✅ **装成**：容器 `dsh-relay` Up（`caddy:2.11.4`，`--restart unless-stopped`）；脚本自检打印 `https 入口：401（basic auth 在挡着）✓` 和 `隧道出口：401 ✓` |
| 7 | 家里在 tmux（会话 `dsh-tunnel`）里起 `ssh -N -T -E /tmp/dsh-tunnel.log -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o TCPKeepAlive=yes -R 127.0.0.1:18080:127.0.0.1:3080 mindul@123.56.158.212` | ✅ 云上 `127.0.0.1:18080` 开始听；经 Caddy 带密码访问，**回的是家里 dsh web 的 401 原文**（`dsh web authentication required; reopen the URL printed by dsh web.`）→ 证明反代真的到了家里 |
| 8 | 从家里打公网 `https://123.56.158.212:8443/` | ❌ **11:52 时超时**（绑到 eth1 绕开本机 Clash 后 40s 无连接；同一路径打 80 端口 0.03s 就 200）→ 当时判定**安全组没放行 8443** |
| 9 | **12:03 复测同一条路径** | ✅ **通了**：连打 3 次都是 `connect≈0.02s / 401`；带密码拿到的 body 是**家里 dsh web 的 401 原文**；不带密码是 `401 + WWW-Authenticate: Basic realm="restricted"`（Caddy 在挡）→ **从公网到家里这条链路已经完整走通** |

**关于第 8→9 步的变化**：中间没有人通知改了什么东西，**助手没有动安全组 / 防火墙**（那是禁区）。
两次观测都是同一条命令、同一条路径（`curl -sk --interface eth1`，SO_BINDTODEVICE 绕开本机 Clash TUN），
差别只在时间 —— 结论只能写到这一步：**11:52 时外面连不上、12:03 时外面能连上**
（大概率是用户自己在阿里云控制台把 8443 放行了；助手没有见证这个动作）。
所以"安全组"这条**按"已放行"记**，但**没人核对过控制台里的规则原文**（来源段是不是只放了手机出口 IP，不知道）。

**密码落在哪**：云上 `/home/mindul/dsh-relay/relay-password.txt`（**600**，里面有 URL / 用户名 /
密码，以及"怎么改密码"三步）。仓库里没有密码（`git ls-files` 可验）。

**✅ 已经能用的判据**（2026-10-07 12:03 从家里实测）：

```sh
# 不带密码 → Caddy 的 401（有 WWW-Authenticate: Basic realm="restricted"）
curl -sk -D - -o /dev/null https://123.56.158.212:8443/
# 带密码 → 401 + 家里 dsh web 的原文（说明反代真的到了家里）
curl -sk -u dsh:<pw> https://123.56.158.212:8443/
#   → dsh web authentication required; reopen the URL printed by dsh web.
```

⚠️ **必须是 https**：8443 上只有 TLS，`http://123.56.158.212:8443` 实测回 **400**。

**⬜ 还差的最后一步（只有用户能做）**：手机上打开
`https://123.56.158.212:8443` → 过自签证书警告 → 输 basic auth（`dsh` / 见上面那个文件）
→ **再贴一次 `dsh web` 打印的带 token 地址**（token 只在用户浏览器的地址栏里；
这台实例不是 `dsh-remote serve` 起的，`~/.local/state/dsh-remote/web-url.txt` 是空的）。
带 token 之后能不能出界面、流式刷新正不正常 —— **没验过**。

**还没做的**：真手机打开（上面那条）；域名模式（`--domain`）一次没跑过；
安全组规则原文没人核对。（隧道常驻与重连时长已在同日做完，见下面的 U3。）

---

## ✅ 建立 wsw 文档体系（2026-10-07）

**为什么**：用户 2026-10-07 要求"重新看下这个项目的设计文档，调整此文档为此 git
项目自己的文档，文档标准按 `~/.dsh/AGENTS.md` 里的【wsw 文档体系】来"。

**做了什么**（全部在 `tools/dsh-remote/` 内，只改这一个仓）：

- 新增 `architecture.md`：**只写现状**，逐行核对代码后写成 —— 14 个子命令的真实行为、
  `dsh-notify` 的三种模式与 provider 表、`install.sh` 的契约变量与"源找不到"语义、
  `relay.sh` 的两种模式与 7 步流程、两个 Caddyfile 与 compose 的实质内容、
  配置字段与环境变量总表、四个测试文件各测什么/多少条/要什么。
- 新增 `docs/adr/`：索引 + **ADR-001…011**（云上 Caddy+反向隧道、容器化 + 命名卷、
  域名/IP 两种模式、basic auth、`dsh web` 只绑回环、hook 桥与"未证实"的记录方式、
  `install.sh` 只认契约变量、Host/Origin 改写、配置不放 `~/.dsh`、推送恒 0 退出、
  `relay.sh` 的 stdout 约定）。
- 新增 `docs/hazards.md`：**H1…H12**（每条：现象 → 根因 → 修法 → 判据/复现 + 验证程度）。
- 新增 `journal.md`（可选第六类）：把 `13734e3` / `7388984` / `f8da57c` / `b68e491` /
  `bc5c797` 几个关键提交按日期与判据记下来。
- 更新 `AGENTS.md`（文档地图 + 加载顺序 + 交付方式 + 本项目硬规矩）、`README.md`
  （订正与代码不符处，见下）、本文件。

**验证到什么程度**：

- `sh tests/run_tests.sh` → **185 通过 0 失败**（2026-10-07 晚复跑；当时是 179 通过 —— 
  后来的 U6 修复加了 6 条断言）；逐节 A 10 / B 6 / C 22 / D 21 /
  E 45 / F 14 / G 8 / H 6 / I 53；跑完真 `$HOME` 指纹不变那条断言是绿的。
- 文档里的每个"现状"都对着代码核过；与 README/AGENTS 的旧说法冲突处**按代码改文档**
  （README 共 10 处 + AGENTS 加了文档地图/硬规矩，逐条列在提交信息里；
  例如 README §5.6 原来写 `systemctl stop caddy`
  —— 云上是容器，没有这个服务，见 hazards H7）。
- 全程没跑 docker 测试、没联网、没碰云上、没在真 `$HOME` 上装东西
  （唯一一次碰 docker 是 `run_tests.sh` 的 D 节自己经 `relay.sh --dry-run` 调了
  `caddy validate`，镜像本地已有、没拉、没留容器；口径已写进 hazards H8）。

**还剩什么**：文档体系本身没有遗留；**U1–U9 一条都没解决**（这次只动文档）。

---

## ✅ install.sh 写死引擎内部布局 —— "报成功却什么都没装"（2026-10-04 修）

**现象**（临时环境里实测复现，改前的脚本）：

```
tools/dsh-remote: 警告：找不到 .../home/.wtool/wtool-work-dir/links/tools/dsh-remote/bin/dsh-remote（wtool 的稳定链接还没建好？）
tools/dsh-remote: 警告：找不到 .../home/.wtool/wtool-work-dir/links/tools/dsh-remote/bin/dsh-notify（wtool 的稳定链接还没建好？）
tools/dsh-remote: 软链 .../xdg-conf/dsh-remote -> .../prefix/etc/dsh-remote
tools/dsh-remote: 布局：
tools/dsh-remote:   命令      .../prefix/bin/{dsh-remote,dsh-notify}
...
（exit 0）
$ ls -l .../prefix/bin
total 0                                  ← 一条命令都没有
```

它还会把**空目录**的配置/日志软链铺好、打一份"布局"总结 —— 装完看起来和装好了
一模一样，`wtool` 那边照样报 `install 完成`。这台机器上的现状正好是这个病的活标本：
引擎现在的 `~/.wtool/wtool-work-dir/links/` 根本不存在，而 `~/.wtool/usr/bin/`
里那两条 Sep 20 的软链还指着**更老**的一格 `~/.wtool/links/tools/dsh-remote/bin/*`。

**根因**：`scripts/install.sh:31` 把"源"写死成引擎的内部布局
`link_dir="$HOME/.wtool/wtool-work-dir/links/tools/dsh-remote"`
（`bootstrap/lib/wtool_plan.py` 的 `WORK_DIR_NAME`），第 96/112 行拿它当源。
两种情况下立刻指丢：① `WTOOL_HOME != $HOME`（影子家 / 临时家 / 测试）—— 中转链接
建在 `$WTOOL_HOME/.wtool/...`，脚本却去真家目录那格找；② 引擎以后再挪一次那一格
（2026-09-23 已经挪过一次，`tools/android_repack` 就是在那一挪之后坏掉的）。
而检查是"源不存在就 `continue`"，于是整轮静默跳过。
同一个病在 `tools/android_repack`（`14bf463`）和 `harness/dsh-conf`（`977101b`）
上修过 —— **这是最后一处**。

**改动**（`f8da57c`，都在 `ds_dev` 上）：

1. `scripts/install.sh`：
   * 源 = **`WTOOL_PROJECT_DIR`**（引擎对项目脚本的契约，见 `bootstrap/wtool.sh` 的
     `wt_run_project_script`：`export WTOOL_PROJECT_DIR="$_rs_dir"`），手跑时按 `$0`
     自推 `<项目>/scripts/..`；
   * 落点 = `WTOOL_PREFIX`（默认从 `WTOOL_HOME` 推）、`~/.config` / `~/.local/state`
     的默认值也从 `WTOOL_HOME` 推（XDG 显式设了就用 XDG）；
   * 某条源找不到 = **只跳过那一条** + 打印"找的地方：…（来自 WTOOL_PROJECT_DIR）"，
     末尾还要交代跳过了几条；只有真要装才 `mkdir`（源找不到时连空目录都不建）；
   * 往 `$WTOOL_PREFIX/bin` 里放东西时，**已存在且不是软链就警告跳过**，不覆盖。
2. `env.zsh` / `env.bash`：单独 source 时的兜底从写死 `$HOME/.wtool/...` 改成
   `${WTOOL_HOME:-$HOME}/.wtool/...`（同一个病：换影子 HOME 就指错）。
3. `tests/run_tests.sh` 新增 **I 节**（五个场景，见下）。
4. `README.md`（§2 第 0 步、§4 新增一段"安装脚本为什么不自己拼路径"、§6 测试、
   §7 占地与清理重写；顺手订正了三处过期路径：`hooks.json` 在配置目录、
   `web-url.txt` / `notify.log` 在 state 目录）、新建本仓库的 `AGENTS.md` / `BACKLOG.md`。

**复现**（临时环境，不碰真 `$HOME`；`$T` 是临时目录）：

```sh
# 改前：源写死在 $HOME 下的影子 HOME，换 WTOOL_HOME 就找不到
HOME=$T/home WTOOL_HOME=$T/home WTOOL_PREFIX=$T/prefix WTOOL_PROJECT_DIR=$PWD \
  XDG_CONFIG_HOME=$T/conf XDG_STATE_HOME=$T/state sh scripts/install.sh
#   → 警告两条 + exit 0 + $T/prefix/bin 是空的
# 改后：同样一条命令 → 已链接 $T/prefix/bin/dsh-remote -> <项目>/bin/dsh-remote（两条都装）
```

**验证到什么程度**：

* `sh tests/run_tests.sh` → **179 通过 0 失败**（改前基线 **126** 条，本次 +53）。
  I 节全部用临时 `HOME` / `WTOOL_HOME` / `WTOOL_PREFIX` / `DSH_HOME` /
  `XDG_CONFIG_HOME` / `XDG_STATE_HOME`，五个场景：
  ① 引擎调用（`WTOOL_PROJECT_DIR`；引擎内部那格故意埋一份**假的**可执行文件，
  还从那儿取源就会挂）② 手工跑按 `$0` 自推（cwd 在别处 / 相对路径两种）
  ③ 换 `WTOOL_HOME` 装到别处（落点跟它走，真 `$HOME` 一个东西都不多）
  ④ 源找不到（只跳过、说清去哪儿找、**一个字节都不写**）⑤ `--uninstall` 撤干净
  （软链撤掉、配置/日志实体留着）。跑完比对真 `$HOME` 的指纹
  （`.zshrc` / `.bashrc` / `.config/dsh-remote` / `.local/state/dsh-remote`，
  `stat -c '%F|%s|%Y'`）**逐字不变**；另有 `grep -F` 断言守着
  "`scripts/install.sh` / `env.zsh` / `env.bash` 里不许出现 `$HOME/.wtool/...` 字面量"。
* **反证**（证明这 53 条不是永远绿的摆设）：把改前的 `scripts/install.sh` /
  `env.zsh` / `env.bash`（`git show HEAD:...`）放进仓库副本，用**同一份新用例**
  跑 → **148 通过 31 失败**（exit 1）。挂掉的正是 I 节那批（命令没装出来、
  软链指到埋的假链接、`$WTOOL_HOME` 场景全挂、源找不到时还铺了空目录软链、
  `grep -F` 三条）。
* **引擎端到端**（全临时环境：`HOME` / `WTOOL_HOME` / `WTOOL_STATE` / `WTOOL_ROOT`
  全指临时目录，`env -i`）：`wtool install tools/dsh-remote` → exit 0，
  `$WTOOL_HOME/.wtool/usr/bin/{dsh-remote,dsh-notify}` 指向临时工作区里的项目目录，
  配置/日志软链 + 两份样板都到位；`dsh-remote help` / `status` 退出 0；
  `wtool uninstall tools/dsh-remote` → 软链撤掉、实体留着。
* 真 `$HOME` 没被碰：11 条真路径（rc 文件、两条配置软链、`~/.wtool/usr/...`）
  在**整轮测试 + 上面那些临时实验**前后 `stat` 逐字相同。
* **2026-10-07 复跑**：`sh tests/run_tests.sh` 仍然 **179 / 0**。

**还剩什么**：

* ⏸ 这台机器上那两条 **Sep 20 的老软链**（`~/.wtool/usr/bin/dsh-remote` →
  `~/.wtool/links/tools/dsh-remote/bin/dsh-remote`，老布局）还留着。
  修好之后重跑一次 `wtool install tools/dsh-remote` 会把它们纠正到新落点 ——
  **这是用户自己在真 `$HOME` 上跑的动作，助手不代跑**（当前 `dsh-remote` 走
  `~/.local/bin/dsh-remote` → 工作树，所以命令本身是可用的）。
* ⏸ 要不要让"找不到源"变成**真失败**（`exit 1`）而不是警告 + 继续：现在选的是
  "警告 + 继续 + 末尾交代跳过了几条"，因为脚本失败会把整个 `wtool install`
  拉下水；坏处是它仍然是"半装"。三个仓库现在口径一致（都选了警告）。
* ⏸ `main` 与 `ds_dev` 的差距要不要合 —— 由用户定（助手不合并、不推送）。

---

## ✅ `wtool.xml` 跟上引擎：`id=` 已取消 + `<env>` 旧标签（2026-10-04 修）

**怎么发现的**：做上面那条的**引擎端到端**验证时，`wtool install tools/dsh-remote`
直接 `exit 2`：

```
wtool: error: wtool.xml 里的 id='tools/dsh-remote' 已经取消：项目身份就是它相对工作区根的路径。
       删掉这个属性即可（.../wtool.xml）
```

`id=` 是**硬报错**（`bootstrap/lib/wtool_plan.py:214-219`，用户 2026-10-04 拍板，
不留兼容窗口）—— 带着它，`scripts/install.sh` **根本没机会跑**，上面那条修复
也就用不上。工作区里其它项目（`android_repack` / `dsh-conf` / `astronvim_v5` /
`git-repo-sh-tools` …）都已经删掉了，只剩 `tools/dsh-remote` 和 `terminal/tmux`。

**改动**：`wtool.xml` 删掉 `id="tools/dsh-remote"`；顺手把旧标签
`<env src= shells=>`（每次解析都告警）换成 `<zshrc src="env.zsh"/>` +
`<bashrc src="env.bash"/>`（和别的项目一致，`env.zsh`/`env.bash` 两份不变）。

**验证**：`wtool validate tools/dsh-remote` → 改前 `error: ... id=... 已经取消`（exit 1），
改后 `ok: tools/dsh-remote`（exit 0，无告警）；随后上面那套引擎端到端跑通。

**还剩什么**：

* ⏸ `terminal/tmux/wtool.xml` 有**一模一样的两个问题**（`id=` + `<env>`）——
  那是另一个仓库，本次不动；`tools/gerrit-gate` 用户明确说不动（已废弃）。

---

## ⏸ U1/U2 真阿里云那台要不要现在装 + 落地步骤（待用户决定）

**先记清楚事实**：**端到端从未真跑过**。跑过的只有本机的 179 条自动测试
（`cloud-install` 只用**假的 ssh/scp** 验了参数拼装；`relay.sh` 只在
`--dry-run` 里渲染 + 用 `caddy:2` 校验过配置）。真机器上会发生什么，没有任何记录。

**要不要装、什么时候装、用哪条路 —— 用户定。** 三个选项：

1. **先不装**：本机已经把能验的都验了（179 条），云端留到需要出门时再说。
2. **只做域名模式**（有域名且已备案）：对外 443 + Let's Encrypt。
3. **IP 模式**（没域名 / 没备案）：`--ip <公网IP> --port 8443`，自签证书，
   手机第一次点一次"继续访问"。

**落地步骤**（助手不代跑；每一步都要用户点头才动云上）：

```sh
# ① 家这头：填 remote.conf（cloud_host / cloud_user / cloud_ssh_port / identity）
cp ~/.config/dsh-remote/remote.conf.example ~/.config/dsh-remote/remote.conf

# ② 一条命令装到云上（走域名模式；IP 模式见下）
dsh-remote cloud-install --domain dsh.example.com --email me@example.com
#   IP 模式：dsh-remote cloud-install --ip <公网IP> --port 8443
#   想先看它要干什么：加 --dry-run
#   等价手工（cloud-install 内部就是这两条）：
#     scp -r cloud/ root@<host>:/opt/dsh-relay
#     ssh -t root@<host> 'cd /opt/dsh-relay && sudo sh relay.sh --tunnel-port 18080 --domain …'

# ③ 阿里云控制台安全组：只放行 22/tcp（限家里出口 IP）+ 443/tcp（或 8443/tcp）
#    ⚠️ 隧道端口 18080 和 harness 端口 3080 **绝对不要开**

# ④ 家这头把隧道装成常驻（断了会自己回来）；先前台调试就用 dsh-remote tunnel
dsh-remote tunnel-install  # systemd --user 常驻：Restart=always + ssh 保活
dsh-remote tunnel-status --probe   # 体检（含云上只读检查）；dsh-remote url 打印手机地址
```

**还没定的细节（要用户拍）**：

- 域名与备案：大陆机器 80/443 要备案；没备案就走 IP 模式（或把机器放境外）。
- 云上那台是不是就用 `root` 做隧道用户；建议给隧道专用一把钥匙 + `authorized_keys`
  里 `restrict,port-forwarding,permitlisten="127.0.0.1:18080"`（样板在 `remote.conf.example`）。
- 要不要 `--allow-ip <家里出口IP>/32` 再收紧一层（出口 IP 变了要重跑 `relay.sh`）；
  注意 `relay.sh` 重跑会**重新随机密码**（除非 `--password`）。

---

## ✅ U3 隧道常驻 / 断线重连（2026-10-07 做完并实测）

**用户 2026-10-07 拍板**："加上吧"——常驻用 systemd `--user`（`Restart=always`）+ ssh 自带的
`ServerAlive*`/`ExitOnForwardFailure`，**不依赖 autossh**（本机与云上都没有，装包越界）。
决策与否决项见 **ADR-0013**；现状见 `architecture.md` §3.1。

**做了什么（全部在真机上跑过）**：

| # | 做了什么 | 结果 |
|---|---|---|
| 1 | 新子命令 `tunnel-install` / `tunnel-uninstall` / `tunnel-status`（旧 `systemd` 保留为 `--no-enable` 的同义词） | 渲染 `~/.config/systemd/user/dsh-tunnel.service` → `daemon-reload` → `enable --now`，打印判据；`--dry-run` 一个字节都不写 |
| 2 | 单元：`Restart=always` / `RestartSec=3` / `StartLimitIntervalSec=0`（**在 `[Unit]` 段**）/ `StandardOutput=journal` / `ExecStart` = 绝对路径 ssh + `-N -T -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o TCPKeepAlive=yes -o StrictHostKeyChecking=accept-new -p <port> [-i <key>] -R 127.0.0.1:18080:127.0.0.1:3080 <user>@<host>` | `systemd-analyze --user verify` 无警告；本机 `ss -ltn` 看不到 18080（正常），云上 `ss -ltn` 看到 `127.0.0.1:18080` |
| 3 | 退役旧的一次性 tmux 会话 `dsh-tunnel`：装之前检测 → `kill-session` → 等 1 秒让云上让出端口 | `tmux ls` 里已没有 `dsh-tunnel`；两处端口都被新服务接管 |
| 4 | **断线重连实测**：`kill -9 <MainPID>`（两次） | 新进程 **3199ms / 3207ms** 起来；公网 `curl -sk --interface eth1 https://123.56.158.212:8443/` 恢复 **401** 用时 **3276ms / 3305ms** |
| 5 | **端口冲突实测**（故意造）：先自己起一条占着 18080 的 ssh，再起服务 | journal 出现 `Error: remote port forwarding failed for listen port 18080`，**每 3 秒重试一次**（12 秒 4 次）；把占端口的那条杀掉 → **760ms** 服务接上（见 hazards H14） |
| 6 | `tunnel-status --probe` 体检 | 单元/进程/端口/云上 `ss`/`curl`（401 = 请求穿到家里）/linger 全绿 |
| 7 | 顺带订正的配置（真机事实，见 hazards H16 / H17） | `remote.conf`：`cloud_user=root`→`mindul`、`identity=~/.ssh/id_rsa`→`~/.ssh/id_ed25519`、`public_url` 填上；云上 basic auth 密码按文件里的值重渲染（12:05 验通） |

**判据（怎么证明常驻是真的）**：

```sh
systemctl --user is-active dsh-tunnel.service     # active
systemctl --user is-enabled dsh-tunnel.service    # enabled
systemctl --user show -p MainPID -p NRestarts --value dsh-tunnel.service
ssh mindul@123.56.158.212 'ss -ltn | grep 18080'  # 云上 127.0.0.1:18080 在听（只读检查）
curl -sk --interface eth1 https://123.56.158.212:8443/   # 401（Caddy 在挡）
dsh-remote tunnel-status --probe                  # 一条命令看全
```

**验证到什么程度 / 没验什么**：

- ✅ 进程被杀 → 重连（两次，秒级数字在上面）；端口冲突 → 自愈（760ms）。
- ✅ 公网端到端：不带密码 401（Caddy）、带密码拿到**家里 dsh web 的 401 原文（68 字节）**
  → 反代真的到了家里（12:05 实测）。带 token 的 200 界面要用户浏览器里的 token，**没验**。
- ✅ `sh tests/run_tests.sh` → **268 通过 0 失败**（新增 J 节 69 条，全是离线断言）。
- ✅ `loginctl enable-linger mindul`（**本机实测不需要 sudo**，polkit 允许 self-linger），
  用户管理器随之起来 —— 在这之前本机 `systemctl --user` 根本连不上 bus（hazards H15）。
- ⬜ **"网络真断"那条路没测**：ServerAlive 要 15s×3 才发现 + 3s 重启，理论上 ≤48s 回来，
  但没有真拔网线/换网络复测过。
- ⬜ **重启机器后是否自动恢复没测**（linger=yes、`enabled`、`WantedBy=default.target` 都到位，
  没人重启过这台机器）。
- ⬜ 真手机打开公网地址（带 token）仍然没验（U1 剩下的那一条）。

---

## ⏸ U4 钩子桥未证实会触发（复查命令在这里）

**现状**：`notify-enable` 写的 profile patch 能让 `dsh --profile web --dump-config`
里出现 `hooks-claude-code`，但 2026-09-21 的对照实验表明**插件没有被真正加载**
（`configPath` 指到不存在的文件也不报错；一次性 headless 会话三种钩子一个都没触发；
正在跑的实例十几轮没写日志）。细节与已排除的可能写在 `architecture.md` §9、
`docs/hazards.md` H3、`README.md` §4。

**一条命令复查**（一次性进程、不动正在跑的会话、会真调一次模型、几十秒）：

```sh
dsh-remote check-hooks     # 触发 → 退出码 0；没触发 → 1，并打印两条出路
```

**两条出路（用户选）**：

- **A（官方路子，要重启 harness）**：`npm i -g pnpm && dsh plugin --profile web add
  @deepseek-ai/dsh-hooks-claude-code`，然后重启 `dsh web`（**会打断正在跑的会话**），
  再跑一次 `check-hooks`。
- **B（先不折腾桥）**：推送通道本身是通的（`dsh-remote notify-test` 实测能到本地接收端，
  测试里也真发过）；需要"卡住就提醒"时手动 `dsh-notify "…" "…"`。

**在证实之前**：不许把"会话卡住会推手机"写成已有能力（ADR-006）。

---

## ⬜ U5 人工验收清单（要 docker / 要两台机器 / 要手机）

**要 docker 的两条**（助手不代跑；本机 `/usr/bin/docker` 有、`caddy:2` 镜像本地已有）：

```sh
cd tools/dsh-remote
sh tests/caddy-validate.sh    # 3 条：两个模板各 caddy validate 一遍 + 一条"坏配置必须被拒"的反证
sh tests/relay-e2e.sh         # 9 条：真起 caddy 容器（host 网络）+ 假后端，
                              #   验 401 / 200 / body 来自后端 / Host 改写成回环 / 密码错 401 /
                              #   compose down -v 撤干净（跑完自己收摊）
```

⚠️ **没 docker 时这两条打印"跳过"并 `exit 77`**（跳过码 —— 2026-10-07 由 `exit 0`
改来，见 hazards H8）—— 所以 `77` 是"**没测**"，别当通过。

**要两台机器 / 要手机的（2026-10-07 更新）**：

- 🟡 真阿里云上 `relay.sh --ip` **已跑通**（`--no-compose` 用户空间模式，见上面那节）；
  `--domain`（Let's Encrypt）**一次没跑过**；
- ⬜ 真 Let's Encrypt 签发 + 续期（`docker compose logs` 看 ACME 日志）；
- ⬜ **真手机浏览器**：第一次 basic auth + 贴带 token 的地址 + 会话能流式刷新
  —— 要用户拿手机；**前置条件：安全组先放行 8443**；
- ✅ 隧道断开→恢复的真实时长：**2026-10-07 实测 3199/3207ms 拉起、3276/3305ms 公网恢复**（`kill -9`，两次；见 U3）；
- ⬜ 手机丢了/要断入口：`docker rm -f dsh-relay`（用户空间模式）或
  `docker compose -f /opt/dsh-relay/docker-compose.yml down`
  （**不是** `systemctl stop caddy`，见 hazards H7）。

**仍待用户拍的一条**：要不要让 `tests/run_tests.sh` 的 D 节也**显式挡住 docker**
（现在装了 docker 就会真跑一次 `caddy validate`，只把话写在文件头了）。

---

## ✅ U6 三个代码小瑕疵（2026-10-07 用户批准"按建议改" → 已修）

| # | 在哪 | 原现象 | 实际怎么改的 |
|---|---|---|---|
| 1 | `bin/dsh-remote` 的 `status` | 没配推送时提示"照 notify.conf.example 写 **`~/.dsh/notify.conf`**"，而落点是 `~/.config/dsh-remote/notify.conf`（只有 `migrate` 会读 `~/.dsh`） | 提示改成 `$CONF_DIR/notify.conf`（hazards H9） |
| 2 | `bin/dsh-remote` / `bin/dsh-notify` 的 `usage()` | `help` 打 `sed -n '2,25p'`，多打 `set -u` 和两行注释（注释块只到 21 行）；`dsh-notify --help` 是 `2,20p`，把"退出码永远是 0"那段截断 | 两处都改成**算范围**：`awk 'NR == 1 { next } /^#/ { print; next } { exit }' "$0" \| sed 's/^# \{0,1\}//'`（hazards H10） |
| 3 | `tests/caddy-validate.sh`、`tests/relay-e2e.sh` | 没 docker 时"跳过"并 `exit 0`，CI/`&&` 链里算通过 | 没 docker → **`exit 77`**（跳过码）（hazards H8） |

**验证到什么程度**（2026-10-07 实测）：

- `sh tests/run_tests.sh` → **185 通过 0 失败**（A 10 / B 6 / C 22 / D 21 / E 45 / F 14 /
  G 8 / H 6 / I 53）。比修复前多 6 条，全是新加的**回归断言**：
  C 节 `--help` 要含"失败只写一行到"、不含 `set -u`；E 节 `help` 不含 `set -u`、
  `tail -1` 就是注释块末行、`status` 提示落在 `$DSH_REMOTE_HOME/notify.conf`、
  且不再出现 `~/.dsh/notify.conf`。
- 两条 docker 脚本的 77 用 H8 那条 shim 复现（**不碰真 docker**），两个都实测 rc=77。
- ⚠️ **第一版修法写错过一次并被抓出来**：`sed -n '2,/^[^#]/p'` 里空行不匹配 `^[^#]`，
  会多吃一行正文 —— 是新加的那条断言（`tail -1` 必须是注释块末行）抓出来的。
  细节记在 hazards H10 的订正段（**别重犯**）。

**另一条口径也改了**：`tests/run_tests.sh` 文件头原来写"不碰 docker"，实际本机装了
docker 时它的 D 节会经 `relay.sh --dry-run` 真跑 `docker run --rm caddy:2 caddy validate`
（2026-10-07 实测：没拉镜像、没留下容器）。文件头已改成事实
（"不联网、不碰真 `$HOME`" + 另起一段声明 D 节会碰 docker）。
**D 节的行为没动** —— 要不要让它显式挡 docker，仍留在 U5。

---

## ⏸ U7–U9 其余待决定

- ⏸ **U7**：这台机器上两条 Sep 20 的老软链还指着老布局（见上面 install.sh 那节的"还剩什么"）；
  纠正动作是用户自己在真 `$HOME` 上重跑 `wtool install tools/dsh-remote`，助手不代跑。
- ⏸ **U8**：`scripts/install.sh` 的"源找不到"现在是**警告 + 继续 + 末尾交代**，
  要不要改成 `exit 1`（三个仓库现在口径一致，都选了警告）。
- ⏸ **U9**：`main` 与 `ds_dev` 的差距要不要合 —— 助手不合并、不推送。
