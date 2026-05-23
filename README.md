VPS转发管理器

VPS Forward Manager 是一款 Linux VPS 端口转发一键管理脚本，支持通过 `realm` 和 `nftables` 创建、查看、删除端口转发规则。

适合用于：

- VPS 端口中转
- TCP / UDP 转发
- 动态域名转发
- 固定 IPv4 内核级转发
- 多条转发规则管理

项目地址：

https://github.com/akshathayadav378-boop/vps-forward-manager

---

## 功能特点

- 中文交互菜单
- 支持 Debian / Ubuntu / Alpine
- 支持 `realm` 用户态转发
- 支持 `nftables` 内核级转发
- 支持 TCP 转发
- 支持 UDP 转发
- 支持 TCP + UDP 转发
- 支持追加多条规则
- 支持按编号查看全部规则
- 支持按编号查看单条规则
- 支持按编号删除单条规则
- 支持删除全部规则
- 支持卸载脚本安装的全部内容
- `realm` 模式支持域名 / IP / IPv6
- `realm` 模式支持 DNS 自动刷新
- `nftables` 模式支持固定 IPv4 内核级转发

---

## 支持系统

目前支持：

- Debian
- Ubuntu
- Alpine

暂不支持：

- CentOS
- Fedora
- Arch Linux
- OpenWrt

- ## 快速部署

### Debian / Ubuntu

```sh
apt-get update
apt-get install -y curl
cd /root
rm -f install.sh
curl -L -o install.sh https://raw.githubusercontent.com/akshathayadav378-boop/vps-forward-manager/main/install.sh
chmod +x install.sh
./install.sh
```

### Alpine

```sh
apk add --no-cache curl
cd /root
rm -f install.sh
curl -L -o install.sh https://raw.githubusercontent.com/akshathayadav378-boop/vps-forward-manager/main/install.sh
chmod +x install.sh
./install.sh
```

---


