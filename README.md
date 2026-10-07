# socksctl

一个轻量的、多配置的 **SOCKS5 over SSH** 管理脚本，底层使用 `autossh` 保持 SSH 动态端口转发长期在线。

它适合这种场景：

- 第一次运行时交互输入 SSH 服务器、用户、私钥、端口。
- 之后再次运行时默认复用上一次使用的配置。
- 可以追加多个出口配置，例如 `sg`、`jp`、`us`。
- 不修改 `~/.ssh/config`。
- 支持同时运行多个 SOCKS5 隧道，只要监听端口不冲突。
- 支持启动、停止、重启、状态查看、出口 IP 测试和日志查看。

## 工作方式

例如原始 SSH 命令：

```bash
ssh -fNT \
  -i ~/ap-southeast \
  -o IdentitiesOnly=yes \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  -D 127.0.0.1:18080 \
  ubuntu@47.130.28.161
```

使用 socksctl 后，第一次只需要：

```bash
socksctl start
```

按提示填写信息，配置会被保存。

之后再次启动：

```bash
socksctl start
```

会直接使用上一次选择的配置，不再重复询问。

---

## 依赖

Debian / Ubuntu：

```bash
sudo apt update
sudo apt install -y autossh curl openssh-client
```

需要 Bash。

---

## 安装

克隆仓库：

```bash
git clone https://github.com/aawai/socksctl.git
cd socksctl
```

安装到系统 PATH：

```bash
sudo install -m 755 socksctl /usr/local/bin/socksctl
```

确认：

```bash
socksctl help
```

---

## 第一次使用

直接运行：

```bash
socksctl start
```

示例：

```text
未找到已有配置。
配置名称 [default]: sg

配置 SOCKS5 SSH 隧道: sg
直接回车保留 [] 中的默认值。

SSH Host: 47.130.28.161
SSH User [ubuntu]:
SSH Port [22]:
Private Key（留空则使用 ssh-agent/默认密钥）: ~/ap-southeast
Bind Address [127.0.0.1]:
SOCKS Port [18080]:
```

启动成功后：

```text
已启动
Profile: sg
SOCKS5:  socks5h://127.0.0.1:18080
```

之后执行：

```bash
socksctl start
```

会默认启动上一次使用的 `sg` 配置。

---

## 多配置

新增一个配置：

```bash
socksctl add jp
```

新配置会自动继承当前配置中的：

- SSH User
- SSH Port
- Private Key
- Bind Address
- SOCKS Port

因此通常只需要修改不同的 SSH Host 和 SOCKS 监听端口。

例如：

```text
sg -> 127.0.0.1:18080 -> Singapore SSH server
jp -> 127.0.0.1:18081 -> Japan SSH server
us -> 127.0.0.1:18082 -> US SSH server
```

多个配置可以同时运行：

```bash
socksctl start sg
socksctl start jp
socksctl start us
```

查看：

```bash
socksctl list
```

示例：

```text
    NAME             STATUS     SOCKS                    SSH
--- ---------------- ---------- ------------------------ ----------------------------
    sg               running    127.0.0.1:18080         ubuntu@47.130.28.161:22
*   jp               running    127.0.0.1:18081         ubuntu@1.2.3.4:22
    us               stopped    127.0.0.1:18082         ubuntu@5.6.7.8:22

* 当前默认配置: jp
```

`*` 表示当前默认配置。

---

## 常用命令

```bash
# 启动上一次使用的配置
socksctl start

# 启动指定配置
socksctl start sg

# 新增配置
socksctl add jp

# 编辑当前配置
socksctl edit

# 编辑指定配置
socksctl edit sg

# 设置默认配置
socksctl use sg

# 查看全部配置
socksctl list

# 查看当前配置状态
socksctl status

# 查看指定配置状态
socksctl status sg

# 查看配置内容
socksctl show sg

# 停止当前配置
socksctl stop

# 停止指定配置
socksctl stop sg

# 停止全部配置
socksctl stop-all

# 重启
socksctl restart sg

# 测试 SOCKS5 出口 IP
socksctl test sg

# 查看实时日志
socksctl logs sg

# 删除配置
socksctl remove sg
```

---

## 测试代理

socksctl 内置出口 IP 测试：

```bash
socksctl test sg
```

也可以手动测试：

```bash
curl \
  --proxy socks5h://127.0.0.1:18080 \
  https://api.ipify.org
```

使用 `socks5h://` 时，域名解析也会通过 SOCKS 代理执行，通常比 `socks5://` 更适合远程代理场景。

---

## 配置文件

配置默认存放在：

```text
~/.config/socksctl/
├── current
└── profiles/
    ├── sg.conf
    ├── jp.conf
    └── us.conf
```

`current` 保存上一次选择的默认配置。

单个 profile 示例：

```bash
HOST=47.130.28.161
USER_NAME=ubuntu
SSH_PORT=22
KEY=/home/user/ap-southeast
BIND=127.0.0.1
PORT=18080
```

配置文件权限会设置为 `600`。

运行状态和日志默认存放在：

```text
~/.local/state/socksctl/
├── sg.pid
├── sg.log
├── jp.pid
└── jp.log
```

如果设置了 `XDG_CONFIG_HOME` 或 `XDG_STATE_HOME`，脚本会遵循相应的 XDG 路径。

---

## 使用 ssh-agent

如果不想在配置里保存私钥路径，可以提前把私钥加入 ssh-agent：

```bash
eval "$(ssh-agent -s)"
ssh-add ~/ap-southeast
```

创建 profile 时，在下面这一项直接留空：

```text
Private Key（留空则使用 ssh-agent/默认密钥）:
```

socksctl 会让 OpenSSH 使用 ssh-agent 或默认 SSH 密钥。

---

## autossh 保活参数

脚本默认使用：

```text
ServerAliveInterval=30
ServerAliveCountMax=3
TCPKeepAlive=yes
ExitOnForwardFailure=yes
ConnectTimeout=10
```

并通过：

```text
autossh -M 0
```

使用 OpenSSH 的 ServerAlive 机制检测连接异常。SSH 连接退出后，autossh 会自动重新建立隧道。

---

## 监听地址

默认：

```text
127.0.0.1:18080
```

这意味着只有本机可以连接 SOCKS5 代理。

如果需要让 Docker 容器通过宿主机访问 SOCKS，例如 Docker bridge 网关为 `172.30.0.1`，可以将 Bind Address 设置为：

```text
172.30.0.1
```

然后容器可使用：

```text
socks5h://172.30.0.1:18080
```

不建议无必要地绑定：

```text
0.0.0.0
```

因为这可能让 SOCKS5 端口暴露给其他网络设备。SOCKS5 本身没有由本脚本提供额外认证机制。

---

## 多代理同时运行

不同 profile 同时运行时必须使用不同的监听地址或端口。

正确：

```text
sg  127.0.0.1:18080
jp  127.0.0.1:18081
us  127.0.0.1:18082
```

错误：

```text
sg  127.0.0.1:18080
jp  127.0.0.1:18080
```

第二个进程会因为端口已被占用而启动失败。

---

## 查看实际监听

可以使用：

```bash
ss -lntp | grep 18080
```

例如：

```text
LISTEN 0 128 127.0.0.1:18080 0.0.0.0:* users:(("ssh",pid=12345,fd=4))
```

---

## 安全说明

- 私钥文件本身不会被复制到 socksctl 配置目录。
- profile 只保存私钥路径。
- profile 文件权限为 `600`。
- 默认只监听 `127.0.0.1`。
- 请谨慎使用 `0.0.0.0` 作为 Bind Address。
- 不要把私钥、密码或其他敏感内容提交到 Git 仓库。
- 建议 SSH 服务器使用密钥认证并关闭密码登录。

---

## 卸载

删除程序：

```bash
sudo rm -f /usr/local/bin/socksctl
```

如果同时需要删除所有本地配置和状态：

```bash
rm -rf ~/.config/socksctl
rm -rf ~/.local/state/socksctl
```

注意：这会删除所有 profile 和日志。

---

## License

目前仓库未附加许可证。
