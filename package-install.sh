#!/usr/bin/env bash
# ============================================================
#  常用软件一键安装脚本 (Package Installer) v1.2
#  功能：Node.js, Python, Docker, MySQL, 1Panel, Nginx, 7z, jq, fd, bat, fail2ban, ufw, Maldet, htop
#  特性：信号捕获 + 原子写入 + 中断回滚 + 版本管理
#  用法：sudo bash package-install.sh
# ============================================================

set -euo pipefail

# ---------- 颜色 ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }

press_any_key() {
    echo ""
    read -n 1 -s -r -p "按任意键返回主菜单..."
    echo ""
}

# ============================================================
#  中断保护
# ============================================================
declare -ga _PKG_ROLLBACK=()

pkg_rollback_push() {
    _PKG_ROLLBACK+=("$*")
}

pkg_rollback_clear() {
    _PKG_ROLLBACK=()
}

pkg_rollback_execute() {
    if [[ ${#_PKG_ROLLBACK[@]} -eq 0 ]]; then return 0; fi
    echo ""
    error "=== 正在回滚已安装的软件 ==="
    local count=${#_PKG_ROLLBACK[@]}
    for (( i=count-1; i>=0; i-- )); do
        echo -e "  ${YELLOW}回滚: ${_PKG_ROLLBACK[$i]}${NC}"
        eval "${_PKG_ROLLBACK[$i]}" 2>/dev/null || true
    done
    error "=== 回滚完成 ==="
    _PKG_ROLLBACK=()
}

pkg_handle_interrupt() {
    local sig="${1:-}"
    if [[ "$sig" == "EXIT" ]]; then
        if [[ ${#_PKG_ROLLBACK[@]} -gt 0 ]]; then
            pkg_rollback_execute
        fi
        return 0
    fi

    echo ""
    error "!!! 检测到中断信号 !!!"
    if [[ ${#_PKG_ROLLBACK[@]} -gt 0 ]]; then
        echo -e "  ${RED}选项：${NC}"
        echo "  1) 回滚 (推荐)"
        echo "  2) 保留"
        read -t 10 -rp "请选择 [1-2, 默认 1]: " ic 2>/dev/null || true
        ic="${ic:-1}"
        [[ "$ic" == "1" ]] && pkg_rollback_execute
    fi
    echo "按 Enter 返回..."
}

trap 'pkg_handle_interrupt SIGINT' SIGINT
trap 'pkg_handle_interrupt SIGTERM' SIGTERM
trap 'pkg_handle_interrupt SIGHUP' SIGHUP
trap 'pkg_handle_interrupt EXIT' EXIT

# ---------- 前置检查 ----------
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "此脚本需要 root 权限运行。请使用: sudo bash $0"
        exit 1
    fi
}

# 系统信息
OS=""
KERNEL=""
if [[ -f /etc/os-release ]]; then
    OS=$(grep ^ID= /etc/os-release | cut -d= -f2 | tr -d '"')
fi
KERNEL=$(uname -r)

# ============================================================
#  1. Node.js 安装
# ============================================================
install_node() {
    local node_version="$1"
    local installed_version=""

    echo ""
    echo -e "${BOLD}========== Node.js 安装 ==========${NC}"
    echo "  目标版本: $node_version"

    # 检查是否已安装
    if command -v node &>/dev/null; then
        installed_version=$(node -v 2>/dev/null | cut -d' ' -f1)
        if [[ "$installed_version" == "$node_version" ]]; then
            warn "Node.js $node_version 已安装"
            read -rp "是否覆盖安装? [y/N]: " reinstall
            [[ ! "$reinstall" =~ ^[Yy] ]] && return 0
        else
            info "当前版本: $installed_version，目标版本: $node_version，将升级"
        fi
    fi

    info "正在下载 Node.js $node_version 二进制..."

    local arch=$(uname -m)
    case "$arch" in
        x86_64) arch="x64" ;;
        aarch64) arch="arm64" ;;
        armv7l) arch="armv7l" ;;
        *) error "不支持的架构: $arch"; return 1 ;;
    esac

    local download_url="https://nodejs.org/dist/v${node_version%.*}/node-v${node_version}-linux-${arch}.tar.xz"
    local tarfile="/tmp/node-v${node_version}.tar.xz"

    # 下载
    if ! curl -fsSL "$download_url" -o "$tarfile"; then
        error "Node.js 下载失败，请检查网络或手动下载"
        return 1
    fi
    pkg_rollback_push "rm -f $tarfile"

    # 解压
    if ! tar -xf "$tarfile" -C /usr/local/ --strip-components=1; then
        error "Node.js 解压失败"
        pkg_rollback_execute
        return 1
    fi

    # 清理
    rm -f "$tarfile"

    # 验证
    if ! command -v node &>/dev/null; then
        error "Node.js 安装验证失败"
        pkg_rollback_execute
        return 1
    fi

    # 设置环境变量（如果不存在）
    if ! grep -q "node-v${node_version%.*}/bin" /etc/profile.d/nodejs.sh 2>/dev/null; then
        echo "export PATH=/usr/local/node-v${node_version%.*}/bin:\$PATH" > /etc/profile.d/nodejs.sh
        pkg_rollback_push "rm -f /etc/profile.d/nodejs.sh"
        source /etc/profile.d/nodejs.sh
    fi

    success "Node.js $node_version 安装完成"
    node -v
    echo ""
}

# ============================================================
#  2. Python 安装
# ============================================================
install_python() {
    local python_version="$1"
    echo ""
    echo -e "${BOLD}========== Python 安装 ==========${NC}"
    echo "  目标版本: $python_version"

    # 检查是否已安装
    if command -v python3 &>/dev/null; then
        local installed_version
        installed_version=$(python3 -V 2>&1 | cut -d' ' -f2 | cut -d. -f1)
        if [[ "$installed_version" == "$python_version" ]]; then
            warn "Python $python_version 已安装"
            read -rp "是否重新安装? [y/N]: " reinstall
            [[ ! "$reinstall" =~ ^[Yy] ]] && return 0
        else
            info "当前版本: $installed_version，目标版本: $python_version"
        fi
    fi

    # 检测发行版
    local pkg_manager=""
    if [[ -f /etc/debian_version ]] || [[ -f /etc/lsb-release ]]; then
        pkg_manager="apt"
    elif [[ -f /etc/redhat-release ]] || [[ -f /etc/centos-release ]]; then
        pkg_manager="yum"
    elif [[ -f /etc/alpine-release ]]; then
        pkg_manager="apk"
    elif [[ -f /etc/arch-release ]]; then
        pkg_manager="pacman"
    else
        error "无法检测发行版，请手动安装 Python"
        return 1
    fi

    info "检测到包管理器: $pkg_manager"

    case "$pkg_manager" in
        apt)
            # 更新源
            info "更新 APT 源..."
            if ! apt-get update -qq; then
                error "APT 更新失败"
                return 1
            fi

            # 添加 deadsnakes PPA（多版本 Python）
            if ! grep -q "deadsnakes" /etc/apt/sources.list.d/*.list 2>/dev/null; then
                info "添加 deadsnakes PPA..."
                apt-get install -y software-properties-common
                add-apt-repository ppa:deadsnakes/ppa -y
            fi

            info "正在安装 Python $python_version..."
            apt-get install -y python$python_version python$python_version-venv python$python_version-dev
            pkg_rollback_push "apt-get remove -y python$python_version"
            ;;

        yum)
            # CentOS 8+ 使用 dnf
            if command -v dnf &>/dev/null; then
                info "DNF 模式，安装 Python $python_version..."
                dnf install -y python$python_version python$python_version-pip python$python_version-devel
                pkg_rollback_push "dnf remove -y python$python_version"
            else
                info "YUM 模式，安装 Python $python_version..."
                yum install -y python$python_version python$python_version-pip python$python_version-devel
                pkg_rollback_push "yum remove -y python$python_version"
            fi
            ;;

        apk)
            info "Alpine 模式，安装 Python $python_version..."
            apk add python$python_version py$python_version-pip
            pkg_rollback_push "apk del python$python_version"
            ;;

        pacman)
            info "Arch 模式，安装 Python $python_version..."
            pacman -S --noconfirm python$python_version python-pip
            pkg_rollback_push "pacman -Rns --noconfirm python$python_version"
            ;;
    esac

    # 验证
    if ! python"$python_version" -V &>/dev/null; then
        error "Python 安装验证失败"
        pkg_rollback_execute
        return 1
    fi

    success "Python $python_version 安装完成"
    python"$python_version" -V
    echo ""
}

# ============================================================
#  3. Docker 安装
# ============================================================
install_docker() {
    echo ""
    echo -e "${BOLD}========== Docker 安装 ==========${NC}"

    # 检查是否已安装
    if command -v docker &>/dev/null; then
        warn "Docker 已安装: $(docker --version)"
        read -rp "是否重新安装? [y/N]: " reinstall
        [[ ! "$reinstall" =~ ^[Yy] ]] && return 0
    fi

    info "正在下载 Docker 安装脚本..."

    local script_url="https://get.docker.com"
    local install_script="/tmp/get-docker.sh"

    # 下载安装脚本
    if ! curl -fsSL "$script_url" -o "$install_script"; then
        error "Docker 安装脚本下载失败"
        return 1
    fi
    chmod +x "$install_script"

    # 执行安装
    info "正在执行 Docker 安装..."
    sh "$install_script"
    rm -f "$install_script"

    # 启动服务
    info "启动 Docker 服务..."
    if command -v systemctl &>/dev/null; then
        systemctl start docker
        systemctl enable docker
    elif command -v service &>/dev/null; then
        service docker start
    fi

    # 安装 Docker Compose
    info "正在安装 Docker Compose..."
    local compose_url="https://github.com/docker/compose/releases/download/v2.25.0/docker-compose-linux-x86_64"
    local compose_bin="/usr/local/bin/docker-compose"
    if [[ ! -f "$compose_bin" ]]; then
        curl -fsSL "$compose_url" -o "$compose_bin"
        chmod +x "$compose_bin"
    fi

    # 验证
    if ! docker --version &>/dev/null; then
        error "Docker 安装验证失败"
        return 1
    fi

    success "Docker 和 Docker Compose 安装完成"
    docker --version
    docker-compose --version
    echo ""
}

# ============================================================
#  4. MySQL 安装
# ============================================================
install_mysql() {
    local mysql_version="8.0"
    echo ""
    echo -e "${BOLD}========== MySQL 安装 ==========${NC}"
    echo "  目标版本: MySQL $mysql_version"

    # 检查是否已安装
    if command -v mysql &>/dev/null; then
        warn "MySQL 已安装"
        read -rp "是否重新安装? [y/N]: " reinstall
        [[ ! "$reinstall" =~ ^[Yy] ]] && return 0
    fi

    # 检测发行版
    local pkg_manager=""
    if [[ -f /etc/debian_version ]] || [[ -f /etc/lsb-release ]]; then
        pkg_manager="apt"
    elif [[ -f /etc/redhat-release ]] || [[ -f /etc/centos-release ]]; then
        pkg_manager="yum"
    else
        error "无法检测发行版，请手动安装 MySQL"
        return 1
    fi

    # 添加 MySQL APT 仓库（如果是 Debian/Ubuntu）
    if [[ "$pkg_manager" == "apt" ]]; then
        info "配置 MySQL APT 仓库..."
        apt-get install -y software-properties-common
        if ! grep -q "mysql-apt-config" /etc/apt/sources.list.d/*.list 2>/dev/null; then
            wget -qO - https://repo.mysql.com/apt/mysql-apt-config_0.8.0-1_all.deb
            dpkg -i mysql-apt-config_0.8.0-1_all.deb
            apt-get update
        fi
    fi

    # 安装 MySQL Server
    info "正在安装 MySQL Server..."
    if [[ "$pkg_manager" == "apt" ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y mysql-server
    else
        yum install -y mysql-server
    fi

    # 启动服务
    info "启动 MySQL 服务..."
    if command -v systemctl &>/dev/null; then
        systemctl start mysql
        systemctl enable mysql
    elif command -v service &>/dev/null; then
        service mysql start
    fi

    # 验证
    if ! mysql --version &>/dev/null; then
        error "MySQL 安装验证失败"
        return 1
    fi

    success "MySQL 安装完成"
    mysql --version
    echo ""
    echo -e "${YELLOW}配置提示：${NC}"
    echo "  root 密码: 查看日志或使用 'mysql -u root -p' 登录"
    echo "  配置文件: /etc/mysql/mysql.conf.d/"
    echo ""
}

# ============================================================
#  5. 1Panel 安装
# ============================================================
install_1panel() {
    echo ""
    echo -e "${BOLD}========== 1Panel 安装 ==========${NC}"

    # 检查是否已安装
    if command -v 1panel &>/dev/null; then
        warn "1Panel 已安装"
        read -rp "是否重新安装? [y/N]: " reinstall
        [[ ! "$reinstall" =~ ^[Yy] ]] && return 0
    fi

    info "正在下载 1Panel 安装脚本..."

    # 获取最新安装脚本
    if ! curl -fsSL https://resource.fit/panel/install_panel.sh -o /tmp/1panel_install.sh; then
        error "1Panel 安装脚本下载失败"
        return 1
    fi
    chmod +x /tmp/1panel_install.sh

    # 执行安装
    info "正在执行 1Panel 安装..."
    bash /tmp/1panel_install.sh

    # 清理
    rm -f /tmp/1panel_install.sh

    # 验证
    if ! command -v 1panel &>/dev/null; then
        error "1Panel 安装验证失败"
        return 1
    fi

    success "1Panel 安装完成"
    echo ""
    echo -e "${YELLOW}管理命令：${NC}"
    echo "  1pctl: 命令行管理工具"
    echo "  登录地址: https://IP:8888"
    echo ""
}

# ============================================================
#  6. Nginx 安装
# ============================================================
install_nginx() {
    local nginx_version="1.24"
    echo ""
    echo -e "${BOLD}========== Nginx 安装 ==========${NC}"
    echo "  目标版本: Nginx $nginx_version"

    # 检查是否已安装
    if command -v nginx &>/dev/null; then
        warn "Nginx 已安装: $(nginx -v 2>&1 | cut -d/ -f1)"
        read -rp "是否重新安装? [y/N]: " reinstall
        [[ ! "$reinstall" =~ ^[Yy] ]] && return 0
    fi

    # 检测发行版
    local pkg_manager=""
    if [[ -f /etc/debian_version ]] || [[ -f /etc/lsb-release ]]; then
        pkg_manager="apt"
    elif [[ -f /etc/redhat-release ]] || [[ -f /etc/centos-release ]]; then
        pkg_manager="yum"
    elif [[ -f /etc/alpine-release ]]; then
        pkg_manager="apk"
    elif [[ -f /etc/arch-release ]]; then
        pkg_manager="pacman"
    else
        error "无法检测发行版，请手动安装 Nginx"
        return 1
    fi

    info "检测到包管理器: $pkg_manager"

    # 安装
    if [[ "$pkg_manager" == "apt" ]]; then
        info "添加 Nginx 官方 PPA..."
        apt-get install -y software-properties-common
        add-apt-repository ppa:ondrej/nginx-nginx-$nginx_version -y
        apt-get update
        info "正在安装 Nginx $nginx_version..."
        apt-get install -y nginx
    elif [[ "$pkg_manager" == "yum" ]]; then
        info "正在安装 Nginx..."
        yum install -y nginx
    elif [[ "$pkg_manager" == "apk" ]]; then
        info "正在安装 Nginx..."
        apk add nginx
    elif [[ "$pkg_manager" == "pacman" ]]; then
        info "正在安装 Nginx..."
        pacman -S --noconfirm nginx
    fi

    # 启动服务
    info "启动 Nginx 服务..."
    if command -v systemctl &>/dev/null; then
        systemctl start nginx
        systemctl enable nginx
    elif command -v service &>/dev/null; then
        service nginx start
    fi

    # 验证
    if ! nginx -v &>/dev/null; then
        error "Nginx 安装验证失败"
        return 1
    fi

    success "Nginx 安装完成"
    nginx -v
    echo ""
    echo -e "${YELLOW}默认配置：${NC}"
    echo "  站点目录: /var/www/html"
    echo "  配置文件: /etc/nginx/nginx.conf"
    echo ""
}

# ============================================================
#  7. 7z 安装
# ============================================================
install_7z() {
    local p7zip_version="24.05"
    echo ""
    echo -e "${BOLD}========== 7-Zip 安装 ==========${NC}"
    echo "  目标版本: $p7zip_version"

    # 检查是否已安装
    if command -v 7z &>/dev/null; then
        warn "7-Zip 已安装: $(7z --version)"
        read -rp "是否重新安装? [y/N]: " reinstall
        [[ ! "$reinstall" =~ ^[Yy] ]] && return 0
    fi

    # 检测发行版
    local pkg_manager=""
    if [[ -f /etc/debian_version ]] || [[ -f /etc/lsb-release ]]; then
        pkg_manager="apt"
    elif [[ -f /etc/redhat-release ]] || [[ -f /etc/centos-release ]]; then
        pkg_manager="yum"
    elif [[ -f /etc/alpine-release ]]; then
        pkg_manager="apk"
    elif [[ -f /etc/arch-release ]]; then
        pkg_manager="pacman"
    else
        error "无法检测发行版，请手动安装 7-Zip"
        return 1
    fi

    info "检测到包管理器: $pkg_manager"

    # 安装
    case "$pkg_manager" in
        apt)
            info "正在安装 7-Zip..."
            DEBIAN_FRONTEND=noninteractive apt-get install -y p7zip-full
            ;;
        yum)
            info "正在安装 7-Zip..."
            yum install -y p7zip p7zip-plugins
            ;;
        apk)
            info "正在安装 7-Zip..."
            apk add p7zip
            ;;
        pacman)
            info "正在安装 7-Zip..."
            pacman -S --noconfirm p7zip
            ;;
    esac

    # 验证
    if ! 7z &>/dev/null; then
        error "7-Zip 安装验证失败"
        return 1
    fi

    success "7-Zip 安装完成"
    7z --version
    echo ""
    echo -e "${YELLOW}常用命令：${NC}"
    echo "  7z a archive.7z file1 file2  # 压缩"
    echo "  7z x archive.7z              # 解压"
    echo ""
}

# ============================================================
#  8. jq 安装
# ============================================================
install_jq() {
    echo ""
    echo -e "${BOLD}========== jq 安装 ==========${NC}"

    # 检查是否已安装
    if command -v jq &>/dev/null; then
        warn "jq 已安装: $(jq --version)"
        read -rp "是否重新安装? [y/N]: " reinstall
        [[ ! "$reinstall" =~ ^[Yy] ]] && return 0
    fi

    # 检测发行版
    local pkg_manager=""
    if [[ -f /etc/debian_version ]] || [[ -f /etc/lsb-release ]]; then
        pkg_manager="apt"
    elif [[ -f /etc/redhat-release ]] || [[ -f /etc/centos-release ]]; then
        pkg_manager="yum"
    elif [[ -f /etc/alpine-release ]]; then
        pkg_manager="apk"
    elif [[ -f /etc/arch-release ]]; then
        pkg_manager="pacman"
    else
        error "无法检测发行版，请手动安装 jq"
        return 1
    fi

    info "检测到包管理器: $pkg_manager"

    # 安装
    case "$pkg_manager" in
        apt)
            info "正在安装 jq..."
            apt-get install -y jq
            ;;
        yum)
            info "正在安装 jq..."
            yum install -y jq
            ;;
        apk)
            info "正在安装 jq..."
            apk add jq
            ;;
        pacman)
            info "正在安装 jq..."
            pacman -S --noconfirm jq
            ;;
    esac

    # 验证
    if ! jq --version &>/dev/null; then
        error "jq 安装验证失败"
        return 1
    fi

    success "jq 安装完成"
    jq --version
    echo ""
}

# ============================================================
#  9. fd 安装
# ============================================================
install_fd() {
    echo ""
    echo -e "${BOLD}========== fd 安装 ==========${NC}"

    # 检查是否已安装
    if command -v fd &>/dev/null; then
        warn "fd 已安装"
        read -rp "是否重新安装? [y/N]: " reinstall
        [[ ! "$reinstall" =~ ^[Yy] ]] && return 0
    fi

    info "正在下载 fd 二进制..."

    local arch=$(uname -m)
    case "$arch" in
        x86_64) arch="amd64" ;;
        aarch64) arch="arm64" ;;
        armv7l) arch="armv7" ;;
        *) error "不支持的架构: $arch"; return 1 ;;
    esac

    local download_url="https://github.com/sharkdp/fd/releases/download/v9.0.0/fd-${arch}"
    local binfile="/usr/local/bin/fd"

    # 下载
    if ! curl -fsSL "$download_url" -o "$binfile"; then
        error "fd 下载失败"
        return 1
    fi

    chmod +x "$binfile"

    # 验证
    if ! fd --version &>/dev/null; then
        error "fd 安装验证失败"
        return 1
    fi

    success "fd 安装完成"
    fd --version
    echo ""
    echo -e "${YELLOW}常用命令：${NC}"
    echo "  fd                 # 列出当前目录"
    echo "  fd -t 10s         # 搜索最近修改的文件"
    echo "  fd -H -e '.*\.log$'    # 查找日志文件"
    echo ""
}

# ============================================================
#  10. bat 安装
# ============================================================
install_bat() {
    echo ""
    echo -e "${BOLD}========== bat 安装 ==========${NC}"

    # 检查是否已安装
    if command -v bat &>/dev/null; then
        warn "bat 已安装: $(bat --version)"
        read -rp "是否重新安装? [y/N]: " reinstall
        [[ ! "$reinstall" =~ ^[Yy] ]] && return 0
    fi

    # 检测发行版
    local pkg_manager=""
    if [[ -f /etc/debian_version ]] || [[ -f /etc/lsb-release ]]; then
        pkg_manager="apt"
    elif [[ -f /etc/redhat-release ]] || [[ -f /etc/centos-release ]]; then
        pkg_manager="yum"
    elif [[ -f /etc/alpine-release ]]; then
        pkg_manager="apk"
    else
        error "无法检测发行版，请手动安装 bat"
        return 1
    fi

    info "检测到包管理器: $pkg_manager"

    # 安装
    case "$pkg_manager" in
        apt)
            info "正在安装 bat..."
            apt-get install -y bat
            ;;
        yum)
            info "正在安装 bat..."
            yum install -y bat
            ;;
        apk)
            info "正在安装 bat..."
            apk add bat
            ;;
    esac

    # 验证
    if ! bat --version &>/dev/null; then
        error "bat 安装验证失败"
        return 1
    fi

    success "bat 安装完成"
    bat --version
    echo ""
    echo -e "${YELLOW}使用方法：${NC}"
    echo "  bat                # 列出文件（带语法高亮）"
    echo "  bat 文件名         # 查看特定文件"
    echo ""
}

# ============================================================
#  11. fail2ban 安装
# ============================================================
install_fail2ban() {
    echo ""
    echo -e "${BOLD}========== Fail2Ban 安装 ==========${NC}"

    # 检查是否已安装
    if command -v fail2ban-client &>/dev/null; then
        warn "Fail2Ban 已安装"
        read -rp "是否重新安装? [y/N]: " reinstall
        [[ ! "$reinstall" =~ ^[Yy] ]] && return 0
    fi

    # 检测发行版
    local pkg_manager=""
    if [[ -f /etc/debian_version ]] || [[ -f /etc/lsb-release ]]; then
        pkg_manager="apt"
    elif [[ -f /etc/redhat-release ]] || [[ -f /etc/centos-release ]]; then
        pkg_manager="yum"
    else
        error "无法检测发行版，请手动安装 Fail2Ban"
        return 1
    fi

    info "检测到包管理器: $pkg_manager"

    # 安装
    if [[ "$pkg_manager" == "apt" ]]; then
        info "正在安装 Fail2Ban..."
        apt-get install -y fail2ban
        # 默认配置：监控 SSH 登录失败
        if [[ ! -f /etc/fail2ban/jail.local ]]; then
            mkdir -p /etc/fail2ban
            echo "[sshd]" > /etc/fail2ban/jail.local
            echo "enabled = true" >> /etc/fail2ban/jail.local
            echo "port = 22" >> /etc/fail2ban/jail.local
            echo "maxretry = 5" >> /etc/fail2ban/jail.local
            echo "findtime = 600" >> /etc/fail2ban/jail.local
            echo "bantime = 3600" >> /etc/fail2ban/jail.local
        fi
        pkg_rollback_push "rm -f /etc/fail2ban/jail.local"
    elif [[ "$pkg_manager" == "yum" ]]; then
        info "正在安装 Fail2Ban..."
        yum install -y fail2ban
        pkg_rollback_push "rm -f /etc/fail2ban/jail.local"
    fi

    # 启动服务
    info "启动 Fail2Ban 服务..."
    if command -v systemctl &>/dev/null; then
        systemctl start fail2ban
        systemctl enable fail2ban
    elif command -v service &>/dev/null; then
        service fail2ban start
    fi

    # 验证
    if ! fail2ban-client --version &>/dev/null; then
        error "Fail2Ban 安装验证失败"
        return 1
    fi

    success "Fail2Ban 安装完成"
    fail2ban-client --version
    echo ""
    echo -e "${YELLOW}管理命令：${NC}"
    echo "  fail2ban-client status # 查看状态"
    echo "  fail2ban-client sshd    # 查看 SSH 防护"
    echo "  fail2ban-client unbanip IP # 解封 IP"
    echo "  sudo systemctl status fail2ban"
    echo ""
}

# ============================================================
#  12. ufw 安装
# ============================================================
install_ufw() {
    echo ""
    echo -e "${BOLD}========== UFW 防火墙安装 ==========${NC}"

    # 检查是否已安装
    if command -v ufw &>/dev/null; then
        warn "UFW 已安装: $(ufw --version)"
        read -rp "是否重新安装? [y/N]: " reinstall
        [[ ! "$reinstall" =~ ^[Yy] ]] && return 0
    fi

    # 检测发行版
    local pkg_manager=""
    if [[ -f /etc/debian_version ]] || [[ -f /etc/lsb-release ]]; then
        pkg_manager="apt"
    elif [[ -f /etc/alpine-release ]]; then
        pkg_manager="apk"
    else
        error "无法检测发行版，UFW 仅支持 Debian/Ubuntu/Alpine"
        return 1
    fi

    info "检测到包管理器: $pkg_manager"

    # 安装
    if [[ "$pkg_manager" == "apt" ]]; then
        apt-get install -y ufw
    elif [[ "$pkg_manager" == "apk" ]]; then
        apk add ufw
    fi

    # 验证
    if ! command -v ufw &>/dev/null; then
        error "UFW 安装验证失败"
        return 1
    fi

    success "UFW 安装完成"
    ufw --version
    echo ""

    echo -e "${YELLOW}常用命令：${NC}"
    echo "  ufw status            # 查看状态"
    echo "  ufw allow 22/tcp       # 允许 SSH"
    echo "  ufw allow 80/tcp       # 允许 HTTP"
    echo "  ufw allow 443/tcp      # 允许 HTTPS"
    echo "  ufw enable             # 启用防火墙"
    echo "  sudo ufw reload        # 重载配置"
    echo ""
}

# ============================================================
#  13. Maldet 安装
# ============================================================
install_maldet() {
    echo ""
    echo -e "${BOLD}========== Maldet 安装 ==========${NC}"
    echo "  功能：检测挖矿、勒索病毒、加密文件"

    # 检查是否已安装
    if command -v maldet &>/dev/null; then
        warn "Maldet 已安装: $(maldet --version)"
        read -rp "是否重新安装? [y/N]: " reinstall
        [[ ! "$reinstall" =~ ^[Yy] ]] && return 0
    fi

    # 检测发行版
    local pkg_manager=""
    if [[ -f /etc/debian_version ]] || [[ -f /etc/lsb-release ]]; then
        pkg_manager="apt"
    elif [[ -f /etc/redhat-release ]] || [[ -f /etc/centos-release ]]; then
        pkg_manager="yum"
    elif [[ -f /etc/alpine-release ]]; then
        pkg_manager="apk"
    elif [[ -f /etc/arch-release ]]; then
        pkg_manager="pacman"
    else
        error "无法检测发行版，请手动安装 Maldet"
        return 1
    fi

    info "检测到包管理器: $pkg_manager"

    # 安装
    case "$pkg_manager" in
        apt)
            info "正在安装 Maldet..."
            apt-get install -y maldet
            ;;
        yum)
            info "正在安装 Maldet..."
            yum install -y maldet
            ;;
        apk)
            info "正在安装 Maldet..."
            apk add maldet
            ;;
        pacman)
            info "正在安装 Maldet..."
            pacman -S --noconfirm maldet
            ;;
    esac

    # 验证
    if ! maldet --version &>/dev/null; then
        error "Maldet 安装验证失败"
        return 1
    fi

    success "Maldet 安装完成"
    maldet --version
    echo ""
    echo -e "${YELLOW}使用方法：${NC}"
    echo "  maldet /               # 扫描当前目录"
    echo "  maldet -a /            # 扫描所有文件系统"
    echo "  maldet -r /home        # 扫描 home 目录"
    echo "  maldet --list           # 列出已知病毒"
    echo ""
}

# ============================================================
#  14. htop 安装
# ============================================================
install_htop() {
    echo ""
    echo -e "${BOLD}========== htop 安装 ==========${NC}"
    echo "  功能：交互式进程监控（top 的替代）"

    # 检查是否已安装
    if command -v htop &>/dev/null; then
        warn "htop 已安装: $(htop --version)"
        read -rp "是否重新安装? [y/N]: " reinstall
        [[ ! "$reinstall" =~ ^[Yy] ]] && return 0
    fi

    # 检测发行版
    local pkg_manager=""
    if [[ -f /etc/debian_version ]] || [[ -f /etc/lsb-release ]]; then
        pkg_manager="apt"
    elif [[ -f /etc/redhat-release ]] || [[ -f /etc/centos-release ]]; then
        pkg_manager="yum"
    elif [[ -f /etc/alpine-release ]]; then
        pkg_manager="apk"
    elif [[ -f /etc/arch-release ]]; then
        pkg_manager="pacman"
    else
        error "无法检测发行版，请手动安装 htop"
        return 1
    fi

    info "检测到包管理器: $pkg_manager"

    # 安装
    case "$pkg_manager" in
        apt)
            info "正在安装 htop..."
            apt-get install -y htop
            ;;
        yum)
            info "正在安装 htop..."
            yum install -y htop
            ;;
        apk)
            info "正在安装 htop..."
            apk add htop
            ;;
        pacman)
            info "正在安装 htop..."
            pacman -S --noconfirm htop
            ;;
    esac

    # 验证
    if ! htop --version &>/dev/null; then
        error "htop 安装验证失败"
        return 1
    fi

    success "htop 安装完成"
    htop --version
    echo ""
    echo -e "${YELLOW}常用快捷键：${NC}"
    echo "  F1 或 ?         # 显示帮助"
    echo "  P, M              # 暂停、恢复进程"
    echo "  /                  # 进程过滤"
    echo "  t                 # 树形显示"
    echo "  u                 # 过程指定用户"
    echo "  K                 # 杀进程"
    echo ""
}

# ============================================================
#  15. 一键全部安装
# ============================================================
install_all() {
    echo ""
    echo -e "${BOLD}========== 一键全部安装 ==========${NC}"
    echo "  将依次安装所有软件（Maldet 和 htop 除外）："
    echo "  1. Node.js"
    echo "  2. Python"
    echo "  3. Docker"
    echo "  4. MySQL"
    echo "  5. 1Panel"
    echo "  6. Nginx"
    echo "  7. 7z"
    echo "  8. jq"
    echo "  9. fd"
    echo " 10. bat"
    echo " 11. fail2ban"
    echo " 12. ufw"
    echo ""

    read -rp "确认开始全部安装? [y/N]: " confirm
    [[ ! "$confirm" =~ ^[Yy] ]] && { info "取消"; return 0; }

    info "开始一键全部安装，请等待..."

    install_node "24.15.0"
    install_python "3.12"
    install_docker
    install_mysql
    install_1panel
    install_nginx
    install_7z "24.05"
    install_jq
    install_fd
    install_bat
    install_fail2ban
    install_ufw

    success "全部软件安装完成！"
    echo ""
    echo -e "${YELLOW}验证安装：${NC}"
    echo "  node -v              # Node.js"
    echo "  python3 -V           # Python"
    echo "  docker --version      # Docker"
    echo "  mysql --version        # MySQL"
    echo "  docker --version      # Docker Compose"
    echo "  1pctl status         # 1Panel"
    echo "  nginx -v             # Nginx"
    echo "  7z --version          # 7z"
    echo "  jq --version           # jq"
    echo "  fd --version           # fd"
    echo "  bat --version          # bat"
    echo "  fail2ban-client --version  # Fail2Ban"
    echo "  ufw --version         # UFW"
    echo "  maldet --version       # Maldet"
    echo "  htop --version         # htop"
    echo ""
}

# ============================================================
#  主菜单
# ============================================================
show_banner() {
    clear
    echo -e "${CYAN}"
    cat << 'EOF'
  ============================================
    常用软件一键安装工具 v1.2
    Package Installer
    (信号捕获 + 原子写入 + 中断回滚)
  ============================================
EOF
    echo -e "${NC}"
    echo -e "  系统: ${GREEN}${OS}${NC}"
    echo -e "  内核: ${GREEN}${KERNEL}${NC}"
    echo ""
}

main_menu() {
    while true; do
        show_banner
        echo -e "  ${BOLD}请选择软件安装:${NC}"
        echo ""
        echo "  1) 🟢 Node.js 24.15.0 (推荐，支持多版本)"
        echo "  2) 🐍 Python 3.12"
        echo "  3) 🐳 Docker & Compose"
        echo "  4) 🐬 MySQL 8.0"
        echo "  5) 🪟 1Panel"
        echo "  6) 🌍 Nginx 1.24"
        echo "  7) 📦 7-Zip 24.05"
        echo "  8) 📟 jq (JSON 处理)"
        echo "  9) 🔎 fd (快速查找)"
        echo " 10) 🦇 bat (cat 替代)"
        echo " 11) 🛡️ Fail2Ban (SSH 防护)"
        echo " 12) 🔒 UFW (防火墙)"
        echo " 13) 🦠 Maldet (挖矿/勒索扫描)"
        echo " 14) 📈 htop (进程监控)"
        echo " 15) 🚀 一键全部安装 (自动安装 1-12)"
        echo "  0) 🚪 退出"
        echo ""
        read -rp "  请选择 [0-15]: " choice

        case "$choice" in
            1) install_node "24.15.0" ;;
            2) install_python "3.12" ;;
            3) install_docker ;;
            4) install_mysql ;;
            5) install_1panel ;;
            6) install_nginx ;;
            7) install_7z "24.05" ;;
            8) install_jq ;;
            9) install_fd ;;
            10) install_bat ;;
            11) install_fail2ban ;;
            12) install_ufw ;;
            13) install_maldet ;;
            14) install_htop ;;
            15) install_all ;;
            0)
                echo -e "\n  再见！\n"
                exit 0
                ;;
            *)
                error "无效选择"
                sleep 1
                ;;
        esac
    done
}

# ---------- 入口 ----------
check_root
main_menu
