# ADR-0016. 改密码做成一条命令（`dsh-remote passwd`），而且只换那一行哈希

- 状态：Accepted（2026-10-07）
- 相关：ADR-0004（basic auth 在最外层、密码随机）、ADR-0011（`relay.sh` 的 stdout 约定）、
  ADR-0015（一条命令装好）、`docs/hazards.md` H17 / H21 / **H23**、`architecture.md` §3.4

## 背景

2026-10-07 用户实测反馈（原话大意）："改密码那三步教程，照做先要 root、加了 sudo 又说没有
docker compose，让我再加 `--no-compose --dir … --docker-cmd 'sudo docker'`；命令还是折行的，
我只复制了 `--port 8443 --password '…'` 那半行 —— **莫名其妙的看不懂了**。"

也就是说，改一个密码要：① 知道云上没 compose、② 知道 docker 要 sudo、③ 知道目录在哪、
④ 把一条**折成三行**的命令完整复制。任何一步没做到，得到的错误信息都指向**错误的方向**
（"没有 docker compose" 让人以为是环境问题，其实是参数掉了 —— H23）。

而这件事在工具里本来就有全部信息：`cloud_host` / `cloud_user` / `identity` /
`remote_port` / `public_url` 都在 `remote.conf` 里，云上的 docker 用法也能**探**出来。

## 决策

**1）加 `dsh-remote passwd`：在家里一条命令改完。**

```
dsh-remote passwd [--user <用户名>] [--password <新密码>] [--dry-run]
```

它按顺序做（`--dry-run` 只打印这五步）：

1. 收参数：`--user` 默认 conf 的 `web_user` 或 `dsh`；`--password` 不给就**问**（回车 = 随机
   20 位）；含单引号/空格**直接拒**（要塞进远程命令行）。
2. 探云上该用 `docker` 还是 `sudo docker`（H18 的教训：探真正要执行的那条命令），
   在**云上**用**钉住的镜像**算哈希：`<docker> run --rm caddy:2.11.4 caddy hash-password
   --plaintext '<新密码>'`（和渲染时同一份实现，不会出现"Caddy 版本不同、哈希不认"）。
3. 远端脚本走 stdin（`ssh … sh -s`）：备份 `Caddyfile` → **只把 `basic_auth` 里那一行的
   bcrypt 哈希换掉**（`awk -v u=… -v h=…`，按用户名精确匹配；找不到就 `exit 3`）→
   `<docker> restart dsh-relay` → 轮询 `https://127.0.0.1:<port>/` 直到回 401（最多 20s）→
   只替换 `relay-password.txt` 的 `PASSWORD=` 行（没有就补一份）→ `chmod 600`。
4. **从家里验**：新密码 → 200/302 ✓；旧密码（改之前从云上读的）→ 401 ✓。
   旧 == 新时不做第二条（免得"验过了"其实是自己骗自己）。
5. 打印"手机怎么用新密码"（含"浏览器可能记着旧密码，清掉或换无痕窗口"）。

**2）改密码**不整份重渲染 `Caddyfile`，只换那一行。**

**3）`relay.sh` 的提示语改成"按检测到的模式给一行完整命令"**（`mode_cmd()`）：
参数全给（模式 / 端口 / 用户 / 三条隧道端口 / `--allow-ip` / 无 compose 模式下的
`--dir` 与 `--docker-cmd`），**不折行、不罗列分支**；dry-run 也会把它打成
`HINT-CMD: …`，测试就抽这一行去本机再跑一遍 `--dry-run`（验"真能用"，不是字符串断言）。
`relay-password.txt` 里的"改密码三步"改成：**首先指向 `dsh-remote passwd`**，
再附**同一条一行命令**给不装工具的人。

## 理由

- **改密码是个"意图明确的小事"，不该让人拼命令行**：所有输入都在 conf 里、都在工具手里，
  让人去背 `--no-compose --dir --docker-cmd` 是把实现细节漏给了用户。
- **只换那一行**：整份重渲染会（a）把容器 **recreate**（不是 restart），
  （b）如果这次没把 `--allow-ip` 等参数带全，就把安全策略改回去了，
  （c）多出一堆"其实没变"的 diff。改密码**只该动密码**。
- **必须验旧/新**：不验的话，"改成功了吗"只能靠猜；而 basic auth 是唯一那道门（ADR-0004），
  改坏了等于把手机挡在外面。旧密码那条同时证明了"新哈希真的生效了"（不是缓存/旧容器）。
- **提示语必须一行能复制**：折行的命令在聊天窗口/终端里会被截断，而截断后的报错指向
  错误方向（H23）—— 这是**我们的缺陷**，不是用户的问题。

## 否决

| 方案 | 为什么否 |
|---|---|
| 继续用"三步教程"（改密码文档） | 用户实测走不通；错在文档却让人以为环境有问题 |
| 让用户自己 `sh relay.sh … --password <新>` 重渲染 | 会 recreate 容器、会漏参数（`--allow-ip` 一旦漏了就是放开访问）、还得记住三种模式 |
| 在 `passwd` 里也整份重渲染 Caddyfile | 同上；而且"改密码"变成"重装一遍" |
| 用 `docker exec` 进容器改 `/etc/caddy/Caddyfile` | 挂载是只读的（`:ro`），而且那会绕过 `relay-password.txt` 的同步 |
| `caddy reload`（API）代替 restart | 需要 admin API 可达 + 证书/配置一致；`restart` 更笨但更可靠（容器 `--restart unless-stopped` 本来就会回来）。**没否决 reload**，只是这版选了 restart，理由是它能顺带证明"容器自己也能起来" |
| 把密码写进命令行参数再 `ps` 可见 | 已经是 `relay.sh` 既有行为（`--password`），这里没有变差；仓库里永远不写密码 |

## 后果 / 代价（要认）

- 新密码会出现在**云上的进程列表**里一小会儿（`caddy hash-password --plaintext`），
  和 `relay.sh` 一样；落点仍只有云上 `relay-password.txt`（600）。
- `passwd` 依赖云上能跑 `sudo docker run`（算哈希）—— 那本来也是本项目的硬前提。
- `relay-password.txt` 的 `URL=` / `USER=` 不重写（只换 `PASSWORD=`）；换域名/换用户名要走
  `relay.sh` 重渲染。
- 手机浏览器可能记着旧密码（basic auth 是浏览器缓存的）：改完要清一次或换无痕窗口 ——
  命令的最后一段会这么说。
