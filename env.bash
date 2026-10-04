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
