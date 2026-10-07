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
| U10 | ✅ | **手机固定地址**（不用再抄 token） | `harness` 函数抓 token + 家里 broker 302 + Caddy 两条 `not`；本机同构 Caddy 实测 302→303→200 与"换 token 后固定 URL 仍可用"（见下面 U10 节） |
| U11 | ✅ | **一条命令装好**（`dsh-remote server` + 二维码） | 自检 → 部署 → 家里两个常驻单元 → 起 harness → 打印固定地址 + 自绘二维码；真机幂等跑通（见下面 U11 节） |
| U12 | ✅ | **用户实测的两条反馈**（二维码太小 / 改密码教程看不懂） | 图片放大到短边 ≥1024px（每模块整数倍、静默区 4）；新增 `dsh-remote passwd` 一条命令改密码（只换那一行哈希）+ `relay.sh` 提示语改一行给全（见下面 U12 节） |

**明确"没有"的能力**（别当成已有）：会话卡住自动推手机（钩子桥未证实）；
**"用真 token 从公网走一遍 302→200"**（要家里的 harness 用 `harness` 函数重启一次才有
token；现在跑着的那个实例是 10-05 起的，token 只在它内存里，读不出来 —— hazards H22）；
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

## ✅ U10 手机固定地址：token broker + `harness` 函数（2026-10-07 做完并实测）

**要解决的问题**：`dsh web` 的 token 每个进程随机、只在内存里（官方没有固定 token /
关鉴权的开关 —— hazards H22），所以"家里重启一次 harness，手机上那个带 token 的地址就作废"。
用户 2026-10-07 要求：手机只访问 `https://<入口>/`（不带 token）也能进，重启 harness 后
不用改链接。做法与取舍见 **ADR-0014**，现状见 `architecture.md` §3.2。

**做了什么**：

| # | 做了什么 | 在哪 |
|---|---|---|
| 1 | `harness` shell 函数（**zsh/bash 两份逐字等价**）：包装 `npx @deepseek-ai/dsh web`，抓启动那行的 token → `current-token.txt`（600）/ `web-url.txt`，退出时删掉 token 文件；source 时 `unalias harness` | `env.zsh` / `env.bash` |
| 2 | `bin/dsh-token-broker`（纯 python 标准库，172 行）：只绑 `127.0.0.1:3081`，`GET /`（不带 token）与 `/go` → 302；没 token / dsh web 没在听 → 503；别的 404/405。**不代理应用流量** | 新文件 |
| 3 | `dsh-remote token-broker` / `broker-install` / `broker-uninstall`（systemd `--user` 单元 `dsh-token-broker.service`） | `bin/dsh-remote` |
| 4 | 隧道多一条 `-R 127.0.0.1:18081:127.0.0.1:3081`（`broker_local_port` / `broker_remote_port` 可配，设 `off` 就不要） | `bin/dsh-remote` 的 `tunnel_argv` |
| 5 | 两份 Caddyfile 加 `@entry`（`path /` + `not query token=*` + `not header Cookie *dsh-auth-*` → broker）与 `@go`；`relay.sh` 加 `--broker-port` / `{{BROKER_PORT}}` / 自检多打一行 broker | `cloud/` |
| 6 | `tunnel-status` 增 broker 段（单元/ token 文件 / 3081 在不在听），`--probe` 增云上 18081 的 302/503 判读 | `bin/dsh-remote` |

**实测（判据全在 `journal.md` 同日条目）**：

- **本机同构 Caddy**（用真 `caddy:2.11.4` 容器 + 同一份模板渲染出来的配置 + 我自己起的
  harness 实例 3090 + 真 broker 3082）：
  `/` 不带 token → **302** `Location: /?token=<值>` → 跟随（303 + Set-Cookie）→ **200 +
  `<title>DeepSeek Harness</title>`**（2 次跳转）；带 cookie 再打 `/` → **200、0 次跳转**
  （证明没有 302 死循环）；没有 token 文件 → 经 Caddy 拿到 **503** 与那句人话。
- **换 token 后固定 URL 仍可用**（本次的核心判据）：杀掉我那台实例、用 `harness` 函数重启 →
  token 从 `flsx0…` 变成 `ibxqL…` → 同一固定 URL **302 到新 token** → 跟随 → 200 + 标题；
  拿旧 token 直连 → 401。老 cookie 跨重启仍然有效（签名密钥是持久的）。
- **真公网**：`https://123.56.158.212:8443/` 带 basic auth、不带 token → **302**
  （`server: dsh-token-broker`，即真的穿过了云上 Caddy + 那条新隧道到家里），
  临时写个占位 token 验的；`/go` 同样 302；把 token 文件删掉 → **503**；
  `/?token=…`（老用法）仍直连 dsh web（401 + 家里 dsh web 原文）。
- **没验的一条**：拿**真 token** 从公网走 302→200 —— 需要用户用新的 `harness` 函数
  重启一次 harness（那个在跑的实例是 10-05 起的，token 读不出来）。手机到手后一条命令就验完。

**测试**：`sh tests/run_tests.sh` → **366 通过 0 失败**（新增 K 节 38 条 / L 节 12 条 / M 节 46 条）。

---

## ✅ U11 一条命令装好：`dsh-remote server` + 二维码（2026-10-07 做完并实测）

**用户 2026-10-07 要的**：一条命令问清信息 → 说清要什么权限并给教程 → 自己部署 →
配账号密码 → 本地起 harness → 给链接/二维码 → 扫码就能用。做法与取舍见 **ADR-0015**，
现状见 `architecture.md` §3.3。

**做了什么**：

- 新子命令 `dsh-remote server`（`bin/dsh-remote-server` 是等价的薄封装）；
  选项 `--host --ssh-user --ssh-port --port --web-user --password --dir --docker-cmd
  --tunnel-port --broker-port --local-port --broker-local-port --yes --dry-run
  --skip-deploy --skip-local --no-harness`。
- **四类自检**（失败就打印"怎么修"并停）：免密 ssh + 远端 `id -un` 对得上；
  `docker info` 与 `sudo -n docker info` **分开探**（H18）；对外端口没被别人占；
  从家里 `curl` 判安全组；认出已装的 `dsh-relay`（幂等重配置）。
- **部署复用** `cloud/relay.sh --no-compose`（不写第二套云端逻辑）；远程输出**先落文件再判 rc**
  （H20），装完立刻从家里打一次入口当判据。
- **家里**：`broker-install` + `tunnel-install`；`local_port` 上已经有 dsh web 就**不动它**。
- **`bin/dsh-qr`**：自带二维码（纯 python；字节模式 + RS 纠错 + 标准罚分挑掩码；
  终端半块画 / 1 位灰度 PNG / SVG），**正确性跟 npm 那份独立实现逐模块对过账**；
  码里编的永远是不带 token 的固定地址。
- `relay.sh` 现在**自己写** `relay-password.txt`（600）—— H17 那个漂移的根因从源头堵住；
  顺带修了 `--dir` 指向不存在的目录时 `set -eu` 直接退出（H19）。

**实测**：

- 真机（那台已经在跑的阿里云）**幂等跑通**：自检 → scp → `relay.sh`（重渲染 + 重启容器，
  rc=0）→ 回写 `remote.conf` → 两个单元 `enable` 后 `active` → 打印固定地址 + 二维码
  （自绘，PNG 落在 `~/.local/state/dsh-remote/phone-qr.png`）。
- 入口判据：不带密码 **401**；带密码、不带 token → **503**（broker 说"还没有当前 token"）；
  带密码带 token → **401 + 家里 dsh web 的原文**（老路径没坏）。
- 云上 `relay-password.txt` 现在由脚本写成 600、内容与 Caddyfile 一致（H17 的判据）。
- 二维码 PNG 解回来与终端那张矩阵**逐位一致**（1 位灰度、29×29 含静默区）。
- **第一版在真机上被自检抓出两个 bug**（都不是文档问题）：把"能免密 sudo"当成"能直接用
  docker"（H18）；`ssh … | tee` 吞掉云上失败（H20）—— 都已修 + 加了回归用例。

**没验的**：从**一台全新的机器**（没有现成的阿里云中继、没有配好的 key/sudo）从零跑一遍 ——
只在这台已经装好的机器上验了"幂等重跑"这条路；`--domain`（域名 + Let's Encrypt）也没跑过。

**如实记账（提交边界）**：U10 与 U11 的代码**落在同一个提交**里。原因是两个功能在同一批
文件里交织：`bin/dsh-remote`（隧道那条 `-R` 与 `cmd_server` 相邻）、`tests/run_tests.sh`
（K/L/M 三节连着加）、`architecture.md` / `README.md` / `BACKLOG.md` / `hazards.md` 的改动
还在同一个 hunk 里（`git diff` 的 hunk 边界跨了两个功能）。按功能切需要行级手术 ——
**风险大于收益**（切坏了会留下跑不起来的中间状态），所以选择**一个提交、提交信息里分两段写清**。
验收与判据是各自独立的，都在本文件的 U10 / U11 两节里；U3 那条提交（`2a45076`）没有被搅进来。

---

## ✅ U12 用户实测反馈两条（2026-10-07 下午，做完并实测）

**反馈 1：二维码太小。** 之前 `phone-qr.png` 是"1 模块 = 1 像素"（29 模块的版本就 29px），
手机得先放大才认。

- `bin/dsh-qr` 加 **`--scale N`**（每个模块占几个像素）+ **`--target-px`**（默认 1024）：
  `--png/--svg` 时默认自动 `scale = ceil(1024 / 模块数)`，**不做插值**（每模块是干净整数方块）；
  SVG 的 `width/height` 同步成像素、`viewBox` 仍是模块坐标；`--png/--svg` 会往 stderr 打
  "版本 / 纠错 / 多少模块 / 图片多少 px / 每模块几 px"。
- `server` 生成时用 **`--border 4`（静默区 4 模块）+ 自动 scale**；终端字符画照旧（给人看的）。
- **实测**：`~/.local/state/dsh-remote/phone-qr.png` = **1036×1036**（37 模块 × 28 px，
  位深 1 / 颜色类型 0 = 1 位灰度），SVG `width/height=1036`；用户那份已重新生成。
- **验收口径（"手机上扫得动"就这么量）**写进了 README §2：短边 ≥1024px、模块整数倍、
  静默区 ≥4 模块、SVG 尺寸与 PNG 一致。

**反馈 2：改密码的教程看不懂（这是我们的缺陷）。** 用户照 `relay-password.txt` 的三步走，
先被要 root、加 sudo 又被说"没有 docker compose"，而且命令是折行的、只复制了半行。

- 新增 **`dsh-remote passwd [--user U] [--password P] [--dry-run]`**（ADR-0016）：
  云上探 docker 用法 → 用钉住的 `caddy:2.11.4` 算哈希 → **只替换 `basic_auth` 那一行的
  哈希**（`awk` 精确匹配，不整份重渲染）→ `restart dsh-relay` → 只改
  `relay-password.txt` 的 `PASSWORD=` 行（600）→ **从家里验"新密码 200/302、旧密码 401"**
  → 打印手机怎么用新密码。
- `relay.sh` 的提示语改成 **`mode_cmd()` 一行给全**（模式/端口/用户/三条隧道端口/`--allow-ip`/
  `--no-compose --dir --docker-cmd`），dry-run 也打成 `HINT-CMD: …` 供测试抽出来复跑；
  `relay-password.txt` 的"三步"改成**首选 `dsh-remote passwd`** + 一行手工等价命令。
- **实测（真机，两次）**：先改成临时密码 → 新 302 ✓ / 旧 401 ✓；再改回原来那个 →
  新 302 ✓ / 旧 401 ✓；改完 `https://123.56.158.212:8443/` 固定地址跟随后 **200 +
  `DeepSeek Harness`**、带 token 的老地址 303、带 cookie 的 `/` 200/0 跳转；
  云上 `relay-password.txt` 601 字节 / 600 / `PASSWORD=` 只剩一行，Caddyfile 每次都有
  `Caddyfile.bak-<时间戳>` 备份。
- 测试：D 节 +7 条（把 `HINT-CMD` 抽出来**再跑一遍 `--dry-run`**，不是字符串断言）、
  L 节 +5 条（大图尺寸/整数倍/≥1024/SVG 同步/显式 `--scale`）、**新 N 节 22 条**（passwd
  的正常路径 + 三条失败路径）。全量 **400 通过 0 失败**。

**没验的**：真手机扫码（尺寸判据够了，但没人真扫过）；`--domain` 模式的 `passwd`（那台没域名）；
从一台全新机器从零跑（仍同 U11）。

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

## ✅ 2026-10-07：env.zsh / env.bash 里 `harness` 定义前先 `unalias`（本机真装时暴露）

- **现象**：本机（真 WSL）装完 `wtool bootstrap` 后，新开 zsh 报
  `env.zsh:45: defining function based on alias 'harness'` + `parse error near '()'`，
  该文件（以及它后面 load 的东西）**整个不生效**。
- **根因**：用户在 `~/.zshrc:39` 写过 `alias harness='npx @deepseek-ai/dsh web'`；
  zsh 不允许在别名存在时定义同名**函数**。文件自己在函数体**里**做了 `unalias`，
  但那时解析已经失败了 —— 顺序错了。
- **修法**：把 `unalias harness 2>/dev/null || true` 提到**函数定义之前**（两个 shell 文件都改）。
- **判据**：`zsh -lic 'type harness'` → `harness is a shell function from …/env.zsh`（不再报 parse error）；
  `zsh -n env.zsh` / `bash -n env.bash` 过；`sh tests/run_tests.sh` 全绿。
- **注意**：这会让用户 `.zshrc` 里那条别名失效（这正是项目文档要求的口径：
  "别名优先于函数，先 unalias"）；用户若要保留别名，把这两行删掉即可。

## ✅ 2026-10-07：dsh web 常驻化（开机自启）+ `harness` 复用 + 起来后重连隧道

- **需求**（用户原话）：开机自动执行 harness 开会话；后续执行**复用**老会话、不再开新的；
  `dsh-remote` 在 harness 启动后**自动触发重连**阿里云转发。
- **做了什么**：
  1. 新 `bin/dsh-web-run`（给 systemd 的包装：跑 dsh web + 抓 token + **退出不删 token**；
     端口被占 → exit 1 让 systemd 重试；**真抓到 token 后**才 `try-restart dsh-tunnel.service`）；
  2. 新子命令 `serve-install` / `serve-status` / `serve-uninstall` → 单元
     `~/.config/systemd/user/dsh-web.service`（`Restart=always`、`RestartSec=30`、`WantedBy=default.target`）；
  3. `harness`（env.zsh/env.bash 逐字相同）改成三步：**① 复用 ② 交给服务 ③ 回退前台**；
     逃生阀 `DSH_REMOTE_HARNESS_NO_REUSE=1`。
- **踩到的坑（H24）**：第一版把重连写成单元的 `ExecStartPost` —— "端口被占→服务立刻退出→每 30 秒重试"
  时它**也会跑**，于是隧道被反复重启、手机链路每 30 秒断一次（实测看到隧道 `ActiveEnterTimestamp`
  被刷新）。重连挪进 `dsh-web-run`，并加**回归守卫**（O 节断言单元里没有行首 `ExecStartPost=`）。
- **验证**（真机 + 测试）：
  - 真机：`harness` 在活会话下 → 立刻打印"复用"、rc=0、**没起新进程**；
    `serve-install` → 单元写好并 enable（`default.target.wants` 有软链）、服务因端口被占进入
    `activating`（每 30s 重试）；你正在用的会话**全程没被碰**；隧道 `NRestarts=0`（两次采样、间隔 32s）。
  - 测试：**420 通过 / 0 失败**（原 400 + 新 O 节 20 条：单元渲染/ExecStartPost 回归守卫/
    dsh-web-run 抓 token 且不删/端口被占 exit 1/harness 复用分支/逃生阀/serve-status）。
  - ⚠️ 老 K 节用例原来**依赖"本机 3080 没人听"**（碰巧过的）：已把夹具改到 3085 并显式加逃生阀。
- **可重跑判据**：`sh tests/run_tests.sh`（应 420/0）；真机 `harness`（有会话时应打印"复用"）；
  `dsh-remote serve-status`。
- **没验的**：真·重启机器后的自动恢复（要等下次重启）、服务接管那一刻（需要那个手起会话先结束）。
