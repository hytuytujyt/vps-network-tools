# REALITY / Shadowsocks / HY2 一键安装

sing-box 节点安装脚本，root 交互式执行。结束时终端打印的内容就是客户端配置。

```sh
curl -fsSL https://raw.githubusercontent.com/hytuytujyt/vps-network-tools/main/install_reality.sh -o /tmp/install_reality.sh
sh /tmp/install_reality.sh
```

脚本会依次询问配置，回车使用方括号里的默认值。最后显示配置摘要，确认后才开始安装；取消则不做任何修改。脚本需要在终端中运行。

## 问答流程

1. 选模式：`1` REALITY、`2` Shadowsocks、`3` HY2、`4` REALITY + HY2
2. 服务器公网 IP（自动探测，可修改）
3. 节点名称（默认 `<模式>-<主机名>`）
4. REALITY（模式 1、4）：本机监听端口、客户端连接端口、伪装域名（留空自动选择）
5. Shadowsocks（模式 2）：本机监听端口、客户端连接端口、加密方式（默认 `aes-128-gcm`）、密码（留空自动生成）
6. HY2（模式 3、4）：本机 UDP 端口、对外 UDP 端口或跳跃范围、跳跃处理方式和间隔（仅填范围时询问）、混淆（默认 `gecko`）、SNI（默认 `hy2.local`）
7. 确认摘要，输入 `y` 开始安装

输入不合法时会就地重新提问。

## 端口规则

- **本机端口**：脚本在 VPS 上实际监听的端口。
- **客户端连接端口**：手机连接的端口。
  - 普通 VPS：和本机端口填一样，在系统防火墙或云安全组放行。
  - 商家 NAT：先在商家面板把公网端口映射到本机端口，再把映射后的公网端口填到这一项。

HY2 的端口含义不同：

- **本机 UDP 端口**：本机实际监听的唯一 UDP 端口。
- **对外 UDP 端口或跳跃范围**：手机连接的公网 UDP 端口，可以填单个端口（如 `443`）、范围（如 `30000-30005`）或逗号列表。手机在这些端口之间轮换，最终都落到同一个本机 UDP 端口。
- **跳跃处理方式**（仅填范围时询问）：
  - `1` 本机 nftables：普通公网 VPS 选这个，脚本在本机建转发。
  - `2` 外部 NAT 映射：商家面板已经把端口映射好，脚本不改网络规则。

单端口不需要任何转发：普通 VPS 两个端口填同一个；商家 NAT 则本机端口填本机端口，对外端口填公网端口。

## 安装后

```sh
cat /etc/sing-box/node_output.txt
```

重新登录后直接执行 `shownode` 效果相同。完整客户端配置在 `/etc/sing-box/client.json`，单协议配置为 `client-reality.json` / `client-ss.json` / `client-hy2.json`（按所选模式生成）。这些文件含密码，不要公开。

## 低流量 VPS 对比测试（独立工具）

TcpQuality 广东低流量比较工具已拆分到独立公开仓库：[hytuytujyt/tcpquality-gd-compare](https://github.com/hytuytujyt/tcpquality-gd-compare)。该工具只测广东电信、移动 IPv4 普通/大包回程，以及 VPS → 广东的单线程下载；预算、安装流量、外联、系统依赖、操作流程和注意事项请查看该仓库自己的 README。它与本仓库的 sing-box 安装器是独立项目。

### 快速安装

```sh
curl -fsSL https://raw.githubusercontent.com/hytuytujyt/tcpquality-gd-compare/main/run.sh -o /root/tq-gd.sh
chmod 700 /root/tq-gd.sh
/root/tq-gd.sh baseline
```

后续按该工具 README 指引执行 `tune`、`after` 和 `compare`。

## 关闭 SSH 密码登录（可选，脚本不会自动做）

先执行 `sshkey` 保存私钥，并在另一个窗口确认能用它登录，同时保留当前会话和服务商救援控制台。然后：

```sh
closepwd
```

阅读提示后输入 `CLOSE` 确认。命令会备份 SSH 主配置、关闭 `PasswordAuthentication` 和 `KbdInteractiveAuthentication` 并重启 SSH，失败自动恢复；未启用公钥认证、配置检查失败或检测到 `Match` 规则时拒绝执行。

## 注意事项

- **重跑会覆盖除 Argo 外的入站节点并重新生成凭据**，请使用本次输出的配置。
- HY2 证书自签并内嵌客户端，无需域名或 Cloudflare API；有效期 36 个月，同 SNI 重装会复用，替换下的旧证书留在 `/etc/sing-box/hy2-tls/`。客户端不支持 gecko 混淆时，重跑时选择 `2` salamander 并使用新配置。
- 已装 sing-box 低于 **1.12.0** 会被自动换成最新版（生成的配置使用 1.12 起的 DNS/route 写法）。不想自动升级请先自行升级。
- 已存在的 `/etc/systemd/system/sing-box.service` 会备份为 `sing-box.service.pre-installer`（仅一次）。
- 本机转发需要 nftables、CAP_NET_ADMIN 和 systemd/OpenRC；检测到旧版网络集成状态时脚本会停止并提示人工检查。
- 云安全组需自行放行。不要为安装删除已有网络规则或 SSH 端口映射。
- 修改跳跃范围或跳跃处理方式前先断开客户端，否则旧连接可能沿用旧转发。
- **本机转发的端到端验证尚未完成**（已通过语法、配置生成与规范化回归测试）；SSH 关闭功能也未在 Linux VPS 上实测。请在可救援的机器上先测试。
