# tools/dsh-remote —— 用手机接管家里的 DSH 会话

出门在外的时候：**看**某个会话是不是卡在等你回答，**答**它，或者**直接派新活**
（发布 wtool、发邮件……）。手机上不装任何东西，一个浏览器标签页就够。

它是独立子项目：`wtool install tools/dsh-remote` 之后才有 `dsh-remote` /
`dsh-notify` 两条命令。

---

## 1. 长什么样

```
   📱 手机浏览器
        │  https（Let's Encrypt 或自签）+ HTTP basic auth
        ▼
   阿里云 Caddy                     ← 对外唯一的入口
        │  reverse_proxy → 127.0.0.1:18080
        │  （顺手把 Host/Origin/Referer 改写成回环，见 §4）
        ▼
   云上 sshd 的反向隧道端            ← 云上不用开新端口，家主动连出去
        ▲
        │  ssh -N -R 127.0.0.1:18080:127.0.0.1:3080
        │
   家里这台机器                     ← 只有这条出站连接，家里不需要公网 IP、不用端口映射
        │  127.0.0.1:3080 = dsh web
        ▼
   DSH 会话（就是你现在用的这个界面）
```

外加一条**推送**：会话卡在"等你回答"或者一轮跑完时，手机上收一条消息
（Server酱 / 钉钉 / Telegram / Bark / 任意 webhook）。推送走 DSH 官方的
hook 桥（`@deepseek-ai/dsh-hooks-claude-code`），不是去猜会话日志的格式。

---

## 2. 五步装好

> 下面 2–4 步在**家**这台机器上；第 5 步在**阿里云**那台。

> ⚠️ **第 0 步的 `wtool install` 属于"真机安装"**（用户级规矩，2026-10-04）：wtool 的
> 项目平时**只在容器里装 / 测**，本机（WSL）是临时的手工环境、wtool 调通之前不在本地
> 落地。本项目天生要在真机上跑（手机要连的就是这台机器），所以**真机上装必须由用户
> 明确同意**，助手不得自行 `wtool install`。只想验证脚本行为就用临时
> `HOME`/`WTOOL_HOME`/`WTOOL_PREFIX`（`tests/run_tests.sh` 的 I 节就是这么做的）。

```sh
# 0. 装命令（在工作区里）
wtool install tools/dsh-remote
#    命令软链进 $WTOOL_PREFIX/bin（默认 ~/.wtool/usr/bin，已在 PATH 上）；
#    配置实体在 $WTOOL_PREFIX/etc/dsh-remote，日志实体在 $WTOOL_PREFIX/var/dsh-remote，
#    ~/.config/dsh-remote 和 ~/.local/state/dsh-remote 是指向它们的软链（见 §7）

# 1. 推送（可选，但强烈建议 —— 不然你只能靠"时不时刷一下"）
cp ~/.config/dsh-remote/notify.conf.example ~/.config/dsh-remote/notify.conf
vi ~/.config/dsh-remote/notify.conf      # 选一个渠道（provider=…）并把 key 填进去
dsh-remote notify-test                   # 结果：手机收到一条「🔔 dsh-notify 测试」；没收到看日志

# 2. 打开"卡住就推我"的钩子
dsh-remote notify-enable      # 写 ~/.config/dsh-remote/hooks.json + profile patch；web profile 的 patchReload 是 live，正常情况下不用重启

# 3. 阿里云那台（一条命令：传脚本 → 拉 caddy 镜像起容器 → 生成随机密码 → 自检 → 把地址记回配置）
dsh-remote cloud-install --domain dsh.example.com --email me@example.com
#   没域名/没备案：dsh-remote cloud-install --ip <公网IP> --port 8443
#   只想看它要做什么：加 --dry-run（宿主要 docker；加 --install-docker 才会顺手装 docker）
#   ⚠️ 那台没有 docker compose 插件 / 不在 docker 组（比如 2026-10 的阿里云那台）时，
#      cloud-install 里的 `sudo sh relay.sh` 走不通 —— 见 §4 的"用户空间模式"。

# 4. 反向隧道：装成常驻（断了会自己回来，不用 tmux 看着）
cp ~/.config/dsh-remote/remote.conf.example ~/.config/dsh-remote/remote.conf
#   填 cloud_host / cloud_user / identity，并把 public_url 填成云端脚本打印的那个地址
dsh-remote tunnel-install     # systemd --user 单元 dsh-tunnel.service：Restart=always + ssh 保活
#   想先前台看日志：dsh-remote tunnel（Ctrl-C 退出）
#   想让它在你没登录时也活着：loginctl enable-linger "$USER"（本机实测不需要 sudo）
dsh-remote tunnel-status --probe                   # 体检（含云上只读检查）
dsh-remote status                                  # 总览：harness / 隧道 / 推送 / 手机地址
```

手机上：打开 `public_url`（**不带 token 的固定地址**）→ 输一次 basic auth 的用户名密码
→ 就能进。`dsh web` 自己的 token 由家里的 **token broker** 自动补上（它把 `/` 302 到
`/?token=<当前值>`，浏览器拿到 30 天的 cookie 之后就一直直连了），所以**家里重启
harness 也不用改手机上的链接**。

要让 broker 知道"当前 token"是什么，harness 得用 `dsh-remote` 装的那两个 shell 里的
**`harness` 函数**起（`env.zsh` / `env.bash`，它会把 token 写进
`~/.local/state/dsh-remote/current-token.txt`）。原来那条
`alias harness='npx @deepseek-ai/dsh web'` 删掉 —— 别名优先于函数，会把它盖住。

最省事的是：**`dsh-remote server`**（或 `dsh-remote-server`）一条命令把"云上中继 +
家里常驻隧道 + broker"装好，最后打印固定地址和一张能直接扫的二维码。

---

## 3. 命令

| 命令 | 作用 |
|---|---|
| `dsh-remote status` | 体检：harness / 隧道 / 推送 / 手机地址 |
| `dsh-remote serve` | 在**后台**起 `dsh web --no-open`，把带 token 的地址存下来 |
| `dsh-remote tunnel` | 前台保活反向隧道（调试用；常驻用 `tunnel-install`） |
| `dsh-remote tunnel-install` | 装成 systemd `--user` 常驻服务：`Restart=always`（默认 3s）+ ssh 的 `ServerAlive*`，日志进 journald |
| `dsh-remote tunnel-uninstall` | 撤掉它（`disable --now` + 删单元文件） |
| `dsh-remote tunnel-status` | 看单元/进程/端口/云上隧道口/公网；`--probe` 会 ssh 上云做**只读**检查 |
| `dsh-remote systemd` | 旧名字：只生成单元不 enable（= `tunnel-install --no-enable`） |
| `dsh-remote token-broker` | 前台跑"把不带 token 的 `/` 302 到当前 token"的小服务（常驻用 `broker-install`） |
| `dsh-remote broker-install` / `broker-uninstall` | 把 token broker 装成 / 撤出 systemd `--user` 常驻 |
| `dsh-remote server` | **一条命令装好**：自检 → 云上中继 → 家里常驻隧道 + broker → 起 harness → 打印固定地址 + 二维码（`dsh-remote-server` 是等价入口） |
| `dsh-remote url` | 打印手机该收藏的地址 |
| `dsh-remote notify-test` | 推一条测试消息 |
| `dsh-remote notify-enable` / `notify-disable` | 打开 / 关掉 hook 推送 |
| `dsh-remote cloud-install` | 真装到阿里云：传 cloud/ → 跑 relay.sh → 把地址写回配置 |
| `dsh-remote cloud-setup` | 只打印要做的事（不动手） |
| `dsh-remote migrate` | 把旧版放在 `~/.dsh` 下的配置/日志搬到自己目录 |
| `dsh-remote check-hooks` | 一次性进程验证钩子桥到底会不会触发（对照实验，几十秒） |
| `dsh-remote log` | 看推送日志（`notify.log`）和 harness 日志（`web.log`）；隧道日志在 tmux / systemd 那边 |
| `dsh-notify "标题" "正文"` | 直接推一条（脚本里也能用，退出码永远是 0） |

`cloud-install` 的选项（真装到云上那一条）：

| 选项 | 默认 | 作用 |
|---|---|---|
| `--domain D` | — | 域名模式（443 + Let's Encrypt）；与 `--ip` 二选一 |
| `--ip I` | — | IP 模式（默认 8443 + 自签）；与 `--domain` 二选一 |
| `--email E` | `admin@<域名>` | ACME 邮箱（域名模式用） |
| `--port P` | 443 / 8443 | 对外端口 |
| `--user U` | `dsh` | basic auth 的用户名 |
| `--allow-ip CIDR` | — | 只放行这些来源（可给多次），其它一律 403 |
| `--ssh-user S` | `cloud_user`（默认 `root`） | 云上 ssh 用哪个用户 |
| `--dry-run` | — | 只打印要执行的 scp / ssh 命令，一个字节都不传 |

隧道端口和本地端口不在命令行上：从 `remote.conf` 的 `remote_port` / `local_port`
取（默认 18080 / 3080）。密码也不在命令行上 —— 云上 `relay.sh` 每次随机生成。

---

## 4. 为什么这么设计（和踩过的坑）

**为什么把 Host/Origin 改写成回环，而不是给 harness 加 `--trusted-host`？**
`dsh web` 有一道"浏览器信任围栏"，默认只认回环地址。要想让域名进来，要么
`--trusted-host dsh.example.com`（**得重启 harness**，而重启会打断正在跑的
会话），要么让 Caddy 把 `Host` / `Origin` / `Referer` 改写成
`127.0.0.1:3080`。后者不用重启，代价是 harness 分不清请求来自本地还是远程 ——
**所以对外的全部安全性都压在 Caddy 那一层**（见 §5）。

**为什么用 SSH 反向隧道，而不是在家开个端口/IPv6/内网穿透？**
家这台机器没有公网 IP，也不该为了这个去动路由器。反向隧道是家里**主动连出去**，
云上只在 `127.0.0.1` 上开一个端口，安全组里根本不用放它。

**为什么不用 WireGuard / VPN？**
公司网络常封 UDP，手机上还要常驻一个 VPN 客户端。反向隧道只用一条 TCP，
断了自己重连，对网络环境最不挑。

**为什么推送走 hook 桥，而不是去读会话日志？**
会话日志是 `session.v3.jsonl.zstd`，**多帧 + 自定义分帧**，用标准 zstd 解压
到第二帧就报 `Unknown frame descriptor`（实测）。格式是内部实现，会变；
hook 桥是官方给"会话/工具/回合"这些时机留的接口，稳定得多。

**钩子为什么不许失败？**
`dsh-notify` 挂在 `PreToolUse` 上，而 Claude Code 的钩子协议里**退出码 2 =
阻止这次工具调用**。推送失败（没网、key 过期、云服务抽风）绝不能把工具拦掉
或者把 agent 卡住，所以：

- 所有的错误路径都 `exit 0`（连"配置文件不存在""provider 不认识"也是）
- 钩子里用 `--async`：先把自己 fork 出去，父进程立刻返回；子进程的
  stdout/stderr/stdin 全部重定向走，不然钩子 runner 会等管道 EOF，
  `--async` 就成了摆设
- 失败只写一行到 `~/.local/state/dsh-remote/notify.log`

**profile patch 必须写成 `- insert:`。**
patch 层的语义是"**按 id 覆盖已有的行** + `insert` 列表"，直接写
`- id: hooks-claude-code` 会被当成"覆盖一个叫这个名字的已有行"，boot 时打印
`patch: entry "hooks-claude-code" not found`，然后什么都不发生 —— 看着像成功了。
`dsh --profile web --dump-config` 是验证它到底挂上没有的唯一可信办法，
`notify-enable` 会提示你跑这一条。

**⚠️ 已知缺口（2026-09-21 实测）：hook 桥"挂上"了，但**没有真的触发**。**
`dsh-remote notify-enable`（或 dsh-conf 渲染）写出来的 profile patch 能让
`dsh --profile web --dump-config` 里出现 `hooks-claude-code` 这一行，但插件本身
**没有真的加载**：把 `configPath` 故意指到一个不存在的文件，harness 不报任何错；
用一次性的 `dsh --profile headless --patch <同一个 insert 行>` 跑真实任务，
`SessionStart` / `Stop` / `PreToolUse` 三种钩子**一个都没触发**（本地接收端一条没收到、
`notify.log` 是空的）；正在跑的那个 web 实例跑了十几轮也没写过一行日志。
又排除了几种可能（2026-09-21 第二轮实验）：插件**能解析**（`require.resolve` 通）；
插件树**加载失败会大声报错**（故意插一行重名条目会直接 `duplicate loader entry id` 起不来），
所以之前"没声音"不是"被静默跳过"；它 `inject` 的 `shell` / `sessionProjections`
两个服务在 profile 里都有提供者；配置两种形状（`{"hooks":{...}}` 和扁平的
`{"Stop":[...]}`）都试过——**都不触发**。
剩下的嫌疑集中在：它挂的事件（`agent/turn-stopping`、`tools/pre-execute`）在这个
构建里需要别的前置，或者必须作为 bundle 的一部分（`dsh plugin add`）才算正式挂载。
**一条命令就能复查这件事**（它就是上面那套对照实验的封装，一次性进程、不动正在跑的会话）：

```sh
dsh-remote check-hooks     # 触发 → 退出码 0；没触发 → 退出码 1，并打印两条出路
```

**结论：推送脚本本身是好的（测试里真发到本地接收端），但"会话卡住就推手机"这条
链路还没被证实。** 要证实只有两条路，都得你来定：

```sh
# A. 装 pnpm，把桥正式装进 profile（官方路子）
npm i -g pnpm && dsh plugin --profile web add @deepseek-ai/dsh-hooks-claude-code
#    然后重启 dsh web（会打断正在跑的会话），提一个问题看手机响不响

# B. 先不折腾桥：dsh-remote notify-test 证明了推送通道是通的，
#    需要"卡住就提醒"时手动 `dsh-notify "…" "…"`
```

在证实之前，别把"会推手机"当成已经有的能力。

**中继器容器被一个真容器测试钉住了。** `tests/relay-e2e.sh` 会在本机起一个
`caddy` 容器（host 网络）+ 一个假后端，验这几件事：没密码 401、密码对 200、
密码错 401、body 真的来自"隧道口后面的服务"、Host 被改写成回环，最后
`compose down -v` 收摊干净（共 9 条）。写这条测试当场抓到一个真 bug：
Caddy 默认要占宿主 `:80` 做 http→https 跳转，80 被占（或大陆机器没备案用不了 80）时
容器会 restart 循环 —— 所以两个模板都加了 `auto_https disable_redirects`。

**`cloud/relay.sh --dry-run` 的 stdout 就是 Caddyfile 本体**，
进度和报告都走 stderr，方便直接重定向成文件去 `caddy validate`。

**2026-10-07 第一次真装到阿里云，撞到三件"本机永远测不到"的事**（细节见
`docs/hazards.md` H13 和 ADR-012）：

1. **IP 模式必须加 `default_sni`**。手机访问 `https://<IP>:8443` 时**不发 SNI**
   （RFC 6066 不允许 SNI 里放 IP），Caddy 没有 SNI 就选不出证书，握手直接
   `internal error` —— 也就是说那份模板**设计上就跑不通**，只是此前从没真装过。
   现在 `Caddyfile.ip` 的全局块有 `default_sni {{IP}}`。
2. **镜像 tag 要钉住**。那台机器配了国内 mirror，`caddy:2` 被兑成 **4 年前的 v2.4.6**
   （没有 `basic_auth` 指令）→ 容器起来就崩、无限重启；而 `--dry-run` 的
   `caddy validate` 用的是本机镜像，**"本机验过了"完全掩盖了这件事**。
   现在默认写死 `caddy:2.11.4`，`relay.sh` 还会先问一下镜像里的版本。
3. **那台没有 docker compose 插件、docker 还要 sudo**，而 `relay.sh` 原来同时要
   root 和 compose —— 一条路都走不通。现在有**用户空间模式**（不要 root、不要 compose）：

   ```sh
   # 在云上（relay.sh 和 Caddyfile.* 放同一个目录；--dir 是数据/配置的落点）
   sh relay.sh --ip <公网IP> --port 8443 --no-compose \
       --dir ~/dsh-relay --docker-cmd 'sudo docker'
   ```

   它做的事完全一样（渲染 → 起容器 → 自检 → 打印手机地址和密码），
   只是用 `docker run -d --name dsh-relay --network=host` 顶替 `docker compose up -d`，
   数据落在 `--dir` 的 `{Caddyfile,logs,data,config}` 里（普通目录，好备份）。
   ⚠️ **重跑一次会换新密码**（不给 `--password` 时每次随机），手机上要重输一次。

**安装脚本为什么不自己拼路径？** `scripts/install.sh` 的"源"问引擎的
`WTOOL_PROJECT_DIR` 要（手跑时按 `$0` 自推项目目录），"落点"从
`WTOOL_HOME` / `WTOOL_PREFIX` 推。写死 `~/.wtool/wtool-work-dir/links/...`
（引擎的内部布局）等于给自己留了第二份真相：换 `WTOOL_HOME` 装（影子家、
临时家、测试）时它一定指丢，引擎以后再挪一次布局也一样 —— 而脚本的检查是
"源找不到就跳过"，于是**报了"install 完成"却什么都没装**，敲 `dsh-remote`
是 command not found。同一个病在 `tools/android_repack`（`14bf463`）和
`harness/dsh-conf`（`977101b`）上修过，这里是最后一处；回归测试是
`tests/run_tests.sh` 的 I 节（源找不到时**只跳过那一条**、说清去哪儿找了，
而且一个字节都不写）。

---

## 5. 安全边界（这段要看）

这个入口等于**整台家里机器的完全控制权**（会话界面能执行任意命令、读写任意
文件）。所以：

1. **对外只有一个端口**：域名模式 443，或 IP 模式 8443。隧道端口（18080）和
   harness 端口（3080）**绝对不要在安全组里开**。
2. **basic auth 的密码必须长且随机**。`relay.sh` 不传 `--password`
   就每次随机生成 20 位；想固定用 `--password`。
3. 能上域名就上域名 + Let's Encrypt（自动续期，手机不用点"继续访问"）。
   大陆机器 80/443 要**备案**；没备案就用 `--ip <公网IP> --port 8443`，
   Caddy 自签，浏览器第一次会警告一次 —— 点过去就行，流量依然是加密的。
4. 想再收紧：`--allow-ip <你家出口IP>/32`（Caddy 会 403 掉其它来源）。
   注意出口 IP 会变，变了要重跑脚本。
5. 云上的 SSH 只放**你家出口 IP**，并且给隧道专用一把钥匙，在
   `authorized_keys` 里限制成只能转发：

   ```
   restrict,port-forwarding,permitlisten="127.0.0.1:18080" ssh-ed25519 AAAA... dsh-remote
   ```

6. 手机丢了：云上 `docker compose -f /opt/dsh-relay/docker-compose.yml down`
   （或者 `docker stop dsh-relay`；把安全组那个端口关掉也一样）即可
   断掉整条路。harness 本身没有对公网监听，所以没有第二条路。
   （云上的 Caddy 是**容器**，宿主上没有 `caddy.service` 可以 `systemctl stop`。）

**不做什么**：不改 `dsh web` 的默认监听（它拒绝 `0.0.0.0` 是有意的，
那是把 RCE 直接挂网上）；不把 basic auth 换成"藏在 URL 里的 token"；
不在仓库里放证书、密码、密钥。

---

## 6. 测试

```sh
sh tests/run_tests.sh        # 199 条（以输出为准），不联网、不碰真 $HOME
                             #   ⚠️ 装了 docker 的机器上，D 节会经 relay.sh --dry-run
                             #   跑几次 docker run …（第一次会把 caddy:2.11.4 拉下来，约 50MB）
sh tests/caddy-validate.sh   # 3 条（2 个模板 + 1 条"坏配置必须被拒"的反证），要 docker，人工跑
sh tests/relay-e2e.sh        # 9 条（401 / 200 / 真代理 / Host 改写 / 密码错 / 撤干净），要 docker，人工跑
```

⚠️ 后两条**没有 docker 时打印"跳过"并 `exit 77`** —— **77 是"没测"，不是通过**
（以前是 `exit 0`，放进 CI / `&&` 链里空跑也算绿；见 `docs/hazards.md` H8）。

`run_tests.sh` 覆盖：dash/bash 两种解释器的语法、`env.zsh`/`env.bash` 等价、
`dsh-notify` 真发一条到本地 HTTP 接收端（含 `--hook` 解析、`on_stop` 开关、
`--async` 不拖住钩子、**所有失败路径退出码都是 0**）、Caddyfile 渲染、
`dsh-remote` 子命令（含 `notify-enable`/`notify-disable` 幂等和"删干净后补回 `[]`"）、
`cloud-install` 的参数拼装（假 ssh/scp）、"自己的东西不放 `~/.dsh`"、`check-hooks`，
最后是**安装脚本**（I 节，五个场景，全程临时
`HOME`/`WTOOL_HOME`/`WTOOL_PREFIX`/`DSH_HOME`/`XDG_CONFIG_HOME`）：

| 场景 | 断言 |
|---|---|
| 引擎调用（`WTOOL_PROJECT_DIR` 由 `wt_run_project_script` 导出） | 命令/配置/日志都到位，软链指向**项目检出目录**（故意在引擎内部那格埋一份假的，还从那儿取源就会挂） |
| 手工跑（没设 `WTOOL_PROJECT_DIR`） | 按 `$0` 自推项目目录（cwd 在别处、相对路径两种都试） |
| 换 `WTOOL_HOME`（≠ `HOME`） | 落点跟着它走，真 `$HOME` 一个东西都不多 |
| 源找不到 | 只跳过那一条 + 打印去哪儿找了 + **一个字节都不写**（不留空目录/悬空链） |
| `--uninstall` | 撤掉自己铺的软链，配置/日志实体留着 |

跑完还会比对真 `$HOME`（`.zshrc` / `.bashrc` / `.config/dsh-remote` /
`.local/state/dsh-remote`）的指纹，证明这一节没写真家目录。
`grep -F` 守着"脚本里不许出现 `$HOME/.wtool/...` 字面量"。

逐节条数（2026-10-07 实测，合计 **366**）：语法 A 10 / `env` 两份 B 6 /
`dsh-notify` C 22 / Caddyfile 渲染 D 27 / 子命令 E 53 / `cloud-install` F 14 /
`~/.dsh` 边界 G 8 / `check-hooks` H 6 / 安装脚本 I 55 / **常驻隧道 J 69** /
**token 固定地址 K 38** / **二维码 L 12** / **一条命令装好 M 46**。
J 节用 `DSH_REMOTE_UNIT_DIR` 把单元落点钉到临时目录、`systemctl`/`tmux` 全是桩，
跑完比一次真 `~/.config/systemd/user` 的指纹（真 tmux 上可能正跑着生产隧道）。

`caddy-validate.sh` 还会故意塞一条坏配置，确认这个测试**能失败**
（永远绿的测试等于没测）。

没有自动测的部分（要两台机器 / 要手机，`BACKLOG.md` 里列全了）：真阿里云上的
安全组/防火墙、真实 Let's Encrypt 签发与续期、手机浏览器上的实际体验、
"网络真断"那条重连路（进程被杀那条已实测：3.2s）、重启机器后会不会自动恢复、
钩子桥到底会不会触发。

---

## 7. 占地与清理

- 仓库里只有文本（脚本 + 两个 Caddyfile 模板 + 文档）；证书、密码、密钥、
  日志一律在**安装落点**和云上的 `/opt/dsh-relay/`（证书与续期状态在命名卷
  `caddy-data` 里），不进 git。
- `wtool install tools/dsh-remote` 装出来的东西（`$WTOOL_PREFIX` 默认
  `~/.wtool/usr`，`$WTOOL_HOME` 默认 `$HOME`）：

  | 落点 | 是什么 |
  |---|---|
  | `$WTOOL_PREFIX/bin/dsh-remote`、`dsh-notify` | 软链 → 仓库 `bin/` 里的脚本（`$WTOOL_PREFIX/bin` 由引擎放进 PATH） |
  | `$WTOOL_PREFIX/etc/dsh-remote/` | 配置**实体**（install 只放两份 `*.example`；`remote.conf` / `notify.conf` / `hooks.json` 是之后由你和 `notify-enable` 写进去的） |
  | `$WTOOL_PREFIX/var/dsh-remote/` | 日志/运行期文件**实体**（`notify.log`、`web.log`、`web-url.txt`） |
  | `~/.config/dsh-remote` | 软链 → 上面那个 `etc/dsh-remote` |
  | `~/.local/state/dsh-remote` | 软链 → 上面那个 `var/dsh-remote` |
  | `~/.config/systemd/user/dsh-tunnel.service` | **常驻隧道单元**（`tunnel-install` 渲染，改配置就重跑它） |
  | `~/.config/systemd/user/dsh-token-broker.service` | **token broker 单元**（`broker-install` 渲染） |
  | `$WTOOL_PREFIX/var/dsh-remote/current-token.txt` | 当前 token（`harness` 函数写、broker 读；600，harness 退出即删） |
  | `$WTOOL_PREFIX/var/dsh-remote/phone-qr.png` / `.svg` | `server` 打出来的二维码图片（可以直接用手机相册扫） |
  | `~/.dsh/profiles/web/cordis.patch.yml` | **唯一**必须待在 `~/.dsh` 的东西（profile patch 只能放那儿），由 `dsh-remote notify-enable` 写 |

  家在跑的时候只有一条 ssh 进程（`dsh-remote tunnel` / systemd 单元）。
- 全撤：`dsh-remote notify-disable` → `dsh-remote tunnel-uninstall` → 云上
  `docker compose -f /opt/dsh-relay/docker-compose.yml down`
  （要连证书一起撤就加 `-v`）→ `wtool uninstall tools/dsh-remote`。
  **只撤软链**：`etc/` 和 `var/` 里的实体（你的配置和日志）留着 —— 要彻底清
  得自己删那个目录。

