# Server Bootstrap

Linux 服务器一键初始化工具包。交互式管理 SSH 用户、密钥、sudo 权限、安全加固及共享工作区。

## 脚本列表

| 脚本 | 功能 | 行数 |
|------|------|------|
| `user-manager.sh` | 用户管理、SSH 密钥、sudo 权限、安全加固 | 1400+ |
| `shared-workspace-setup.sh` | 共享工作区、目录权限、用户组管理 | 660+ |

## 快速开始

```bash
# 克隆仓库
git clone https://github.com/你的用户名/server-bootstrap.git
cd server-bootstrap

# 上传到服务器
scp *.sh root@你的服务器IP:/root/

# 登录服务器后执行
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
├── resources/   资源/素材
└── tmp/         临时文件 (>7天自动清理)
```

### 安全特性

- **不改全局 umask**（v1 的 P0 事故教训）
- 共享权限通过 SGID + ACL 保证，不影响系统其他目录
- 路径字符白名单 + 深度校验 + 遍历攻击防护
- 原子写入、信号捕获、回滚栈

## 典型工作流

```bash
# 1. root 登录，运行用户管理
sudo bash user-manager.sh
# → 创建新用户（SSH 密钥 + NOPASSWD sudo）
# → 退出，用新用户登录验证

# 2. 新用户登录，验证 sudo
sudo whoami  # 应输出 root

# 3. 确认没问题后，运行安全加固
sudo bash user-manager.sh
# → 选 7) SSH 安全加固

# 4. 设置共享工作区
sudo bash shared-workspace-setup.sh
# → 选 1) 初始化
# → 选 2) 管理用户访问
```

## 救急方案

如果加固后锁死了（比如 root 禁了、sudo 也没配好）：

1. 用普通用户登录运行 `bash user-manager.sh`（非 root 自动进入诊断模式）
2. 选 5) 生成 VNC 恢复命令
3. 复制命令到云控制台 VNC 以 root 执行

## License

MIT
