#!/bin/sh
# install.sh —— wtool install 调这个。**契约**：
#   产物落在 $WTOOL_PREFIX（默认 ~/.wtool/usr）下面，$HOME 里只留**软链**，
#   而且软链是可撤销的（install.sh --uninstall 撤掉）。
#
# 所以这个项目装完是这样：
#
#   ~/.wtool/usr/bin/dsh-remote         -> 仓库 bin/dsh-remote        （命令）
#   ~/.wtool/usr/bin/dsh-notify         -> 仓库 bin/dsh-notify
#   ~/.wtool/usr/etc/dsh-remote/        真正的配置（实体在这儿）
#   ~/.wtool/usr/var/dsh-remote/        真正的日志/运行期文件
#   ~/.config/dsh-remote                -> ../.wtool/usr/etc/dsh-remote   （软链）
#   ~/.local/state/dsh-remote           -> ../.wtool/usr/var/dsh-remote   （软链）
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

link_dir="$HOME/.wtool/wtool-work-dir/links/tools/dsh-remote"
prefix="${WTOOL_PREFIX:-$HOME/.wtool/usr}"
bin_dir="$prefix/bin"
etc_dir="$prefix/etc/dsh-remote"
var_dir="$prefix/var/dsh-remote"
conf_link="${XDG_CONFIG_HOME:-$HOME/.config}/dsh-remote"
state_link="${XDG_STATE_HOME:-$HOME/.local/state}/dsh-remote"

# 把 $HOME 下的一个目录变成指向 $prefix 的软链；里面已有的东西先搬进前缀（不覆盖）
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
            say "警告：$src 里还有东西（没搬走的），保留原样，不换成软链"
            return 0
        fi
    elif [ -e "$src" ]; then
        say "警告：$src 不是目录也不是软链，跳过"
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

# 1) 命令
mkdir -p -- "$bin_dir"
for n in dsh-remote dsh-notify; do
    src="$link_dir/bin/$n"
    dst="$bin_dir/$n"
    if [ ! -x "$src" ]; then
        say "警告：找不到 $src（wtool 的稳定链接还没建好？）"
        continue
    fi
    if [ -L "$dst" ] && [ "$(readlink -- "$dst" || true)" = "$src" ]; then
        continue
    fi
    ln -sfn -- "$src" "$dst"
    say "已链接 $dst -> $src"
done

# 2) 配置/日志的实体目录 + $HOME 里的软链
mkdir -p -- "$etc_dir" "$var_dir"
for f in notify.conf remote.conf; do
    if [ -f "$link_dir/${f}.example" ] && [ ! -f "$etc_dir/${f}.example" ]; then
        cp -f -- "$link_dir/${f}.example" "$etc_dir/${f}.example"
        say "配置样板：$etc_dir/${f}.example"
    fi
done
link_dir_out "$conf_link" "$etc_dir"
link_dir_out "$state_link" "$var_dir"

say ""
say "布局："
say "  命令      $bin_dir/{dsh-remote,dsh-notify}"
say "  配置实体  $etc_dir          （$conf_link 是它的软链）"
say "  日志实体  $var_dir          （$state_link 是它的软链）"
say ""
say "下一步（都在家这台机器上）："
say "  1. 推送：cp $conf_link/notify.conf.example $conf_link/notify.conf → 填 provider/key → dsh-remote notify-test"
say "  2. 云端：dsh-remote cloud-install --domain <域名>  或  --ip <公网IP>（真装）"
say "  3. 隧道：cp $conf_link/remote.conf.example $conf_link/remote.conf → 填 cloud_host → dsh-remote tunnel"
say "  4. 体检：dsh-remote status"
