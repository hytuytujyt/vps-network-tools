# REALITY / Shadowsocks / HY2 一键安装

sing-box 节点安装脚本，root 交互式执行，取消则不做任何修改。

```sh
curl -fsSL https://raw.githubusercontent.com/hytuytujyt/vps-network-tools/main/install_reality.sh -o /tmp/install_reality.sh
sh /tmp/install_reality.sh
```

## 端口规则

HY2 端口：

- **本机 UDP 端口**：本机实际监听的唯一 UDP 端口。固定填443！
- **对外 UDP 端口或跳跃范围**：手机连接的公网 UDP 端口，可以填单个端口（如 `443`）、范围（如 `30000-30005`）或逗号列表。
- **跳跃处理方式**（仅填范围时询问）：
  - `1` 本机 nftables：普通公网 VPS 选这个，脚本在本机建转发。
  - `2` 外部 NAT 映射：商家面板已经把端口映射好，脚本不改网络规则。

## 安装后

```sh
shownode
```

`shownode` 按当前服务端配置列出可以导出的 VLESS、Shadowsocks、HY2 出站片段。

### 节点开关

```sh
vless off   # 关闭 VLESS / Reality
vless on    # 恢复 VLESS / Reality
hy2 off     # 关闭 HY2（包括端口跳跃）
hy2 on      # 恢复 HY2
```

用 `vless status` 或 `hy2 status` 检查状态。按协议识别入站，不看 tag；不重启 sing-box，不换客户端配置。`off` 只拦外部访问，`on` 不改云安全组。

新版安装时自动添加命令。已装节点可用新版脚本执行 `sh /tmp/install_reality.sh --install-switches`，不必重装。需 root 和 nftables 权限。开机会尝试恢复关闭状态；如果恢复失败或防火墙重载清空规则，节点可能重新可访问，请用 `status` 检查。

### HY2 安装检查

诊断路径会打印在终端，默认在 `/etc/sing-box/install-diagnostics.*`。

本机协议自检默认关闭，需要时在运行前加环境变量：

```sh
SELF_CHECK=1 sh /tmp/install_reality.sh
```

## Let's Encrypt 证书（HY2，推荐）

1. 安装脚本选择 HY2 + Let’s Encrypt，并提供自定义域名和 Cloudflare API 令牌。
2. 如果没有可复用的有效证书，脚本调用 acme.sh，向 Let’s Encrypt 申请这个域名的证书。
3. Let’s Encrypt 发起一次 DNS-01 挑战，要求在指定名称下发布本次挑战对应的 TXT 内容，例如 _acme-challenge.hy2.example.com。
4. acme.sh 按 ACME 规则计算 TXT 值，通过 Cloudflare API 添加记录。脚本设置的 --dnssleep 30 会在验证前等待 30 秒，让 DNS 记录有时间传播。
5. Let’s Encrypt 查询 TXT 记录并检查内容。匹配后，说明申请方当时能够控制该域名的 DNS，Let’s Encrypt 随后签发证书。验证结束后，acme.sh 通常会清理挑战记录。
6. 之后用户端连接 VPS 时，VPS 在 TLS 握手中发送证书链，并证明自己持有对应的私钥。用户端在本地检查证书链是否能追溯到自己信任的 CA、证书是否有效，以及证书上的域名是否匹配配置的 SNI。
7. 检查通过后，用户端和 VPS 建立加密连接。这证明连接对端持有一张适用于该域名的有效证书，不代表 VPS 本身没有恶意软件或其他风险。

## 关闭 SSH 密码登录（可选，脚本不会自动做）

先执行 `sshkey` 保存私钥，并在另一个窗口确认能用它登录，同时保留当前会话和服务商救援控制台。然后：

```sh
closepwd
```

阅读提示后输入大写的 `CLOSE` 确认。命令会备份 SSH 主配置、关闭 `PasswordAuthentication` 和 `KbdInteractiveAuthentication` 并重启 SSH，失败自动恢复；未启用公钥认证、配置检查失败或检测到 `Match` 规则时拒绝执行。

## 注意事项

- 客户端不支持 gecko 混淆时，重跑时选择 `2` salamander 并使用新配置。
- 默认最低核心版本为 **1.12.0**；HY2 需要支持 QUIC 的核心，选择 Gecko 时最低版本升为 **1.14.0**。
- 每次重装前会备份服务端配置为 `config.json.bak.*`（含全部节点凭据，权限 600），只保留最近 3 份。
- 云安全组需自行放行。
