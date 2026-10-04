#!/bin/sh
# install.sh —— wtool install 调这个。**契约**：
#   产物落在 $WTOOL_PREFIX（默认 $WTOOL_HOME/.wtool/usr）下面，$HOME 里只留**软链**，
#   而且软链是可撤销的（install.sh --uninstall 撤掉）。
#
# 所以这个项目装完是这样（$WTOOL_HOME 默认就是 $HOME）：
#
#   $WTOOL_PREFIX/bin/dsh-remote        -> <项目>/bin/dsh-remote        （命令）
#   $WTOOL_PREFIX/bin/dsh-notify        -> <项目>/bin/dsh-notify
#   $WTOOL_PREFIX/etc/dsh-remote/       真正的配置（实体在这儿）
#   $WTOOL_PREFIX/var/dsh-remote/       真正的日志/运行期文件
#   $WTOOL_HOME/.config/dsh-remote      -> ../.wtool/usr/etc/dsh-remote  （软链）
#   $WTOOL_HOME/.local/state/dsh-remote -> ../.wtool/usr/var/dsh-remote  （软链）
#
# 为什么要软链：程序按 XDG 约定写 ~/.config/dsh-remote 和
# ~/.local/state/dsh-remote，而实体在 $WTOOL_PREFIX 下面 —— 这样
# `wtool uninstall tools/dsh-remote` 能干净撤掉、`wtool list` 看得见、
# 别的机器上 `wtool install tools/dsh-remote` 得到同样的布局。
#
# 约定（同 tools/gerrit-gate）：
#   * stdin 是 /dev/null —— 不写交互式提问
#   * 可重入 —— 重复跑不报错、不重复添加
#   * 不做不可逆的事 —— 绝不覆盖已有配置；目录要变成软链时先把内容搬进前缀
#
# **不碰网络、不碰 docker、不碰 systemd**：隧道、Caddy、hooks 都是
# `dsh-remote ...` 那一步才做的。
set -eu

say() { printf '%s: %s\n' 'tools/dsh-remote' "$*"; }
warn() { printf '%s: 警告：%s\n' 'tools/dsh-remote' "$*" >&2; }

# --------------------------------------------------------------------------
# 路径全部问引擎要，**不把影子 HOME（~/.wtool）的内部布局写死进脚本**
#
#   WTOOL_PROJECT_DIR  项目检出目录 —— 引擎对项目脚本的正式契约
#                      （bootstrap/wtool.sh 的 wt_run_project_script：
#                       `export WTOOL_PROJECT_DIR="$_rs_dir"`）。
#                      手工跑（没设这个变量）时按 $0 自己推 <项目>/scripts/.. 。
#   WTOOL_HOME         引擎管理的那个家目录，默认 $HOME。**落点从它推** ——
#                      换 WTOOL_HOME 装（影子家 / 临时家 / 测试）时落点跟着走。
#   WTOOL_PREFIX       命令落点，默认 $WTOOL_HOME/.wtool/usr。
#
# 为什么"源"不用稳定中转链接（$WTOOL_HOME/.wtool/wtool-work-dir/links/<项目>）：
# 那一格是**引擎的内部布局**（bootstrap/lib/wtool_plan.py 的 WORK_DIR_NAME，
# 2026-09-23 才从 ~/.wtool/links/ 挪过去）—— 写进项目脚本就有了两份真相：
#   * 影子家里（WTOOL_HOME != $HOME）它一定指丢：中转链接建在
#     $WTOOL_HOME/.wtool/... 下，脚本却去**真家目录**那格（写死的 `~/.wtool/...`）找；
#   * 引擎以后再挪一次，脚本立刻指丢（tools/android_repack 就是这么坏掉的）。
# 后果一样：**"找不到就跳过"让它静默地什么都没装** —— 装完敲 dsh-remote 是
# command not found，而 wtool 那边报 "install 完成"。同一个病 2026-10-04 在
# tools/android_repack（14bf463）和 harness/dsh-conf（977101b）上修过，这是最后一处。
#
# 所以本脚本有两条硬规矩：
#   ① 某条源找不到 = **只跳过那一条** + 说清去哪儿找了（绝不整脚本静默退出）；
#   ② 只有真要装才 mkdir —— 源找不到时一个字节都不写，连"空目录 + 指向它的软链"
#      那种看着像装好了的东西也不留。
# --------------------------------------------------------------------------
SELF=$(readlink -f -- "$0" 2>/dev/null || printf '%s' "$0")
HERE=$(dirname -- "$SELF")                      # = <项目>/scripts
SELF_PROJECT_DIR=$(CDPATH= cd -- "$HERE/.." && pwd)
proj=${WTOOL_PROJECT_DIR:-$SELF_PROJECT_DIR}    # 源：项目检出目录
home=${WTOOL_HOME:-$HOME}                       # 被管理的家目录
prefix=${WTOOL_PREFIX:-$home/.wtool/usr}        # 命令落点

bin_dir="$prefix/bin"
etc_dir="$prefix/etc/dsh-remote"
var_dir="$prefix/var/dsh-remote"
# 配置/日志的落点：跟 XDG 走（人显式设了就用它），默认从 $WTOOL_HOME 推。
# **不认 DSH_REMOTE_CONF_DIR / DSH_REMOTE_STATE_DIR**：那两个是**运行期**变量
# （命令去哪儿找配置），不是安装布局 —— 调用者的 shell 里恰好导出过它们
# （装过一遍的人一定导出过）就会把软链铺到别处去。落点只看家目录 / XDG。
conf_link=${XDG_CONFIG_HOME:-$home/.config}/dsh-remote
state_link=${XDG_STATE_HOME:-$home/.local/state}/dsh-remote

# 某条"源"找不到：**只跳过这一条**，并说清去哪儿找了。
# 绝不整脚本静默退出 —— 那会让"什么都没装"看起来像安装成功。
skipped=0
miss() {
    skipped=$((skipped + 1))
    warn "找不到源文件：$1"
    if [ -n "${WTOOL_PROJECT_DIR:-}" ]; then
        warn "  找的地方：$proj（来自 WTOOL_PROJECT_DIR）"
    else
        warn "  找的地方：$proj（WTOOL_PROJECT_DIR 没设，按脚本位置自推）"
    fi
}

# 把家目录（$WTOOL_HOME，默认 $HOME）下的一个目录变成指向 $prefix 的软链；
# 里面已有的东西先搬进前缀（不覆盖）
link_dir_out() { # <home 下的路径> <prefix 下的目标>
    src=$1
    dst=$2
    if [ -L "$src" ]; then
        cur=$(readlink -- "$src" || true)
        if [ "$cur" = "$dst" ]; then
            return 0
        fi
        rm -f -- "$src"
    elif [ -d "$src" ]; then
        # 老布局：实体就在 ~/.config 下 —— 先搬进前缀，再换成软链
        mkdir -p -- "$dst"
        for f in "$src"/* "$src"/.[!.]*; do
            [ -e "$f" ] || continue
            base=${f##*/}
            if [ ! -e "$dst/$base" ]; then
                mv -- "$f" "$dst/$base"
                say "搬进前缀：$f -> $dst/$base"
            fi
        done
        if rmdir -- "$src" 2>/dev/null; then
            say "旧目录已清空，换成软链"
        else
            warn "$src 里还有东西（没搬走的），保留原样，不换成软链"
            return 0
        fi
    elif [ -e "$src" ]; then
        warn "$src 不是目录也不是软链，跳过"
        return 0
    fi
    mkdir -p -- "$(dirname -- "$src")"
    ln -sfn -- "$dst" "$src"
    say "软链 $src -> $dst"
}

if [ "${1:-}" = "--uninstall" ]; then
    for n in dsh-remote dsh-notify; do
        if [ -L "$bin_dir/$n" ]; then
            rm -f -- "$bin_dir/$n"
            say "已移除 $bin_dir/$n"
        fi
    done
    # 只撤软链，**不删前缀里的实体**（配置和日志是用户的东西）
    for l in "$conf_link" "$state_link"; do
        if [ -L "$l" ]; then
            rm -f -- "$l"
            say "已移除软链 $l（实体还在 $prefix 下）"
        fi
    done
    say "（要连钩子一起关掉：dsh-remote notify-disable）"
    exit 0
fi

# 1) 命令：$WTOOL_PREFIX/bin/<名字> -> <项目>/bin/<名字>
n_cmd=0
for n in dsh-remote dsh-notify; do
    src="$proj/bin/$n"
    dst="$bin_dir/$n"
    if [ ! -x "$src" ]; then
        miss "$src"                 # ← 只跳过这一条，不拉下别的
        continue
    fi
    mkdir -p -- "$bin_dir"          # ← 只有真要装才建目录
    if [ -L "$dst" ]; then
        cur=$(readlink -- "$dst" || true)
        if [ "$cur" = "$src" ]; then
            n_cmd=$((n_cmd + 1))
            continue                # 幂等：已经是这条软链
        fi
        ln -sfn -- "$src" "$dst"
        say "软链已更正 $dst -> $src"
    elif [ -e "$dst" ]; then
        warn "$dst 已存在且不是软链，跳过（自己决定要不要删）"
        continue
    else
        ln -sfn -- "$src" "$dst"
        say "已链接 $dst -> $src"
    fi
    n_cmd=$((n_cmd + 1))
done

# 2) 配置/日志的实体目录 + $HOME 里的软链。
#    两张样板一个都找不到 = 项目目录根本不对：这一摊**整段跳过**（连目录都不建）——
#    "空目录 + 指向它的软链"看着像装好了，其实是同一个静默失败的变种。
found_sample=0
for f in notify.conf remote.conf; do
    src="$proj/${f}.example"
    if [ ! -f "$src" ]; then
        miss "$src"
        continue
    fi
    found_sample=1
    mkdir -p -- "$etc_dir"          # ← 只有真要装才建目录
    if [ ! -f "$etc_dir/${f}.example" ]; then
        cp -f -- "$src" "$etc_dir/${f}.example"
        say "配置样板：$etc_dir/${f}.example"
    fi
done

if [ "$found_sample" = 1 ]; then
    mkdir -p -- "$var_dir"
    link_dir_out "$conf_link" "$etc_dir"
    link_dir_out "$state_link" "$var_dir"
fi

say ""
say "源（项目检出目录）：$proj"
say "  命令      $bin_dir/dsh-remote、$bin_dir/dsh-notify（这次到位 $n_cmd 条）"
if [ "$found_sample" = 1 ]; then
    say "  配置实体  $etc_dir          （$conf_link 是它的软链）"
    say "  日志实体  $var_dir          （$state_link 是它的软链）"
fi
if [ "$skipped" -gt 0 ]; then
    warn "有 $skipped 条源没找到（上面每条都说了去哪儿找）—— 那些**没装**。"
fi
say ""
say "下一步（都在家这台机器上）："
say "  1. 推送：cp $conf_link/notify.conf.example $conf_link/notify.conf → 填 provider/key → dsh-remote notify-test"
say "  2. 云端：dsh-remote cloud-install --domain <域名>  或  --ip <公网IP>（真装）"
say "  3. 隧道：cp $conf_link/remote.conf.example $conf_link/remote.conf → 填 cloud_host → dsh-remote tunnel"
say "  4. 体检：dsh-remote status"
