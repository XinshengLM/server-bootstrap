#!/usr/bin/env bash
# ============================================================
#  共享工作区配置脚本 (Shared Workspace Setup) v2.0
#  功能：创建共享目录、配置权限、管理用户访问
#  特性：信号捕获 + 原子写入 + 中断回滚 + 不改全局 umask
#  用法：sudo bash shared-workspace-setup.sh
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
declare -ga _WS_ROLLBACK=()

ws_rollback_push() {
    _WS_ROLLBACK+=("$*")
}

ws_rollback_clear() {
    _WS_ROLLBACK=()
}

ws_rollback_execute() {
    if [[ ${#_WS_ROLLBACK[@]} -eq 0 ]]; then return 0; fi
    echo ""
    error "=== 共享工作区：正在回滚 ==="
    local count=${#_WS_ROLLBACK[@]}
    for (( i=count-1; i>=0; i-- )); do
        echo -e "  ${YELLOW}回滚: ${_WS_ROLLBACK[$i]}${NC}"
        eval "${_WS_ROLLBACK[$i]}" 2>/dev/null || true
    done
    error "=== 回滚完成 ==="
    _WS_ROLLBACK=()
}

ws_handle_interrupt() {
    local sig="${1:-}"
    # EXIT 在正常退出时静默处理，只在有回滚时执行
    if [[ "$sig" == "EXIT" ]]; then
        if [[ ${#_WS_ROLLBACK[@]} -gt 0 ]]; then
            ws_rollback_execute
        fi
        return 0
    fi

    echo ""
    error "!!! 检测到中断信号 !!!"
    if [[ ${#_WS_ROLLBACK[@]} -gt 0 ]]; then
        echo -e "  ${RED}选项：${NC}"
        echo "  1) 回滚 (推荐)"
        echo "  2) 保留当前状态"
        read -t 10 -rp "请选择 [1-2, 默认 1]: " ic 2>/dev/null || true
        ic="${ic:-1}"
        [[ "$ic" == "1" ]] && ws_rollback_execute
    fi
    echo "按 Enter 返回..."
}

trap 'ws_handle_interrupt SIGINT' SIGINT
trap 'ws_handle_interrupt SIGTERM' SIGTERM
trap 'ws_handle_interrupt SIGHUP' SIGHUP
trap 'ws_handle_interrupt EXIT' EXIT

# ============================================================
#  前置检查
# ============================================================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "此脚本需要 root 权限运行。请使用: sudo bash $0"
        exit 1
    fi
}

# ---------- 配置变量 ----------
SHARED_GROUP="sharedwork"
SHARED_DIR="/home/workspace"

# ============================================================
#  原子写入工具
# ============================================================
ws_atomic_write() {
    local target="$1"
    local content="$2"
    local tmpfile="${target}.tmp.$$"
    printf '%s\n' "$content" > "$tmpfile" || { rm -f "$tmpfile"; return 1; }
    mv -f "$tmpfile" "$target" || { rm -f "$tmpfile"; return 1; }
}

ws_atomic_write_heredoc() {
    local target="$1"
    local tmpfile="${target}.tmp.$$"
    cat > "$tmpfile" || { rm -f "$tmpfile"; return 1; }
    mv -f "$tmpfile" "$target" || { rm -f "$tmpfile"; return 1; }
}

# ============================================================
#  1. 初始化共享工作区
# ============================================================
init_workspace() {
    echo -e "\n${BOLD}========== 初始化共享工作区 ==========${NC}"

    read -rp "共享目录路径 [默认 $SHARED_DIR]: " custom_dir
    SHARED_DIR="${custom_dir:-$SHARED_DIR}"

    read -rp "共享组名 [默认 $SHARED_GROUP]: " custom_group
    SHARED_GROUP="${custom_group:-$SHARED_GROUP}"

    # 输入校验
    if ! [[ "$SHARED_GROUP" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        error "组名格式不合法"
        press_any_key
        return 1
    fi

    # 路径安全校验
    # 1. 必须是绝对路径
    if [[ "$SHARED_DIR" != /* ]]; then
        error "共享目录必须是绝对路径 (以 / 开头)"
        press_any_key
        return 1
    fi
    # 2. 路径字符白名单：只允许字母、数字、-、_、/、.
    #    防止 $() `` 等命令注入
    if ! [[ "$SHARED_DIR" =~ ^[a-zA-Z0-9_/\-.]+$ ]]; then
        error "路径含非法字符（只允许字母、数字、-、_、/）"
        press_any_key
        return 1
    fi
    # 3. 去除尾部斜杠，然后用 readlink -f 或手动规范化
    SHARED_DIR="${SHARED_DIR%/}"
    # 使用 readlink -f 规范化路径（解析 .. 和符号链接）
    if command -v readlink &>/dev/null; then
        local resolved
        resolved=$(readlink -f "$SHARED_DIR" 2>/dev/null || echo "$SHARED_DIR")
        SHARED_DIR="$resolved"
    else
        # 没有 readlink 时，用 cd 规范化（目录必须已存在才有效）
        local normalized
        normalized=$(cd "$SHARED_DIR" 2>/dev/null && pwd || echo "$SHARED_DIR")
        SHARED_DIR="$normalized"
    fi
    # 4. 禁止系统关键目录（精确匹配，规范化后的路径）
    local -a forbidden_paths=("/" "/root" "/home" "/etc" "/var" "/usr" "/bin" "/sbin" "/lib" "/boot" "/dev" "/proc" "/sys" "/tmp" "/opt" "/run" "/srv")
    for fp in "${forbidden_paths[@]}"; do
        if [[ "$SHARED_DIR" == "$fp" ]]; then
            error "禁止使用系统目录 '$SHARED_DIR'"
            press_any_key
            return 1
        fi
    done
    # 5. 路径深度至少 2 层（如 /home/workspace），不允许 /xxx
    local depth
    depth=$(echo "$SHARED_DIR" | tr -cd '/' | wc -c)
    if [[ "$depth" -lt 2 ]]; then
        error "共享目录路径太浅，至少需要 2 层（如 /home/workspace）"
        press_any_key
        return 1
    fi

    echo ""
    info "配置信息:"
    echo "  共享目录: $SHARED_DIR"
    echo "  共享组:   $SHARED_GROUP"
    echo ""

    # ---- 创建共享组 ----
    if ! getent group "$SHARED_GROUP" &>/dev/null; then
        groupadd "$SHARED_GROUP"
        ws_rollback_push "groupdel '$SHARED_GROUP' 2>/dev/null || true"
        success "共享组 '$SHARED_GROUP' 已创建 (GID: $(getent group "$SHARED_GROUP" | cut -d: -f3))"
    else
        info "共享组 '$SHARED_GROUP' 已存在"
    fi

    # ---- 创建目录结构 ----
    info "正在创建目录结构..."
    mkdir -p "$SHARED_DIR"/{projects,documents,scripts,backup,resources,tmp}
    ws_rollback_push "rm -rf '$SHARED_DIR' 2>/dev/null || true"
    success "目录结构已创建"

    # ---- 设置权限 ----
    info "正在配置权限..."
    chgrp -R "$SHARED_GROUP" "$SHARED_DIR"
    # 目录: 2775 (SGID)
    find "$SHARED_DIR" -type d -exec chmod 2775 {} \;
    # 文件: 664
    find "$SHARED_DIR" -type f -exec chmod 664 {} \; 2>/dev/null || true
    # tmp: sticky bit
    chmod 3777 "$SHARED_DIR/tmp"

    success "权限已配置"

    # ---- 配置 ACL ----
    if command -v setfacl &>/dev/null; then
        info "正在配置 ACL..."
        setfacl -R -m g:"$SHARED_GROUP":rwx "$SHARED_DIR" 2>/dev/null || true
        setfacl -R -d -m g:"$SHARED_GROUP":rwx "$SHARED_DIR" 2>/dev/null || true
        setfacl -R -d -m o::rx "$SHARED_DIR" 2>/dev/null || true
        success "ACL 已配置"
    else
        warn "setfacl 未安装，跳过 ACL。安装: apt install acl"
    fi

    # ---- 配置共享 profile（不改全局 umask！）----
    setup_shared_profile

    # ---- 配置 tmp 自动清理 ----
    setup_tmp_cleanup

    # ---- 生成使用指南 ----
    generate_guide_silent

    # ---- 初始化完成 ----
    ws_rollback_clear

    echo ""
    success "========== 共享工作区初始化完成 =========="
    echo -e "  路径:  ${CYAN}$SHARED_DIR${NC}"
    echo -e "  组:    ${CYAN}$SHARED_GROUP${NC}"
    echo -e "  结构:"
    echo -e "    $SHARED_DIR/"
    echo -e "    ├── projects/   项目文件"
    echo -e "    ├── documents/  文档资料"
    echo -e "    ├── scripts/    脚本工具"
    echo -e "    ├── backup/     备份"
    echo -e "    ├── resources/  资源/素材（安装包、镜像、大文件）"
    echo -e "    └── tmp/        临时文件 (自动清理)"
    echo ""

    press_any_key
}

# ============================================================
#  配置共享环境（v2 关键改动：不改全局 umask）
#
#  v1 的致命错误：直接 umask 002 写入 /etc/profile.d/
#  → 影响所有用户所有目录的默认权限
#  → 如果共享目录初始化中途失败，umask 已生效
#
#  v2 方案：只在共享目录内通过 SGID + ACL 保证组权限
#  不修改全局 umask，不给系统带来副作用
# ============================================================
setup_shared_profile() {
    local profile_file="/etc/profile.d/shared-workspace.sh"

    info "正在配置共享环境快捷命令..."

    # 注意：不写 umask！只写快捷别名和环境变量
    ws_atomic_write_heredoc "$profile_file" << PROFILE_EOF
#!/bin/bash
# Shared Workspace 快捷命令
# 注意：不修改全局 umask，共享目录权限通过 SGID + ACL 保证
export SHARED_DIR="$SHARED_DIR"
alias ws="cd $SHARED_DIR"
alias projects="cd $SHARED_DIR/projects"
alias docs="cd $SHARED_DIR/documents"
alias scripts="cd $SHARED_DIR/scripts"
alias shareinfo="echo '共享目录: $SHARED_DIR'; echo '你的文件:'; find $SHARED_DIR -maxdepth 3 -user \$(whoami) -type f 2>/dev/null | head -20"
PROFILE_EOF

    chmod 644 "$profile_file"
    ws_rollback_push "rm -f '$profile_file'"
    success "快捷命令已配置 (不含全局 umask 修改)"
    info "共享目录权限由 SGID 位 + ACL 保证，不影响系统其他目录"
}

# ============================================================
#  配置 tmp 定时清理
# ============================================================
setup_tmp_cleanup() {
    local cron_file="/etc/cron.d/shared-workspace-cleanup"
    local tmpfile="${cron_file}.tmp.$$"

    info "正在配置 tmp 自动清理 (每天凌晨 3 点清理 >7 天的文件)..."

    # 原子写入 cron 文件
    {
        echo "# 每天凌晨 3 点清理共享 tmp 目录中超过 7 天的文件"
        echo "0 3 * * * root find \"$SHARED_DIR/tmp\" -type f -mtime +7 -delete 2>/dev/null"
        echo "0 3 * * * root find \"$SHARED_DIR/tmp\" -type d -empty -mtime +7 -delete 2>/dev/null"
    } > "$tmpfile"
    chmod 644 "$tmpfile"
    mv -f "$tmpfile" "$cron_file"

    ws_rollback_push "rm -f '$cron_file'"
    success "tmp 自动清理已配置 ($cron_file)"
}

# ============================================================
#  2. 管理用户访问
# ============================================================
manage_users() {
    echo -e "\n${BOLD}========== 管理共享工作区用户 ==========${NC}"
    echo ""
    echo "当前 '$SHARED_GROUP' 组成员:"
    echo "──────────────────────────"
    local members
    members=$(getent group "$SHARED_GROUP" 2>/dev/null | cut -d: -f4) || members=""
    if [[ -n "$members" ]]; then
        echo "$members" | tr ',' '\n' | nl -ba
    else
        echo "  (无)"
    fi
    echo ""

    while true; do
                echo "  1) ➕ 添加用户到共享组"
                echo "  2) ➖ 从共享组移除用户"
                echo "  3) 💾 查看用户磁盘使用"
                echo "  4) 📦 批量添加所有普通用户"
                echo "  5) ↩️  返回主菜单"
        read -rp "请选择 [1-5]: " user_action

        case "$user_action" in
            1)
                echo ""
                echo "可添加的用户:"
                echo "──────────────"
                while IFS=: read -r u _ uid _ _ _ _; do
                    [[ "$uid" -lt 1000 || "$uid" -ge 65534 ]] && continue
                    if ! id -nG "$u" | grep -qw "$SHARED_GROUP"; then
                        echo "  $u (UID: $uid)"
                    fi
                done < /etc/passwd
                echo ""
                read -rp "输入用户名 (多个用空格分隔): " usernames
                for u in $usernames; do
                    if [[ "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && id "$u" &>/dev/null; then
                        usermod -aG "$SHARED_GROUP" "$u"
                        success "'$u' 已加入 '$SHARED_GROUP'"
                    else
                        error "'$u' 不存在或格式不合法"
                    fi
                done
                ;;
            2)
                read -rp "输入要移除的用户名: " username
                if [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && id "$username" &>/dev/null; then
                    gpasswd -d "$username" "$SHARED_GROUP"
                    success "'$username' 已从 '$SHARED_GROUP' 移除"
                else
                    error "'$username' 不存在"
                fi
                ;;
            3)
                echo ""
                echo "共享目录磁盘使用:"
                echo "──────────────────"
                if [[ -d "$SHARED_DIR" ]]; then
                    du -sh "$SHARED_DIR" 2>/dev/null || echo "  无法统计"
                    echo ""
                    echo "按用户统计:"
                    local member_list
                    member_list=$(getent group "$SHARED_GROUP" 2>/dev/null | cut -d: -f4) || member_list=""
                    if [[ -n "$member_list" ]]; then
                        for u in $(echo "$member_list" | tr ',' ' '); do
                            if [[ -n "$u" ]]; then
                                local fcount
                                fcount=$(find "$SHARED_DIR" -user "$u" -type f 2>/dev/null | wc -l)
                                if [[ "$fcount" -gt 0 ]]; then
                                    usage=$(find "$SHARED_DIR" -user "$u" -type f -exec du -ch {} + 2>/dev/null | tail -1 | cut -f1)
                                else
                                    usage="0"
                                fi
                                printf "  %-16s %s\n" "$u" "$usage"
                            fi
                        done
                    else
                        echo "  (无成员)"
                    fi
                else
                    warn "共享目录不存在"
                fi
                ;;
            4)
                info "将所有普通用户加入 '$SHARED_GROUP'..."
                count=0
                while IFS=: read -r u _ uid _ _ _ _; do
                    [[ "$uid" -lt 1000 || "$uid" -ge 65534 ]] && continue
                    if ! id -nG "$u" | grep -qw "$SHARED_GROUP"; then
                        usermod -aG "$SHARED_GROUP" "$u"
                        echo "  + $u"
                        count=$((count + 1))
                    fi
                done < /etc/passwd
                success "已添加 $count 个用户"
                ;;
            5) break ;;
            *) error "无效选择" ;;
        esac
        echo ""
    done

    press_any_key
}

# ============================================================
#  3. 目录权限管理
# ============================================================
manage_permissions() {
    echo -e "\n${BOLD}========== 目录权限管理 ==========${NC}"

    if [[ ! -d "$SHARED_DIR" ]]; then
        error "共享目录 '$SHARED_DIR' 不存在，请先初始化"
        press_any_key
        return 1
    fi

    echo "当前 $SHARED_DIR 权限:"
    echo "──────────────────"
    ls -la "$SHARED_DIR"/ 2>/dev/null | head -20
    echo ""

    echo "  1) 🔧 修复权限 (重置为正确的共享权限)"
    echo "  2) 📖 设置子目录为只读"
    echo "  3) 🔒 设置子目录私有 (仅创建者可写)"
    echo "  4) 🔍 查看指定文件/目录的详细权限"
    echo "  5) 返回主菜单"
    read -rp "请选择 [1-5]: " perm_action

    case "$perm_action" in
        1)
            read -rp "确认修复 $SHARED_DIR 的所有权限? [y/N]: " pc
            [[ ! "$pc" =~ ^[Yy] ]] && { info "取消"; press_any_key; return 0; }
            info "正在修复所有权限..."
            chgrp -R "$SHARED_GROUP" "$SHARED_DIR"
            find "$SHARED_DIR" -type d -exec chmod 2775 {} \;
            find "$SHARED_DIR" -type f -exec chmod 664 {} \;
            chmod 3777 "$SHARED_DIR/tmp"
            if command -v setfacl &>/dev/null; then
                setfacl -R -m g:"$SHARED_GROUP":rwx "$SHARED_DIR" 2>/dev/null || true
                setfacl -R -d -m g:"$SHARED_GROUP":rwx "$SHARED_DIR" 2>/dev/null || true
            fi
            success "权限已修复"
            ;;
        2)
            read -rp "输入子目录名 (如 resources): " subdir
            if ! [[ "$subdir" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                error "子目录名不合法"; press_any_key; return 1
            fi
            local target="$SHARED_DIR/$subdir"
            if [[ -d "$target" ]]; then
                chmod -R 2755 "$target"
                success "'$target' 已设为只读"
            else
                error "'$target' 不存在"
            fi
            ;;
        3)
            read -rp "输入子目录名 (如 projects): " subdir
            if ! [[ "$subdir" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                error "子目录名不合法"; press_any_key; return 1
            fi
            local target="$SHARED_DIR/$subdir"
            if [[ -d "$target" ]]; then
                chmod 3775 "$target"
                success "'$target' 已设为私有模式 (sticky bit)"
            else
                error "'$target' 不存在"
            fi
            ;;
        4)
            read -rp "输入文件/目录路径 (相对于 $SHARED_DIR/): " target
            local full_path="$SHARED_DIR/$target"
            if [[ -e "$full_path" ]]; then
                echo ""
                ls -la "$full_path"
                command -v getfacl &>/dev/null && { echo ""; getfacl "$full_path" 2>/dev/null; }
            else
                error "'$full_path' 不存在"
            fi
            ;;
        *) return ;;
    esac

    press_any_key
}

# ============================================================
#  4. 生成使用指南（静默版，初始化时调用）
# ============================================================
generate_guide_silent() {
    local guide_file="$SHARED_DIR/README-共享工作区使用指南.md"

    ws_atomic_write_heredoc "$guide_file" << GUIDE
# 共享工作区使用指南

## 目录结构

\`\`\`
$(basename "$SHARED_DIR")/
├── projects/    项目文件
├── documents/   文档资料
├── scripts/     脚本工具
├── backup/      备份文件
├── resources/   资源/素材（安装包、镜像、大文件）
└── tmp/         临时文件 (自动清理 >7天)
\`\`\`

## 快捷命令

| 命令 | 功能 |
|------|------|
| \`ws\` | 快速进入共享目录 |
| \`projects\` | 进入 projects 子目录 |
| \`shareinfo\` | 查看你在共享目录中的文件 |

## 使用规范

1. 按分类存放 — 文件放到对应的子目录中
2. tmp 目录 — 临时文件放 tmp，超过 7 天自动清理
3. 不要删别人的文件
4. 大文件放 resources

## 权限说明

- 所有共享组成员都可以读写
- 新文件通过 SGID + ACL 自动继承共享组权限
- tmp 目录有 sticky bit 保护，只能删自己的文件
GUIDE

    chgrp "$SHARED_GROUP" "$guide_file" 2>/dev/null || true
    chmod 664 "$guide_file"
    success "使用指南已生成: $guide_file"
}

# 交互版
generate_guide() {
    echo -e "\n${BOLD}========== 使用指南 ==========${NC}"
    generate_guide_silent
    [[ -f "$SHARED_DIR/README-共享工作区使用指南.md" ]] && cat "$SHARED_DIR/README-共享工作区使用指南.md"
    press_any_key
}

# ============================================================
#  5. 状态总览
# ============================================================
show_status() {
    echo -e "\n${BOLD}========== 共享工作区状态 ==========${NC}"
    echo ""

    if [[ ! -d "$SHARED_DIR" ]]; then
        warn "共享目录 '$SHARED_DIR' 不存在，请先初始化"
        press_any_key
        return 1
    fi

    echo -e "${BOLD}[ 基本信息 ]${NC}"
    echo "  路径:       $SHARED_DIR"
    echo "  共享组:     $SHARED_GROUP"
    local gid; gid=$(getent group "$SHARED_GROUP" 2>/dev/null | cut -d: -f3) || gid=""
    echo "  GID:        ${gid:-不存在}"
    echo ""

    echo -e "${BOLD}[ 磁盘使用 ]${NC}"
    du -sh "$SHARED_DIR" 2>/dev/null || echo "  无法统计"
    echo ""
    echo "  子目录大小:"
    for d in "$SHARED_DIR"/*/; do
        [[ -d "$d" ]] && printf "    %-20s %s\n" "$(basename "$d")" "$(du -sh "$d" 2>/dev/null | cut -f1)"
    done
    echo ""

    echo -e "${BOLD}[ 共享组成员 ]${NC}"
    members=$(getent group "$SHARED_GROUP" 2>/dev/null | cut -d: -f4) || members=""
    if [[ -n "$members" ]]; then
        for m in $(echo "$members" | tr ',' ' '); do
            printf "  %-16s\n" "$m"
        done
    else
        echo "  (无成员)"
    fi
    echo ""

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
    共享工作区管理工具 v2.0
    Shared Workspace Manager
    (信号捕获 + 原子写入 + 不改全局 umask)
  ============================================
EOF
    echo -e "${NC}"
    if [[ -d "$SHARED_DIR" ]]; then
        echo -e "  共享目录: ${GREEN}$SHARED_DIR${NC}  |  状态: ${GREEN}已初始化${NC}"
    else
        echo -e "  共享目录: $SHARED_DIR  |  状态: ${YELLOW}未初始化${NC}"
    fi
    echo -e "  共享组:   $SHARED_GROUP"
    echo ""
}

main_menu() {
    while true; do
        show_banner
        echo -e "  ${BOLD}请选择操作:${NC}"
        echo ""
        echo "  1) 🚀 初始化共享工作区"
        echo "  2) 👥 管理用户访问"
        echo "  3) 🔐 目录权限管理"
        echo "  4) 📝 生成使用指南"
        echo "  5) 📊 状态总览"
        echo "  0) 🚪 退出"
        echo ""
        read -rp "  请选择 [0-5]: " choice

        case "$choice" in
            1) init_workspace ;;
            2) manage_users ;;
            3) manage_permissions ;;
            4) generate_guide ;;
            5) show_status ;;
            0)
                if [[ ${#_WS_ROLLBACK[@]} -gt 0 ]]; then
                    warn "检测到未完成的操作！"
                    read -rp "强制退出? [y/N]: " fe
                    [[ ! "$fe" =~ ^[Yy] ]] && continue
                fi
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
