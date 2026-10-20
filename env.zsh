# env.zsh —— 手机远程接管的客户端环境（zsh 版，和 env.bash 等价）
#
# 这个项目几乎不需要 shell 集成：命令本体是 $WTOOL_PREFIX/bin/dsh-remote 和
# dsh-notify（由 scripts/install.sh 软链进去），$WTOOL_PREFIX/bin 由引擎保证
# 在 PATH 上。这里只导出两个目录变量，方便脚本互相找、也方便人去看配置。
#
# 两份必须同改；tests/run_tests.sh 会用同一张用例表把两个 shell 都跑一遍。

# 由 wtool 的加载器在 source 之前导出 WTOOL_PROJECT_DIR（= 引擎的 L1 中转链接
# <WTOOL_HOME>/wtool/dsh-projects/dsh-remote）。
# 单独 source（不经 wtool）时的兜底**从 WTOOL_HOME 推**，别写死家目录 ——
# WTOOL_HOME 默认是引擎的 .wtool 根（${HOME}/.wtool，见 wtool.sh），换 .wtool
# 根目录装（影子家 / 临时家 / 测试）时写死家目录会指到一个不存在的路径。
DSH_REMOTE_DIR=${WTOOL_PROJECT_DIR:-${WTOOL_HOME:-${HOME}/.wtool}/wtool/dsh-projects/dsh-remote}
export DSH_REMOTE_DIR

# 配置和日志**不放 ~/.dsh** —— 那是 DSH 自己的目录。我们只在那里放一样
# 它强制要求的东西：profiles/web/cordis.patch.yml（profile patch 只能在那儿）。
# 自己的东西放标准位置：
#   ~/.config/dsh-remote/        remote.conf / notify.conf / hooks.json
#   ~/.local/state/dsh-remote/   notify.log / web.log / web-url.txt
# 这两个变量只是把它们显式导出，方便人和脚本找；DSH_REMOTE_HOME 是测试用的
# 伞覆盖（设了它两个目录都在它下面）。
export DSH_REMOTE_CONF_DIR=${DSH_REMOTE_CONF_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/dsh-remote}
export DSH_REMOTE_STATE_DIR=${DSH_REMOTE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dsh-remote}

# --------------------------------------------------------------- harness 函数
# `harness` = **本地管理器**：有 `dsh web` 就立刻开浏览器；没有才起一个。
#
# 这是 2026-10-09 用户明确重做的语义（ADR-0024），一句话：
#   "任意时刻执行 harness，它立刻检查有没有 dsh web，有就立刻打开浏览器，
#    没有就自己打开一个。**不许再有'等 20 秒'那种行为。**"
# 所以这个函数只有两条路：
#   ① 127.0.0.1:<端口> 已经有人听 → 打**一行**状态（是 systemd 托管还是手工起的）
#      → 立刻开浏览器 → return 0。**不再起第二个、不等待、不重启**。
#   ② 没人听 → 起一个（优先 dsh-web.service，它才会把 token 抓成文件；
#      没有那个单元就用命令行给的端口走前台 `npx … dsh web`）→ 端口一出现
#      （最多 DSH_REMOTE_HARNESS_WAIT 秒，默认 10）→ 打一行状态 → 开浏览器。
#
# 开浏览器（②③ 两路都要）：依次试 wslview → cmd.exe → explorer.exe → xdg-open，
# 谁都不在就只打印地址。**打开失败不算失败**（rc 仍是 0，只多一行提示）——
# 这个命令的职责是"让会话起来并给出地址"，浏览器只是顺手（ADR-0024）。
#
# 输出契约（ADR-0020 的"状态 + 原因 + 判据"风格，**整条命令 ≤3 行**）：
#   harness: dsh web 已在跑 ✓  http://127.0.0.1:3080/（PID 152050，systemd 托管 / 手工起的）
#   URL: http://127.0.0.1:3080/（+ 一行 opener 结果，或"没有 opener，自己去开"）
#
# `dsh web` 的 token 是**每个进程随机、只在它内存里**的（H22），所以：
#   * 地址优先用 web-url.txt 里那份（带了 token，本机直接可用）；
#     没有就退回 http://127.0.0.1:<端口>/ —— 浏览器通常已经有 30 天 cookie，
#     服务托管那条路上 broker 也会把不带 token 的入口 302 到当前 token。
#   * **不**为了凑 token 去多等：`--no-open` 是给 npx 的，浏览器由我们开。
#
# 参数：`--port <n>` 由我们接下来（默认取 remote.conf 的 local_port，再默认 3080），
# **其余原样透传**给 `npx @deepseek-ai/dsh web`（例如 `--no-open`）。
#
# 为什么还要包一层（老理由，仍然成立）：`dsh web` 的 token 是**每个进程随机、
# 只在内存里**的（32 字节 base64url；`dsh web --help` 和 dsh-client-connection 的
# `processLaunchToken` 里都没有"固定 token / 关鉴权"的开关，2026-10-07 查过）。
# 手机要访问的固定地址靠家里的 token broker（`dsh-remote broker-install`，默认
# 127.0.0.1:3081）302 到当前 token —— 走服务那条路是 `dsh-web-run` 在写：
#
#   $DSH_REMOTE_STATE_DIR/current-token.txt      只有 token 一行（600）—— broker 的数据源
#   $DSH_REMOTE_STATE_DIR/web-url.txt            带 token 的完整地址（600，和 `dsh-remote serve` 同一份）
#   $DSH_REMOTE_STATE_DIR/.harness-wrote-token   "这份是我写的"标记（本函数退出时 cmp 过才删）
#
# 只有"没有 dsh-web.service、必须前台起 npx"那条路才由本函数自己抓 token；
# 抓到了就留着（这样 broker 能用），退出时按标记删掉自己写的那一份。
#
# 环境变量：
#   DSH_HARNESS_OPENER=<命令名>   指定开浏览器用的命令（**没设 = 按顺序自动探**；
#                                 设成 `quiet` / `none` / 空 = 什么都不试，直接打印 URL）
#                                 例：DSH_HARNESS_OPENER=/tmp/我的opener
#   DSH_REMOTE_HARNESS_WAIT=<秒>  ②那条最多等端口出现多久（默认 10；0 = 不等）
#   DSH_REMOTE_HARNESS_UNIT=<单元名>  换一个单元名（给一个不存在的 = 强制前台起 npx）
#
# ⚠️ **别名优先于函数**：如果你（或旧文档）写过 `alias harness='npx @deepseek-ai/dsh web'`，
# 先 `unalias harness` —— 本文件在 source 时也会替你 unalias 一次。
# 想在后台起、不占用终端，用 `dsh-remote serve`（它同样把 token 存进 web-url.txt）。
unalias harness 2>/dev/null || true

# ---- harness 用的**只读**探测（两份 env 逐字相同；一个字节都不写）------------
# XDG_RUNTIME_DIR 在非登录 shell（WSL / cron / 手工 sh）里可能是空的，那时
# `systemctl --user` 会报 "Failed to connect to bus"，而用户管理器其实活着 ——
# 只在这一次调用里补一个（和 bin/dsh-remote 的 systemctl_user 同一个约定）。
_hr_sctl() {
    if [ -z "${XDG_RUNTIME_DIR:-}" ] && [ -d "/run/user/$(id -u 2>/dev/null)" ]; then
        XDG_RUNTIME_DIR="/run/user/$(id -u)" systemctl --user "$@"
    else
        systemctl --user "$@"
    fi
}

_hr_listening() { # 127.0.0.1:<端口> 有人在听吗（ss；没有 ss 就 curl 敲一下）
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | grep -q "127.0.0.1:$1 "
    elif command -v curl >/dev/null 2>&1; then
        curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$1/" 2>/dev/null
    else
        return 1
    fi
}

_hr_port_line() { # 听 <端口> 的那一行原文（任何地址；ss -ltnp 拿不到就是空）
    command -v ss >/dev/null 2>&1 || return 0
    ss -ltnp 2>/dev/null | grep -E "[:.]$1[[:space:]]" | head -n 1
}

_hr_port_pid() { # 听 <端口> 的那个 PID；拿不到就打印空（那时只说"被占"，不编 PID）
    _hr_port_line "$1" | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p'
}

_hr_port_taken() { # 这个端口上有人听吗（任何地址 —— 那正是"服务绑不上"的原因）
    [ -n "$(_hr_port_line "$1")" ] && return 0
    _hr_listening "$1"   # 没有 ss 时退回 curl 那一招
}

_hr_unit_prop() { # $1=单元 $2=属性（MainPID/SubState/…）—— 拿不到就打印空
    local _v
    _v=$(_hr_sctl show "$1" -p "$2" --value 2>/dev/null | head -n 1)
    [ -n "${_v}" ] || _v=$(_hr_sctl show "$1" -p "$2" 2>/dev/null | head -n 1 | sed "s/^$2=//")
    printf '%s' "${_v}"
}

_hr_pid_in_unit() { # $1=PID $2=单元名：这个 PID 跑在那个单元里吗（cgroup 比只比 MainPID 稳）
    [ -n "${1:-}" ] || return 1
    [ -n "${2:-}" ] || return 1
    grep -qF -- "$2" "/proc/$1/cgroup" 2>/dev/null
}

_hr_url_of() { # $1=端口 $2=web-url.txt → 能打开的地址。文件里有**这个端口**的地址就用它
    # 带了 token 的地址优先（H22：token 只在内存里，文件里那份可能已经作废，
    # 但对自己起的实例它是对的；验 token 要多打一次请求，这里不为此多等）。
    # 端口对不上就别用 —— 那多半是别的实例上一次留下的（ADR-0024）。
    if [ -s "${2:-}" ]; then
        local _u
        _u=$(head -n 1 "$2" 2>/dev/null)
        case $_u in
        *":$1/"* | *":$1?"*) printf '%s' "$_u" && return 0 ;;
        esac
    fi
    printf 'http://127.0.0.1:%s/' "$1"
}

# ---- 开浏览器（三档，**全程不经 shell 拼 URL**；打不开不算失败）--------------
# 2026-10-09 用户实测踩到的坑：把 URL 拼进 shell 字符串（`cmd /c start "$url"`）
# 会被 WSL 的路径转换糟蹋成 `http \127.0.0.1 3984\token=MTOK`，Windows 弹
# "找不到文件"框。**这条路的错在"经 shell"，不是错在 opener 选得不对。**
# 所以照 DSH 自己的做法（@deepseek-ai/dsh-web-app：`spawn(node, […,'--',url])`
# + 用 npm 的 `open@11` 包 + 起之前 scrub 掉代理）：
#   ① 首选：`node <临时脚本> <url> <open 包根>` —— 脚本里 `import open`，
#      纯 argv、绝不过 shell；`open` 包自己会按平台/WSL 选 opener 并正确传参。
#   ② 退档：`explorer.exe` / `wslview` / `xdg-open` —— 也是 exec **一个 argv
#      数组**（`"$_o" "$_url"`），不拼字符串。
#   ③ 再退：什么都不试，只打印地址（**rc 恒 0**）。
# 环境变量：
#   DSH_HARNESS_OPENER=<命令名>    只用这个命令开（**只换命令，URL 仍是 argv**；
#                                  测试就靠它桩掉）。quiet / none / 空 = 第③档。
#   DSH_HARNESS_OPEN_ROOT=<npx 缓存目录>  显式指定 `open` 包在哪儿（跳过探测）
#   DSH_HARNESS_OPENER_LOG=<文件>  把"本来要 spawn 什么"记一行（现场排障用）
_hr_open_pkg() { # 找 npx 缓存里的 `open` 包根（找到打印，找不到打印空）
    local _p
    if [ -n "${DSH_HARNESS_OPEN_ROOT:-}" ]; then
        if [ -f "${DSH_HARNESS_OPEN_ROOT}/node_modules/open/index.js" ]; then
            printf '%s' "${DSH_HARNESS_OPEN_ROOT}"
        fi
        return 0
    fi
    for _p in "${HOME:-$PWD}"/.npm/_npx/*; do
        [ -f "$_p/node_modules/open/index.js" ] || continue
        printf '%s' "$_p"
        return 0
    done
    return 0
}

_hr_open() {
    local _url=$1 _o= _rc=1 _mode= _root= _js= _cand= _log=${DSH_HARNESS_OPENER_LOG:-}
    [ -n "${_log}" ] && printf 'opener=%s url=<%s>\n' "${DSH_HARNESS_OPENER-unset}" "${_url}" >>"$_log" 2>/dev/null

    local _want=${DSH_HARNESS_OPENER-unset}
    case ${_want} in
    quiet | none | '')
        printf 'harness: 没开浏览器（DSH_HARNESS_OPENER=%s）—— 自己去开上面那个地址\n' "${_want:-空}"
        return 0
        ;;
    unset) ;;
    *) _o=$_want ;;
    esac

    # ① node + open 包（无 shell）。open 的入口走**文件 URL**，不能用裸路径 import。
    if [ -z "${_o}" ] && command -v node >/dev/null 2>&1; then
        _root=$(_hr_open_pkg)
        if [ -n "${_root}" ]; then
            _js=${TMPDIR:-/tmp}/.harness-open.$$.mjs
            if cat >"$_js" 2>/dev/null <<'JSEOF'
const argv = process.argv.slice(2);
const [url, root] = argv;
for (const k of Object.keys(process.env)) {
    if (k === 'no_proxy' || k === 'NO_PROXY') continue;
    if (/^(https?|all)_proxy$/i.test(k)) delete process.env[k];
}
const { pathToFileURL } = await import('node:url');
const mod = await import(pathToFileURL(root + '/node_modules/open/index.js').href);
await mod.default(url, { wait: false });
process.exit(0);
JSEOF
            then
                if node "$_js" "$_url" "$_root" >/dev/null 2>&1; then
                    _rc=0
                    _mode='node + open 包'
                fi
            fi
            rm -f -- "$_js" 2>/dev/null
        fi
    fi

    # ② explorer.exe / wslview / xdg-open（只传 argv，绝不拼字符串）。
    #    ⚠️ 循环里**一旦把某个候选清成空就必须 break** —— 否则后面 `command -v ""`
    #    会报错，还继续拿清空的 `_o` 往下走（2026-10-09 实测：`command -v` 的
    #    退出码被误当成"这个命令在"）。
    if [ "${_rc}" != 0 ] && [ -z "${_o}" ]; then
        for _cand in explorer.exe wslview xdg-open; do
            if command -v "$_cand" >/dev/null 2>&1; then
                _o=$_cand
                break
            fi
        done
    fi
    if [ "${_rc}" != 0 ] && [ -n "${_o}" ]; then
        if command -v "$_o" >/dev/null 2>&1; then
            [ -n "${_mode}" ] || _mode=$_o
            "$_o" "$_url" >/dev/null 2>&1 && _rc=0
        else
            _mode="$_o 不在"
            _rc=1
        fi
    fi

    # ③ 结果（一行；开不了也 rc=0 —— 会话已经起来了，地址也打出来了）
    if [ "${_rc}" = 0 ]; then
        printf 'harness: 已用 %s 打开浏览器\n' "${_mode}"
    else
        printf 'harness: 开不了浏览器（试过 %s）—— 自己去开上面那个地址\n' "${_mode:-没有 opener}"
    fi
    return 0
}

harness() {
    unalias harness 2>/dev/null || true
    local _hr_state _hr_tok _hr_url _hr_conf _hr_unit _hr_lp _hr_have_unit _hr_args
    local _hr_i _hr_wait _hr_url_before _hr_pid _hr_pid_txt _hr_managed _hr_mark _hr_u _hr_runner
    local _hr_line _hr_cfg_lp _hr_wp _hr_svc _hr_svc_state _hr_npx_pid _hr_fargs _a _hr_log
    _hr_state=${DSH_REMOTE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dsh-remote}
    _hr_tok=$_hr_state/current-token.txt
    _hr_url=$_hr_state/web-url.txt
    _hr_mark=$_hr_state/.harness-wrote-token     # "这份 token 是我写的"（退出时 cmp 过才删）
    _hr_conf=${DSH_REMOTE_CONF_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/dsh-remote}/remote.conf
    # 本仓规矩：常驻由服务负责（ADR-0017）。DSH_REMOTE_HARNESS_UNIT 可以换一个
    # **不存在的**单元名 → 走到"没有服务、前台起 npx"那条（测试离线验它用；
    # 也可用于"我就是要手工起、别碰服务"）。
    _hr_unit=${DSH_REMOTE_HARNESS_UNIT:-dsh-web.service}
    _hr_log=$_hr_state/harness-npx.log           # 前台那条路的 npx 输出（抓 token 靠它）
    mkdir -p -- "$_hr_state" 2>/dev/null
    rm -f -- "$_hr_mark" 2>/dev/null

    # ① 定端口：remote.conf 的 local_port（默认 3080）→ 命令行 --port 覆盖它。
    #    其余参数**一个字节都不动**往下透传（`harness --no-open` 这种）。
    _hr_args=
    _hr_lp=
    while [ $# -gt 0 ]; do
        case $1 in
        --port)
            _hr_lp=${2:-}
            shift 2
            ;;
        --port=*)
            _hr_lp=${1#--port=}
            shift
            ;;
        *)
            _hr_args="$_hr_args $1"
            shift
            ;;
        esac
    done
    if [ -z "${_hr_lp}" ] && [ -f "$_hr_conf" ]; then
        _hr_lp=$(sed -n 's/^[[:space:]]*local_port[[:space:]]*=[[:space:]]*//p' "$_hr_conf" 2>/dev/null | tail -n 1)
    fi
    [ -n "${_hr_lp}" ] || _hr_lp=3080

    # 这个单元装着没有（没 systemctl / 没单元 = 只能走前台）
    _hr_have_unit=0
    if command -v systemctl >/dev/null 2>&1 && _hr_sctl cat "$_hr_unit" >/dev/null 2>&1; then
        _hr_have_unit=1
    fi

    # ── ② 探测：127.0.0.1:<端口> 有人听吗（ss -ltnp）────────────────────────
    #    有人听 = 已经有了（systemd 的、或谁手工起的）→ **只认它，绝不起第二个**
    #    —— 这是用户 2026-10-09 的原话："有就立刻打开浏览器……就是这么简单"。
    _hr_pid=$(_hr_port_pid "${_hr_lp}")
    if _hr_listening "${_hr_lp}"; then
        if [ -n "${_hr_pid}" ]; then _hr_pid_txt="PID ${_hr_pid}"; else _hr_pid_txt='PID 拿不到（ss -ltnp 看不到）'; fi
        _hr_managed=0
        if [ "${_hr_have_unit}" = 1 ] && [ -n "${_hr_pid}" ] \
            && { [ "$(_hr_unit_prop "$_hr_unit" MainPID)" = "${_hr_pid}" ] || _hr_pid_in_unit "${_hr_pid}" "$_hr_unit"; }; then
            _hr_managed=1
        fi
        if [ "${_hr_managed}" = 1 ]; then
            printf 'harness: dsh web 已在跑 ✓  http://127.0.0.1:%s/（%s，systemd 托管）\n' "${_hr_lp}" "${_hr_pid_txt}"
        else
            printf 'harness: dsh web 已在跑 ✓  http://127.0.0.1:%s/（%s，手工起的）\n' "${_hr_lp}" "${_hr_pid_txt}"
        fi
        _hr_u=$(_hr_url_of "${_hr_lp}" "$_hr_url")
        printf 'URL: %s\n' "${_hr_u}"
        _hr_open "${_hr_u}"
        return 0
    fi

    # ── ③ 没人听 → 起一个 ────────────────────────────────────────────────
    #    优先 dsh-web.service：它会（经 dsh-web-run）把 token 抓成文件，而且本仓的
    #    规矩就是"常驻由服务负责、前台只是没装服务时的退路"（ADR-0017）。
    #    命令行显式换了端口（≠ remote.conf 的 local_port）时**不走服务** ——
    #    单元里钉的是配置文件那个端口，拿它去起只会起在别处、还报个假成功。
    _hr_cfg_lp=
    [ -f "$_hr_conf" ] && _hr_cfg_lp=$(sed -n 's/^[[:space:]]*local_port[[:space:]]*=[[:space:]]*//p' "$_hr_conf" 2>/dev/null | tail -n 1)
    [ -n "${_hr_cfg_lp}" ] || _hr_cfg_lp=3080
    # DSH_REMOTE_HARNESS_WAIT=0 是**合法值**（= 不等待，直接看现在有没有人听；测试用它跑快）。
    # 只有"没设"或"设了但不是数字"才退回默认 10。
    if [ -n "${DSH_REMOTE_HARNESS_WAIT:-}" ]; then
        _hr_wait=$(printf '%s' "${DSH_REMOTE_HARNESS_WAIT}" | tr -cd '0-9')
        [ -n "${_hr_wait}" ] || _hr_wait=10
    else
        _hr_wait=10
    fi

    if [ "${_hr_have_unit}" = 1 ] && [ "${_hr_lp}" = "${_hr_cfg_lp}" ]; then
        # --no-block：Type=simple 的单元若绑不上端口会立刻退出并等重试，
        # 同步 start 会把那种情况报成"失败"（其实 systemd 正在按 RestartSec 重试）。
        _hr_sctl start --no-block "$_hr_unit" >/dev/null 2>&1 || true
    elif [ "${_hr_have_unit}" = 1 ]; then
        command -v npx >/dev/null 2>&1 || {
            printf 'harness: 端口 %s 上没人听；%s 钉的是 %s，起不到 %s 上 ✗\n' \
                "${_hr_lp}" "${_hr_unit}" "${_hr_cfg_lp}" "${_hr_lp}"
            printf 'harness:   要么改 remote.conf 的 local_port，要么把 npx 放进 PATH 走前台\n' >&2
            return 127
        }
        _hr_runner=npx
    else
        command -v npx >/dev/null 2>&1 || {
            printf 'harness: 端口 %s 上没人听，PATH 里也没有 npx ✗（这套用法是 npx @deepseek-ai/dsh web）\n' "${_hr_lp}"
            printf 'harness:   有 dsh-web.service 就能走服务：dsh-remote serve-install\n' >&2
            return 127
        }
        _hr_runner=npx
    fi

    # 前台那条路：`npx … dsh web [参数] --port <端口>`，输出边转发边抓 token。
    # 浏览器**不等 npx 退出**：端口一出现就开（ADR-0024），npx 之后继续占着终端。
    if [ "${_hr_runner}" = npx ]; then
        # 参数透传：按字符收集再整体展开（`$_fargs` 不加引号）—— 不做 eval，
        # 也不去引号，`--no-open`、`--trusted-host x` 这种原样带过去。
        _hr_fargs=
        for _a in $_hr_args; do
            _hr_fargs="$_hr_fargs $_a"
        done
        if [ "${_hr_have_unit}" = 1 ]; then
            printf 'harness: 端口 %s 上没人听；命令行换了端口，前台跑 npx（%s 钉的是 %s）\n' \
                "${_hr_lp}" "${_hr_unit}" "${_hr_cfg_lp}"
        else
            printf 'harness: 端口 %s 上没人听，也没有 %s → 前台跑 npx @deepseek-ai/dsh web\n' \
                "${_hr_lp}" "${_hr_unit}"
        fi
        # shellcheck disable=SC2086
        npx @deepseek-ai/dsh web $_hr_fargs --port "${_hr_lp}" >"$_hr_log" 2>&1 &
        _hr_npx_pid=$!
        _hr_i=0
        while [ "${_hr_i}" -lt "${_hr_wait}" ]; do
            _hr_listening "${_hr_lp}" && break
            sleep 1
            _hr_i=$((_hr_i + 1))
        done
        if _hr_listening "${_hr_lp}"; then
            _hr_u=$(_hr_url_of "${_hr_lp}" "$_hr_url")
            printf 'URL: %s\n' "${_hr_u}"
            _hr_open "${_hr_u}"
        fi
        wait "$_hr_npx_pid" 2>/dev/null
        # 抓 token 交给**等它退出之后**的文件解析（不再用管道 + 子 shell：
        # 那样循环里的变量传不出来，等一下都不好加）。
        _hr_line=$(sed -n 's/^.*\(http:\/\/[^ ]*[?&]token=[^ ]*\).*$/\1/p' "$_hr_log" 2>/dev/null | head -n 1)
        case $_hr_line in
        *token=*)
            printf '%s\n' "${_hr_line##*token=}" >"$_hr_tok" && chmod 600 -- "$_hr_tok" 2>/dev/null
            printf '%s\n' "$_hr_line" >"$_hr_url" && chmod 600 -- "$_hr_url" 2>/dev/null
            cp -f -- "$_hr_tok" "$_hr_mark" 2>/dev/null && chmod 600 -- "$_hr_mark" 2>/dev/null
            printf 'harness: 已捕获 token → %s\n' "$_hr_tok"
            ;;
        esac
        # npx 的输出原样转给用户（桩 npx / 真 npx 都一样：先看它说了什么）
        if [ -s "$_hr_log" ]; then
            cat -- "$_hr_log"
        else
            printf 'harness: npx 一行输出都没有（起得来吗？）；日志：%s\n' "$_hr_log" >&2
        fi
        if [ -f "$_hr_mark" ] && [ -s "$_hr_tok" ] && cmp -s -- "$_hr_mark" "$_hr_tok"; then
            rm -f -- "$_hr_tok" "$_hr_mark"
            printf 'harness: npx 退出；token 文件已清掉（broker 回 503，不会 302 到死 token）\n'
        else
            rm -f -- "$_hr_mark" 2>/dev/null
            printf 'harness: 没抓到 token —— 原来的 token 文件**保持不动**（broker 不会因此 503）\n' >&2
        fi
        return 0
    fi

    # ── ④ 服务那条路：**最多等 ~10s 端口出现**（不为 token 多等，ADR-0024）─────
    _hr_url_before=
    [ -s "$_hr_url" ] && _hr_url_before=$(head -n 1 "$_hr_url" 2>/dev/null)
    _hr_i=0
    while [ "${_hr_i}" -lt "${_hr_wait}" ]; do
        _hr_listening "${_hr_lp}" && break
        sleep 1
        _hr_i=$((_hr_i + 1))
    done
    if _hr_listening "${_hr_lp}"; then
        _hr_pid=$(_hr_port_pid "${_hr_lp}")
        _hr_managed=0
        if [ -n "${_hr_pid}" ] && { [ "$(_hr_unit_prop "$_hr_unit" MainPID)" = "${_hr_pid}" ] || _hr_pid_in_unit "${_hr_pid}" "$_hr_unit"; }; then
            _hr_managed=1
        fi
        _hr_svc_state=$(_hr_sctl is-active "$_hr_unit" 2>/dev/null || printf '未知')
        if [ -n "${_hr_pid}" ]; then _hr_pid_txt="PID ${_hr_pid}"; else _hr_pid_txt='PID 拿不到（ss -ltnp 看不到）'; fi
        if [ "${_hr_managed}" = 1 ]; then
            printf 'harness: dsh web 已由 systemd 拉起 ✓  http://127.0.0.1:%s/（%s，%s）\n' \
                "${_hr_lp}" "${_hr_pid_txt}" "${_hr_unit}"
        elif [ "${_hr_svc_state}" = active ] || [ "${_hr_svc_state}" = activating ]; then
            # 这次是我们自己 start 的，而单元 active/activating、端口也在听 ——
            # 只是 `ss -ltnp` 看不到 pid 或 pid 对不上 MainPID（拿不到 ptrace 权限时常见）。
            # 判据：`systemctl --user show -p MainPID --value <单元>` 与 `ss -ltnp` 对一下。
            printf 'harness: dsh web 已由 systemd 拉起 ✓  http://127.0.0.1:%s/（%s，%s is-active=%s）\n' \
                "${_hr_lp}" "${_hr_pid_txt}" "${_hr_unit}" "${_hr_svc_state}"
        else
            # 服务自己不在活跃状态（端口是别人抢的）—— 端口上**确实有东西能服务**，照开
            printf 'harness: 端口 %s 上已有实例在跑 ✓（%s，%s 现在是 %s）\n' \
                "${_hr_lp}" "${_hr_pid_txt}" "${_hr_unit}" "${_hr_svc_state}"
        fi
        _hr_u=$(_hr_url_of "${_hr_lp}" "$_hr_url")
        printf 'URL: %s\n' "${_hr_u}"
        _hr_open "${_hr_u}"
        return 0
    fi

    # ── ⑤ 等不到端口：**说清实测到的原因**，别装成成功；还在起就照常报成功 ──
    _hr_wp=$(_hr_port_line "${_hr_lp}")          # 任何地址上有人在听吗（不只是回环）
    _hr_svc=$(_hr_sctl is-active "$_hr_unit" 2>/dev/null || printf '未知')
    _hr_next=
    if [ -n "${_hr_url_before}" ]; then
        _hr_next="上一份地址（可能是旧的）：${_hr_url_before}"
    else
        _hr_next="看日志：journalctl --user -u ${_hr_unit} -n 20"
    fi
    if [ -n "${_hr_wp}" ]; then
        # 端口在听，但 `_hr_listening` 说回环上没人 —— 多半是别的东西占着这个端口号
        printf 'harness: dsh web 没起来 ✗ 原因：%s 被别人占着（%s，不是回环上的 dsh web）\n' \
            "${_hr_lp}" "$(_hr_port_pid "${_hr_lp}" | sed 's/^/PID /')"
        printf 'harness:   判据：ss -ltnp | grep -E "[:.]%s "；journalctl --user -u %s -n 20\n' "${_hr_lp}" "${_hr_unit}"
        printf 'harness:   %s\n' "${_hr_next}"
        return 1
    fi
    case ${_hr_svc} in
    activating | active)
        # 服务还在起（Type=simple + 冷启动的 npx 可能超过等待窗口）：**这不是失败**
        printf 'harness: dsh web 还在起 … 等了 %ss，%s 上还没人听（%s is-active=%s）；它自己会继续\n' \
            "${_hr_wait}" "${_hr_lp}" "${_hr_unit}" "${_hr_svc}"
        printf 'harness:   判据：ss -ltn | grep -E "[:.]%s "；journalctl --user -u %s -n 20\n' "${_hr_lp}" "${_hr_unit}"
        printf 'harness:   %s\n' "${_hr_next}"
        return 0
        ;;
    esac
    printf 'harness: dsh web 没起来 ✗ 原因：%s 上没人听，%s is-active=%s\n' \
        "${_hr_lp}" "${_hr_unit}" "${_hr_svc}"
    printf 'harness:   判据：systemctl --user is-active %s；ss -ltn | grep -E "[:.]%s "\n' "${_hr_unit}" "${_hr_lp}"
    printf 'harness:   %s\n' "${_hr_next}"
    return 1
}
