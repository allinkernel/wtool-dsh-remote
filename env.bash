# env.bash —— 手机远程接管的客户端环境（bash 版，和 env.zsh 等价）
#
# 这个项目几乎不需要 shell 集成：命令本体是 $WTOOL_PREFIX/bin/dsh-remote 和
# dsh-notify（由 scripts/install.sh 软链进去），$WTOOL_PREFIX/bin 由引擎保证
# 在 PATH 上。这里只导出两个目录变量，方便脚本互相找、也方便人去看配置。
#
# 两份必须同改；tests/run_tests.sh 会用同一张用例表把两个 shell 都跑一遍。

# 由 wtool 的加载器在 source 之前导出 WTOOL_PROJECT_DIR（= 引擎的中转链接
# <影子 HOME>/.wtool/wtool-work-dir/links/tools/dsh-remote）。
# 单独 source（不经 wtool）时的兜底**从 WTOOL_HOME 推**，别写死 $HOME ——
# 换 WTOOL_HOME 装（影子家 / 临时家 / 测试）时写死 $HOME 会指到一个不存在的路径。
DSH_REMOTE_DIR=${WTOOL_PROJECT_DIR:-${WTOOL_HOME:-$HOME}/.wtool/wtool-work-dir/links/tools/dsh-remote}
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
# `harness` = 起 dsh web，并把它启动时打印的 token 捕获下来。
#
# 为什么要包一层：`dsh web` 的 token 是**每个进程随机、只在内存里**的（32 字节
# base64url；`dsh web --help` 和 harness 源码里都没有"固定 token / 关鉴权"的开关，
# 2026-10-07 查过 dsh-client-connection 的 processLaunchToken）。手机要访问的固定
# 地址靠家里的 token broker（`dsh-remote broker-install`，默认 127.0.0.1:3081）
# 302 到当前 token —— 所以 token 必须落到一个文件里，就是下面这个函数干的。
#
#   $DSH_REMOTE_STATE_DIR/current-token.txt      只有 token 一行（600）—— broker 的数据源
#   $DSH_REMOTE_STATE_DIR/web-url.txt            带 token 的完整地址（600，和 `dsh-remote serve` 同一份）
#   $DSH_REMOTE_STATE_DIR/.harness-wrote-token   "这份是我写的"标记（退出时 cmp 过才删）
#   $DSH_REMOTE_STATE_DIR/.harness-wait-start    等 systemd 写地址的起点（判 web-url.txt 是不是**刚**写的）
#
# **输出契约（2026-10-09 用户要求；见 docs/adr/0020-harness-status-output-contract.md）**：
# 正常最多 4–5 行、每行都要有信息量，第一行永远是**状态 + 为什么** ——
# 不许"交给常驻服务 dsh-web.service…"然后沉默等待：
#
#   harness: dsh web 已在跑 ✓  http://127.0.0.1:3080（PID 152050，非 systemd）
#   harness: dsh web 已由 systemd 拉起 ✓  http://127.0.0.1:3080/?token=…（PID 152051，dsh-web.service）
#   harness: dsh web 没起来 ✗ 原因：<实测出来的那一条>
#   harness:   判据：<自己复现这个结论的命令>
#
# **原因不许猜**，全都来自实测：`ss -ltnp`（谁占着端口）、
# `systemctl --user is-active / show -p SubState/NRestarts/ExecMainStatus/MainPID`、
# `journalctl -o cat -n 1`（最后一行原文），以及拿真请求探一次 token
# （无效 = 401、有效 = 303/200，2026-10-09 在本机实测）。
#
# 退出时删掉 current-token.txt：宁可让 broker 回 503「还没起」，也别 302 到一个死 token。
# 参数原样透传（`harness --no-open` / `harness --port 3090` 都行）。
#
# 环境变量：
#   DSH_REMOTE_HARNESS_NO_REUSE=1   跳过"复用/交给服务"，永远走前台
#                                   （测试用它验前台抓 token；"我就想再起一个"也用它）
#   DSH_REMOTE_HARNESS_WAIT=<秒>    systemd 那条最多等多久写出地址（默认 20；测试用它跑快）
#
# ⚠️ **别名优先于函数**：如果你（或旧文档）写过 `alias harness='npx @deepseek-ai/dsh web'`，
# 先 `unalias harness` —— 本文件在 source 时也会替你 unalias 一次。
# 想在后台起、不占用终端，用 `dsh-remote serve`（它同样把 token 存进 web-url.txt，
# 但它在后台跑、不接管当前终端）。
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

_hr_unit_prop() { # $1=单元 $2=属性（MainPID/SubState/NRestarts/ExecMainStatus/RestartUSec…）
    local _v
    _v=$(_hr_sctl show "$1" -p "$2" --value 2>/dev/null | head -n 1)
    [ -n "${_v}" ] || _v=$(_hr_sctl show "$1" -p "$2" 2>/dev/null | head -n 1 | sed "s/^$2=//")
    printf '%s' "${_v}"
}

_hr_pid_in_unit() { # 这个 PID 跑在这个单元里吗（cgroup 里带单元名 —— 比只比 MainPID 稳）
    [ -n "${1:-}" ] || return 1
    [ -n "${2:-}" ] || return 1
    grep -qF -- "$2" "/proc/$1/cgroup" 2>/dev/null
}

_hr_journal_last() { # journal 最后一行原文（拿不到就是空）
    command -v journalctl >/dev/null 2>&1 || return 0
    journalctl --user -u "$1" -n 1 --no-pager -o cat 2>/dev/null | tail -n 1
}

_hr_url_fresh() { # 地址文件是"这次刚写的"吗：$1=web-url.txt $2=起点标记 $3=起点时的内容
    # 两条判据取或：**比标记新**，或者**内容变了**。只比 mtime 不够 —— 同一毫秒里
    # 写完两个文件时 mtime 会一模一样（文件时间戳用的是粗粒度时钟），`-nt` 就假阴性。
    [ -s "$1" ] || return 1
    [ "$1" -nt "$2" ] && return 0
    [ "$(cat "$1" 2>/dev/null)" != "$3" ] && return 0
    return 1
}

_hr_token_probe() { # $1=端口 $2=token → ok / bad / 空。dsh web 对无效 token 回 401（本机实测）
    command -v curl >/dev/null 2>&1 || return 0
    local _c
    _c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$1/?token=$2" 2>/dev/null)
    case ${_c} in
    2*|3*) printf 'ok' ;;
    4*|5*) printf 'bad' ;;
    esac
}

_hr_svc_note() { # 单元的实测状态拼一句人话（带 SubState / 重试次数 / RestartSec）
    local _s=${1:-} _sub=${2:-} _n=${3:-} _rs=${4:-}
    [ -n "${_s}" ] || _s=未知
    [ -n "${_sub}" ] && [ "${_sub}" != "${_s}" ] && _s="${_s}/${_sub}"
    # "还没到最终状态"才有重试次数可讲；inactive/failed 是终态，带上反而误导
    case ${_s} in
    activating*)
        if [ -n "${_n}" ]; then
            printf '%s（已重试 %s 次%s）' "${_s}" "${_n}" "${_rs:+，每 ${_rs} 一次}"
        else
            printf '%s' "${_s}"
        fi
        ;;
    *) printf '%s' "${_s}" ;;
    esac
}

harness() {
    unalias harness 2>/dev/null || true
    if ! command -v npx >/dev/null 2>&1; then
        printf 'harness：PATH 里没有 npx（这套用法是 npx @deepseek-ai/dsh web）\n' >&2
        return 127
    fi
    local _hr_state _hr_tok _hr_url _hr_conf _hr_line _hr_u _hr_pub _hr_mark _hr_lp _hr_live _hr_i
    local _hr_unit _hr_have_unit _hr_svc _hr_sub _hr_main _hr_pid _hr_pid_txt _hr_managed _hr_tokfile
    local _hr_wait_start _hr_wait _hr_fresh _hr_code _hr_restarts _hr_rsec _hr_jlast _hr_url_before
    _hr_state=${DSH_REMOTE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dsh-remote}
    _hr_tok=$_hr_state/current-token.txt
    _hr_url=$_hr_state/web-url.txt
    # 只有"这次真的抓到了 token"才在退出时删 token 文件。标记文件里存我们写进去的那一刻
    # 的值：抓取循环在子 shell 里（变量传不出来），而且**端口被占时这个函数会什么都没抓到**
    # —— 那时绝不能去删别人（另一个正在跑的实例）写的 token 文件，否则 broker 又回 503。
    _hr_mark=$_hr_state/.harness-wrote-token
    _hr_wait_start=$_hr_state/.harness-wait-start
    rm -f -- "$_hr_mark" "$_hr_wait_start" 2>/dev/null
    _hr_conf=${DSH_REMOTE_CONF_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/dsh-remote}/remote.conf
    mkdir -p -- "$_hr_state" 2>/dev/null

    _hr_unit=dsh-web.service
    _hr_lp=$(sed -n 's/^[[:space:]]*local_port[[:space:]]*=[[:space:]]*//p' "$_hr_conf" 2>/dev/null | tail -n 1)
    [ -n "${_hr_lp}" ] || _hr_lp=3080
    _hr_pub=$(sed -n 's/^[[:space:]]*public_url[[:space:]]*=[[:space:]]*//p' "$_hr_conf" 2>/dev/null | tail -n 1)
    # systemd 那个单元装着没有（没 systemctl / 没单元 = 走前台，和以前一样）
    _hr_have_unit=0
    if command -v systemctl >/dev/null 2>&1 && _hr_sctl cat "$_hr_unit" >/dev/null 2>&1; then
        _hr_have_unit=1
    fi

    # ── ① 已经有会话在跑 → 复用（绝不起第二个）──────────────────────────────
    _hr_live=0
    _hr_listening "${_hr_lp}" && _hr_live=1
    # 逃生阀：DSH_REMOTE_HARNESS_NO_REUSE=1 → 不做"复用/交给服务"，就走下面的前台路。
    # 用途：测试（用例要验前台抓 token）、以及"我就是想再起一个新的"这种特殊场合。
    if [ "${DSH_REMOTE_HARNESS_NO_REUSE:-0}" = 1 ]; then _hr_live=0; fi
    if [ "${_hr_live}" = 1 ]; then
        _hr_pid=$(_hr_port_pid "${_hr_lp}")
        if [ -n "${_hr_pid}" ]; then _hr_pid_txt="PID ${_hr_pid}"; else _hr_pid_txt='PID 拿不到（ss -ltnp 看不到）'; fi
        _hr_svc=
        _hr_main=0
        _hr_sub=
        _hr_restarts=
        _hr_rsec=
        if [ "${_hr_have_unit}" = 1 ]; then
            _hr_svc=$(_hr_sctl is-active "$_hr_unit" 2>/dev/null || true)
            _hr_main=$(_hr_unit_prop "$_hr_unit" MainPID)
            _hr_sub=$(_hr_unit_prop "$_hr_unit" SubState)
            _hr_restarts=$(_hr_unit_prop "$_hr_unit" NRestarts)
            _hr_rsec=$(_hr_unit_prop "$_hr_unit" RestartUSec)
        fi
        # 端口上那个是不是 systemd 那个单元在服务？（cgroup 认得更准）
        _hr_managed=0
        if [ "${_hr_svc}" = active ] && [ -n "${_hr_pid}" ] \
            && { [ "${_hr_main}" = "${_hr_pid}" ] || _hr_pid_in_unit "${_hr_pid}" "$_hr_unit"; }; then
            _hr_managed=1
        fi
        if [ "${_hr_managed}" = 1 ]; then
            # systemd 那个单元在服务，web-url.txt / current-token.txt 就是它写的
            if [ -s "$_hr_url" ]; then
                _hr_u=$(cat "$_hr_url")
            elif [ -s "$_hr_tok" ]; then
                _hr_u="http://127.0.0.1:${_hr_lp}/?token=$(tr -d '\n' <"$_hr_tok")"
            else
                _hr_u="http://127.0.0.1:${_hr_lp}/"
            fi
            printf 'harness: dsh web 已在跑 ✓  %s（PID %s，%s 托管）\n' "${_hr_u}" "${_hr_pid}" "${_hr_unit}"
            [ -n "${_hr_pub}" ] && printf 'harness: 手机 %s\n' "${_hr_pub}"
            return 0
        fi
        # 端口上那个**不是** systemd 管的。两种情形：
        #   ① 单元没装、或它是 inactive/unknown → 本来就是"手起的实例在跑"，这就是正常复用
        #   ② 单元装着但起不来（activating/failed）→ **服务没起来**，原因就是端口被占
        _hr_tokfile=
        if [ -s "$_hr_tok" ]; then
            _hr_tokfile=$(tr -d '\n' <"$_hr_tok")
        elif [ -s "$_hr_url" ]; then
            _hr_tokfile=$(sed -n 's/.*[?&]token=\([^&[:space:]]*\).*/\1/p' "$_hr_url" | head -n 1)
        fi
        if [ "${_hr_have_unit}" = 1 ] && [ -n "${_hr_svc}" ] \
            && [ "${_hr_svc}" != inactive ] && [ "${_hr_svc}" != unknown ]; then
            printf 'harness: dsh web 没起来 ✗ 原因：%s 被另一个实例占着（%s，不是 systemd 管的）\n' \
                "${_hr_lp}" "${_hr_pid_txt}"
            # 那个实例的 token 只在它内存里才一定准 —— 拿真请求验一次再打（H22）
            if [ -n "${_hr_tokfile}" ] && [ "$(_hr_token_probe "${_hr_lp}" "${_hr_tokfile}")" = ok ]; then
                printf 'harness:   现在能用的还是那个实例：http://127.0.0.1:%s/?token=%s（token 实测有效）\n' \
                    "${_hr_lp}" "${_hr_tokfile}"
            else
                printf 'harness:   现在能用的还是那个实例：http://127.0.0.1:%s/（token 没记下或实测已失效 —— 那个实例不是这里起的）\n' \
                    "${_hr_lp}"
            fi
            printf 'harness:   → 让它接管：先退出那个实例；或 DSH_REMOTE_HARNESS_NO_REUSE=1 harness 起新的\n'
            printf 'harness:   systemd: %s  看：journalctl --user -u %s -n 20\n' \
                "$(_hr_svc_note "${_hr_svc}" "${_hr_sub}" "${_hr_restarts}" "${_hr_rsec}")" "${_hr_unit}"
            [ -n "${_hr_pub}" ] && printf 'harness: 手机 %s\n' "${_hr_pub}"
            return 0
        fi
        # 情形 ①：手起的实例在跑，没有服务要它让位
        printf 'harness: dsh web 已在跑 ✓  http://127.0.0.1:%s/（%s，非 systemd）\n' "${_hr_lp}" "${_hr_pid_txt}"
        if [ -n "${_hr_tokfile}" ]; then
            case $(_hr_token_probe "${_hr_lp}" "${_hr_tokfile}") in
            ok) printf 'harness:   带 token 的入口（实测有效）：http://127.0.0.1:%s/?token=%s\n' "${_hr_lp}" "${_hr_tokfile}" ;;
            bad) printf 'harness:   本地 token 文件里那个实测已失效（401）—— 这个实例不是这里起的，它的 token 只在它内存里\n' ;;
            *) printf 'harness:   带 token 的入口（没验过，取自 %s）：http://127.0.0.1:%s/?token=%s\n' "$_hr_tok" "${_hr_lp}" "${_hr_tokfile}" ;;
            esac
        else
            printf 'harness:   没记下这个实例的 token（不是这里起的；手机走固定地址即可）\n'
        fi
        [ -n "${_hr_pub}" ] && printf 'harness: 手机 %s\n' "${_hr_pub}"
        [ "${_hr_have_unit}" = 1 ] || printf 'harness: 想让它开机自动起：dsh-remote serve-install\n'
        return 0
    fi

    # ── ② 装了 dsh-web.service 但没跑 → 起来（后台常驻，退出 shell 也不停）────
    if [ "${DSH_REMOTE_HARNESS_NO_REUSE:-0}" != 1 ] && [ "${_hr_have_unit}" = 1 ]; then
        _hr_wait=$(printf '%s' "${DSH_REMOTE_HARNESS_WAIT:-20}" | tr -cd '0-9')
        [ -n "${_hr_wait}" ] || _hr_wait=20
        [ "${_hr_wait}" -gt 0 ] 2>/dev/null || _hr_wait=20
        printf 'harness: 等 systemd 写出地址（最多 %ss）…\n' "${_hr_wait}"
        # 起点标记 + 起点内容：只有"这次刚写的" web-url.txt 才算数。旧文件不算 ——
        # 否则上一次留下的死地址会被当成"刚起来"的证据，那正是"看不出来起没起来"的来源。
        _hr_url_before=
        [ -s "$_hr_url" ] && _hr_url_before=$(cat "$_hr_url")
        : >"$_hr_wait_start" 2>/dev/null
        # --no-block：服务是 Type=simple，若端口被别的会话占着它会立刻退出并等重试，
        # 同步 start 会把那种情况报成"失败"（其实 systemd 正在按 RestartSec 重试）。
        _hr_sctl start --no-block "$_hr_unit" 2>/dev/null || true
        _hr_i=0
        _hr_fresh=0
        while [ "${_hr_i}" -lt "${_hr_wait}" ]; do
            if _hr_url_fresh "$_hr_url" "$_hr_wait_start" "$_hr_url_before" && _hr_listening "${_hr_lp}"; then
                _hr_fresh=1
                break
            fi
            sleep 1
            _hr_i=$((_hr_i + 1))
            # 早停：单元已经 failed —— 不用把等待等满，原因现在就拿得到
            [ "$(_hr_sctl is-active "$_hr_unit" 2>/dev/null || true)" = failed ] && break
        done
        _hr_svc=$(_hr_sctl is-active "$_hr_unit" 2>/dev/null || true)
        _hr_sub=$(_hr_unit_prop "$_hr_unit" SubState)
        _hr_restarts=$(_hr_unit_prop "$_hr_unit" NRestarts)
        _hr_rsec=$(_hr_unit_prop "$_hr_unit" RestartUSec)
        _hr_main=$(_hr_unit_prop "$_hr_unit" MainPID)
        rm -f -- "$_hr_wait_start" 2>/dev/null
        if [ "${_hr_fresh}" = 1 ]; then
            _hr_pid=${_hr_main}
            if [ -z "${_hr_pid}" ] || [ "${_hr_pid}" = 0 ]; then _hr_pid=$(_hr_port_pid "${_hr_lp}"); fi
            printf 'harness: dsh web 已由 systemd 拉起 ✓  %s（PID %s，%s）\n' \
                "$(cat "$_hr_url")" "${_hr_pid:-未知}" "${_hr_unit}"
            [ -n "${_hr_pub}" ] && printf 'harness: 手机 %s\n' "${_hr_pub}"
            return 0
        fi
        # 没等到地址 → 报**实测出来的**原因，不许猜（2026-10-09 用户要求：
        # 先看端口有没有人听 —— 有人听就是"端口被占"这一档，原因就确定了，别再写
        # "端口被占 / npx 卡住都可能是这个"；没人听才去看 systemd，分三档，
        # 每档都给一条能原地复现的判据命令）。
        _hr_pid=$(_hr_port_pid "${_hr_lp}")
        _hr_jlast=$(_hr_journal_last "$_hr_unit")
        _hr_tokfile=
        if [ -s "$_hr_tok" ]; then
            _hr_tokfile=$(tr -d '\n' <"$_hr_tok")
        elif [ -s "$_hr_url" ]; then
            _hr_tokfile=$(sed -n 's/.*[?&]token=\([^&[:space:]]*\).*/\1/p' "$_hr_url" | head -n 1)
        fi
        if _hr_port_taken "${_hr_lp}"; then
            if [ -n "${_hr_pid}" ]; then _hr_pid_txt="PID ${_hr_pid}"; else _hr_pid_txt='PID 拿不到（ss -ltnp 看不到）'; fi
            if [ -n "${_hr_pid}" ] && _hr_pid_in_unit "${_hr_pid}" "$_hr_unit"; then
                # 端口上是**服务自己**的人，却没写出新地址（罕见，别赖到"端口被占"上）
                printf 'harness: dsh web 没起来 ✗ 原因：%s 上在听的那个 %s 属于 %s，但 %ss 内没写出新地址\n' \
                    "${_hr_lp}" "${_hr_pid_txt}" "${_hr_unit}" "${_hr_wait}"
                printf 'harness:   判据：ss -ltnp | grep -E "[:.]%s "；ls -l %s；journalctl --user -u %s -n 20\n' \
                    "${_hr_lp}" "$_hr_url" "${_hr_unit}"
            else
                printf 'harness: dsh web 没起来 ✗ 原因：%s 被别人占着（%s，不是 systemd 管的）—— 服务只能等它让位\n' \
                    "${_hr_lp}" "${_hr_pid_txt}"
                # 那个实例的 token 只在它内存里才一定准 —— 拿真请求验一次再打（H22）
                if [ -n "${_hr_tokfile}" ] && [ "$(_hr_token_probe "${_hr_lp}" "${_hr_tokfile}")" = ok ]; then
                    printf 'harness:   现在能用的还是那个实例：http://127.0.0.1:%s/?token=%s（token 实测有效）\n' \
                        "${_hr_lp}" "${_hr_tokfile}"
                else
                    printf 'harness:   现在能用的还是那个实例：http://127.0.0.1:%s/（token 没记下或实测已失效 —— 那个实例不是这里起的，它的 token 只在它内存里）\n' \
                        "${_hr_lp}"
                fi
                printf 'harness:   → 让它接管：先退出那个实例；或 DSH_REMOTE_HARNESS_NO_REUSE=1 harness 起新的\n'
                printf 'harness:   判据：ss -ltnp | grep -E "[:.]%s "   # 这一行就是占着它的那个进程\n' "${_hr_lp}"
            fi
            printf 'harness:   systemd: %s  看：journalctl --user -u %s -n 20\n' \
                "$(_hr_svc_note "${_hr_svc}" "${_hr_sub}" "${_hr_restarts}" "${_hr_rsec}")" "${_hr_unit}"
        elif [ "${_hr_svc}" = failed ]; then
            _hr_code=$(_hr_unit_prop "$_hr_unit" ExecMainStatus)
            printf 'harness: dsh web 没起来 ✗ 原因：%s 失败（exit %s），端口 %s 上没人听 —— 日志最后一行：%s\n' \
                "${_hr_unit}" "${_hr_code:-未知}" "${_hr_lp}" "${_hr_jlast:-（journalctl 没给出内容）}"
            printf 'harness:   判据：systemctl --user show -p ExecMainStatus -p NRestarts --value %s；journalctl --user -u %s -n 1 -o cat\n' \
                "${_hr_unit}" "${_hr_unit}"
        elif [ "${_hr_svc}" = activating ] || [ "${_hr_svc}" = active ]; then
            printf 'harness: dsh web 没起来 ✗ 原因：%s 还在起（%s），端口 %s 上没人听 —— 日志最后一行：%s\n' \
                "${_hr_unit}" "$(_hr_svc_note "${_hr_svc}" "${_hr_sub}" "${_hr_restarts}" "${_hr_rsec}")" \
                "${_hr_lp}" "${_hr_jlast:-（journalctl 没给出内容）}"
            printf 'harness:   判据：systemctl --user show -p NRestarts -p RestartUSec --value %s；journalctl --user -u %s -n 1 -o cat\n' \
                "${_hr_unit}" "${_hr_unit}"
        else
            printf 'harness: dsh web 没起来 ✗ 原因：%s 没在跑（is-active=%s：没装 / 没 enable / 自己退了），端口 %s 上也没人听\n' \
                "${_hr_unit}" "${_hr_svc:-空}" "${_hr_lp}"
            printf 'harness:   日志最后一行：%s\n' "${_hr_jlast:-（journalctl 没给出内容）}"
            printf 'harness:   判据：systemctl --user is-active %s；ss -ltn | grep -E "[:.]%s "；journalctl --user -u %s -n 1 -o cat\n' \
                "${_hr_unit}" "${_hr_lp}" "${_hr_unit}"
            printf 'harness:   → 起它：systemctl --user start %s（要开机自动起：dsh-remote serve-install）\n' "${_hr_unit}"
        fi
        if ! _hr_port_taken "${_hr_lp}" && [ -s "$_hr_url" ]; then
            printf 'harness:   （web-url.txt 还是上一次的，没被重写）\n'
        fi
        return 0
    fi

    # ── ③ 没有常驻服务（或 NO_REUSE）→ 前台起（老行为：抓 token，退出即清）────
    if [ "${DSH_REMOTE_HARNESS_NO_REUSE:-0}" = 1 ]; then
        printf 'harness: DSH_REMOTE_HARNESS_NO_REUSE=1 → 不复用、也不交给服务，前台起新的\n'
    else
        printf 'harness: 没有 %s（没装/没 enable）→ 前台跑 npx @deepseek-ai/dsh web（这个终端退出就没了；常驻用 dsh-remote serve-install）\n' \
            "${_hr_unit}"
    fi
    npx @deepseek-ai/dsh web "$@" 2>&1 | while IFS= read -r _hr_line; do
        case $_hr_line in
        *'dsh web: http'*)
            # 那行长这样：dsh web: http://127.0.0.1:3080/?token=XXXX (LAN: …)
            # 按空格切成词，取**第一个** http URL —— 别用贪婪的 `.*\(...\)`：
            # 那会抓到行尾那个 LAN 地址（实测踩过）。
            _hr_u=$(printf '%s\n' "$_hr_line" | tr ' ' '\n' |
                sed -n '/^http:\/\/.*[?&]token=/p' | head -n 1)
            case $_hr_u in
            *token=*)
                printf '%s\n' "${_hr_u##*token=}" >"$_hr_tok" && chmod 600 -- "$_hr_tok" 2>/dev/null
                printf '%s\n' "$_hr_u" >"$_hr_url" && chmod 600 -- "$_hr_url" 2>/dev/null
                cp -f -- "$_hr_tok" "$_hr_mark" 2>/dev/null && chmod 600 -- "$_hr_mark" 2>/dev/null
                printf 'harness: 已捕获 token → %s\n' "$_hr_tok"
                if [ -n "${_hr_pub}" ]; then
                    printf 'harness: 手机 %s（broker 会补 token；收藏这个就行）\n' "${_hr_pub}"
                fi
                ;;
            esac
            ;;
        esac
        printf '%s\n' "$_hr_line"
    done

    if [ -f "$_hr_mark" ] && [ -s "$_hr_tok" ] && cmp -s -- "$_hr_mark" "$_hr_tok"; then
        rm -f -- "$_hr_tok" "$_hr_mark"
        printf 'harness: npx 退出；token 文件已清掉（broker 回 503，不会 302 到死 token）\n'
    else
        rm -f -- "$_hr_mark" 2>/dev/null
        printf 'harness: 没抓到 token（端口被占 / 没起来？）—— 原来的 token 文件**保持不动**（broker 不会因此 503）\n' >&2
    fi
}
