# REALITY / Shadowsocks / HY2 一键安装

sing-box 节点安装脚本，root 交互式执行。结束时终端打印的内容就是客户端配置。

```sh
curl -fsSL https://raw.githubusercontent.com/hytuytujyt/vps-network-tools/main/install_reality.sh -o /tmp/install_reality.sh
sh /tmp/install_reality.sh
```

脚本会依次询问配置，回车使用方括号里的默认值。最后显示配置摘要，确认后才开始安装；取消则不做任何修改。脚本需要在终端中运行。

## 端口规则

HY2 端口：

- **本机 UDP 端口**：本机实际监听的唯一 UDP 端口。
- **对外 UDP 端口或跳跃范围**：手机连接的公网 UDP 端口，可以填单个端口（如 `443`）、范围（如 `30000-30005`）或逗号列表。手机在这些端口之间轮换，最终都落到同一个本机 UDP 端口。
- **跳跃处理方式**（仅填范围时询问）：
  - `1` 本机 nftables：普通公网 VPS 选这个，脚本在本机建转发。
  - `2` 外部 NAT 映射：商家面板已经把端口映射好，脚本不改网络规则。

单端口不需要任何转发：普通 VPS 两个端口填同一个；商家 NAT 则本机端口填本机端口，对外端口填公网端口。

## 安装后

```sh
shownode
```

`shownode` 按当前服务端配置列出可以导出的 VLESS、Shadowsocks、HY2 出站片段。若当前终端仍使用旧别名，重新登录，或直接执行 `/usr/local/bin/shownode`。

旧节点的公网地址和映射端口不一定能从服务端配置恢复。`shownode` 会复用能匹配的旧客户端配置；缺少资料时在 stderr 提示，不猜地址或端口。若已经有可用的客户端 JSON，可以绑定到当前入站：

```sh
shownode --import reality-in /root/old-client.json
# 同类型出站有多个时，在文件路径后加客户端的出站 tag：
shownode --import argo-in /root/old-client.json 'Argo 节点名'
```

`/etc/sing-box/node_output.txt` 和 `client.json` 仍是最近一次安装的输出及客户端配置。`client-reality.json` / `client-ss.json` / `client-hy2.json` 只更新本次所选协议的文件。导出包含客户端连接凭据，请勿公开。

### HY2 安装检查

诊断路径会打印在终端，默认在 `/etc/sing-box/install-diagnostics.*`。

本机协议自检默认关闭，需要时在运行前加环境变量：

```sh
SELF_CHECK=1 sh /tmp/install_reality.sh
```

## Let's Encrypt 证书（HY2，推荐）

证书方式选 `2` 后，脚本用 [acme.sh](https://github.com/acmesh-official/acme.sh) 通过 Cloudflare DNS 验证自动签发，不占用 80 端口，域名也不需要解析到本机。你只需要准备：

- 一个托管在 Cloudflare 的真实域名，填作 SNI（如 `hy2.example.com`）。
- 一个 Cloudflare API 令牌，权限为 `Zone:DNS:Edit` 和 `Zone:Zone:Read`，范围限定到该域名所在的 Zone。

脚本会自动完成：安装 acme.sh、签发 ECC 证书、安装到 `/etc/sing-box/le/<域名>/`（`fullchain.pem` 和 `privkey.pem`）、配置自动续期，续期后自动重启 sing-box。客户端使用系统根证书校验，不再内嵌证书。

- acme.sh 是纯 shell 程序，只依赖 curl 和 openssl，内存占用只有几 MB，适合 128MB 这类小内存 NAT 机器。
- 续期：systemd 系统用 `sing-box-acme-renew.timer`，Alpine 用 `/etc/periodic/daily/acme-renew`（脚本会确保 crond 已启动并开机自启）。
- 令牌保存在 `/root/.secrets/cloudflare.ini` 和 acme.sh 自己的账户文件里，权限均为仅 root 可读。不再需要时请自行删除并在 Cloudflare 撤销令牌。
- 默认从 acme.sh 的 `master` 分支下载。需要固定版本时，运行前设置 `ACME_SH_URL` 指向指定版本的源码压缩包。
- 签发失败时先确认令牌权限、域名确实在该 Cloudflare 账户下，再重跑脚本。

## 关闭 SSH 密码登录（可选，脚本不会自动做）

先执行 `sshkey` 保存私钥，并在另一个窗口确认能用它登录，同时保留当前会话和服务商救援控制台。然后：

```sh
closepwd
```

阅读提示后输入 `CLOSE` 确认。命令会备份 SSH 主配置、关闭 `PasswordAuthentication` 和 `KbdInteractiveAuthentication` 并重启 SSH，失败自动恢复；未启用公钥认证、配置检查失败或检测到 `Match` 规则时拒绝执行。

## 注意事项

- **只替换本次所选协议中标签完全相同的入站；找不到同名标签就追加。** 服务端 `/etc/sing-box/config.json` 的 `inbounds` 标签分别是 VLESS/REALITY `hytvless`、Shadowsocks `hytss`、HY2 `hythy2`，不是客户端显示名。例如模式 `3` 只替换 `hythy2`，不会修改 `hytvless`、`hytss`、`argo-in` 或其他入站；模式 `4` 同时处理 `hytvless` 和 `hythy2`。本次重装的节点会重新生成凭据；保留的节点凭据不变，但重启 sing-box 会短暂中断现有连接。
- 旧版标签（如 `reality-in`、`ss-in`、`hy2-in`）不会被自动删除或改名。若要让新版接管对应节点，请先备份并手动迁移入站标签以及自定义配置中对该标签的引用；否则新旧节点需要使用不冲突的监听地址和端口。
- HY2 默认使用自签证书并内嵌客户端，无需域名或 Cloudflare API；有效期 36 个月，同 SNI 重装会复用，替换下的旧证书留在 `/etc/sing-box/hy2-tls/`。需要受信任证书时选 Let's Encrypt，见上文。客户端不支持 gecko 混淆时，重跑时选择 `2` salamander 并使用新配置。
- 默认最低核心版本为 **1.12.0**；HY2 需要支持 QUIC 的核心，选择 Gecko 时最低版本升为 **1.14.0**。没有核心或版本过低时先暂存最新稳定版；用选中的核心检查服务端和客户端配置，通过后才替换正式核心、应用网络规则和重启服务。已有核心通过版本门槛但不支持所选功能时，脚本报错停止，不会替换核心。预检不验证公网连通性或端口跳跃。
- 查询核心最新版本时优先用 GitHub Releases API，失败时改从公开发布页的最终跳转地址读取稳定版本号，无需 token。
- 已存在的 `/etc/systemd/system/sing-box.service` 会备份为 `sing-box.service.pre-installer`（仅一次）。
- 每次重装前会备份服务端配置为 `config.json.bak.*`（含全部节点凭据，权限 600），只保留最近 3 份。
- 本机转发需要 nftables、CAP_NET_ADMIN 和 systemd/OpenRC；检测到旧版网络集成状态时脚本会停止并提示人工检查。
- 云安全组需自行放行。不要为安装删除已有网络规则或 SSH 端口映射。
- 修改跳跃范围或跳跃处理方式前先断开客户端，否则旧连接可能沿用旧转发。
- **本机转发的端到端验证尚未完成**（已通过语法、配置生成与规范化回归测试）；SSH 关闭功能也未在 Linux VPS 上实测。请在可救援的机器上先测试。
- **acme.sh 证书流程尚未在真机上端到端验证**（改自原 certbot 流程，修改时未在 Linux 环境做过语法检查或实际运行）。请先在可重装的机器上试一次；NAT 机器选 HY2 跳跃时请选“外部 NAT 映射”。
