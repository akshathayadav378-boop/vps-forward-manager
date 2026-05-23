## 快速部署

### Debian / Ubuntu

```sh
apt-get update
apt-get install -y curl
cd /root
rm -f install.sh
curl -L -o install.sh https://raw.githubusercontent.com/akshathayadav378-boop/vps-forward-manager/main/install.sh
chmod +x install.sh
cp install.sh /usr/local/bin/vfm
chmod +x /usr/local/bin/vfm
vfm
```

### Alpine

```sh
apk add --no-cache curl
cd /root
rm -f install.sh
curl -L -o install.sh https://raw.githubusercontent.com/akshathayadav378-boop/vps-forward-manager/main/install.sh
chmod +x install.sh
cp install.sh /usr/local/bin/vfm
chmod +x /usr/local/bin/vfm
vfm
```

---

## 快捷命令

首次部署完成后，脚本会被保存为：

```text
/usr/local/bin/vfm
```

之后可以直接输入：

```sh
vfm
```

打开管理菜单，无需每次重新拉取脚本。

如果 GitHub 脚本有更新，可以执行：

```sh
curl -L -o /usr/local/bin/vfm https://raw.githubusercontent.com/akshathayadav378-boop/vps-forward-manager/main/install.sh
chmod +x /usr/local/bin/vfm
vfm
```

---
