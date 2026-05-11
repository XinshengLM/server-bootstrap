# Server Bootstrap

Linux 服务器一键初始化工具包。交互式管理 SSH 用户、密钥、sudo 权限、安全加固、共享工作区及常用软件安装。

## 脚本列表

| 脚本                        | 功能                                     | 行数  |
| --------------------------- | ---------------------------------------- | ----- |
| `user-manager.sh`           | 用户管理、SSH 密钥、sudo 权限、安全加固  | 1400+ |
| `shared-workspace-setup.sh` | 共享工作区、目录权限、用户组管理         | 660+  |
| `package-install.sh`        | 常用软件一键安装（15 个软件 + 全部安装） | 1163+ |

## 快速开始

```bash
# 1. 克隆或下载脚本
git clone https://github.com/XinshengLM/server-bootstrap.git
cd server-bootstrap

# 2. 上传到服务器
scp *.sh root@你的服务器IP:/root/

# 3. 登录服务器后执行
ssh root@你的服务器IP
chmod +x *.sh
```

## user-manager.sh — 用户与 SSH 管理

```bash
# root 模式：完整管理功能
sudo bash user-manager.sh

# 非 root 模式：诊断 + 生成 VNC 恢复命令（救急用）
bash user-manager.sh
```

### 功能

- 👤 创建用户（SSH 密钥 / 密码认证，NOPASSWD sudo）
- 🗑️ 删除用户（自动备份 home 目录）
- 📋 列出所有用户（UID、Shell、Sudo 状态）
- 🔑 管理 SSH 密钥（导入 / 粘贴 / 生成密钥对）
- 🔒 锁定/解锁用户
- ✏️ 修改用户信息（Shell、密码、sudo、附加组）
- 🛡️ SSH 安全加固（禁 root、禁密码、改端口）
- 🔍 诊断模式（非 root 可用，查看状态、生成 VNC 恢复命令）

### 安全特性

- **信号捕获 + 回滚栈**：Ctrl+C 中断时自动回滚未完成的操作
- **原子写入**：所有关键文件操作（sudoers、authorized_keys、sshd_config）通过临时文件 + mv 保证原子性
- **安全网检查**：加固前自动检查是否还有可登录的入口，三条全断则拒绝执行
- **NOPASSWD sudo 默认**：密钥认证用户默认免密 sudo，不会出现"没密码但 sudo 要密码"的死锁
- **sudoers 语法检查**：写入前 `visudo -c` 校验，失败自动回滚
- **输入校验**：用户名、组名、路径全部正则校验，防注入
- **禁止删除/锁定 root 和当前用户**

## shared-workspace-setup.sh — 共享工作区

```bash
sudo bash shared-workspace-setup.sh
```

### 目录结构

```
/home/workspace/
├── projects/    项目文件
├── documents/   文档资料
├── scripts/     脚本工具
├── backup/      备份
├── resources/   资源/素材（安装包、镜像、大文件）
└── tmp/         临时文件 (>7天自动清理)
```

### 安全特性

- **不改全局 umask**（v1 的 P0 事故教训）
- 共享权限通过 SGID + ACL 保证，不影响系统其他目录
- 路径字符白名单 + 深度校验 + 遍历攻击防护
- 原子写入、信号捕获、回滚栈

## package-install.sh — 常用软件一键安装

```bash
sudo bash package-install.sh
```

### 支持软件

| #   | 软件     | 版本    | 功能                                  | 安全防护 |
| --- | -------- | ------- | ------------------------------------- | -------- |
| 1   | Node.js  | 24.15.0 | 支持多版本（自动检测架构 x64/arm64）  |          |
| 2   | Python   | 3.12    | 自动检测发行版（apt/yum/apk/pacman）  |          |
| 3   | Docker   | 最新    | 官方安装脚本 + systemd 服务 + Compose |          |
| 4   | MySQL    | 8.0     | 自动添加 APT 仓库 + systemd 服务启动  |          |
| 5   | 1Panel   | 最新    | 官方安装脚本                          |          |
| 6   | Nginx    | 1.24    | 官方 PPA / EPEL 支持                  |          |
| 7   | 7-Zip    | 24.05   | 自动检测发行版安装                    |          |
| 8   | jq       | 最新    | JSON 处理工具                         |          |
| 9   | fd       | 9.0.0   | 快速查找工具（比 find 快 10 倍）      |          |
| 10  | bat      | 最新    | cat 替代（语法高亮、行号、自动分页）  |          |
| 11  | Fail2Ban | 最新    | SSH 暴力破解防护（自动封禁 IP）       | ✅       |
| 12  | UFW      | 最新    | 防火墙管理（iptables 前端）           | ✅       |
| 13  | Maldet   | 最新    | 挖矿/勒索病毒扫描（检测加密文件）     | ✅       |
| 14  | htop     | 最新    | 交互式进程监控（top 的替代）          | ✅       |

### 安全特性

- **信号捕获 + 回滚栈**：中断时自动清理已下载的安装包
- **版本管理**：升级失败时自动回滚到旧版本
- **环境变量设置**：Node.js 安装后自动更新 PATH
- **发行版自动检测**：apt/yum/apk/pacman/dnf 适配
- **依赖冲突处理**：安装失败时自动回滚

### 一键全部安装

选项 `15) 一键全部安装` 会自动依次安装：

1. Node.js 24.15.0
2. Python 3.12
3. Docker & Compose
4. MySQL 8.0
5. 1Panel
6. Nginx 1.24
7. 7-Zip 24.05
8. jq
9. fd
10. bat
11. Fail2Ban
12. UFW

## 推荐工作流

```bash
# 1. root 登录，运行软件安装
sudo bash package-install.sh
# → 选 13) 安装 Maldet（挖矿/勒索扫描）
# → 选 14) 安装 htop（进程监控）
# → 选 1) 安装 Node.js
# → 选 3) 安装 Docker

# 2. 配置用户
sudo bash user-manager.sh
# → 创建新用户（SSH 密钥 + NOPASSWD sudo）
# → 用新用户登录测试

# 3. 安全加固
sudo bash user-manager.sh
# → 选 7) SSH 安全加固
# → 禁 root SSH 登录
# → 禁用密码登录
# → 修改 SSH 端口

# 4. 安装 Fail2Ban（如果 package-install.sh 没装）
sudo bash package-install.sh
# → 选 11) 安装 Fail2Ban
# → 重启 SSH 服务
# → 自动封禁暴力破解 IP

# 5. 设置共享工作区
sudo bash shared-workspace-setup.sh
# → 选 1) 初始化
# → 选 2) 添加用户到共享组
```

## 救急方案

如果加固后锁死了（比如 root 禁了、sudo 也没配好）：

1. 用普通用户登录运行 `bash user-manager.sh`（非 root 自动进入诊断模式）
2. 选 5) 生成 VNC 恢复命令
3. 复制命令到云控制台 VNC 以 root 执行

## 更新日志

### v1.2 (2026-05-12)

- 新增 `package-install.sh` v1.2（15 个常用软件 + 全部安装）
- 新增安全防护工具：Maldet（挖矿/勒索扫描）、htop（进程监控）
- 新增一键全部安装功能
- 更新 `README.md`，添加完整软件列表和使用流程
