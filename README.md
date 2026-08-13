# MTG Telegram 代理一键安装脚本

适用于 **NAT** 的 Telegram MTProto 代理（[mtg v2](https://github.com/9seconds/mtg)）一键安装脚本。

- 无需编译：直接下载官方预编译的静态二进制（仅约 20MB）
- 交互式向导：端口 / 公网端口 / Fake-TLS 域名 / 密码 全自动配置
- OpenRC 服务管理，崩溃自动重启，日志落盘
- 自动适配中国大陆网络（DNS、公网 IP）
- 适合 NAT 小鸡、128MB 内存/硬盘的极简 VPS

## 文件

| 文件 | 说明 |
|------|------|
| `install-mtg.sh` | 一键安装 / 诊断 / 卸载脚本 |

## 快速开始

将脚本传到小鸡后，以 root 运行：

```sh
sh install-mtg.sh
```

脚本会自动：
1. 清理残留的编译工具链（`build-base`/`g++` 等，防止占满磁盘）
2. 安装依赖（仅需 `curl`，无需编译器）
3. 下载 mtg 静态二进制并校验 SHA256
4. 交互式向导（见下）
5. 写入配置 `/etc/mtg/mtg.toml`，注册并启动 OpenRC 服务 `mtg`
6. 打印 `tg://` 代理链接

## 交互向导步骤

1. **内网端口** — mtg 监听的端口。NAT 小鸡填供应商转发规则的目标端口（或端口段内任选一个 1:1 转发的端口）。
2. **公网端口** — 供应商 NAT 规则里的公网端口，仅用于生成链接。留空则与内网端口相同。
3. **Fake-TLS 伪装域名** — mtg v2 必须使用 FakeTLS，选择大陆可访问的 HTTPS 网站域名（默认 `www.bing.com`，可用 `www.apple.com`、`www.cloudflare.com` 等）。
4. **密码（Secret）**：
   - `1` 自动生成随机密码（推荐，基于所选域名，以 `ee` 开头）
   - `2` 自定义密码（用 MD5 生成确定性的 FakeTLS 密码）
5. **确认页** — 核对后输入 `Y` 开始安装。

> 注意：mtg v2 **只接受 FakeTLS 密码**（以 `ee` 开头或 base64 格式）。旧版 MTProxy 的 32 位十六进制密码会被拒绝。

## 配置文件 `/etc/mtg/mtg.toml`

安装后自动生成，关键项：

```toml
secret = "ee473ce5...62696e672e636f6d"   # FakeTLS 密码（客户端 secret）
bind-to = "0.0.0.0:8533"                 # 内网监听端口
prefer-ip = "prefer-ipv4"                # 仅 IPv4 优先
dns = "udp://223.5.5.5"                  # AliDNS（大陆可达）
public-ipv4 = "157.254.191.32"           # 安装时自动探测并写入
```

修改后重启：`rc-service mtg restart`。

### 大陆网络自动适配

- **DNS**：默认 `udp://223.5.5.5`（AliDNS），绕开 mtg 默认 DoH `https://1.1.1.1`（大陆不可达）。可改为 `dns = "udp://119.29.29.29"`（DNSPod）。
- **公网 IP**：安装时探测并写入 `public-ipv4`，避免 mtg 运行时访问被墙的 `ifconfig.co`。
- 可用环境变量覆盖：`DNS="udp://119.29.29.29" sh install-mtg.sh`。

## NAT 小鸡 / 端口段

供应商提供公网端口段（如 `157.254.191.32:8501-8700` 1:1 转发）时：

- 内网端口和公网端口填同一个段内端口即可，无需额外转发规则。
- 若使用「公网端口 → 内网端口」的显式转发规则（如 `8533 → 443`），内网端口填规则目标端口，公网端口填规则公网端口。
- 最终 `tg://` 链接必须使用 **公网 IP + 公网端口**。

## 服务管理

```sh
rc-service mtg status      # 状态
rc-service mtg restart     # 重启
rc-update del mtg          # 取消开机自启
tail -f /var/log/mtg.log   # 实时日志
```

## 诊断

```sh
sh install-mtg.sh doctor
```

输出服务状态、监听端口、最近日志、以及 `mtg doctor` 的 Telegram DC 连通性检查（DC 1~5 应全部 `✅`）。

## 其他命令

```sh
sh install-mtg.sh                    # 安装 / 重装（保留已有效密码）
sh install-mtg.sh doctor             # 诊断
sh install-mtg.sh uninstall          # 卸载（KEEP_CONFIG=1 保留配置）
sh install-mtg.sh help               # 帮助
```

非交互式安装（cron/脚本用）：

```sh
PORT=8533 FAKE_TLS_DOMAIN=www.bing.com sh install-mtg.sh
```

可用环境变量：`PORT`、`PUBLIC_PORT`、`FAKE_TLS_DOMAIN`、`SECRET`、`DNS`、`MTG_VERSION`、`MTG_SHA256`、`KEEP_CONFIG`。

## 常见问题

### 服务启动失败 / `incorrect first byte of secret`

配置文件里是无效的旧密码。删除后重新安装：

```sh
rm -f /etc/mtg/mtg.toml
sh install-mtg.sh
```

向导中选「1 自动生成密码」。

### 客户端连不上

1. 确认服务在运行：`sh install-mtg.sh doctor`，DC 1~5 应全 `✅`。
2. 确认链接用的是 **公网 IP + 公网端口**（不是内网端口）。
3. 确认供应商 NAT 转发规则存在且目标端口 = mtg 监听端口。
4. 从本机测试：`nc -vz 公网IP 公网端口`。
5. 若 DC 检查失败且小鸡在大陆，需要额外出墙（mtg 支持 `proxies = ["socks5://..."]` 链式代理）。

### 磁盘不足

脚本会自动清理残留的 `build-base`/`g++`。仍不足时手动：

```sh
apk del --purge build-base 2>/dev/null; apk cache clean; df -h
```

## 安全提示

- 密码（secret）就是代理的访问凭证，请勿公开。
- 默认启用 firehol 封锁列表（含内网地址段）；若需允许同一局域网/同网段客户端，在配置中取消注释：

```toml
[defense.blocklist]
enabled = false
```
