# 用 Outlook / Microsoft Graph 接收 DSH 推送（`provider=graph`）

> 这份是**给用户照抄的教程**：从零注册一个 Azure 应用，授权，然后让
> `dsh-notify` 通过 Microsoft Graph 的 `/me/sendMail` 把"会话在等你回答 / 一轮跑完"
> 发到你的 Outlook 邮箱。
>
> 不需要 SMTP AUTH，不需要应用密码，不需要客户端密钥，也不会把密码存到任何地方。
>
> 相关代码：`bin/dsh-notify`（`provider=graph`）、`bin/dsh-notify-graph-setup`
> （一次性授权）。配置样板：`notify.conf.example` 的 graph 段。

---

## 0. 五分钟版（已经知道要做什么就看这段）

```sh
# 0) 命令装了吗（没装才需要）
wtool install dsh-projects/dsh-remote

# 1) 在 Azure / Entra 注册一个应用（第 2 节，大约 2 分钟），拿到 client id

# 2) 一次性授权：浏览器打开它打印的地址、输入短码
dsh-notify-graph-setup
#   脚本会问：Application (client) ID、收件人邮箱；租户默认 common。
#   也可以在命令行直接给：
#   dsh-notify-graph-setup --client-id <你的 client_id> --mail-to you@outlook.com

# 3) 发一封测试信
dsh-remote notify-test
#   只想单独测 Graph 这一条（不管 provider= 写的是什么）：
dsh-remote notify-test --provider graph

# 4) 让"卡住 / 跑完"自动推
dsh-remote notify-enable
```

收到标题是 `🔔 dsh-notify 测试` 的邮件就通了。没收到看第 6 节排错表。

---

## 1. 两条路：个人 outlook.com vs 公司 M365

| | **个人 outlook.com / hotmail / live** | **公司 / 学校 M365** |
|---|---|---|
| 谁能注册应用 | 你自己（Microsoft 账户就行，免费，不需要订阅） | 你，或公司管理员 |
| 支持的账户类型 | "个人 Microsoft 账户"或"任何组织目录 + 个人" | "仅此组织目录"或"任何组织目录" |
| 管理员同意 | **不需要**，授权时自己点同意 | **可能需要**：租户关了"用户可以同意应用"，就要管理员点一次"授予管理员同意" |
| 条件访问 | 一般没有 | 可能有（要求公司设备、MFA、禁止 device code 流等），会被拦 |
| SMTP AUTH | 个人账户也逐步在关 | **经常整个租户被禁**（安全默认值） |
| 结论 | **推荐这条路**，最省事 | 能做，但要先确认管理员/条件访问放行；**别去折腾 SMTP AUTH** |

两条路用的都是同一套东西：**Microsoft Graph + 委派权限 `Mail.Send` + device code
授权**。区别只在"注册应用时选哪种账户类型"和"要不要管理员同意"。

> **为什么不用 SMTP AUTH / 应用密码？**
> 微软在逐步关掉 basic auth，M365 租户默认也常把 SMTP AUTH 关掉；而且"应用密码"
> 是另一套凭据，泄露了照样能发信。Graph 是微软现在推荐的路子，权限还能单独撤销。
> 如果你在报错里看到 `SMTP AUTH disabled`，说明你走错路了 —— **用 Graph 根本不需要它**。

---

## 2. 注册 Azure 应用（两条路都从这里开始）

下面用 **Entra 管理中心**的菜单名；老界面在 `portal.azure.com` → "Microsoft Entra ID"
里，名字基本一样。

> 如果 `entra.microsoft.com` 用**个人 Microsoft 账户**登不进去（有些入口只收工作账号），
> 直接开 <https://portal.azure.com>，搜索 "Microsoft Entra ID" → App registrations，
> 菜单和下面写的一样。

1. 浏览器打开 <https://entra.microsoft.com>，用**要发信的那个邮箱账号**登录。
2. 左边 **Applications（应用程序）→ App registrations（应用注册）→ New registration
   （新注册）**。
3. **Name**：随便起，建议 `dsh-notify`（以后撤销授权时认得出来）。
4. **Supported account types（支持的账户类型）**：
   - 个人 outlook.com：选 **"Personal Microsoft accounts only"**，
     或 **"Accounts in any organizational directory and personal Microsoft accounts"**；
   - 公司 M365：选 **"Accounts in this organizational directory only"**（单租户）
     或 **"Accounts in any organizational directory"**（多租户）。
   - 选错了后面会报 `AADSTS700016` / `AADSTS65001`，改完要重新授权。
5. **Redirect URI**：**留空**（device code 流不需要）。
6. 点 **Register**。进去以后把 **Application (client) ID** 抄下来 ——
   这就是配置里的 `GRAPH_CLIENT_ID`。
   （`Directory (tenant) ID` 也顺手抄下来，公司租户后面可能用得上。）

### 2.1 添加**委派**权限（不是 Application 权限）

**API permissions（API 权限）→ Add a permission（添加权限）→ Microsoft Graph →
Delegated permissions（委派权限）**，勾上这四个：

| 权限 | 干什么 |
|---|---|
| `Mail.Send` | 以**你本人**的身份发信（核心权限） |
| `offline_access` | 让授权能换来 refresh token（**少了它脚本会拿不到 refresh token**） |
| `openid` | device code 登录用 |
| `profile` | 同上（拿基本账号信息） |

> ⚠️ 一定选 **Delegated permissions（委派）**。选成 **Application permissions**
> 会要求管理员同意 + 客户端密钥，而且发信人变成"应用"，不是你要的效果。

公司租户：加完权限后如果页面上的 **Grant admin consent（授予管理员同意）** 可以点，
就点一下（需要管理员角色）；点不了/灰的，把这一页发给管理员，让他点。
个人账户不需要这一步，第一次授权时浏览器里自己同意即可。

### 2.2 打开"允许公共客户端流"（**必须**）

**Authentication（身份验证）→ 页面最下面 Advanced settings →
Allow public client flows（允许公共客户端流）→ Enable the following mobile and
desktop flows 选 Yes → Save**。

device code 流走的就是"公共客户端"，不开这个会报
`AADSTS7000218` / "public client flow not enabled"。

### 2.3 **不要**创建客户端密钥

**Certificates & secrets 那一页不用碰。** device code 流是公共客户端，
不需要 client secret；别生成、别复制、别保存。教程里出现的
`GRAPH_CLIENT_SECRET` 之类的键都是别的授权方式用的，`provider=graph` 不需要。

---

## 3. 一次性授权：把 refresh token 换回来

在家这台机器上跑（它会自己问 client id 和收件人）：

```sh
dsh-notify-graph-setup
```

或者一步到位（适合复制粘贴）：

```sh
dsh-notify-graph-setup \
  --client-id '<第 2 步抄的 Application (client) ID>' \
  --tenant common \
  --mail-to 'you@outlook.com,another@example.com'
```

- `--tenant`：`common`（个人 + 组织，默认）/ `organizations`（只要组织）/
  `consumers`（只要个人）/ 具体租户 ID 或域名。**它必须和注册应用时选的账户类型对得上。**
- `--mail-to`：收件人，多个用**英文逗号**分隔。不给的话脚本会问；
  再不给也可以之后自己往 `notify.conf` 里加 `MAIL_TO=`。
- `--conf <路径>`：不想用默认的 `~/.config/dsh-remote/notify.conf` 时用。

脚本会打印类似：

```
============================================================
 1) 在浏览器打开：https://microsoft.com/devicelogin
 2) 输入代码：    XXXXXXXXX
============================================================
```

**在你自己的浏览器里**打开那个地址，输入短码，选"要发信的那个账号"，同意权限。
脚本会自己轮询等待（默认 15 分钟内有效），成功后：

- 把 `provider=graph`、`GRAPH_CLIENT_ID`、`GRAPH_TENANT`、`GRAPH_SCOPE`、
  `GRAPH_REFRESH_TOKEN`、`MAIL_TO` 写进 `~/.config/dsh-remote/notify.conf`；
- **其它键和注释原样保留**（比如你原来的 `SENDKEY`、`public_url`）；
- 写之前把原文件备份成 `notify.conf.bak-graph-setup-<时间>-<pid>`；
- 文件权限设成 **600**。

> 已经有 `GRAPH_REFRESH_TOKEN` 时，脚本会先问一句（覆盖前备份）。
> 非交互环境（没有终端）不会覆盖，除非显式加 `--yes`。

---

## 4. 配置长这样

`~/.config/dsh-remote/notify.conf`（**权限必须是 600**）：

```ini
provider=graph

GRAPH_CLIENT_ID=<你的 client_id>
GRAPH_TENANT=common
GRAPH_REFRESH_TOKEN=<脚本写入；别手抄、别贴群里>
MAIL_TO=you@outlook.com,another@example.com
# 可选：
#GRAPH_SCOPE=offline_access Mail.Send
#MAIL_SUBJECT_PREFIX=[dsh]
```

| 键 | 必填 | 说明 |
|---|---|---|
| `provider` | ✅ | 必须是 `graph`（也认 `outlook` / `msgraph` / `o365`） |
| `GRAPH_CLIENT_ID` | ✅ | Azure 应用的 Application (client) ID |
| `GRAPH_TENANT` | ✅ | `common` / `organizations` / `consumers` / 租户 ID；默认建议 `common` |
| `GRAPH_REFRESH_TOKEN` | ✅ | `dsh-notify-graph-setup` 写的；**等同密码** |
| `MAIL_TO` | ✅ | 收件人，英文逗号分隔（也认分号） |
| `GRAPH_SCOPE` | 可选 | 换 token 时带的 scope，默认 `offline_access Mail.Send` |
| `MAIL_SUBJECT_PREFIX` | 可选 | 拼在邮件标题最前面，**自动加一个空格**（写 `[dsh]` 得到 `[dsh] 🔔 …`） |

**检查权限**（不要 `cat` 整个文件，里面是 refresh token）：

```sh
stat -c '%a %n' ~/.config/dsh-remote/notify.conf     # 应该是 600
grep -E '^(provider|GRAPH_CLIENT_ID|GRAPH_TENANT|MAIL_TO|GRAPH_SCOPE)=' \
  ~/.config/dsh-remote/notify.conf
```

access token 会缓存在 `~/.local/state/dsh-remote/graph-token.json`（也是 600），
有效期 1 小时左右；**过期的 access token 自动换，不用管**。refresh token 轮换时
`dsh-notify` 会自动把它写回 `notify.conf`（只改那一行）。

---

## 5. 验证

```sh
# 用配置里的 provider（现在应该是 graph）
dsh-remote notify-test

# 只想单独测 Graph 这一条（哪怕配置里暂时是别的 provider）
dsh-remote notify-test --provider graph

# 没装 dsh-remote 的等价写法
dsh-notify --test --provider graph
```

成功时终端最后一行是：

```
graph: 已交给 Microsoft Graph（HTTP 202），收件人：you@outlook.com
```

（Graph 的 `sendMail` **成功判据是 HTTP 202**，不是 200。）

失败时**退出码仍然是 0**（这是设计：它挂在钩子上，绝不能拦工具），
错误会打在屏幕上并写进日志：

```sh
dsh-remote log
# 或
tail -n 20 ~/.local/state/dsh-remote/notify.log
```

例如：

```
dsh-notify: graph 换 token 失败（HTTP 400）：error=invalid_grant error_description=AADSTS70008: ...
dsh-notify: graph 发信失败（HTTP 403）：error.code=ErrorSendAsDenied error.message=The user account ...
```

---

## 6. 排错表（报错 → 原因 → 怎么办）

先看日志里那一行（`dsh-remote log`）。`error.code=` 是 Graph 的错，
`error=` / `AADSTSxxxxx` 是登录（OAuth）的错。

| 报错 | 什么意思 | 怎么办 |
|---|---|---|
| `AADSTS50076` | 需要多因素认证（MFA） | 重新跑 `dsh-notify-graph-setup`，**在浏览器里完成 MFA**。公司环境可能是条件访问要求的，见下面"条件访问" |
| `AADSTS50079` | 账号还没注册 MFA，需要先注册 | 去 <https://aka.ms/mfasetup> 完成 MFA 注册，再重新授权 |
| `AADSTS65001` | 用户/管理员还没同意这些权限 | 委派权限没加全（尤其 `Mail.Send`）；公司租户让管理员点"授予管理员同意"，或让管理员允许用户同意应用；改完**重新授权** |
| `AADSTS700016` | 在租户里找不到这个应用 | `GRAPH_CLIENT_ID` 抄错，或 `GRAPH_TENANT` 和注册时选的账户类型不匹配（个人应用用了 `organizations`、单租户应用用了 `common`）。改完重新授权 |
| `AADSTS7000218` / `AADSTS70008` | 公共客户端流没开 / refresh token 过期或被撤销 | 前者去 Authentication 打开"允许公共客户端流"；后者重新跑授权脚本（改密码、管理员撤销同意都会让旧 token 失效） |
| `AADSTS50173` / `invalid_grant` | refresh token 已经不能用了（密码变了、会话被吊销、token 太久没用） | 重新跑 `dsh-notify-graph-setup` |
| `ErrorInvalidRecipients` / `InvalidRecipients` | `MAIL_TO` 里有地址格式不对 / 空项 | 检查 `MAIL_TO`：英文逗号分隔、每项是完整邮箱；改完再跑 `dsh-remote notify-test --provider graph` |
| `ErrorSendAsDenied` | 当前登录账号**没有以该邮箱发信**的权限 | `MAIL_TO` 是收件人，不影响发信人；发信人永远是授权时登录的那个账号。想用共享邮箱发信要先被授予 Send As；最简单的办法是用自己的邮箱重新授权 |
| `MailboxNotEnabledForRESTAPI` | 这个邮箱不在 Microsoft 365 里（本地 Exchange / 只有 IMAP） | Graph 发不了这个邮箱；换一个 M365/outlook.com 邮箱账号授权 |
| `SMTP AUTH disabled` / `SmtpClientAuthentication is disabled` | 你在用 SMTP，不是 Graph | **走 Graph 不需要 SMTP AUTH**。检查 `provider=graph`，并删掉 `SMTP_*` 之类的配置。不要为了这个去开租户的 SMTP AUTH |
| `InvalidAuthenticationToken` / `Access token has expired` | access token 过期或缓存坏了 | 一般是自动处理的；还报就 `rm -f ~/.local/state/dsh-remote/graph-token.json` 再试，仍不行重新授权 |
| `Authorization_RequestDenied` / `Insufficient privileges` | 权限没生效 / 同意了别的权限 | 核对 API permissions 里是 **Delegated** 的 `Mail.Send`；改完重新授权 |
| 条件访问拦截（页面提示 "Your sign-in was successful but your admin requires..." / `AADSTS53003` 等） | 公司策略禁止这类登录（设备不合规、禁止 device code、只允许公司网络等） | 找管理员确认；或换个人 outlook.com 账号按第 1 节那条路走 |
| `AADSTS50034` / `AADSTS500011` | 账号不在这个租户 / 租户不存在 | 检查 `GRAPH_TENANT` 和登录账号；公司租户用租户 ID 最稳 |
| 脚本卡在"等待授权"直到超时 | 浏览器里没完成、或短码输错 | 重新跑脚本拿新码；确认浏览器里登录的是**要发信的那个账号** |

> 拿不准时，先跑 `dsh-remote notify-test --provider graph` 把错误原文打出来，
> 再对着上表的第一列找。**别把 refresh token 贴进工单/群里**，见下一节。

---

## 7. 安全与撤销（重要）

**refresh token 等同密码。** 拿到它的人可以在你不知情的时候以你的名义发信，
直到它失效或被撤销。所以：

- `notify.conf` **必须 600**（授权脚本会设）。别改成 644，别放进任何 git 仓库。
- 别 `cat` 给别人看、别贴聊天群、别贴 issue / 工单。要给人看配置就用
  `grep -E '^(provider|GRAPH_CLIENT_ID|GRAPH_TENANT|MAIL_TO)='`。
- 本项目的仓库里**只有占位符**；测试用假 token（`FAKE-REFRESH-TOKEN`），不碰真凭据。
- access token 缓存在 `~/.local/state/dsh-remote/graph-token.json`（600），
  只有 1 小时左右，泄露面比 refresh token 小。
- 怀疑泄露：**立刻撤销同意**（下面），再重新授权换一个新 token。

### 怎么撤销

任选一条，按"彻底程度"从轻到重：

1. **撤销这个应用对你的授权**（只撤权限，应用注册还在）
   - 个人 Microsoft 账户：<https://account.live.com/consent/Manage> →
     找到 `dsh-notify` → **Remove these permissions / 删除这些权限**。
   - 工作/学校账户：<https://myapps.microsoft.com> → 找到应用 → 卸载/撤销；
     或让管理员去 **Entra 管理中心 → 企业应用（Enterprise applications）→ 找到应用 →
     用户和组 / 权限** 里撤销同意。
   - 撤销后旧 refresh token 立刻作废；`dsh-notify` 会报 `invalid_grant`，
     要重新跑授权脚本。
2. **删除应用注册**（最彻底）：Entra → **应用注册 → `dsh-notify` → 删除**。
   client id 直接失效，所有 token 一起作废。
3. **改密码**：能踢掉大部分会话，但**不保证**撤销已经发出去的 refresh token
   （尤其是公共客户端）。要确保撤销，用第 1 或第 2 条；改密码可以作为补充。

平时想换账号 / 换收件人：

```sh
# 换账号：重跑授权（会问是否覆盖，覆盖前备份）
dsh-notify-graph-setup

# 只换收件人 / 加标题前缀：直接编辑 notify.conf 的 MAIL_TO / MAIL_SUBJECT_PREFIX
vi ~/.config/dsh-remote/notify.conf
dsh-remote notify-test --provider graph
```

---

## 8. 它是怎么工作的（可选，排错时有用）

1. `dsh-notify-graph-setup` 用 **device code flow** 向
   `https://login.microsoftonline.com/<租户>/oauth2/v2.0/devicecode` 要一个短码；
   你在浏览器里登录并同意 `offline_access Mail.Send openid profile`。
2. 脚本按返回的 `interval` 轮询 token 端点（`authorization_pending` 继续等，
   `slow_down` 自动放慢），拿到 **refresh token**，写进 600 的 `notify.conf`。
   refresh token 不出现在屏幕、argv 或仓库里。
3. 之后每次推送：
   - 看 `~/.local/state/dsh-remote/graph-token.json` 里的 access token 是否还有效，
     有效就直接用；无效就用 refresh token 换新的（`grant_type=refresh_token`）；
   - 微软如果随响应发来**新的 refresh token**，自动回写 `notify.conf`（只改那一行）；
   - `POST https://graph.microsoft.com/v1.0/me/sendMail`，`Authorization: Bearer ...`，
     JSON 里带 `subject` / `body{contentType:"Text"}` / `toRecipients` /
     `saveToSentItems:true`；
   - **HTTP 202 = 成功**；其它状态码把 Graph 的 `error.code` /
     `error.message` 原样打出来。

`dsh-notify` 只用 `curl` + `python3`，**不需要 jq**。

---

## 9. 不想跑脚本 / 环境变量

手工配置也可以，把第 4 节那几个键写进 `notify.conf` 即可（refresh token 得自己
从别处拿；不推荐）。

测试或临时改端点时认这几个环境变量（正常别设）：

| 变量 | 作用 |
|---|---|
| `GRAPH_TOKEN_URL` | 覆盖 token 端点（测试用假端点） |
| `GRAPH_SENDMAIL_URL` | 覆盖 sendMail 端点 |
| `GRAPH_DEVICECODE_URL` | 覆盖授权脚本的 device code 端点 |
| `GRAPH_TOKEN_CACHE` | 覆盖 access token 缓存路径 |
| `DSH_NOTIFY_CONF` | 换 notify.conf 路径 |
| `DSH_NOTIFY_LOG` | 换 notify.log 路径 |

测试用的假端点在 `tests/fake_graph.py`，**不联网**。

---

## 10. 明天的最少步骤

1. 打开 <https://entra.microsoft.com>，注册应用（名字 `dsh-notify`，账户类型按自己情况）→
   抄 **Application (client) ID**。
2. API permissions → Microsoft Graph → **Delegated**：`Mail.Send`、`offline_access`、
   `openid`、`profile`。
3. Authentication → **Allow public client flows = Yes** → Save。
4. 终端跑 `dsh-notify-graph-setup`，按提示填 client id / 收件人，浏览器输码。
5. 跑 `dsh-remote notify-test`，收到邮件就完事。
6. `dsh-remote notify-enable` 打开自动推送。

全程不需要客户端密钥、不需要 SMTP AUTH、不需要管理员（个人 outlook.com）。
公司 M365 最多多一步：让管理员点"授予管理员同意"。
