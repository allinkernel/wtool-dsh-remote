# ADR-0025：Outlook 推送走 Microsoft Graph（device code + refresh token），不走 SMTP AUTH

- 状态：Accepted（2026-10-21，用户要求"实现用 Outlook / Microsoft Graph 发邮件的推送后端"）
- 相关：ADR-0010（`dsh-notify` 退出码永远是 0）、ADR-0009（配置/日志不放 `~/.dsh`）
- 取代：无（新增）

## 背景

`dsh-notify` 原来有 Server酱 / 钉钉 / Telegram / Bark / generic 五种 provider。
用户要再加一条**用 Outlook / Microsoft 365 发邮件**的路，并且明天要自己配置。

这条路有两个现实约束：

1. **SMTP AUTH 不可靠**：微软在逐步关 basic auth；M365 租户默认常把 SMTP AUTH
   整个关掉（安全默认值），个人账户也在收紧。用"邮箱 + 应用密码"是逆着走。
2. **不能要求用户存密码**：存邮箱密码等于把账号交出去；应用密码也是长期凭据，
   泄露了照样能发信，而且没法单独撤销。

另外机器上**可能没有 `jq`**（虽然开发机有），不能把 JSON 解析押在它身上。

## 决定

1. **用 Microsoft Graph 的 delegated `/me/sendMail`**，不是 SMTP，也不是
   application permission（客户端凭据）。
2. **授权用 device code flow**（公共客户端）：
   `POST .../devicecode` 拿 `user_code` + `verification_uri`，用户在任意浏览器里
   登录并同意 `offline_access Mail.Send openid profile`，脚本轮询 token 端点拿
   **refresh token**。**不需要客户端密钥**，注册应用时也不用填 redirect URI。
3. **refresh token 是唯一的长期凭据**，只写进 `notify.conf`（600）；
   `dsh-notify` 每次发信前用它换 access token，access token 缓存在
   `$STATE_DIR/graph-token.json`（600，60 秒余量）。
4. **refresh token 轮换要回写**：token 响应带新的 `refresh_token` 就重写
   `notify.conf` 的 `GRAPH_REFRESH_TOKEN=` 那一行（保留其它键/注释，600）。
5. **成功判据是 HTTP 202**（Graph `sendMail` 的契约）；200 不算成功。
6. **JSON 全部用 python3** 生成/解析，**不依赖 jq**；refresh token 用
   `curl --data-urlencode name@file` 传，**不进 argv**（`ps` 看不见）。
7. **失败可诊断**：把 Graph 的 `error.code` / `error.message` 或 OAuth 的
   `error` / `error_description` / `error_codes` 打一行到 stderr + `notify.log`，
   **任何 token 都不打印**；`--provider graph` 让 `notify-test` 能只测这一条。
8. **授权脚本 `dsh-notify-graph-setup` 是独立的 bin 命令**（`install.sh` 装），
   不是给用户看的文档里的手工步骤；配置写入保留其它键、先备份、600。

## 理由

- **Graph 是微软现在推荐的路**：delegated `Mail.Send` 以用户本人身份发信，
  权限可以单独撤销（Entra / 我的应用）；device code 让"没有浏览器回调地址"的
  命令行程序也能授权，用户只需要输一个短码。
- **refresh token 放 600 的配置文件**是现有 `notify.conf` 体系里最自然的位置：
  `dsh-notify` 已经在那儿读 key，不需要引入第二套凭据存储；日志/状态目录只放
  **短命的 access token**，泄露面小。
- **202** 是 Graph 的契约（异步排队发送），按 200 判成功会把"其实没排队"
  当成成功；反过来把 202 当失败会重复发信。
- **不依赖 jq**：`dsh-notify` 已经要求 python3 解析 hook JSON（没有就退化），
  graph 直接把 python3 当硬依赖并在缺失时给出明确信息，比"悄悄发不出去"好。
- **轮换回写**：微软会轮换 refresh token；不回写的话旧 token 终有一天失效，
  用户会莫名其妙收不到信。回写失败只警告，不影响这次发信（access token 已到手）。

## 否决

- **SMTP AUTH + 应用密码**：M365 租户常被禁；应用密码是长期全权凭据；
  微软在关 basic auth。用户报错里出现 `SMTP AUTH disabled` 时，本方案的回答是
  "走 Graph 不需要它"，不是"去开 SMTP AUTH"。
- **Application permission + client secret**：要管理员同意、要客户端密钥、
  发信人变成"应用"，而且密钥泄露照样能发信；不适合"发给用户自己"的场景。
- **把 refresh token 也放 `graph-token.json`**：状态目录是运行期缓存，
  可能被清、被备份、被误发；长期凭据只在 600 的配置里，撤销/迁移也更清楚。
- **把 refresh token 放命令行参数**：`ps` / 审计日志可见；用 curl 的 `name@file`。
- **用自己的 JSON 转义（sed）**：正文里有 emoji / 引号 / 换行时必然出错；
  python3 本来就在。
- **成功判 200（或 2xx 任意）**：违反 Graph 契约，见上。
- **在助手这轮真调微软端点/填真凭据**：用户明确说"不要真的发信、不要填真实凭据"；
  测试全打本地假端点（`tests/fake_graph.py`）。

## 后果 / 判据

- 新增配置键：`GRAPH_CLIENT_ID` / `GRAPH_TENANT` / `GRAPH_REFRESH_TOKEN` /
  `MAIL_TO`，可选 `GRAPH_SCOPE` / `MAIL_SUBJECT_PREFIX`；样板里全是占位符。
- 新增命令 `dsh-notify-graph-setup`；`install.sh` 的装/卸两份清单都要带上它。
- 测试（`tests/run_tests.sh` C2 节，76 条）用假端点覆盖：换 token 成功/失败、
  202 成功、403 `ErrorSendAsDenied` 透出、HTTP 200 不算成功、refresh token 轮换
  回写、token 缓存命中/过期、`--provider` 覆盖、`dsh-remote notify-test` 转发、
  device code 的 pending / slow_down / declined / expired、配置 600 + 备份 + 保留
  其它键。
- **验证边界**：真微软端点一次都没调，真账号一次都没授权 —— 那是用户明天按
  `docs/notify-outlook-graph.md` 做的事。测试 token 全是 `FAKE-*`。
- 用户可见的完整步骤、排错表、撤销方法在 `docs/notify-outlook-graph.md`；
  现状（代码怎么走）在 `architecture.md` §7。
