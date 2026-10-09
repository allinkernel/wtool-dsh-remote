# ADR-0021：`dsh-web-run` 起 npx 前**默认清空代理**（要代理就显式配）

- 状态：Accepted（2026-10-09）
- 相关：ADR-0017（dsh web 常驻 + `dsh-web-run`）、ADR-0020（`harness` 的输出契约：
  "等 20s 没等到地址"就是这条 hazard 的表象）、hazards H28
- 取代：无（新增）。

## 背景（2026-10-09 实测：服务被坏代理卡死，永远不写 token）

WSL 的 `autoProxy=true` 会把 **Windows 注册表里的系统代理**注入环境。开机时
`systemd --user` 抓到了这套环境，`dsh-web.service` 里的 `npx @deepseek-ai/dsh web`
就**永久卡住、永远不写 token**（`web-url.txt` 不存在 → `harness` 等超时 →
broker 回 503 → 手机打不开）；而**手工**跑 npx 前先 `proxy_off` 就一切正常。

关键在于"服务的环境不是你的环境"：

- 交互 shell 里代理是**会话级**的，用户随手 `proxy_on` / `proxy_off`；
- 而 `systemd --user` 是在**开机那一刻**把环境**快照**下来的（`systemctl --user
  show-environment` 看得到），之后**不会**跟着你的 shell 变；
- 于是同一个 npx，在终端里好的、在服务里卡死 —— 症状看起来像"npx 坏了 / dsh 坏了"，
  实际是"服务继承了一个连不通的代理端口"。

## 决定

1. `bin/dsh-web-run` 在起 npx **之前**显式处理代理：
   **默认 `unset`** `http_proxy` / `https_proxy` / `HTTP_PROXY` / `HTTPS_PROXY` /
   `all_proxy` / `ALL_PROXY`；**保留** `no_proxy` / `NO_PROXY`
   （那是"哪些不走代理"的名单，清掉只会更容易误伤内网/回环）。
2. **要代理就显式给**：`remote.conf` 里 `web_proxy=<url>`，或环境变量
   `DSH_REMOTE_WEB_PROXY=<url>`（**后者优先** —— 临时改一次不用动文件）。
   给了就把上面六个变量都设成该值。
3. **日志里必须留一行判据**：`代理: 已清空（…；no_proxy 保留：<值或 没设>）`
   或 `代理: =<值>（来自 <哪来的>；no_proxy 保留：…）` —— 服务起来就写进 journald，
   `journalctl --user -u dsh-web.service` 第一条就能看到。
4. **只动服务这条链**：用户在交互 shell 里的 `harness`（前台那条）**不碰**代理 ——
   那是用户自己的会话，他有 `proxy_on`/`proxy_off`；我们不替他决定。

## 理由

- 服务要的是"连得上 npm / dsh"，不是"跟着桌面会话的代理走"。桌面代理是给浏览器和
  交互命令用的，它**随时可能不在**（关机、换网络、代理软件没起）—— 让开机自启的常驻
  服务依赖它是错的方向。
- 默认清空 + 显式开关，比"默认继承 + 出问题再说"可诊断：日志里那一行把
  "代理是不是元凶"这条排查路**变成一次 grep**。
- 保留 `no_proxy` 是有意的：它通常是内网/回环白名单，清掉会改变"哪些地址直连"的语义。

## 否决

- **默认什么都不做（只写文档让人自己配）**：坏代理是**开机时**注入的，
  用户根本不会在"服务卡住"时想到去看 systemd 的环境快照；这条 hazard 已经真实发生过一次。
- **只在 `dsh-web.service` 单元里写 `Environment=` 清空**：那只覆盖 systemd 这条链，
  `dsh-web-run` 被手工/别的包装拉起时照样中招；而且改单元要 `daemon-reload`，
  不如把策略放在脚本里（脚本是唯一入口）。
- **顺手把 `no_proxy` 也清掉**：见上，语义不同，清了更容易出别的问题。
- **给 npx 加 `--no-proxy` 之类的 npm 参数**：npm 的代理配置来源很多
  （env / `npm_config_*` / `.npmrc`），逐个堵不如在环境层清干净；而且 dsh web 自己
  也可能发请求，不只是 npm。
- **连 `harness` 前台那条一起清**：越权动了用户会话的环境（见决定 4）。

## 判据 / 后果

- **静态**：`bin/dsh-web-run` 里那六个 `unset` 与两个来源的读取顺序（env > conf）。
- **动态（回归在 O 节 ⑦）**：桩 npx 把**子进程**里 `env | grep -i proxy` 的全文 dump 到
  探针文件，再断言 —— ① 带坏代理启动后子进程里**没有**那六个变量、`no_proxy`/`NO_PROXY`
  还在；② `web_proxy=` 时六个变量都等于它、日志写 `代理: =<值>`；
  ③ `DSH_REMOTE_WEB_PROXY` 覆盖 `remote.conf`。
  （只断言日志不算数：日志说"已清空"而子进程还带着代理，这一条就会红。）
- **现场判据**（本机，只读）：

  ```sh
  systemctl --user show-environment | grep -i proxy      # 服务管理器那一份快照
  journalctl --user -u dsh-web.service -n 5 -o cat       # 应有「[dsh-web-run] 代理: 已清空（…）」
  ```
  2026-10-09 实测：本机 3080 上跑着用户手起的实例，`dsh-web.service` 每 30 秒重试一次，
  那行"代理: 已清空"每次重启都出现在 journal 里（见 `journal.md` 第 24 轮）。
- **反例（同一个现象的对照）**：手工跑 npx 之前 `proxy_off` → npx 正常启动。
