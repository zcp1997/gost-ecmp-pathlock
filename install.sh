#!/usr/bin/env bash
set -euo pipefail

# 项目唯一安装入口：负责角色选择、交互配置、GOST 下载和 systemd unit 安装。
# Remote 逻辑保留在本文件；CN 委托给 standalone 的唯一实现，避免共享多线路逻辑双份漂移。
PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SELECTED_ROLE=""
MTCP_AUTH_USERNAME="mtcp"

valid_mtcp_auth_password() {
    local password="${1-}"

    (( ${#password} >= 12 && ${#password} <= 128 )) || return 1
    [[ "$password" =~ ^[A-Za-z0-9._~!@#%+=:,/-]+$ ]]
}

prompt_mtcp_auth_password() {
    local output_var="$1" prompt="$2" password confirmation

    if [[ -n "${MTCP_AUTH_PASSWORD+x}" ]]; then
        password="$MTCP_AUTH_PASSWORD"
        if ! valid_mtcp_auth_password "$password"; then
            echo "MTCP_AUTH_PASSWORD 无效：长度须为 12-128，只能包含字母、数字及 ._~!@#%+=:,/-" >&2
            return 1
        fi
    else
        while :; do
            if ! IFS= read -r -s -p "$prompt: " password; then
                printf '\n未输入 MTCP 鉴权密码，安装已取消。\n' >&2
                return 1
            fi
            printf '\n' >&2
            if ! valid_mtcp_auth_password "$password"; then
                echo "密码长度须为 12-128，只能包含字母、数字及 ._~!@#%+=:,/-，请重新输入。" >&2
                continue
            fi
            if ! IFS= read -r -s -p "请再次输入以确认: " confirmation; then
                printf '\n未确认 MTCP 鉴权密码，安装已取消。\n' >&2
                return 1
            fi
            printf '\n' >&2
            if [[ "$password" != "$confirmation" ]]; then
                echo "两次输入的密码不一致，请重新输入。" >&2
                continue
            fi
            break
        done
    fi

    printf -v "$output_var" '%s' "$password"
}

write_mtcp_auth_file() {
    local destination="$1" password="$2"

    (umask 077; printf '%s %s\n' "$MTCP_AUTH_USERNAME" "$password" > "$destination")
    chmod 0600 "$destination"
}

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
# CN 安装实现
# -----------------------------------------------------------------------------
install_cn() {
    # CN 的完整实现由自包含安装器维护，传统入口只负责把项目目录作为安装根目录。
    # 这样多实例聚合、鉴权、事务回滚不会在两个安装器中形成第二份易漂移实现。
    INSTALL_BASE="$PROJECT_ROOT" \
    PATHLOCK_SOURCE_TREE=1 \
    GOST_VERSION="${GOST_VERSION:-v3.2.6}" \
    SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}" \
    SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-systemctl}" \
        bash "$PROJECT_ROOT/standalone-install.sh" cn
}

# -----------------------------------------------------------------------------
# Remote 安装实现
# -----------------------------------------------------------------------------
install_remote() {
    BASE="$PROJECT_ROOT"
    REMOTE_DIR="$BASE/remote"
    SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
    REMOTE_CONFIG="$REMOTE_DIR/remote.yaml"
    AUTH_FILE="$REMOTE_DIR/mtcp.auth"
    MAIN_UNIT="gost-ecmp-pathlock-remote.service"
    ANCHOR_UNIT="gost-ecmp-pathlock-remote-anchor-endpoint.service"
    GOST_REPO="go-gost/gost"
    GOST_VERSION="${GOST_VERSION:-v3.2.6}"
    GITHUB_PROXY_PREFIX="${GITHUB_PROXY_PREFIX-}"
    GOST_TMP_DIR=""
    LISTEN_PORT=""
    AUTH_PASSWORD=""
    SOCAT_BIN=""
    TMP_FILES=()

    cleanup_tmp_files() {
        local tmp
        if [[ -n "$GOST_TMP_DIR" ]]; then
            rm -rf "$GOST_TMP_DIR"
        fi
        if (( ${#TMP_FILES[@]} > 0 )); then
            for tmp in "${TMP_FILES[@]}"; do
                rm -f "$tmp"
            done
        fi
    }
    trap cleanup_tmp_files EXIT

    check_dependencies() {
        local command_name
        local -a missing=()

        for command_name in awk curl grep install mktemp readlink socat systemctl tar; do
            command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
        done
        if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
            missing+=("sha256sum/shasum")
        fi
        if [[ ! -x /bin/bash ]]; then
            missing+=("/bin/bash")
        fi
        if (( ${#missing[@]} > 0 )); then
            echo "缺少依赖命令: ${missing[*]}" >&2
            exit 1
        fi
        SOCAT_BIN="$(command -v socat)"
    }

    ensure_remote_inactive() {
        local unit
        local -a active_units=()
        for unit in "$ANCHOR_UNIT" "$MAIN_UNIT"; do
            systemctl is-active --quiet "$unit" >/dev/null 2>&1 && active_units+=("$unit")
        done
        if (( ${#active_units[@]} > 0 )); then
            echo "Remote 端仍有运行中的 unit: ${active_units[*]}" >&2
            echo "为避免运行进程与重装中的新配置错配，请先停止后重试：" >&2
            echo "  systemctl stop $ANCHOR_UNIT $MAIN_UNIT" >&2
            exit 1
        fi
    }

    cleanup_obsolete_project_units() {
        local unit_file target relative role_dir unit_name
        local -a unit_files=()

        for unit_file in "$SYSTEMD_DIR"/gost-ecmp-pathlock*.service; do
            [[ -L "$unit_file" ]] && unit_files+=("$unit_file")
        done
        (( ${#unit_files[@]} > 0 )) || return 0

        for unit_file in "${unit_files[@]}"; do
            target="$(readlink "$unit_file" 2>/dev/null || true)"
            case "$target" in
                "$BASE"/*)
                    relative="${target#"$BASE"/}"
                    role_dir="${relative%%/*}"
                    if [[ "$role_dir" != "cn" && "$role_dir" != "remote" ]]; then
                        unit_name="${unit_file##*/}"
                        systemctl disable --now "$unit_name" >/dev/null 2>&1 || true
                        rm -f "$unit_file"
                        echo "已清理旧版部署 unit: $unit_name"
                    fi
                    ;;
            esac
        done
    }

    valid_port() {
        local port="$1"
        [[ "$port" =~ ^[0-9]+$ && ${#port} -le 10 ]] || return 1
        (( 10#$port >= 1 && 10#$port <= 65535 ))
    }

    read_current_port() {
        awk '
            /^[[:space:]]*-[[:space:]]name:[[:space:]]*mtcp-server[[:space:]]*$/ {
                in_service = 1
                next
            }
            in_service && /^[[:space:]]*addr:[[:space:]]*:/ {
                value = $0
                sub(/^[[:space:]]*addr:[[:space:]]*:/, "", value)
                sub(/[[:space:]]*$/, "", value)
                print value
                exit
            }
        ' "$REMOTE_CONFIG" 2>/dev/null || true
    }

    configure_listen_port() {
        local default_port input config_tmp auth_tmp

        [[ -r "$REMOTE_CONFIG" ]] || {
            echo "Remote 配置不可读: $REMOTE_CONFIG" >&2
            exit 1
        }
        default_port="$(read_current_port)"
        valid_port "$default_port" || default_port="6600"
        default_port="$((10#$default_port))"

        while :; do
            if ! read -r -p "请输入 Remote 端 MTCP 监听端口 [$default_port]: " input; then
                echo "未输入监听端口，安装已取消。" >&2
                exit 1
            fi
            input="${input:-$default_port}"
            if ! valid_port "$input"; then
                echo "端口必须是 1-65535 之间的数字，请重新输入。" >&2
                continue
            fi
            input="$((10#$input))"
            if [[ "$input" == "12346" ]]; then
                echo "端口 12346 已由本机 Anchor endpoint 使用，请选择其他端口。" >&2
                continue
            fi
            LISTEN_PORT="$input"
            break
        done
        prompt_mtcp_auth_password AUTH_PASSWORD "请设置 Remote MTCP 鉴权密码" || exit 1

        config_tmp="$(mktemp "$REMOTE_DIR/.remote.yaml.tmp.XXXXXX")"
        auth_tmp="$(mktemp "$REMOTE_DIR/.mtcp.auth.tmp.XXXXXX")"
        TMP_FILES+=("$config_tmp" "$auth_tmp")
        write_mtcp_auth_file "$auth_tmp" "$AUTH_PASSWORD"

        awk -v listen_addr=":$LISTEN_PORT" -v auth_file="$AUTH_FILE" '
            function yaml_quote(value) {
                gsub(/\047/, "\047\047", value)
                return "\047" value "\047"
            }
            {
                line = $0

                if (line ~ /^authers:[[:space:]]*$/) {
                    in_authers = 1
                    in_service = 0
                    in_handler = 0
                    authers_seen++
                } else if (!in_authers && line ~ /^- name:[[:space:]]*/) {
                    in_service = (line ~ /^- name:[[:space:]]*mtcp-server[[:space:]]*$/)
                    in_handler = 0
                    if (in_service) {
                        service_seen++
                    }
                } else if (in_authers && line ~ /^- name:[[:space:]]*/) {
                    in_mtcp_auther = (line ~ /^- name:[[:space:]]*mtcp-auth[[:space:]]*$/)
                    if (in_mtcp_auther) {
                        mtcp_auther_seen++
                    }
                }

                if (in_service && line ~ /^  addr:[[:space:]]*/) {
                    sub(/addr:.*/, "addr: " listen_addr, line)
                    listen_updated++
                }
                if (in_service && line ~ /^  handler:[[:space:]]*$/) {
                    in_handler = 1
                } else if (in_handler && line ~ /^  [^ ]/) {
                    in_handler = 0
                }
                if (in_handler && line ~ /^    auther:[[:space:]]*/) {
                    next
                }
                if (in_handler && line ~ /^    type:[[:space:]]*relay[[:space:]]*$/) {
                    print line
                    print "    auther: mtcp-auth"
                    auth_ref_updated++
                    next
                }
                if (in_mtcp_auther && line ~ /^    path:[[:space:]]*/) {
                    line = "    path: " yaml_quote(auth_file)
                    auth_path_updated++
                }

                print line
            }
            END {
                if (service_seen != 1 || listen_updated != 1 || auth_ref_updated != 1 ||
                    authers_seen != 1 || mtcp_auther_seen != 1 || auth_path_updated != 1) {
                    exit 1
                }
            }
        ' "$REMOTE_CONFIG" > "$config_tmp" || {
            echo "无法更新 $REMOTE_CONFIG 中的 MTCP 监听端口或鉴权配置。" >&2
            exit 1
        }
        mv -f "$auth_tmp" "$AUTH_FILE"
        mv -f "$config_tmp" "$REMOTE_CONFIG"
    }

    sha256_file() {
        if command -v sha256sum >/dev/null 2>&1; then
            sha256sum "$1" | awk '{print $1}'
        elif command -v shasum >/dev/null 2>&1; then
            shasum -a 256 "$1" | awk '{print $1}'
        else
            return 1
        fi
    }

    linux_arch() {
        case "$(uname -m)" in
            x86_64|amd64) echo amd64 ;;
            aarch64|arm64) echo arm64 ;;
            armv7l|armv7*) echo armv7 ;;
            armv6l|armv6*) echo armv6 ;;
            armv5tel|armv5*) echo armv5 ;;
            i386|i486|i586|i686) echo 386 ;;
            riscv64) echo riscv64 ;;
            loongarch64) echo loong64 ;;
            mips64el) echo mips64le_hardfloat ;;
            mips64) echo mips64_hardfloat ;;
            mipsel) echo mipsle_hardfloat ;;
            mips) echo mips_hardfloat ;;
            *) echo "unsupported Linux architecture: $(uname -m)" >&2; return 1 ;;
        esac
    }

    download_gost() {
        local tag="$GOST_VERSION" version arch asset upstream_base_url base_url expected actual target_tmp source_name

        [[ -n "$tag" ]] || { echo "unable to resolve GOST release tag" >&2; exit 1; }
        [[ "$tag" == v* ]] || tag="v$tag"
        version="${tag#v}"
        arch="$(linux_arch)"
        asset="gost_${version}_linux_${arch}.tar.gz"
        upstream_base_url="https://github.com/$GOST_REPO/releases/download/$tag"
        if [[ -n "$GITHUB_PROXY_PREFIX" ]]; then
            base_url="${GITHUB_PROXY_PREFIX%/}/$upstream_base_url"
            source_name="GitHub via ${GITHUB_PROXY_PREFIX%/}"
        else
            base_url="$upstream_base_url"
            source_name="GitHub direct"
        fi
        GOST_TMP_DIR="$(mktemp -d)"

        curl -fsSL --retry 3 "$base_url/$asset" -o "$GOST_TMP_DIR/$asset"
        curl -fsSL --retry 3 "$base_url/checksums.txt" -o "$GOST_TMP_DIR/checksums.txt"
        expected="$(awk -v file="$asset" '$2 == file {print $1; exit}' "$GOST_TMP_DIR/checksums.txt")"
        [[ "$expected" =~ ^[[:xdigit:]]{64}$ ]] || {
            echo "checksum entry missing for $asset" >&2
            exit 1
        }
        actual="$(sha256_file "$GOST_TMP_DIR/$asset")"
        [[ "$actual" == "$expected" ]] || {
            echo "checksum mismatch for $asset" >&2
            exit 1
        }
        tar -xzf "$GOST_TMP_DIR/$asset" -C "$GOST_TMP_DIR"
        [[ -f "$GOST_TMP_DIR/gost" ]] || { echo "GOST binary missing in $asset" >&2; exit 1; }

        target_tmp="$(mktemp "$REMOTE_DIR/.gost.tmp.XXXXXX")"
        TMP_FILES+=("$target_tmp")
        install -m 755 "$GOST_TMP_DIR/gost" "$target_tmp"
        mv -f "$target_tmp" "$REMOTE_DIR/gost"
        echo "Downloaded GOST $tag ($arch) from $source_name."
    }

    verify_rendered_unit() {
        local role="$1" unit_file="$2"

        case "$role" in
            main)
                grep -Fqx "WorkingDirectory=$REMOTE_DIR" "$unit_file" &&
                grep -Fqx "ExecStart=$REMOTE_DIR/gost -D -C $REMOTE_CONFIG" "$unit_file"
                ;;
            anchor)
                grep -Fq "ExecStart=$SOCAT_BIN " "$unit_file" &&
                grep -Fq "TCP-LISTEN:12346,bind=127.0.0.1" "$unit_file"
                ;;
            *) return 1 ;;
        esac
    }

    render_systemd_unit() {
        local role="$1" destination="$2" template tmp

        case "$role" in
            main) template="$REMOTE_DIR/gost-ecmp-pathlock-remote.service" ;;
            anchor) template="$REMOTE_DIR/gost-ecmp-pathlock-remote-anchor-endpoint.service" ;;
            *) echo "未知 unit 类型: $role" >&2; exit 1 ;;
        esac
        [[ -r "$template" ]] || { echo "unit 模板不可读: $template" >&2; exit 1; }

        mkdir -p "$SYSTEMD_DIR"
        tmp="$(mktemp "$SYSTEMD_DIR/.${destination}.tmp.XXXXXX")"
        TMP_FILES+=("$tmp")
        awk -v remote_dir="$REMOTE_DIR" -v socat_bin="$SOCAT_BIN" '
            function replace_literal(text, old, replacement, pos, result) {
                result = ""
                while ((pos = index(text, old)) > 0) {
                    result = result substr(text, 1, pos - 1) replacement
                    text = substr(text, pos + length(old))
                }
                return result text
            }
            {
                line = replace_literal($0, "/root/gost-ecmp-pathlock/remote", remote_dir)
                line = replace_literal(line, "/usr/bin/socat", socat_bin)
                print line
            }
        ' "$template" > "$tmp"
        if ! verify_rendered_unit "$role" "$tmp"; then
            echo "生成的 systemd unit 校验失败: $destination" >&2
            exit 1
        fi
        chmod 0644 "$tmp"
        mv -f "$tmp" "$SYSTEMD_DIR/$destination"
    }

    install_systemd_units() {
        render_systemd_unit main "$MAIN_UNIT"
        render_systemd_unit anchor "$ANCHOR_UNIT"
    }

    mkdir -p "$REMOTE_DIR"
    check_dependencies
    ensure_remote_inactive
    cleanup_obsolete_project_units
    configure_listen_port
    download_gost
    install_systemd_units
    systemctl daemon-reload
    systemctl enable "$MAIN_UNIT"
    systemctl enable "$ANCHOR_UNIT"
    # restart 对未运行的 unit 也会执行 start；重装时确保加载新配置、二进制与 unit。
    systemctl restart "$MAIN_UNIT"
    systemctl restart "$ANCHOR_UNIT"

    echo "gost-ecmp-pathlock Remote 端安装完成，MTCP 监听端口: $LISTEN_PORT/tcp，Relay 鉴权: 已启用"
    echo "鉴权文件: ${AUTH_FILE}（权限 0600）"
    echo "安装 CN 时必须输入本次设置的同一密码。"
    echo "服务: $MAIN_UNIT, $ANCHOR_UNIT"
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
