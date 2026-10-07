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
#   $DSH_REMOTE_STATE_DIR/current-token.txt   只有 token 一行（600）—— broker 的数据源
#   $DSH_REMOTE_STATE_DIR/web-url.txt         带 token 的完整地址（600，和 `dsh-remote serve` 同一份）
#
# 退出时删掉 current-token.txt：宁可让 broker 回 503「还没起」，也别 302 到一个死 token。
# 参数原样透传（`harness --no-open` / `harness --port 3090` 都行）。
#
# ⚠️ **别名优先于函数**：如果你（或旧文档）写过 `alias harness='npx @deepseek-ai/dsh web'`，
# 先 `unalias harness` —— 本文件在 source 时也会替你 unalias 一次。
# 想在后台起、不占用终端，用 `dsh-remote serve`（它同样把 token 存进 web-url.txt，
# 但它在后台跑、不接管当前终端）。
unalias harness 2>/dev/null || true
harness() {
    unalias harness 2>/dev/null || true
    if ! command -v npx >/dev/null 2>&1; then
        printf 'harness：PATH 里没有 npx（这套用法是 npx @deepseek-ai/dsh web）\n' >&2
        return 127
    fi
    local _hr_state _hr_tok _hr_url _hr_conf _hr_line _hr_u _hr_pub _hr_mark _hr_lp _hr_live _hr_i
    _hr_state=${DSH_REMOTE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dsh-remote}
    _hr_tok=$_hr_state/current-token.txt
    _hr_url=$_hr_state/web-url.txt
    # 只有"这次真的抓到了 token"才在退出时删 token 文件。标记文件里存我们写进去的那一刻
    # 的值：抓取循环在子 shell 里（变量传不出来），而且**端口被占时这个函数会什么都没抓到**
    # —— 那时绝不能去删别人（另一个正在跑的实例）写的 token 文件，否则 broker 又回 503。
    _hr_mark=$_hr_state/.harness-wrote-token
    rm -f -- "$_hr_mark" 2>/dev/null
    _hr_conf=${DSH_REMOTE_CONF_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/dsh-remote}/remote.conf
    mkdir -p -- "$_hr_state" 2>/dev/null

    # ── ① 已经有会话在跑 → 复用（绝不起第二个）──────────────────────────────
    _hr_lp=$(sed -n 's/^[[:space:]]*local_port[[:space:]]*=[[:space:]]*//p' "$_hr_conf" 2>/dev/null | tail -n 1)
    [ -n "${_hr_lp}" ] || _hr_lp=3080
    _hr_live=0
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | grep -q "127.0.0.1:${_hr_lp} " && _hr_live=1
    elif command -v curl >/dev/null 2>&1; then
        curl -s -o /dev/null --max-time 2 "http://127.0.0.1:${_hr_lp}/" 2>/dev/null && _hr_live=1
    fi
    # 逃生阀：DSH_REMOTE_HARNESS_NO_REUSE=1 → 不做"复用/交给服务"，就走下面的前台路。
    # 用途：测试（用例要验前台抓 token）、以及"我就是想再起一个新的"这种特殊场合。
    if [ "${DSH_REMOTE_HARNESS_NO_REUSE:-0}" = 1 ]; then _hr_live=0; fi
    if [ "${_hr_live}" = 1 ]; then
        printf '[dsh-remote] 已经有会话在 127.0.0.1:%s 上跑 —— 复用，没开新的\n' "${_hr_lp}"
        if [ -s "$_hr_tok" ]; then
            printf '[dsh-remote] 带 token 的本地地址：http://127.0.0.1:%s/?token=%s\n' \
                "${_hr_lp}" "$(tr -d '\n' <"$_hr_tok")"
        elif [ -s "$_hr_url" ]; then
            printf '[dsh-remote] 本地地址：%s\n' "$(cat "$_hr_url")"
        else
            printf '[dsh-remote] （没记下 token：那个会话不是这里起的；手机入口用固定地址即可）\n'
        fi
        _hr_pub=$(sed -n 's/^[[:space:]]*public_url[[:space:]]*=[[:space:]]*//p' "$_hr_conf" 2>/dev/null | tail -n 1)
        [ -n "${_hr_pub}" ] && printf '[dsh-remote] 手机固定地址：%s\n' "${_hr_pub}"
        printf '[dsh-remote] 想让它开机自动开会话：dsh-remote serve-install\n'
        return 0
    fi

    # ── ② 装了 dsh-web.service 但没跑 → 起来（后台常驻，退出 shell 也不停）────
    if [ "${DSH_REMOTE_HARNESS_NO_REUSE:-0}" != 1 ] && command -v systemctl >/dev/null 2>&1 \
        && systemctl --user cat dsh-web.service >/dev/null 2>&1; then
        printf '[dsh-remote] 交给常驻服务 dsh-web.service …\n'
        # --no-block：服务是 Type=simple，若端口被别的会话占着它会立刻退出并等重试，
        # 同步 start 会把那种情况报成"失败"（其实 systemd 正在按 RestartSec 重试）。
        systemctl --user start --no-block dsh-web.service 2>/dev/null || true
        _hr_i=0
        while [ "${_hr_i}" -lt 20 ]; do
            [ -s "$_hr_url" ] && break
            sleep 1
            _hr_i=$((_hr_i + 1))
        done
        if [ -s "$_hr_url" ]; then
            printf '[dsh-remote] 本地地址：%s\n' "$(cat "$_hr_url")"
        else
            printf '[dsh-remote] 还没写出地址（可能端口被别的会话占着，服务会每 30 秒重试）\n'
            printf '[dsh-remote] 看：journalctl --user -u dsh-web.service -n 20\n'
        fi
        _hr_pub=$(sed -n 's/^[[:space:]]*public_url[[:space:]]*=[[:space:]]*//p' "$_hr_conf" 2>/dev/null | tail -n 1)
        [ -n "${_hr_pub}" ] && printf '[dsh-remote] 手机固定地址：%s\n' "${_hr_pub}"
        return 0
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
                printf '[dsh-remote] 已捕获 token → %s\n' "$_hr_tok"
                _hr_pub=$(sed -n 's/^[[:space:]]*public_url[[:space:]]*=[[:space:]]*//p' "$_hr_conf" 2>/dev/null | tail -n 1)
                if [ -n "$_hr_pub" ]; then
                    printf '[dsh-remote] 手机固定地址：%s（broker 会补 token；收藏这个就行）\n' "$_hr_pub"
                fi
                ;;
            esac
            ;;
        esac
        printf '%s\n' "$_hr_line"
    done

    if [ -f "$_hr_mark" ] && [ -s "$_hr_tok" ] && cmp -s -- "$_hr_mark" "$_hr_tok"; then
        rm -f -- "$_hr_tok" "$_hr_mark"
        printf '[dsh-remote] harness 退出：token 文件已清掉（broker 现在回 503）\n'
    else
        rm -f -- "$_hr_mark" 2>/dev/null
        printf '[dsh-remote] harness 没抓到 token（端口被占 / 没起来？）或 token 已经是别人的了\n' >&2
        printf '[dsh-remote] —— 原来的 %s **保持不动**（broker 不会因此变 503）\n' "$_hr_tok" >&2
    fi
}
