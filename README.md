# REALITY / Shadowsocks / HY2 一键安装

sing-box 节点安装脚本，root 交互式执行，取消则不做任何修改。

```sh
curl -fsSL https://raw.githubusercontent.com/hytuytujyt/vps-network-tools/main/install_reality.sh -o /tmp/install_reality.sh
sh /tmp/install_reality.sh
```

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

`shownode` 按当前服务端配置列出可以导出的 VLESS、Shadowsocks、HY2 出站片段。

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

阅读提示后输入大写的 `CLOSE` 确认。命令会备份 SSH 主配置、关闭 `PasswordAuthentication` 和 `KbdInteractiveAuthentication` 并重启 SSH，失败自动恢复；未启用公钥认证、配置检查失败或检测到 `Match` 规则时拒绝执行。

## 注意事项

- 客户端不支持 gecko 混淆时，重跑时选择 `2` salamander 并使用新配置。
- 默认最低核心版本为 **1.12.0**；HY2 需要支持 QUIC 的核心，选择 Gecko 时最低版本升为 **1.14.0**。
- 每次重装前会备份服务端配置为 `config.json.bak.*`（含全部节点凭据，权限 600），只保留最近 3 份。
- 云安全组需自行放行。
