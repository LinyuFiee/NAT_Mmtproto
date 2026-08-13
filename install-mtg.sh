#!/bin/sh
#==============================================================================
#  install-mtg.sh  (remote-executable)
#
#  MTG (Telegram MTProto proxy, https://github.com/9seconds/mtg) installer for
#  a tiny Alpine Linux 3.22 x86_64 box (e.g. NAT VPS with 128MB RAM/disk).
#
#  Remote one-liner:
#    curl -fsSL https://raw.githubusercontent.com/LinyuFiee/NAT_Mmtproto/main/install-mtg.sh | sh
#    wget -qO- https://raw.githubusercontent.com/LinyuFiee/NAT_Mmtproto/main/install-mtg.sh | sh
#
#  When run through a pipe (curl | sh), the script downloads itself to /tmp and
#  re-executes with a real terminal (/dev/tty), so the interactive wizard still
#  works. When run as a file, it behaves exactly the same.
#
#  Interactive wizard (port / public port / fake-TLS domain / secret), downloads
#  the prebuilt static mtg binary, installs an OpenRC service and prints the
#  tg:// link. No compiler needed.
#
#  NOTE: mtg v2 supports ONLY FakeTLS secrets (starting with "ee" or base64).
#
#  Commands:
#    sh install-mtg.sh                install with interactive wizard
#    sh install-mtg.sh doctor         diagnose service + Telegram connectivity
#    sh install-mtg.sh uninstall      stop and remove everything
#    sh install-mtg.sh help           show usage
#
#  Non-interactive env overrides:
#    PORT, PUBLIC_PORT, FAKE_TLS_DOMAIN, SECRET, DNS, MTG_VERSION, MTG_SHA256, KEEP_CONFIG
#==============================================================================

#----------------------------------------------------------------- remote bootstrap
INSTALL_URL="https://raw.githubusercontent.com/LinyuFiee/NAT_Mmtproto/main/install-mtg.sh"

if [ ! -t 0 ] && [ "${INSTALL_BOOTSTRAPPED:-0}" != "1" ]; then
    _tmp="/tmp/install-mtg.$$"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$INSTALL_URL" -o "$_tmp" 2>/dev/null || exit 1
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$_tmp" "$INSTALL_URL" 2>/dev/null || exit 1
    else
        echo "install-mtg.sh: curl or wget is required" >&2
        exit 1
    fi
    chmod 755 "$_tmp"
    INSTALL_BOOTSTRAPPED=1
    export INSTALL_BOOTSTRAPPED
    if [ -r /dev/tty ]; then
        exec "$_tmp" "$@" < /dev/tty
    else
        exec "$_tmp" "$@"
    fi
fi
#----------------------------------------------------------------- end bootstrap

set -eu

#----------------------------------------------------------------- settings
MTG_VERSION="${MTG_VERSION:-v2.2.8}"
MTG_SHA256="${MTG_SHA256:-7ef19d079d85f4e00d4f8334ec1f3f3c8718e3d0ed1f3109ea9a8673138a2102}"
MTG_BIN="/usr/local/bin/mtg"
MTG_DIR="/etc/mtg"
MTG_CONF="$MTG_DIR/mtg.toml"
MTG_LOG="/var/log/mtg.log"
PORT="${PORT:-443}"
PUBLIC_PORT="${PUBLIC_PORT:-}"
SECRET="${SECRET:-}"
FAKE_TLS_DOMAIN="${FAKE_TLS_DOMAIN:-}"
DNS="${DNS:-udp://223.5.5.5}"

V="${MTG_VERSION#v}"
TARBALL="/tmp/mtg-${V}-linux-amd64.tar.gz"
URL="https://github.com/9seconds/mtg/releases/download/${MTG_VERSION}/mtg-${V}-linux-amd64.tar.gz"

#----------------------------------------------------------------- colors / ui
R='\033[0m'
BOLD='\033[1m'
G='\033[32m'
Y='\033[33m'
B='\033[34m'
M='\033[35m'
C='\033[36m'
DIM='\033[2m'

if command -v stty >/dev/null 2>&1; then
    trap 'stty echo 2>/dev/null || true' EXIT INT TERM
fi

info() { printf '%b[ %b*%b ]%b %s\n' "$B" "$C" "$B" "$R" "$*"; }
ok()   { printf '%b[ %b+%b ]%b %s\n' "$G" "$G" "$G" "$R" "$*"; }
warn() { printf '%b[ %b!%b ]%b %s\n' "$Y" "$Y" "$Y" "$R" "$*"; }
err()  { printf '%b[ %bX%b ]%b %s\n' "$R" "$R" "$R" "$R" "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
    cat <<'EOF'
用法: sh install-mtg.sh [install|doctor|uninstall|help]

命令:
  install     安装 / 重装（默认，交互式向导）
  doctor      诊断服务与 Telegram 连通性
  uninstall   卸载（KEEP_CONFIG=1 保留配置）
  help        显示帮助

远程执行（自动下载并交互）:
  curl -fsSL https://raw.githubusercontent.com/LinyuFiee/NAT_Mmtproto/main/install-mtg.sh | sh

环境变量（非交互模式）:
  PORT=8533 FAKE_TLS_DOMAIN=www.bing.com sh install-mtg.sh
  PUBLIC_PORT、SECRET、DNS、MTG_VERSION、MTG_SHA256、KEEP_CONFIG
EOF
}

hline() {
    n="${1:-58}"
    i=0
    while [ "$i" -lt "$n" ]; do printf '─'; i=$((i + 1)); done
    printf '\n'
}

section() {
    printf '\n%b┌─ %s%b\n' "$C" "$1" "$R"
}

banner() {
    printf '%b' "$B$BOLD"
    hline 58
    printf '%b  %bMTG · Telegram 代理 一键安装%b\n' "$BOLD" "$C" "$R"
    printf '%b  %bAlpine Linux 3.22 x86_64  ·  无需编译，仅需 ~20MB%b\n' "$BOLD" "$DIM" "$R"
    printf '%b' "$B$BOLD"
    hline 58
    printf '%b' "$R"
}

#----------------------------------------------------------------- helpers
require_root() {
    [ "$(id -u)" -eq 0 ] || die "请以 root 运行：sudo sh install-mtg.sh"
}

check_arch() {
    case "$(uname -m)" in
        x86_64|amd64) ;;
        *) die "需要 x86_64 架构，当前为 $(uname -m)。" ;;
    esac
}

is_tty() { [ -t 0 ] && [ -t 1 ]; }

# China-friendly: detect the public IPv4 at install time and bake it into the
# config so mtg never has to query ifconfig.co at runtime (blocked/slow in CN).
detect_public_ip() {
    PUBLIC_IPV4=""
    ip="$(curl -fsS -m 10 -4 https://api.ipify.org 2>/dev/null || true)"
    [ -n "$ip" ] || ip="$(curl -fsS -m 10 -4 https://ifconfig.me/ip 2>/dev/null || true)"
    case "$ip" in
        [0-9]*.[0-9]*.[0-9]*.[0-9]*) PUBLIC_IPV4="$ip" ;;
        *) PUBLIC_IPV4="" ;;
    esac
}

ask() {
    # prompt -> stderr (this function runs inside $(), stdout carries the answer)
    question="$1"
    default="$2"
    if [ -n "$default" ]; then
        printf '  %b%s%b [%b%s%b]: ' "$Y" "$question" "$R" "$C" "$default" "$R" >&2
    else
        printf '  %b%s%b: ' "$Y" "$question" "$R" >&2
    fi
    read -r ans || ans="$default"
    ans="$(printf '%s' "$ans" | tr -d '\r')"
    [ -n "$ans" ] || ans="$default"
    printf '%s\n' "$ans"
}

read_secret() {
    # hidden input; prompt -> stderr, answer -> stdout
    if command -v stty >/dev/null 2>&1; then
        stty -echo
    fi
    printf '  %b%s%b: ' "$Y" "$1" "$R" >&2
    read -r pw || pw=""
    pw="$(printf '%s' "$pw" | tr -d '\r')"
    printf '\n'
    if command -v stty >/dev/null 2>&1; then
        stty echo
    fi
    printf '%s\n' "$pw"
}

clean_leftovers() {
    info "清理之前失败安装残留的编译工具链（build-base 会强制拉 g++）..."
    apk del --purge build-base 2>/dev/null || true
    apk del --purge g++ gcc make binutils git 2>/dev/null || true
    apk cache clean 2>/dev/null || true
    df -h /
    ok "磁盘已清理。"
}

install_deps() {
    info "自动安装依赖 ..."
    apk fix --no-network >/dev/null 2>&1 || true
    if ! apk add --no-cache curl >/dev/null; then
        err "apk 安装 curl 失败。若 apk 报告包状态损坏，请先执行："
        err "  apk del --purge build-base; apk fix --no-network; apk cache clean; df -h"
        die "依赖安装失败，已中止。"
    fi
    missing=""
    for t in curl sha256sum tar sed awk od tr head tail; do
        command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
    done
    if [ -n "$missing" ]; then
        die "系统缺少必要工具：$missing（请运行 apk add --no-cache busybox-extras 后重试）"
    fi
    ok "依赖已就绪（curl + busybox 工具集，无需编译器）。"
}

download_binary() {
    if [ -x "$MTG_BIN" ] && "$MTG_BIN" --version >/dev/null 2>&1; then
        ok "mtg 已安装（$("$MTG_BIN" --version 2>&1 | head -n1)）。"
        return 0
    fi
    info "下载 mtg ${MTG_VERSION} ..."
    if ! curl -fsSL -o "$TARBALL" "$URL"; then
        warn "curl 下载失败，尝试 busybox wget ..."
        rm -f "$TARBALL"
        if ! wget -q -O "$TARBALL" "$URL"; then
            die "下载失败：$URL"
        fi
    fi
    info "校验 SHA256 ..."
    actual="$(sha256sum "$TARBALL" | awk '{print $1}')"
    if [ "$actual" != "$MTG_SHA256" ]; then
        die "SHA256 不匹配：实际 $actual，期望 $MTG_SHA256"
    fi
    ok "校验通过。"
    tar -xzf "$TARBALL" -C /tmp
    install -m 0755 "/tmp/mtg-${V}-linux-amd64/mtg" "$MTG_BIN"
    rm -rf "/tmp/mtg-${V}-linux-amd64" "$TARBALL"
    ok "已安装 $MTG_BIN"
}

# mtg v2 accepts ONLY FakeTLS secrets:
#   hex form:  "ee" + 32 hex + hex(hostname)
#   base64 form: base64 of bytes whose first byte is 0xee (marker)
# Plain hex secrets are rejected.
is_valid_secret() {
    s="$1"
    [ -n "$s" ] || return 1
    case "$s" in
        ee*)
            rest="${s#ee}"
            case "$rest" in
                *[!0-9a-fA-F]*) ;; # not hex -> fall through to base64 check
                *) return 0 ;;
            esac
            ;;
    esac
    case "$s" in
        *[!A-Za-z0-9+/=]*) return 1 ;;
    esac
    command -v base64 >/dev/null 2>&1 || return 1
    first="$(printf '%s' "$s" | base64 -d 2>/dev/null | od -An -tx1 | tr -d ' \n' | cut -c1-2)"
    [ "$first" = "ee" ]
}

# deterministic FakeTLS secret from a password + domain
password_to_secret() {
    password="$1"
    domain="$2"
    key_hex="$(printf '%s' "$password" | md5sum | awk '{print $1}')"
    host_hex="$(printf '%s' "$domain" | od -An -tx1 | tr -d ' \n')"
    printf 'ee%s%s\n' "$key_hex" "$host_hex"
}

#----------------------------------------------------------------- wizard
existing_port=""
existing_secret=""

read_existing() {
    if [ -f "$MTG_CONF" ]; then
        existing_port="$(sed -n 's|^bind-to *= *"0\.0\.0\.0:\([0-9]*\)"|\1|p' "$MTG_CONF" | head -n1)"
        existing_secret="$(sed -n 's/^secret *= *"\(.*\)"/\1/p' "$MTG_CONF" | head -n1)"
        if ! is_valid_secret "$existing_secret"; then
            warn "检测到旧的无效密码（mtg v2 仅支持 FakeTLS 密码），将重新生成。"
            existing_secret=""
        fi
    fi
}

choose_secret() {
    printf '\n  %b请选择密码方式：%b\n' "$BOLD" "$R"
    printf '    %b1)%b 自动生成随机密码 %b(推荐，基于 Fake-TLS 域名)%b\n' "$G" "$R" "$DIM" "$R"
    printf '    %b2)%b 使用自定义密码 %b(用 MD5 生成确定性的 FakeTLS 密码)%b\n' "$G" "$R" "$DIM" "$R"
    while :; do
        choice="$(ask "你的选择" "1")"
        case "$choice" in
            1)
                secret_hex="$("$MTG_BIN" generate-secret --hex "$FAKE_TLS_DOMAIN" 2>/dev/null | tail -n1 || true)"
                secret_hex="$(printf '%s' "$secret_hex" | tr -d ' \r')"
                if ! is_valid_secret "$secret_hex"; then
                    warn "自动生成失败，改用密码方式。"
                    continue
                fi
                ok "已生成随机 FakeTLS 密码。"
                break
                ;;
            2)
                pw="$(read_secret "请输入自定义密码（至少 8 位）")"
                if [ "${#pw}" -lt 8 ]; then
                    warn "密码太短，至少 8 位。"
                    continue
                fi
                if is_valid_secret "$pw"; then
                    secret_hex="$pw"
                else
                    secret_hex="$(password_to_secret "$pw" "$FAKE_TLS_DOMAIN")"
                fi
                ok "已设置自定义密码。"
                break
                ;;
            *)
                warn "请输入 1 或 2。"
                ;;
        esac
    done
}

wizard() {
    section "步骤 1/3 · 端口设置"
    dport="${existing_port:-$PORT}"
    while :; do
        p="$(ask "请输入代理监听端口（NAT 小鸡请填内网端口）" "$dport")"
        p="$(printf '%s' "$p" | tr -d ' \r')"
        case "$p" in
            ''|*[!0-9]*)
                warn "端口必须是数字。"
                continue
                ;;
        esac
        if [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
            warn "端口范围是 1 - 65535。"
            continue
        fi
        PORT="$p"
        break
    done

    section "步骤 2/4 · 公网端口（NAT 转发端口，仅用于生成链接）"
    pport="$(ask "供应商 NAT 规则里的公网端口（如 8533；留空=同内网端口）" "${PUBLIC_PORT:-}")"
    pport="$(printf '%s' "$pport" | tr -d ' \r')"
    case "$pport" in
        '')
            PUBLIC_PORT=""
            ;;
        *[!0-9]*)
            warn "端口必须是数字，已忽略，使用内网端口。"
            PUBLIC_PORT=""
            ;;
        *)
            if [ "$pport" -lt 1 ] || [ "$pport" -gt 65535 ]; then
                warn "端口范围是 1 - 65535，已忽略，使用内网端口。"
                PUBLIC_PORT=""
            else
                PUBLIC_PORT="$pport"
            fi
            ;;
    esac

    section "步骤 3/4 · Fake-TLS 伪装域名（mtg v2 必需）"
    ddomain="${FAKE_TLS_DOMAIN:-www.bing.com}"
    while :; do
        ft="$(ask "伪装域名（选择可达的 https 网站，如 www.bing.com）" "$ddomain")"
        ft="$(printf '%s' "$ft" | tr -d ' \r')"
        case "$ft" in
            ''|*[!a-zA-Z0-9.-]*)
                warn "域名格式不正确，例如 www.bing.com。"
                continue
                ;;
        esac
        FAKE_TLS_DOMAIN="$ft"
        break
    done

    section "步骤 4/4 · 密码 (Secret) 设置"
    if [ -n "$existing_secret" ]; then
        keep="$(ask "检测到已有密码，是否保留？" "Y")"
        case "$keep" in
            y|Y|yes|YES|Yes|"") secret_hex="$existing_secret" ;;
            *) choose_secret ;;
        esac
    else
        choose_secret
    fi

    printf '\n'
    hline 58
    printf '  %b内网端口    %b %s%b\n' "$C" "$Y" "$PORT" "$R"
    printf '  %b公网端口    %b %s%b\n' "$C" "$Y" "${PUBLIC_PORT:-（同内网端口）}" "$R"
    printf '  %bFake-TLS    %b %s%b\n' "$C" "$Y" "$FAKE_TLS_DOMAIN" "$R"
    printf '  %b密码Secret  %b %s%b\n' "$C" "$Y" "$secret_hex" "$R"
    hline 58
    c="$(ask "以上信息确认无误？" "Y")"
    case "$c" in
        n|N|no|NO|No|否) die "已取消安装。" ;;
    esac
}

#----------------------------------------------------------------- install
setup_config() {
    mkdir -p "$MTG_DIR"
    chmod 700 "$MTG_DIR"

    public_ipv4_line=""
    if [ -n "$PUBLIC_IPV4" ]; then
        public_ipv4_line="public-ipv4 = \"$PUBLIC_IPV4\""
    fi

    cat > "$MTG_CONF" <<EOF
# MTG configuration (generated by install-mtg.sh)
secret = "$secret_hex"
bind-to = "0.0.0.0:$PORT"
prefer-ip = "prefer-ipv4"
dns = "$DNS"
$public_ipv4_line

# 中国大陆：DNS 已默认设为 AliDNS(udp://223.5.5.5)，因为 mtg 默认的
# DoH(https://1.1.1.1) 在大陆不可达；也可改为 dns = "udp://119.29.29.29" (DNSPod)
# public-ipv4 已在安装时探测并写入，避免 mtg 运行时访问 ifconfig.co。

# 允许同网段/LAN 客户端（默认 firehol 封锁列表含内网地址）：
# [defense.blocklist]
# enabled = false
EOF
    chmod 600 "$MTG_CONF"
    ok "已写入 $MTG_CONF"
}

install_init() {
    cat > /etc/init.d/mtg <<'EOF'
#!/sbin/openrc-run
# MTG MTProto proxy for Telegram - OpenRC service
name="mtg"
description="MTG MTProto proxy for Telegram"
command="/usr/local/bin/mtg"
command_args="run /etc/mtg/mtg.toml"
pidfile="/run/mtg.pid"
supervisor="supervise-daemon"
output_log="/var/log/mtg.log"
respawn_delay=2
respawn_max=5

depend() {
    need net
    after firewall
}

start_pre() {
    [ -x "$command" ] || { eerror "Binary not found: $command"; return 1; }
    [ -f /etc/mtg/mtg.toml ] || { eerror "Missing /etc/mtg/mtg.toml"; return 1; }
}
EOF
    chmod 0755 /etc/init.d/mtg
    rc-update add mtg default >/dev/null 2>&1 || true
    ok "OpenRC 服务已安装并启用（日志：$MTG_LOG）。"
}

start_service() {
    info "启动 mtg 服务 ..."
    rc-service mtg restart >/dev/null 2>&1 || rc-service mtg start >/dev/null 2>&1
    sleep 1
    if rc-service mtg status >/dev/null 2>&1; then
        ok "mtg 正在运行。"
    else
        warn "mtg 未能启动，请查看日志：cat $MTG_LOG"
        warn "或前台运行排查：/usr/local/bin/mtg run /etc/mtg/mtg.toml"
    fi
}

print_summary() {
    secret_hex="$(sed -n 's/^secret *= *"\(.*\)"/\1/p' "$MTG_CONF" | head -n1)"
    port_value="$(sed -n 's|^bind-to *= *"0\.0\.0\.0:\([0-9]*\)"|\1|p' "$MTG_CONF" | head -n1)"
    [ -n "$port_value" ] || port_value="$PORT"
    link_port="${PUBLIC_PORT:-$port_value}"

    public_ip="$PUBLIC_IPV4"
    [ -n "$public_ip" ] || public_ip="$(curl -fsS -m 10 -4 https://api.ipify.org 2>/dev/null || true)"
    [ -n "$public_ip" ] || public_ip="$(curl -fsS -m 10 -4 https://ifconfig.me/ip 2>/dev/null || true)"
    [ -n "$public_ip" ] || public_ip="你的公网IP"

    link="tg://proxy?server=${public_ip}&port=${link_port}&secret=${secret_hex}"

    printf '\n%b' "$G$BOLD"
    hline 58
    printf '%b  ✓ 安装成功  Success%b\n' "$G" "$R"
    printf '%b' "$G$BOLD"
    hline 58
    printf '%b' "$R"
    printf '%b  服务       %b%s%b\n' "$C" "$Y" "rc-service mtg status" "$R"
    printf '%b  日志       %b%s%b\n' "$C" "$Y" "$MTG_LOG" "$R"
    printf '%b  配置       %b%s%b\n' "$C" "$Y" "$MTG_CONF" "$R"
    printf '\n'
    printf '%b  代理链接   %b%s%b\n' "$C" "$G$BOLD" "$link" "$R"
    printf '%b  浏览器链接 %b%s%b\n' "$C" "$Y" "https://t.me/proxy?server=${public_ip}&port=${link_port}&secret=${secret_hex}" "$R"
    printf '\n%b  使用提示：%b\n' "$BOLD" "$R"
    if [ "$link_port" != "$port_value" ]; then
        printf '   %b·%b 内网监听 %b%s%b，公网使用 %b%s%b（NAT 转发 8533 → 443 这类规则）\n' "$G" "$R" "$Y" "$port_value" "$R" "$Y" "$link_port" "$R"
    fi
    printf '   %b·%b 诊断：sh install-mtg.sh doctor\n' "$G" "$R"
    printf '   %b·%b DNS 已用 AliDNS；若仍连不上，可改 dns = "udp://119.29.29.29" 后 rc-service mtg restart\n' "$G" "$R"
    printf '   %b·%b 重新运行本脚本可升级并保留密码；卸载：sh install-mtg.sh uninstall\n' "$G" "$R"
    printf '%b' "$G$BOLD"
    hline 58
    printf '%b' "$R"
}

#----------------------------------------------------------------- commands
doctor() {
    require_root
    printf '\n%b== 服务状态 ==%b\n' "$BOLD" "$R"
    rc-service mtg status || true
    printf '\n%b== 监听端口 ==%b\n' "$BOLD" "$R"
    netstat -tlnp 2>/dev/null | grep -E 'mtg|LISTEN' | grep -v '127.0.0.1' || ss -tlnp 2>/dev/null | grep mtg || true
    printf '\n%b== 最近日志 ==%b\n' "$BOLD" "$R"
    tail -n 30 "$MTG_LOG" 2>/dev/null || echo "（无日志文件）"
    if [ -x "$MTG_BIN" ] && [ -f "$MTG_CONF" ]; then
        printf '\n%b== mtg doctor（Telegram 连通性） ==%b\n' "$BOLD" "$R"
        "$MTG_BIN" doctor "$MTG_CONF" || true
    fi
}

uninstall() {
    require_root
    info "停止并卸载 mtg ..."
    rc-service mtg stop >/dev/null 2>&1 || true
    rc-update del mtg >/dev/null 2>&1 || true
    rm -f /etc/init.d/mtg
    rm -f "$MTG_BIN"
    if [ "${KEEP_CONFIG:-0}" = "1" ]; then
        warn "KEEP_CONFIG=1：保留 $MTG_DIR"
    else
        rm -rf "$MTG_DIR"
    fi
    ok "已卸载。"
}

install_all() {
    require_root
    check_arch
    read_existing
    clean_leftovers
    install_deps
    download_binary
    if is_tty; then
        banner
        wizard
    else
        if [ -z "$FAKE_TLS_DOMAIN" ]; then
            FAKE_TLS_DOMAIN="www.bing.com"
        fi
        if [ -n "$existing_secret" ] && [ -z "$SECRET" ]; then
            secret_hex="$existing_secret"
        elif [ -n "$SECRET" ]; then
            secret_hex="$SECRET"
        else
            secret_hex="$("$MTG_BIN" generate-secret --hex "$FAKE_TLS_DOMAIN" 2>/dev/null | tail -n1 || true)"
            secret_hex="$(printf '%s' "$secret_hex" | tr -d ' \r')"
        fi
        if ! is_valid_secret "$secret_hex"; then
            secret_hex="$(password_to_secret "mtg-$(date +%s)" "$FAKE_TLS_DOMAIN")"
        fi
    fi
    detect_public_ip
    setup_config
    install_init
    start_service
    print_summary
}
#----------------------------------------------------------------- dispatch
case "${1:-install}" in
    install|reinstall) install_all ;;
    uninstall)         uninstall ;;
    doctor|status)     doctor ;;
    help|--help|-h)  usage ;;
    *)
        err "未知命令：$1"
        exit 1
        ;;
esac
