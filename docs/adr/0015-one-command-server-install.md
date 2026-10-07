# ADR-0015. 一条命令装好：`dsh-remote server`（自检 → 部署 → 常驻 → 二维码）

- 状态：Accepted（2026-10-07）
- 相关：ADR-0012（IP 模式在真机上的三处硬化）、ADR-0013（常驻隧道）、ADR-0014（固定手机地址）、
  ADR-0011（`relay.sh` 的 stdout 约定）、`docs/hazards.md` H18/H19/H20、`architecture.md` §3.3

## 背景

到 2026-10-07 为止，把"手机远程接管"从零装起来要人按 README 走五步，跨两台机器：
配 key → 配 sudo → 控制台放安全组 → 云上跑 `relay.sh` → 家里 `tunnel-install` /
`broker-install` → 起 harness → 把带 token 的地址抄到手机。每一步都能出错，而且
**错误信息分散在两台机器、三个脚本里**。用户的原话（大意）："要一条命令，问我要什么，
告诉我需要什么权限、给我教程，然后自己装好，最后给我一个链接或者二维码，我扫码就能用。"

## 决策

**1）命令形态：`dsh-remote server`（子命令），另给一个薄封装可执行 `bin/dsh-remote-server`。**

- 子命令是本项目一贯的形态（`status` / `tunnel-install` / `cloud-install`…），
  放得进 `dsh-remote help`、测得到、装得到；
- `dsh-remote-server` 只是三行的薄封装（`exec dsh-remote server "$@"`），因为用户先说的是
  这个名字；两个入口行为完全一致，**不另起一套代码**。

**2）交互规则：命令行给了就不问；`--yes` 或"stdin 不是终端"时一律用默认值。**

于是同一条命令既能给人用（问 IP/用户/密码，密码回车 = 随机 20 位），
也能被脚本/测试全参数非交互地跑（`--yes`），测试不用去驱动一个交互界面。

**3）自检在前，每条失败都带"怎么修"，而且失败就停（不半装）。**

自检项与判据（都在真机上跑过）：

| 自检 | 判据 | 失败时打印 |
|---|---|---|
| 免密 ssh | `ssh -o BatchMode=yes … true` 且远端 `id -un` == `--ssh-user` | `ssh-copy-id` 那三步 + "不带 `-i` 的前台 ssh 会偷偷换钥匙，别拿'能连'当通过"（H16） |
| docker | `docker info` **或** `sudo -n docker info`（两条分开探！） | 装法（但不代跑）；`NOPASSWD: /usr/bin/docker` 的 sudoers 一行 |
| 对外端口 | 云上 `ss -ltn` 里没别人占着（我们自己的 `dsh-relay` 除外） | 建议 `--port` 换一个 |
| 安全组 | 从家里 `curl -sk https://<host>:<port>/` → 401/302 | 控制台放行说明 + "超时=没放行" |
| 已有安装 | `sudo docker ps --filter name=dsh-relay` | 认出来"只重配置"（幂等，不重装） |

**4）部署复用 `cloud/relay.sh` 的用户空间模式**（`--no-compose --dir … --docker-cmd '…'`），
不写第二套云端逻辑：谁改 Caddyfile 模板都只有一处。装完**立刻**从家里打一次入口
（401 = basic auth 在挡 / 302 = broker 在补 token）作为判据。

**5）家里那半复用 `broker-install` / `tunnel-install`**（ADR-0013/0014 的两个 systemd 单元），
然后：`local_port` 上**已经有** dsh web 就**绝不动它**（重启会打断正在跑的会话），
没有才用 `env.*` 里的 `harness` 函数起一个（前台、token 自动捕获）。

**6）二维码：优先 `qrencode`，没有就用仓库里自带的 `bin/dsh-qr`（纯 python、自己实现）。**

- 不把 `qrencode` 加进依赖（那台机器上没有，装包要动系统）；
- 也不依赖 python 的 `qrcode`/`segno`（同样没装、要 pip）；
- **仓库里只放文本**：`dsh-qr` 是源码（按 ISO/IEC 18004 自己实现字节模式 + RS 纠错 +
  8 种掩码按标准罚分挑），不复制第三方代码、不需要 license 头；输出终端半块字符画、
  PNG（1 位灰度，`zlib`+`struct` 手写）、SVG（纯文本），PNG/SVG 落到 `$STATE_DIR/phone-qr.*`。
- **码里编的是固定 URL（不带 token）**（理由见 ADR-0014 第 3 条）。
- 正确性**跟一份独立实现对过账**：npm 自带 `qrcode-terminal` 里那份 Kazuhiko Arase 的 JS
  实现（MIT），逐模块比对（同一版本 + 同一掩码下必须逐字一致）——回归用例在
  `tests/run_tests.sh` 的 L 节（sha256 向量）。

**7）`relay.sh` 自己写 `relay-password.txt`（地址/用户名/密码，600）。**
"谁渲染谁负责"：以前这文件是人手写的，重渲染一次就与 Caddyfile 漂移（H17），
现在脚本每次重写，漂移从源头消失。

## 理由

- **一条命令的价值在"自检 + 指引"**，不在把步骤藏起来：跨两台机器装东西，失败是常态；
  把"哪一步没过、怎么修、拿什么验"直接打给用户，比任何花哨的自动化都省时间。
- **复用而不是重写**：`relay.sh` 的两种模式、两个 Caddyfile 模板、三个 systemd 单元
  都已经各自有测试；`server` 只做编排。
- **二维码必须自己会画**：这是"人在外面"的唯一入口，不能是可选依赖；
  自己实现 + 对账，比"请先 apt install qrencode"可靠。
- **二维码里不放 token**：一次性密钥不该留在照片/截图里；固定 URL 让"换 token"对用户不可见。

## 否决

| 方案 | 为什么否 |
|---|---|
| 把 `relay.sh` 的逻辑复制进 `server` | 两份云端逻辑必然漂移；模板与选项已经够多 |
| 交互式向导（问一堆问题、逐步回车） | 不能非交互测试；参数化 + `--yes` 两种用法都要有 |
| 依赖 `qrencode` | 那台机器上没有；装包属于改系统，不该由这条命令带 |
| pip 装 python `qrcode`/`segno` | 同上；而且"仓库里只有文本、跑起来才装东西"是这个项目的底线 |
| 把 token 编进二维码 | 换一次 token 就得重新扫码/截图，等于没解决问题（ADR-0014） |
| 顺手重启用户正在跑的 `dsh web` | 会打断正在跑的会话（用户级硬规矩）；只报告"token 还没捕获" |
| 用 `sudo` 给云上装 docker | 改系统 + 用户三条硬约束；只打印装法 |

## 后果 / 代价（要认）

- `server` 会把**它自己**需要的东西装全，但**装 docker、放安全组、配免密**这些
  "改系统 / 动控制台"的事仍然要人做 —— 命令只负责**检查并说清怎么做**。
- `--password` 会出现在**云上的进程列表**里（`relay.sh --password …`）；这是 relay.sh
  本来就有的行为，不是 `server` 引入的。仓库里依旧不写密码，落点只有
  `$DIR/relay-password.txt`（600）与各轮报告。
- 第一次跑完之后，"手机能不能进"仍取决于**家里的 harness 用没用那个 `harness` 函数起**
  （否则 broker 手里没 token，固定地址回 503）—— `server` 会把这句话打出来。
- `dsh-qr` 只实现**字节模式**（不做数字/字母数字/汉字模式的压缩），所以同样内容会比
  `qrencode` 多用一点版本；对 URL 这种几十字节的输入没有实际影响。
