#!/usr/bin/env bash
set -euo pipefail

# 项目源码入口只负责角色选择；CN 与 Remote 的安装事务统一委托给 standalone。
PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SELECTED_ROLE=""

show_banner() {
    cat <<'EOF'
============================================================
  gost-ecmp-pathlock 统一安装向导
============================================================
EOF
}

show_role_guide() {
    cat <<'EOF'

请选择“当前这台服务器”承担的角色：

  1) CN（中国大陆入口端）
     - 部署在中国大陆
     - 接收本地业务连接
     - 连接一个或多个 Remote 节点并进行路径优选

  2) Remote（境外中转端）
     - 部署在韩国、美国等境外地区
     - 监听 MTCP 端口，默认 6600/tcp
     - 接收 CN 发起的 MTCP 连接

  q) 退出安装

说明：de、us 等名称是 Remote 节点/线路别名，不是 CN 地区。
建议先安装 Remote，再安装 CN；配置 CN 时需要 Remote 的 IPv4 地址和监听端口。
EOF
}

show_usage() {
    cat <<'EOF'
用法：
  bash install.sh             交互选择角色
  bash install.sh cn          直接安装 CN 端
  bash install.sh remote      直接安装 Remote 端
  bash install.sh --help      查看帮助

下载说明：
  CN 默认通过 https://ghfast.top/ 加速下载 GitHub Release。
  如需强制直连 GitHub：GITHUB_PROXY_PREFIX= bash install.sh cn
  Remote 默认直连；也可设置 GITHUB_PROXY_PREFIX 使用自定义前缀。
  自动化安装可通过 MTCP_AUTH_PASSWORD 传入两端相同的鉴权密码。
  共享 CN 有活跃业务时，需显式设置 CN_FORCE_RESTART=1 才允许配置重启。
EOF
}

normalize_role() {
    case "${1:-}" in
        1|cn|CN|Cn|cN) printf '%s\n' "cn" ;;
        2|remote|REMOTE|Remote) printf '%s\n' "remote" ;;
        *) return 1 ;;
    esac
}

select_role_interactively() {
    local choice confirmation role_name

    show_role_guide
    while :; do
        if ! read -r -p "请选择角色 [1=CN, 2=Remote, q=退出]: " choice; then
            echo "未选择部署角色，安装已取消。" >&2
            exit 1
        fi
        case "$choice" in
            q|Q|quit|QUIT|exit|EXIT)
                echo "安装已取消。"
                exit 0
                ;;
        esac
        if ! SELECTED_ROLE="$(normalize_role "$choice")"; then
            echo "输入无效：请输入 1、2、cn、remote 或 q。" >&2
            continue
        fi

        if [[ "$SELECTED_ROLE" == "cn" ]]; then
            role_name="CN（中国大陆入口端）"
        else
            role_name="Remote（境外中转端）"
        fi
        while :; do
            if ! read -r -p "确认当前服务器安装 ${role_name}？[Y/n]: " confirmation; then
                echo "未确认部署角色，安装已取消。" >&2
                exit 1
            fi
            case "$confirmation" in
                ""|y|Y|yes|YES) return ;;
                n|N|no|NO)
                    SELECTED_ROLE=""
                    echo "请重新选择服务器角色。"
                    break
                    ;;
                q|Q|quit|QUIT|exit|EXIT)
                    echo "安装已取消。"
                    exit 0
                    ;;
                *) echo "输入无效：请输入 y、n 或 q。" >&2 ;;
            esac
        done
    done
}

show_next_steps() {
    case "$SELECTED_ROLE" in
        cn)
            cat <<'EOF'

已选择：CN（中国大陆入口端）
请先确认 Remote 已安装，并准备好它的公网 IPv4 和 MTCP 监听端口。
接下来将依次询问：
  1. Remote 节点/线路别名，例如 de、us
  2. Remote IPv4 地址、MTCP 端口及 Remote 安装时设置的鉴权密码
  3. CN 业务监听端口，以及 Remote 业务后端地址和端口（地址默认 127.0.0.1）
  4. CN Anchor 监听端口
  5. RTT 快路准入阈值，默认 40ms，可自定义

CN 全机只运行一个共享 GOST 主服务；每条线路保留独立 Watchdog，Anchor 仍只由 Watchdog 控制。
GOST 默认通过 https://ghfast.top/https://github.com/... 下载，并继续校验官方 checksums.txt。
EOF
            ;;
        remote)
            cat <<'EOF'

已选择：Remote（境外中转端）
接下来将询问 Remote 的 MTCP 监听端口和鉴权密码，端口直接回车使用 6600/tcp。
安装完成后会自动启用并重启 Remote 服务。
请放行所选 TCP 端口，并记录 Remote 公网 IPv4、端口和鉴权密码，供 CN 安装时填写。
EOF
            ;;
    esac
    if [[ "$SELECTED_ROLE" == "cn" ]]; then
        printf '\n开始安装 CN 端……\n\n'
    else
        printf '\n开始安装 Remote 端……\n\n'
    fi
}

# -----------------------------------------------------------------------------
# 安装委托
# -----------------------------------------------------------------------------
run_standalone_role() {
    local role="$1"

    # 源码入口只保留角色选择；下载、校验、配置渲染、lifecycle lock 与回滚
    # 全部由 standalone 的唯一实现维护，避免 CN/Remote 事务再次双份漂移。
    INSTALL_BASE="$PROJECT_ROOT" \
    PATHLOCK_SOURCE_TREE=1 \
    GOST_VERSION="${GOST_VERSION:-v3.2.6}" \
    SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}" \
    SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-systemctl}" \
        bash "$PROJECT_ROOT/standalone-install.sh" "$role"
}

install_cn() {
    run_standalone_role cn
}

install_remote() {
    run_standalone_role remote
}

# --help 不需要 root 权限；其他安装路径必须以 root 执行。
main() {
    case "${1:-}" in
        -h|--help)
            show_banner
            show_role_guide
            printf '\n'
            show_usage
            exit 0
            ;;
        "") ;;
        *)
            if ! SELECTED_ROLE="$(normalize_role "$1")"; then
                echo "未知角色: $1" >&2
                show_usage >&2
                exit 2
            fi
            ;;
    esac

    if (( $# > 1 )); then
        echo "参数过多。" >&2
        show_usage >&2
        exit 2
    fi

    if (( EUID != 0 )); then
        echo "安装需要 root 权限，请执行：sudo bash install.sh${1:+ $1}" >&2
        exit 1
    fi

    show_banner
    if [[ -z "$SELECTED_ROLE" ]]; then
        select_role_interactively
    fi
    show_next_steps

    case "$SELECTED_ROLE" in
        cn) install_cn ;;
        remote) install_remote ;;
        *) echo "内部错误：未知角色 $SELECTED_ROLE" >&2; exit 2 ;;
    esac
}

main "$@"
