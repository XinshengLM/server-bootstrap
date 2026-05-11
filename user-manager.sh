#!/usr/bin/env bash
# ============================================================
#  SSH 用户管理脚本 (Interactive User Manager) v4.0
#  功能：创建、删除、列出、锁定/解锁用户，配置 SSH 密钥登录
#  特性：信号捕获 + 原子写入 + 中断自动回滚 + 非 root 诊断模式 + 安全网
#  用法：sudo bash user-manager.sh  (或 bash user-manager.sh 进入诊断模式)

set -euo pipefail

# ---------- 颜色 ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ---------- 工具函数 ----------
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
#  中断保护机制
# ============================================================

# 全局回滚栈：记录需要回滚的操作
declare -ga _ROLLBACK_STACK=()

# 当前正在创建的用户名（用于中断时清理半成品用户）
_CURRENT_CREATING_USER=""

# 注册回滚操作（后进先出，像栈一样）
rollback_push() {
    _ROLLBACK_STACK+=("$*")
}

# 清空回滚栈（操作全部成功完成后调用）
rollback_clear() {
    _ROLLBACK_STACK=()
    _CURRENT_CREATING_USER=""
}

# 执行所有回滚操作
rollback_execute() {
    if [[ ${#_ROLLBACK_STACK[@]} -eq 0 ]]; then
        return 0
    fi
    echo ""
    error "=== 正在执行回滚 ==="
    # 倒序执行
    local count=${#_ROLLBACK_STACK[@]}
    for (( i=count-1; i>=0; i-- )); do
        local cmd="${_ROLLBACK_STACK[$i]}"
        echo -e "  ${YELLOW}回滚: $cmd${NC}"
        eval "$cmd" 2>/dev/null || true
    done
    error "=== 回滚完成 ==="
    echo ""
    _ROLLBACK_STACK=()
}

# 信号处理函数
handle_interrupt() {
    local sig="${1:-}"
    # EXIT 信号在正常退出时也会触发，只在实际中断时处理
    if [[ "$sig" == "EXIT" ]]; then
        # 只在有未完成操作时静默回滚
        if [[ ${#_ROLLBACK_STACK[@]} -gt 0 ]]; then
            rollback_execute
        fi
        return 0
    fi

    echo ""
    echo ""
    error "!!! 检测到中断信号 (Ctrl+C / 信号) !!!"
    echo ""

    # 情况 1：正在创建用户 → 删除半成品用户
    if [[ -n "$_CURRENT_CREATING_USER" ]] && id "$_CURRENT_CREATING_USER" &>/dev/null; then
        warn "检测到未完成的用户创建操作: $_CURRENT_CREATING_USER"
        echo -e "  ${RED}选项：${NC}"
        echo "  1) 回滚 — 删除半成品用户及所有相关配置 (推荐)"
        echo "  2) 保留 — 保留已创建的内容，稍后手动修复"
        echo "  3) 强制退出 — 什么都不做直接退出"
        # 限时 10 秒自动选择回滚
        read -t 10 -rp "请选择 [1-3, 默认 1]: " int_choice 2>/dev/null || true
        int_choice="${int_choice:-1}"
        case "$int_choice" in
            1)
                info "正在回滚..."
                rollback_execute
                # 确保清理用户
                if id "$_CURRENT_CREATING_USER" &>/dev/null; then
                    userdel -r "$_CURRENT_CREATING_USER" 2>/dev/null || userdel "$_CURRENT_CREATING_USER" 2>/dev/null || true
                fi
                rm -f "/etc/sudoers.d/$_CURRENT_CREATING_USER"
                success "已回滚：半成品用户已清理"
                ;;
            2)
                warn "已保留。请手动完成或清理用户: $_CURRENT_CREATING_USER"
                ;;
            3)
                warn "强制退出，不做任何清理"
                ;;
        esac
        _CURRENT_CREATING_USER=""
        echo ""
        echo "按 Enter 返回主菜单..."
        return
    fi

    # 情况 2：有其他待回滚操作
    if [[ ${#_ROLLBACK_STACK[@]} -gt 0 ]]; then
        echo -e "  ${RED}选项：${NC}"
        echo "  1) 回滚 — 撤销所有未完成的操作 (推荐)"
        echo "  2) 保留 — 直接退出"
        read -t 10 -rp "请选择 [1-2, 默认 1]: " int_choice 2>/dev/null || true
        int_choice="${int_choice:-1}"
        if [[ "$int_choice" == "1" ]]; then
            rollback_execute
        fi
        echo ""
        echo "按 Enter 返回主菜单..."
        return
    fi

    # 情况 3：没什么需要回滚的
    warn "没有需要回滚的操作"
    echo "按 Enter 返回主菜单..."
}

# 捕获信号（EXIT 单独处理，避免正常退出弹干扰信息）
trap 'handle_interrupt SIGINT' SIGINT
trap 'handle_interrupt SIGTERM' SIGTERM
trap 'handle_interrupt SIGHUP' SIGHUP
trap 'handle_interrupt EXIT' EXIT

# ---------- 前置检查 ----------
_IS_ROOT=true

check_root() {
    if [[ $EUID -ne 0 ]]; then
        _IS_ROOT=false
    fi
}

# ============================================================
#  安全网：检查系统是否还有"后路"
#  在危险操作（禁 root、禁密码、删用户、锁用户）前调用
# ============================================================
safety_net_check() {
    local action="$1"
    local sshd_config="/etc/ssh/sshd_config"

    echo ""
    echo -e "${YELLOW}[安全网] 即将执行: $action${NC}"

    # 检查 1: root SSH 登录
    local root_ok=false
    local rl
    rl=$(grep -E "^\s*PermitRootLogin" "$sshd_config" 2>/dev/null | awk '{print $2}' || echo "")
    if [[ -z "$rl" || "$rl" == "yes" || "$rl" == "prohibit-password" ]]; then
        root_ok=true
    fi

    # 检查 2: 至少一个普通用户有 SSH 密钥 + sudo
    local safe_user=false
    local safe_name=""
    while IFS=: read -r user _ uid _ _ home shell; do
        [[ "$uid" -lt 1000 || "$uid" -ge 65534 ]] && continue
        [[ "$shell" == */nologin || "$shell" == */false ]] && continue
        if [[ -f "$home/.ssh/authorized_keys" ]] && [[ -s "$home/.ssh/authorized_keys" ]]; then
            if [[ -f "/etc/sudoers.d/$user" ]] && grep -q "NOPASSWD" "/etc/sudoers.d/$user" 2>/dev/null; then
                safe_user=true; safe_name="$user"; break
            fi
            if groups "$user" 2>/dev/null | grep -qE '\b(sudo|wheel)\b'; then
                safe_user=true; safe_name="$user"; break
            fi
        fi
    done < /etc/passwd

    # 检查 3: 密码登录
    local pw_ok=false
    local pv
    pv=$(grep -E "^\s*PasswordAuthentication" "$sshd_config" 2>/dev/null | awk '{print $2}' || echo "")
    if [[ -z "$pv" || "$pv" == "yes" ]]; then pw_ok=true; fi

    # 汇总
    local any_safe=false
    if $root_ok; then info "  root SSH: 可用"; any_safe=true; else warn "  root SSH: 已禁用"; fi
    if $safe_user; then info "  安全用户: $safe_name"; any_safe=true; else warn "  安全用户: 无"; fi
    if $pw_ok; then info "  密码登录: 可用"; any_safe=true; else warn "  密码登录: 已禁用"; fi

    if ! $any_safe; then
        echo ""
        error "!!! 安全网失败：执行后将无法 SSH 登录 !!!"
        error "!!! 唯一恢复方式：云控制台 VNC !!!"
        echo ""
        read -rp "确认继续? 输入 I-KNOW-WHAT-I-AM-DOING: " dc
        [[ "$dc" == "I-KNOW-WHAT-I-AM-DOING" ]] || { info "已取消"; return 1; }
    fi
    return 0
}

# ============================================================
#  非 root 诊断模式
# ============================================================
diagnostic_mode() {
    while true; do
        echo -e "\n${BOLD}========== 诊断模式 (非 root) ==========${NC}"
        echo ""
        echo "  1) 🔍 	查看当前用户和权限"
        echo "  2) ⚙️ 	查看 SSH 配置"
        echo "  3) 📋 	查看用户列表"
        echo "  4) 🛡️ 	安全网检查"
        echo "  5) 🔧 	生成 VNC 恢复命令"
        echo "  0) 🚪 	退出"
        echo ""
        read -rp "  请选择 [0-5]: " dc

        case "$dc" in
            1)
                echo ""
                echo "  当前用户: $(whoami)"
                echo "  UID:      $(id -u)"
                echo "  Groups:   $(id -Gn 2>/dev/null)"
                echo "  Home:     $HOME"
                echo ""
                echo "  ~/.ssh/:"
                ls -la ~/.ssh/ 2>/dev/null || echo "    (不存在)"
                echo ""
                echo "  sudo 状态:"
                if sudo -n true 2>/dev/null; then echo "    免密 sudo: 可用"
                else echo "    免密 sudo: 不可用"; fi
                ;;
            2)
                echo ""
                local sc="/etc/ssh/sshd_config"
                if [[ -r "$sc" ]]; then
                    for k in PermitRootLogin PasswordAuthentication PubkeyAuthentication MaxAuthTries Port; do
                        local v; v=$(grep -E "^\s*${k}\s" "$sc" 2>/dev/null | awk '{print $2}') || v=""
                        printf "  %-28s %s\n" "$k" "${v:-(未设置)}"
                    done
                else echo "  (无权限读取)"; fi
                echo ""
                echo "  SSH_CONNECTION: ${SSH_CONNECTION:-N/A}"
                ;;
            3)
                echo ""
                printf "%-16s %-6s %-15s %-8s\n" "用户名" "UID" "Shell" "SSH密钥"
                echo "──────────────────────────────────────"
                while IFS=: read -r u _ uid _ _ h s; do
                    [[ "$uid" -lt 1000 || "$uid" -ge 65534 ]] && continue
                    local hk="无"
                    [[ -f "$h/.ssh/authorized_keys" ]] && [[ -s "$h/.ssh/authorized_keys" ]] && hk="有"
                    printf "%-16s %-6s %-15s %-8s\n" "$u" "$uid" "$(basename "$s")" "$hk"
                done < /etc/passwd
                ;;
            4)
                echo ""
                echo "  检查系统登录入口..."
                local sc="/etc/ssh/sshd_config"
                local rl; rl=$(grep -E "^\s*PermitRootLogin" "$sc" 2>/dev/null | awk '{print $2}') || rl=""
                [[ -z "$rl" || "$rl" == "yes" ]] && echo "  root SSH: 可用" || echo "  root SSH: 已禁用 ($rl)"
                local pv; pv=$(grep -E "^\s*PasswordAuthentication" "$sc" 2>/dev/null | awk '{print $2}') || pv=""
                [[ -z "$pv" || "$pv" == "yes" ]] && echo "  密码登录: 可用" || echo "  密码登录: 已禁用 ($pv)"
                while IFS=: read -r u _ uid _ _ h s; do
                    [[ "$uid" -lt 1000 || "$uid" -ge 65534 ]] && continue
                    [[ "$s" == */nologin || "$s" == */false ]] && continue
                    if [[ -f "$h/.ssh/authorized_keys" ]] && [[ -s "$h/.ssh/authorized_keys" ]]; then
                        if [[ -f "/etc/sudoers.d/$u" ]] && grep -q "NOPASSWD" "/etc/sudoers.d/$u" 2>/dev/null; then
                            echo "  安全用户: $u (SSH密钥+NOPASSWD sudo)"
                        elif groups "$u" 2>/dev/null | grep -qE '\b(sudo|wheel)\b'; then
                            echo "  安全用户: $u (SSH密钥+sudo组)"
                        else echo "  用户 $u: 有SSH密钥, 无sudo"
                        fi
                    fi
                done < /etc/passwd
                ;;
            5)
                echo ""
                echo -e "${BOLD}  === VNC 恢复命令 ===${NC}"
                echo "  复制以下命令到云控制台 VNC 以 root 执行："
                echo ""
                local users=()
                while IFS=: read -r u _ uid _ _ _ s; do
                    [[ "$uid" -lt 1000 || "$uid" -ge 65534 ]] && continue
                    users+=("$u")
                done < /etc/passwd
                if [[ ${#users[@]} -eq 0 ]]; then
                    echo "  (没有找到普通用户)"
                else
                    echo "  # === 给所有用户设密码 ==="
                    for u in "${users[@]}"; do echo "  echo '$u:你的密码' | chpasswd"; done
                    echo ""
                    echo "  # === 给所有用户加免密 sudo ==="
                    for u in "${users[@]}"; do echo "  echo '$u ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/$u && chmod 440 /etc/sudoers.d/$u"; done
                fi
                echo ""
                echo "  # === 恢复 root SSH 登录 ==="
                echo "  sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config"
                echo ""
                echo "  # === 恢复密码登录 ==="
                echo "  sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config"
                echo ""
                echo "  # === 重启 SSH ==="
                echo "  systemctl restart sshd || systemctl restart ssh || service ssh restart"
                echo ""
                echo "  # === 验证 ==="
                if [[ ${#users[@]} -gt 0 ]]; then
                    for u in "${users[@]}"; do echo "  cat /etc/sudoers.d/$u"; done
                fi
                echo "  grep PermitRootLogin /etc/ssh/sshd_config"
                ;;
            0) echo -e "\n  再见！\n"; exit 0 ;;
            *) error "无效选择" ;;
        esac
    done
}

# ============================================================
#  原子写入工具函数
# ============================================================

# 原子写入文件：先写到临时文件，再 mv 过去
# 用法: atomic_write "目标文件" "内容"
atomic_write() {
    local target="$1"
    local content="$2"
    local tmpfile="${target}.tmp.$$"

    printf '%s\n' "$content" > "$tmpfile" || { rm -f "$tmpfile"; return 1; }
    mv -f "$tmpfile" "$target" || { rm -f "$tmpfile"; return 1; }
}

# 原子追加文件：先备份，追加到临时文件，再 mv
# 用法: atomic_append "目标文件" "内容"
atomic_append() {
    local target="$1"
    local content="$2"
    local tmpfile="${target}.tmp.$$"

    if [[ -f "$target" ]]; then
        cp "$target" "$tmpfile"
    else
        : > "$tmpfile"
    fi
    printf '%s\n' "$content" >> "$tmpfile" || { rm -f "$tmpfile"; return 1; }
    mv -f "$tmpfile" "$target" || { rm -f "$tmpfile"; return 1; }
}

# 原子删除指定行：先备份，操作临时文件，再 mv
# 用法: atomic_delete_line "文件" "行号"
atomic_delete_line() {
    local target="$1"
    local line_num="$2"
    local tmpfile="${target}.tmp.$$"

    if [[ ! -f "$target" ]]; then
        return 1
    fi
    cp "$target" "$tmpfile"
    sed -i "${line_num}d" "$tmpfile"
    mv -f "$tmpfile" "$target" || { rm -f "$tmpfile"; return 1; }
}

# 原子修改 sshd_config（带备份）
_SSHD_BAK_TAG=""

set_ssh_config_value() {
    local key="$1"
    local value="$2"
    local sshd_config="/etc/ssh/sshd_config"

    # 每次加固会话只备份一次
    if [[ -z "$_SSHD_BAK_TAG" ]]; then
        _SSHD_BAK_TAG="$(date +%Y%m%d%H%M%S)"
    fi
    local backup="${sshd_config}.bak.${_SSHD_BAK_TAG}"
    if [[ ! -f "$backup" ]]; then
        cp "$sshd_config" "$backup"
        rollback_push "cp '$backup' '$sshd_config'"
    fi

    # 原子修改：写到临时文件再替换
    local tmpfile="${sshd_config}.tmp.$$"
    cp "$sshd_config" "$tmpfile"

    if grep -q "^\s*${key}" "$tmpfile"; then
        sed -i "s/^\s*${key}.*$/${key} ${value}/" "$tmpfile"
    else
        echo "${key} ${value}" >> "$tmpfile"
    fi

    # 语法检查临时文件
    if ! sshd -t -f "$tmpfile" 2>/dev/null; then
        rm -f "$tmpfile"
        error "修改后 sshd 语法检查失败，已跳过此修改 ($key $value)"
        return 1
    fi

    mv -f "$tmpfile" "$sshd_config"
    info "$key → $value"
    return 0
}

# 安全重启 sshd（带回滚）
restart_sshd_safely() {
    local sshd_config="/etc/ssh/sshd_config"

    if sshd -t 2>/dev/null; then
        if systemctl is-active --quiet sshd 2>/dev/null; then
            systemctl restart sshd
        elif systemctl is-active --quiet ssh 2>/dev/null; then
            systemctl restart ssh
        elif service ssh status &>/dev/null; then
            service ssh restart
        else
            warn "未检测到 sshd 服务，请手动重启"
            return 0
        fi
        success "SSH 配置已重载"
        # 成功后清空回滚栈中的 sshd 回滚
        rollback_clear
    else
        error "sshd 配置语法检查失败！正在回滚..."
        local latest_bak
        latest_bak=$(ls -t "${sshd_config}.bak."* 2>/dev/null | head -1)
        if [[ -n "$latest_bak" && -f "$latest_bak" ]]; then
            cp "$latest_bak" "$sshd_config"
            if systemctl is-active --quiet sshd 2>/dev/null; then
                systemctl restart sshd
            elif systemctl is-active --quiet ssh 2>/dev/null; then
                systemctl restart ssh
            elif service ssh status &>/dev/null; then
                service ssh restart
            fi
            error "已回滚到备份: $latest_bak"
        else
            error "没有找到备份文件！请立即手动检查 $sshd_config"
        fi
        return 1
    fi
}

# 校验 sudoers 文件语法
check_sudoers() {
    local file="$1"
    if command -v visudo &>/dev/null; then
        if ! visudo -c -f "$file" &>/dev/null; then
            error "sudoers 语法检查失败: $file"
            return 1
        fi
    fi
    return 0
}

# ============================================================
#  1. 创建用户
# ============================================================
create_user() {
    echo -e "\n${BOLD}========== 创建新用户 ==========${NC}"

    read -rp "请输入用户名: " username
    if [[ -z "$username" ]]; then
        error "用户名不能为空"
        press_any_key
        return 1
    fi

    if ! [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        error "用户名格式不合法。规则：小写字母/下划线开头，仅含小写字母、数字、下划线、连字符，最长32字符"
        press_any_key
        return 1
    fi

    local -a reserved_names=(root admin administrator daemon bin sys sync games man lp mail news uucp proxy www-data backup list irc gnats nobody systemd)
    for reserved in "${reserved_names[@]}"; do
        if [[ "$username" == "$reserved" ]]; then
            error "用户名 '$username' 是系统保留名称，禁止使用"
            press_any_key
            return 1
        fi
    done

    if id "$username" &>/dev/null; then
        error "用户 '$username' 已存在 (UID: $(id -u "$username"))"
        press_any_key
        return 1
    fi

    echo ""
    echo "请选择默认 Shell:"
    echo "  1) /bin/bash    (推荐)"
    echo "  2) /bin/zsh"
    echo "  3) /bin/sh"
    echo "  4) /usr/sbin/nologin  (服务账户，禁止登录)"
    read -rp "请选择 [1-4, 默认 1]: " shell_choice
    shell_choice="${shell_choice:-1}"
    case "$shell_choice" in
        1) user_shell="/bin/bash" ;;
        2) user_shell="/bin/zsh" ;;
        3) user_shell="/bin/sh" ;;
        4) user_shell="/usr/sbin/nologin" ;;
        *) user_shell="/bin/bash" ;;
    esac

    echo ""
    echo "请选择认证方式:"
    echo "  1) SSH 密钥认证（免密登录，推荐）"
    echo "  2) 密码认证"
    echo "  3) 两者都配置"
    read -rp "请选择 [1-3, 默认 1]: " auth_choice
    auth_choice="${auth_choice:-1}"

    echo ""
    echo "是否授予 sudo 权限?"
    echo "  1) 是 — 免密 sudo (NOPASSWD，推荐)"
    echo "  2) 是 — 需要 sudo 密码 (必须同时设置登录密码)"
    echo "  3) 否 — 普通用户"
    read -rp "请选择 [1-3, 默认 1]: " sudo_choice
    sudo_choice="${sudo_choice:-1}"

    # ---------- 开始创建（此后的操作需要可回滚）----------
    info "正在创建用户 '$username' ..."

    # 标记正在创建的用户（用于中断清理）
    _CURRENT_CREATING_USER="$username"

    useradd -m -s "$user_shell" "$username"
    # 注册回滚：如果后续失败，删除这个用户
    rollback_push "userdel -r '$username' 2>/dev/null || userdel '$username' 2>/dev/null || true"
    success "用户 '$username' 创建成功 (UID: $(id -u "$username"), Shell: $user_shell)"

    # 设置 sudo
    if [[ "$sudo_choice" == "1" || "$sudo_choice" == "2" ]]; then
        local sudoers_file="/etc/sudoers.d/$username"

        if [[ "$sudo_choice" == "1" ]]; then
            # 原子写入 sudoers 文件
            atomic_write "$sudoers_file" "$username ALL=(ALL) NOPASSWD:ALL"
            chmod 440 "$sudoers_file"
            if check_sudoers "$sudoers_file"; then
                rollback_push "rm -f '$sudoers_file'"
                success "已授予免密 sudo 权限 (NOPASSWD)"
            else
                rm -f "$sudoers_file"
                error "sudoers 语法错误，已回滚，请手动配置 sudo"
            fi
        else
            if getent group sudo &>/dev/null; then
                usermod -aG sudo "$username"
            elif getent group wheel &>/dev/null; then
                usermod -aG wheel "$username"
            else
                atomic_write "$sudoers_file" "$username ALL=(ALL:ALL) ALL"
                chmod 440 "$sudoers_file"
                check_sudoers "$sudoers_file" || { rm -f "$sudoers_file"; warn "sudoers 校验失败，已跳过"; }
            fi
            rollback_push "rm -f '$sudoers_file'; gpasswd -d '$username' sudo 2>/dev/null; gpasswd -d '$username' wheel 2>/dev/null"
            success "已授予 sudo 权限 (需要密码)"
        fi
    fi

    # 设置密码
    local need_password=false
    if [[ "$auth_choice" == "2" || "$auth_choice" == "3" ]]; then
        need_password=true
    fi
    if [[ "$sudo_choice" == "2" ]]; then
        need_password=true
        warn "sudo 需要密码，必须设置登录密码"
    fi

    if [[ "$need_password" == true ]]; then
        while true; do
            read -rsp "请设置密码: " password
            echo ""
            if [[ -z "$password" ]]; then
                error "密码不能为空，请重新输入"
                continue
            fi
            if [[ ${#password} -lt 8 ]]; then
                warn "密码少于 8 位，建议使用更长的密码"
                read -rp "仍然使用? [y/N]: " use_weak
                if [[ ! "$use_weak" =~ ^[Yy] ]]; then
                    continue
                fi
            fi
            read -rsp "请确认密码: " password2
            echo ""
            if [[ "$password" != "$password2" ]]; then
                error "两次密码不一致，请重新输入"
                continue
            fi
            break
        done
        echo "$username:$password" | chpasswd
        unset password password2
        success "密码已设置"
    fi

    # 配置 SSH 密钥
    if [[ "$auth_choice" == "1" || "$auth_choice" == "3" ]]; then
        setup_ssh_key "$username"
    fi

    # 安全检查：确保至少有一种方式能登录
    local has_auth=false
    if [[ "$auth_choice" == "2" || "$auth_choice" == "3" ]] || [[ -f "$(eval echo "~$username")/.ssh/authorized_keys" ]]; then
        has_auth=true
    fi
    if [[ "$has_auth" == false ]]; then
        error "!!! 此用户没有配置任何认证方式（无密码、无 SSH 密钥）！"
        error "!!! 该用户将无法登录！建议立即配置认证方式。"
    fi

    # ---------- 创建完成，清空回滚栈 ----------
    rollback_clear
    _CURRENT_CREATING_USER=""

    echo ""
    success "========== 用户创建完成 =========="
    echo -e "  用户名:  ${CYAN}$username${NC}"
    echo -e "  UID:     ${CYAN}$(id -u "$username")${NC}"
    echo -e "  Home:    ${CYAN}$(eval echo "~$username")${NC}"
    echo -e "  Shell:   ${CYAN}$user_shell${NC}"
    echo -e "  Sudo:    ${CYAN}$([ "$sudo_choice" == "1" ] && echo '是(NOPASSWD)' || ([ "$sudo_choice" == "2" ] && echo '是(需密码)' || echo '否'))${NC}"
    echo -e "  认证:    ${CYAN}$([ "$auth_choice" == "1" ] && echo 'SSH密钥' || ([ "$auth_choice" == "2" ] && echo '密码' || echo '密钥+密码'))${NC}"
    echo ""

    press_any_key
}

# ---------- 配置 SSH 密钥 ----------
setup_ssh_key() {
    local username="$1"
    local ssh_dir
    ssh_dir=$(eval echo "~$username")/.ssh

    info "正在配置 SSH 密钥登录..."

    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"

    echo ""
    echo "请选择公钥来源:"
    echo "  1) 从本机已有的公钥文件导入 (如 ~/.ssh/id_rsa.pub)"
    echo "  2) 直接粘贴公钥内容"
    echo "  3) 自动生成新的密钥对"
    read -rp "请选择 [1-3, 默认 2]: " key_choice
    key_choice="${key_choice:-2}"

    local pubkey=""

    case "$key_choice" in
        1)
            read -rp "请输入公钥文件路径 [默认 ~/.ssh/id_rsa.pub]: " pubkey_path
            pubkey_path="${pubkey_path:-$HOME/.ssh/id_rsa.pub}"
            if [[ ! -f "$pubkey_path" ]]; then
                error "文件 '$pubkey_path' 不存在"
                for try_path in "/root/.ssh/id_rsa.pub" "/root/.ssh/id_ed25519.pub" "$HOME/.ssh/id_ed25519.pub"; do
                    if [[ -f "$try_path" ]]; then
                        warn "找到公钥文件: $try_path"
                        read -rp "是否使用此文件? [Y/n]: " use_try
                        use_try="${use_try:-Y}"
                        if [[ "$use_try" =~ ^[Yy] ]]; then
                            pubkey_path="$try_path"
                            break
                        fi
                    fi
                done
                if [[ ! -f "$pubkey_path" ]]; then
                    error "未找到可用公钥文件"
                    press_any_key
                    return 1
                fi
            fi
            pubkey=$(cat "$pubkey_path")
            ;;
        2)
            echo "请粘贴公钥内容（以 ssh-rsa / ssh-ed25519 / ecdsa-sha2-nistp256 开头）："
            read -rp "公钥: " pubkey
            ;;
        3)
            echo "请选择密钥类型:"
            echo "  1) ed25519 (推荐，更安全更短)"
            echo "  2) rsa    (兼容性最好)"
            read -rp "请选择 [1-2, 默认 1]: " kt_choice
            kt_choice="${kt_choice:-1}"
            local key_comment="${username}@$(hostname)-$(date +%Y%m%d)"
            local key_dir="/root/.ssh/generated_keys"
            mkdir -p "$key_dir"
            chmod 700 "$key_dir"
            local tmp_keyfile="${key_dir}/${username}_key_$(date +%Y%m%d%H%M%S)"
            if [[ "$kt_choice" == "1" ]]; then
                ssh-keygen -t ed25519 -C "$key_comment" -f "$tmp_keyfile" -N ""
            else
                ssh-keygen -t rsa -b 4096 -C "$key_comment" -f "$tmp_keyfile" -N ""
            fi
            chmod 600 "$tmp_keyfile"
            pubkey=$(cat "${tmp_keyfile}.pub")
            echo ""
            success "密钥对已生成！"
            echo -e "  ${YELLOW}私钥文件: $tmp_keyfile${NC}"
            echo -e "  ${YELLOW}请立即下载到本地，然后删除服务器上的私钥：${NC}"
            echo -e "  ${CYAN}rm -f $tmp_keyfile${NC}"
            echo ""
            ;;
        *)
            error "无效选择"
            return 1
            ;;
    esac

    if [[ -z "$pubkey" ]]; then
        error "公钥内容为空"
        return 1
    fi

    if ! [[ "$pubkey" =~ ^(ssh-(rsa|ed25519|dss)|ecdsa-sha2-nistp) ]]; then
        warn "公钥格式看起来不太对，确认继续吗？"
        read -rp "继续? [y/N]: " confirm
        if [[ ! "$confirm" =~ ^[Yy] ]]; then
            return 1
        fi
    fi

    # 原子写入 authorized_keys
    local ak_file="$ssh_dir/authorized_keys"
    atomic_append "$ak_file" "$pubkey"
    chmod 600 "$ak_file"
    chown -R "$username:$username" "$ssh_dir"

    success "SSH 密钥已配置 ($ak_file)"
}

# ============================================================
#  2. 删除用户
# ============================================================
delete_user() {
    echo -e "\n${BOLD}========== 删除用户 ==========${NC}"

    list_users_brief
    echo ""

    read -rp "请输入要删除的用户名: " username
    if [[ -z "$username" ]]; then
        error "用户名不能为空"
        press_any_key
        return 1
    fi

    if ! [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        error "用户名格式不合法"
        press_any_key
        return 1
    fi

    if ! id "$username" &>/dev/null; then
        error "用户 '$username' 不存在"
        press_any_key
        return 1
    fi

    local current_user
    current_user=$(whoami)
    if [[ "$username" == "$current_user" ]]; then
        error "不能删除当前登录的用户 '$username'！"
        press_any_key
        return 1
    fi

    local target_uid
    target_uid=$(id -u "$username")
    if [[ "$target_uid" -eq 0 ]]; then
        error "不能删除 root 用户 (UID 0)！"
        press_any_key
        return 1
    fi

    echo -e "${RED}⚠️  警告：即将删除用户 '$username' 及其所有数据！${NC}"
    echo -e "  UID:      $target_uid"
    echo -e "  Home:     $(eval echo "~$username")"
    echo -e "  Groups:   $(groups "$username" 2>/dev/null | cut -d: -f2)"
    local proc_count
    proc_count=$(pgrep -u "$username" -c 2>/dev/null || echo "0")
    if [[ "$proc_count" -gt 0 ]]; then
        echo -e "  ${YELLOW}进程:     有 $proc_count 个运行中的进程${NC}"
    fi
    echo ""
    read -rp "确认删除? 输入用户名 '$username' 以确认: " confirm
    if [[ "$confirm" != "$username" ]]; then
        warn "确认失败，操作取消"
        press_any_key
        return 0
    fi

    read -rp "是否同时删除 home 目录和邮件? [Y/n]: " del_home
    del_home="${del_home:-Y}"

    if [[ "$del_home" =~ ^[Yy] ]]; then
        local backup_path="/root/${username}_home_backup_$(date +%Y%m%d%H%M%S).tar.gz"
        info "正在备份 home 目录到 $backup_path ..."
        tar -czf "$backup_path" -C / "home/$username" 2>/dev/null || true
        success "home 目录已备份"

        if [[ "$proc_count" -gt 0 ]]; then
            warn "正在终止 $username 的 $proc_count 个进程..."
            pkill -u "$username" 2>/dev/null || true
            sleep 1
        fi

        userdel -r "$username" 2>/dev/null || userdel "$username"
        success "用户 '$username' 及其 home 目录已删除"
    else
        if [[ "$proc_count" -gt 0 ]]; then
            warn "正在终止 $username 的 $proc_count 个进程..."
            pkill -u "$username" 2>/dev/null || true
            sleep 1
        fi
        userdel "$username"
        success "用户 '$username' 已删除 (home 目录已保留)"
    fi

    rm -f "/etc/sudoers.d/$username"

    press_any_key
}

# ============================================================
#  3. 列出用户
# ============================================================
list_users() {
    echo -e "\n${BOLD}========== 系统用户列表 ==========${NC}"
    echo ""

    printf "${BOLD}%-16s %-6s %-6s %-20s %-12s %-8s %s${NC}\n" \
        "用户名" "UID" "GID" "Home" "Shell" "Sudo" "状态"
    echo "─────────────────────────────────────────────────────────────────────────────────"

    while IFS=: read -r user _ uid gid _ home shell; do
        [[ "$uid" -lt 1000 || "$uid" -ge 65534 ]] && continue
        [[ "$user" == "nobody" ]] && continue

        local has_sudo="否"
        if groups "$user" 2>/dev/null | grep -qE '\b(sudo|wheel)\b'; then
            has_sudo="是"
        elif [[ -f "/etc/sudoers.d/$user" ]]; then
            has_sudo="是"
        fi

        local status="正常"
        if passwd -S "$user" 2>/dev/null | grep -q "L"; then
            status="${RED}锁定${NC}"
        fi

        local shell_short
        shell_short=$(basename "$shell")

        printf "%-16s %-6s %-6s %-20s %-12s %-8s %b\n" \
            "$user" "$uid" "$gid" "$home" "$shell_short" "$has_sudo" "$status"
    done < /etc/passwd

    echo ""
    press_any_key
}

list_users_brief() {
    printf "%-16s %-6s %-20s\n" "用户名" "UID" "Shell"
    echo "──────────────────────────────────"
    while IFS=: read -r user _ uid _ _ _ shell; do
        [[ "$uid" -lt 1000 || "$uid" -ge 65534 ]] && continue
        [[ "$user" == "nobody" ]] && continue
        printf "%-16s %-6s %-20s\n" "$user" "$uid" "$(basename "$shell")"
    done < /etc/passwd
}

# ============================================================
#  4. 管理 SSH 密钥
# ============================================================
manage_ssh_keys() {
    echo -e "\n${BOLD}========== 管理 SSH 密钥 ==========${NC}"

    list_users_brief
    echo ""

    read -rp "请输入用户名: " username
    if [[ -z "$username" ]]; then
        error "用户名不能为空"
        press_any_key
        return 1
    fi
    if ! [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        error "用户名格式不合法"
        press_any_key
        return 1
    fi
    if ! id "$username" &>/dev/null; then
        error "用户不存在"
        press_any_key
        return 1
    fi

    local ssh_dir
    ssh_dir=$(eval echo "~$username")/.ssh

    while true; do
        echo ""
        echo "--- SSH 密钥管理: $username ---"
        echo "  1) 查看已授权的公钥"
        echo "  2) 添加新公钥"
        echo "  3) 删除公钥"
        echo "  4) 生成新的密钥对"
        echo "  5) 返回主菜单"
        read -rp "请选择 [1-5]: " key_action

        case "$key_action" in
            1)
                if [[ -f "$ssh_dir/authorized_keys" ]]; then
                    echo ""
                    echo "已授权的公钥:"
                    echo "──────────────"
                    nl -ba "$ssh_dir/authorized_keys"
                else
                    warn "尚无授权公钥"
                fi
                ;;
            2)
                echo "请粘贴公钥内容:"
                read -rp "公钥: " new_pubkey
                if [[ -n "$new_pubkey" ]]; then
                    if ! [[ "$new_pubkey" =~ ^(ssh-(rsa|ed25519|dss)|ecdsa-sha2-nistp) ]]; then
                        warn "公钥格式看起来不太对，确认继续吗？"
                        read -rp "继续? [y/N]: " confirm
                        if [[ ! "$confirm" =~ ^[Yy] ]]; then
                            continue
                        fi
                    fi
                    mkdir -p "$ssh_dir"
                    chmod 700 "$ssh_dir"
                    # 原子追加
                    atomic_append "$ssh_dir/authorized_keys" "$new_pubkey"
                    chmod 600 "$ssh_dir/authorized_keys"
                    chown -R "$username:$username" "$ssh_dir"
                    success "公钥已添加"
                fi
                ;;
            3)
                if [[ -f "$ssh_dir/authorized_keys" ]]; then
                    local total_lines
                    total_lines=$(wc -l < "$ssh_dir/authorized_keys")
                    echo ""
                    nl -ba "$ssh_dir/authorized_keys"
                    echo ""
                    read -rp "输入要删除的行号 (1-$total_lines): " line_num
                    if [[ "$line_num" =~ ^[0-9]+$ ]] && [[ "$line_num" -ge 1 ]] && [[ "$line_num" -le "$total_lines" ]]; then
                        # 原子删除
                        atomic_delete_line "$ssh_dir/authorized_keys" "$line_num"
                        chown "$username:$username" "$ssh_dir/authorized_keys"
                        success "第 $line_num 行已删除"
                    else
                        error "无效行号，请输入 1-$total_lines 之间的数字"
                    fi
                else
                    warn "尚无授权公钥"
                fi
                ;;
            4)
                setup_ssh_key "$username"
                ;;
            5)
                break
                ;;
            *)
                error "无效选择"
                ;;
        esac
    done

    press_any_key
}

# ============================================================
#  5. 锁定/解锁用户
# ============================================================
lock_unlock_user() {
    echo -e "\n${BOLD}========== 锁定/解锁用户 ==========${NC}"

    list_users_brief
    echo ""

    read -rp "请输入用户名: " username
    if [[ -z "$username" ]]; then
        error "用户名不能为空"
        press_any_key
        return 1
    fi
    if ! [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        error "用户名格式不合法"
        press_any_key
        return 1
    fi
    if ! id "$username" &>/dev/null; then
        error "用户不存在"
        press_any_key
        return 1
    fi

    if [[ "$(id -u "$username")" -eq 0 ]]; then
        error "不能锁定 root 用户！"
        press_any_key
        return 1
    fi

    if passwd -S "$username" 2>/dev/null | grep -q "L"; then
        echo -e "当前状态: ${RED}锁定${NC}"
        read -rp "是否解锁用户 '$username'? [Y/n]: " unlock
        unlock="${unlock:-Y}"
        if [[ "$unlock" =~ ^[Yy] ]]; then
            # 解锁前先保存当前 shell
            local prev_shell
            prev_shell=$(getent passwd "$username" | cut -d: -f7)
            passwd -u "$username"
            usermod -U "$username" 2>/dev/null || true
            # 如果之前被改成了 nologin，恢复为 bash
            if [[ "$prev_shell" == "/usr/sbin/nologin" ]]; then
                read -rp "Shell 是 nologin，是否恢复为 /bin/bash? [Y/n]: " restore_shell
                restore_shell="${restore_shell:-Y}"
                if [[ "$restore_shell" =~ ^[Yy] ]]; then
                    usermod -s /bin/bash "$username"
                    success "Shell 已恢复为 /bin/bash"
                fi
            fi
            success "用户 '$username' 已解锁"
        fi
    else
        echo -e "当前状态: ${GREEN}正常${NC}"
        echo "  1) 锁定用户（禁止密码登录）"
        echo "  2) 锁定并禁用 SSH（同时改 shell 为 nologin）"
        echo "  3) 取消"
        read -rp "请选择 [1-3, 默认 3]: " lock_type
        lock_type="${lock_type:-3}"

        if [[ "$lock_type" == "1" || "$lock_type" == "2" ]]; then
            read -rp "确认锁定用户 '$username'? [y/N]: " lock_confirm
            if [[ ! "$lock_confirm" =~ ^[Yy] ]]; then
                info "操作取消"
                press_any_key
                return 0
            fi

            # 保存当前状态用于回滚
            local prev_shell
            prev_shell=$(getent passwd "$username" | cut -d: -f7)
            rollback_push "usermod -s '$prev_shell' '$username' 2>/dev/null || true"
            rollback_push "passwd -u '$username' 2>/dev/null; usermod -U '$username' 2>/dev/null || true"

            passwd -l "$username"
            usermod -L "$username" 2>/dev/null || true
            if [[ "$lock_type" == "2" ]]; then
                usermod -s /usr/sbin/nologin "$username"
                success "用户 '$username' 已锁定（密码+SSH 均禁用）"
            else
                success "用户 '$username' 已锁定（密码登录禁用）"
            fi
            # 锁定成功，清回滚
            rollback_clear
        fi
    fi

    press_any_key
}

# ============================================================
#  6. 修改用户信息
# ============================================================
modify_user() {
    echo -e "\n${BOLD}========== 修改用户 ==========${NC}"

    list_users_brief
    echo ""

    read -rp "请输入用户名: " username
    if [[ -z "$username" ]]; then
        error "用户名不能为空"
        press_any_key
        return 1
    fi
    if ! [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        error "用户名格式不合法"
        press_any_key
        return 1
    fi
    if ! id "$username" &>/dev/null; then
        error "用户不存在"
        press_any_key
        return 1
    fi

    local current_shell
    current_shell=$(getent passwd "$username" | cut -d: -f7)

    while true; do
        echo ""
        echo "--- 修改用户: $username ---"
        echo "  1) 修改 Shell          当前: $current_shell"
        echo "  2) 修改密码"
        echo "  3) 切换 sudo 权限"
        echo "  4) 添加到附加组"
        echo "  5) 返回主菜单"
        read -rp "请选择 [1-5]: " mod_choice

        case "$mod_choice" in
            1)
                echo "选择新 Shell:"
                echo "  1) /bin/bash"
                echo "  2) /bin/zsh"
                echo "  3) /bin/sh"
                echo "  4) /usr/sbin/nologin"
                read -rp "请选择 [1-4]: " new_shell
                case "$new_shell" in
                    1) usermod -s /bin/bash "$username"; current_shell="/bin/bash" ;;
                    2) usermod -s /bin/zsh "$username"; current_shell="/bin/zsh" ;;
                    3) usermod -s /bin/sh "$username"; current_shell="/bin/sh" ;;
                    4) usermod -s /usr/sbin/nologin "$username"; current_shell="/usr/sbin/nologin" ;;
                    *) warn "无效选择" ;;
                esac
                success "Shell 已修改为 $current_shell"
                ;;
            2)
                passwd "$username"
                success "密码已修改"
                ;;
            3)
                if groups "$username" 2>/dev/null | grep -qE '\b(sudo|wheel)\b' || [[ -f "/etc/sudoers.d/$username" ]]; then
                    echo "当前有 sudo 权限。"
                    echo "  1) 移除 sudo 权限"
                    echo "  2) 切换为免密 sudo"
                    echo "  3) 取消"
                    read -rp "请选择 [1-3]: " rm_sudo
                    case "$rm_sudo" in
                        1)
                            gpasswd -d "$username" sudo 2>/dev/null || true
                            gpasswd -d "$username" wheel 2>/dev/null || true
                            rm -f "/etc/sudoers.d/$username"
                            success "sudo 权限已移除"
                            ;;
                        2)
                            local sf="/etc/sudoers.d/$username"
                            atomic_write "$sf" "$username ALL=(ALL) NOPASSWD:ALL"
                            chmod 440 "$sf"
                            check_sudoers "$sf" && success "已切换为免密 sudo" || { rm -f "$sf"; error "语法错误，已回滚"; }
                            ;;
                        *)
                            info "操作取消"
                            ;;
                    esac
                else
                    echo "当前无 sudo 权限。"
                    echo "  1) 授予免密 sudo (NOPASSWD)"
                    echo "  2) 授予需要密码的 sudo"
                    echo "  3) 取消"
                    read -rp "请选择 [1-3]: " add_sudo
                    case "$add_sudo" in
                        1)
                            local sf="/etc/sudoers.d/$username"
                            atomic_write "$sf" "$username ALL=(ALL) NOPASSWD:ALL"
                            chmod 440 "$sf"
                            check_sudoers "$sf" && success "已授予免密 sudo" || { rm -f "$sf"; error "语法错误，已回滚"; }
                            ;;
                        2)
                            if getent group sudo &>/dev/null; then
                                usermod -aG sudo "$username"
                            elif getent group wheel &>/dev/null; then
                                usermod -aG wheel "$username"
                            else
                                local sf="/etc/sudoers.d/$username"
                                atomic_write "$sf" "$username ALL=(ALL:ALL) ALL"
                                chmod 440 "$sf"
                                check_sudoers "$sf" || { rm -f "$sf"; warn "语法错误，已跳过"; }
                            fi
                            success "已授予 sudo 权限"
                            ;;
                        *)
                            info "操作取消"
                            ;;
                    esac
                fi
                ;;
            4)
                echo "常见组: docker, www-data, nginx, redis, mysql"
                read -rp "输入要加入的组名: " group_name
                if [[ -n "$group_name" ]]; then
                    if ! [[ "$group_name" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
                        error "组名格式不合法"
                        continue
                    fi
                    if ! getent group "$group_name" &>/dev/null; then
                        warn "组 '$group_name' 不存在，是否创建?"
                        read -rp "[Y/n]: " cg
                        if [[ "${cg:-Y}" =~ ^[Yy] ]]; then
                            groupadd "$group_name"
                        else
                            continue
                        fi
                    fi
                    usermod -aG "$group_name" "$username"
                    success "已将 '$username' 加入 '$group_name' 组"
                fi
                ;;
            5)
                break
                ;;
            *)
                error "无效选择"
                ;;
        esac
    done

    press_any_key
}

# ============================================================
#  7. SSH 安全加固
# ============================================================
security_hardening() {
    echo -e "\n${BOLD}========== SSH 安全加固 ==========${NC}"

    local sshd_config="/etc/ssh/sshd_config"

    echo "当前 SSH 配置:"
    echo "──────────────────"
    for key in PermitRootLogin PasswordAuthentication PubkeyAuthentication MaxAuthTries Port; do
        local val
        val=$(grep -E "^\s*${key}\s" "$sshd_config" 2>/dev/null | awk '{print $2}' || echo "未设置")
        printf "  %-28s %s\n" "$key" "$val"
    done
    echo ""

    echo -e "${RED}!!! 危险操作警告 !!!${NC}"
    echo -e "${RED}这些操作可能让你永久失去对服务器的访问权限！${NC}"
    echo ""
    echo "加固选项:"
    echo "  1) 禁止 root SSH 登录 (PermitRootLogin no)"
    echo "  2) 禁用密码登录 (PasswordAuthentication no)"
    echo "  3) 修改 SSH 端口"
    echo "  4) 一键全部加固 (1+2+3)"
    echo "  5) 返回"
    echo ""
    read -rp "请选择 [1-5, 默认 5]: " harden_choice
    harden_choice="${harden_choice:-5}"

    if [[ "$harden_choice" =~ ^[1-4]$ ]]; then
        # 安全网检查
        if ! safety_net_check "SSH 安全加固 (选项 $harden_choice)"; then
            press_any_key
            return 0
        fi
        echo ""
        echo -e "${YELLOW}请确认：${NC}"
        echo "  1. 你已经用新用户成功 SSH 登录过"
        echo "  2. 新用户的 sudo 权限已验证可用"
        echo "  3. 你有云控制台 VNC 作为后路"
        echo ""
        read -rp "以上都已确认? 输入 YES 继续 [默认 N]: " harden_confirm
        if [[ "$harden_confirm" != "YES" ]]; then
            info "操作取消"
            press_any_key
            return 0
        fi
    fi

    _SSHD_BAK_TAG=""

    case "$harden_choice" in
        1)
            set_ssh_config_value "PermitRootLogin" "no"
            restart_sshd_safely
            ;;
        2)
            set_ssh_config_value "PasswordAuthentication" "no"
            restart_sshd_safely
            ;;
        3)
            read -rp "输入新端口号 (1024-65535): " new_port
            if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [[ "$new_port" -lt 1024 ]] || [[ "$new_port" -gt 65535 ]]; then
                error "无效端口号"
                press_any_key
                return 1
            fi
            set_ssh_config_value "Port" "$new_port"
            if restart_sshd_safely; then
                warn "端口已改为 $new_port，连接时需要: ssh -p $new_port user@host"
                warn "请确保防火墙已放行新端口！"
            fi
            ;;
        4)
            set_ssh_config_value "PermitRootLogin" "no"
            set_ssh_config_value "PasswordAuthentication" "no"
            read -rp "输入新端口号 (1024-65535, 留空保持 22): " new_port
            if [[ -n "$new_port" ]]; then
                if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [[ "$new_port" -lt 1024 ]] || [[ "$new_port" -gt 65535 ]]; then
                    error "无效端口号，跳过端口修改"
                else
                    set_ssh_config_value "Port" "$new_port"
                fi
            fi
            if restart_sshd_safely; then
                success "安全加固完成！"
            fi
            ;;
        *)
            return
            ;;
    esac

    press_any_key
}

# ============================================================
#  主菜单
# ============================================================
show_banner() {
    clear
    echo -e "${CYAN}"
    cat << 'EOF'
  ============================================
    SSH 用户管理工具 v4.0
    Interactive User Manager
    (信号捕获 + 原子写入 + 中断回滚 + 安全网)
  ============================================
EOF
    echo -e "${NC}"
    echo -e "  主机: ${BOLD}$(hostname)${NC}  |  系统: $(lsb_release -ds 2>/dev/null || cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')"
    echo -e "  内核: $(uname -r)  |  用户总数: $(grep -c ':[0-9]\{4,\}:' /etc/passwd 2>/dev/null || echo "?")"
    echo ""
}

main_menu() {
    while true; do
        show_banner
        echo -e "  ${BOLD}请选择操作:${NC}"
        echo ""
        echo "  1) 👤 	创建新用户"
        echo "  2) 🗑️  	删除用户"
        echo "  3) 📋 	列出所有用户"
        echo "  4) 🔑 	管理 SSH 密钥"
        echo "  5) 🔒 	锁定/解锁用户"
        echo "  6) ✏️  	修改用户信息"
        echo "  7) 🛡️  	SSH 安全加固"
        echo "  0) 🚪 	退出"
        echo ""
        read -rp "  请选择 [0-7]: " choice

        case "$choice" in
            1) create_user ;;
            2) delete_user ;;
            3) list_users ;;
            4) manage_ssh_keys ;;
            5) lock_unlock_user ;;
            6) modify_user ;;
            7) security_hardening ;;
            0)
                # 退出前检查是否有未完成操作
                if [[ -n "$_CURRENT_CREATING_USER" ]] || [[ ${#_ROLLBACK_STACK[@]} -gt 0 ]]; then
                    warn "检测到未完成的操作！"
                    read -rp "强制退出? [y/N]: " force_exit
                    if [[ ! "$force_exit" =~ ^[Yy] ]]; then
                        continue
                    fi
                fi
                echo -e "\n  再见！\n"
                exit 0
                ;;
            *)
                error "无效选择，请重新输入"
                sleep 1
                ;;
        esac
    done
}

# ---------- 入口 ----------
check_root

if [[ "$_IS_ROOT" != "true" ]]; then
    diagnostic_mode
else
    main_menu
fi
