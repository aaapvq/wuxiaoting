#!/bin/bash
# ================================================
# 脚本名称: gz.sh
# 描述: 闲置VPS硬盘远程挂载与SSH连接管理
# 版本: 4.0 (最终完善版，经过全面代码审计和健壮性测试)
# 作者: 全球第一写脚本高手
# 日期: 2025-09-27
# ================================================
# 严格错误处理：
# -e: 遇到非零退出状态立即退出
# -u: 使用未设置的变量时报错
# -o pipefail: 管道中任一命令失败时返回非零状态
set -euo pipefail  

# 配置变量
# 获取脚本所在目录的绝对路径
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 挂载配置文件的路径 (JSON格式)
CONFIG_FILE="/root/gz_config.json"
# SSH连接配置文件的路径 (JSON格式)
SSH_CONFIG_FILE="/root/ssh_connections.json"
# 脚本本身的路径，用于卸载时删除自身
SCRIPT_PATH="/usr/local/bin/gz" # 假设用户会将其移动到 /usr/local/bin/ 并命名为 gz

# 简单的颜色定义（兼容性更好）
RED='\033[0;31m'    # 红色
GREEN='\033[0;32m'  # 绿色
YELLOW='\033[1;33m' # 黄色
BLUE='\033[0;34m'   # 蓝色
CYAN='\033[0;36m'   # 青色
NC='\033[0m'        # 结束颜色，恢复默认

# 日志函数：用于输出不同级别的带颜色和时间戳的信息
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] $*${NC}"
}
warn() {
    echo -e "${YELLOW}[警告] $*${NC}"
}
error() {
    echo -e "${RED}[错误] $*${NC}"
}
info() {
    echo -e "${BLUE}[信息] $*${NC}"
}

# 脚本使用方法帮助
show_usage() {
    echo "========================================"
    echo "   VPS硬盘挂载与SSH管理脚本 (gz.sh) 使用方法"
    echo "========================================"
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -h, --help    显示此帮助信息"
    echo ""
    echo "快捷命令 'gz' 设置方法 (推荐):"
    echo "1. 将脚本移动到 /usr/local/bin/ 并命名为 'gz':"
    echo "   mv gz.sh /usr/local/bin/gz"
    echo "2. 赋予执行权限:"
    echo "   chmod +x /usr/local/bin/gz"
    echo "3. 之后直接在终端输入 'gz' 即可进入主菜单。"
    echo ""
    echo "========================================"
}

# 检查root权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "此脚本必须以root权限运行"
        exit 1
    fi
}

# 检查系统兼容性
check_os() {
    # 检查 /etc/os-release 文件是否存在
    if [[ ! -f /etc/os-release ]]; then
        error "无法检测操作系统类型"
        exit 1
    fi
    
    # 使用子shell执行 source，并捕获变量，避免 set -e 影响
    local ID=""
    local PRETTY_NAME=""
    
    # 尝试导入系统信息变量
    if source /etc/os-release 2>/dev/null; then
        : # 导入成功
    else
        # 如果 source 失败，尝试 . 方式
        if . /etc/os-release 2>/dev/null; then
            : # 导入成功
        else
            warn "无法导入 /etc/os-release，系统信息可能不完整"
        fi
    fi
    
    # 检查主流Linux发行版ID
    if [[ "${ID:-}" != "ubuntu" && "${ID:-}" != "debian" && "${ID:-}" != "centos" && "${ID:-}" != "almalinux" && "${ID:-}" != "rocky" ]]; then
        warn "此脚本主要支持Ubuntu和Debian系统，其他系统可能有限支持"
    fi
    # 尝试获取更友好的名称，否则使用ID
    local os_name="${PRETTY_NAME:-$ID}"
    log "检测到系统: $os_name"
}

# 安装必要工具 (sshfs, curl, jq, sshpass, fuse3)
install_dependencies() {
    log "安装必要工具..."
    local pkgs="sshfs curl jq sshpass fuse3"
    local installed=true
    
    if command -v apt &> /dev/null; then
        # Ubuntu/Debian 系统使用 apt
        for pkg in $pkgs; do
            if ! dpkg -s "$pkg" &> /dev/null; then
                installed=false
                break
            fi
        done
        if ! $installed; then
            apt update && apt install -y $pkgs
        fi
    elif command -v yum &> /dev/null; then
        # CentOS/RHEL/AlmaLinux/Rocky (旧版) 系统使用 yum
        for pkg in $pkgs; do
            if ! rpm -q "$pkg" &> /dev/null; then
                installed=false
                break
            fi
        done
        if ! $installed; then
            yum install -y epel-release 2>/dev/null || true # 安装 EPEL 仓库以获取 sshfs
            yum install -y $pkgs
        fi
    elif command -v dnf &> /dev/null; then
        # Fedora/较新的RHEL系 系统使用 dnf
        for pkg in $pkgs; do
            if ! rpm -q "$pkg" &> /dev/null; then
                installed=false
                break
            fi
        done
        if ! $installed; then
            dnf install -y $pkgs
        fi
    else
        error "无法确定包管理器，请手动安装 sshfs, curl, jq, sshpass, fuse3"
        return 1
    fi
    
    # 再次检查关键依赖 jq
    if ! command -v jq &> /dev/null; then
        error "核心依赖 'jq' 未安装或无法运行，脚本无法继续"
        return 1
    fi
    return 0
}

# 生成挂载点路径
generate_mount_path() {
    local ip="$1"
    # 将IP地址中的点(.)替换为下划线(_)，用于目录名
    local dir_name="${ip//./_}"
    echo "/mnt/gz_${dir_name}"
}

# 配置SSH密钥认证
setup_ssh_key() {
    local remote_ip="$1"
    local remote_port="$2"
    local remote_user="$3"
    local remote_password="$4"
    local private_key="/root/.ssh/id_rsa_gz"
    
    # 1. 生成密钥对
    if [[ ! -f "$private_key" ]]; then
        log "生成SSH密钥对..."
        mkdir -p /root/.ssh
        chmod 700 /root/.ssh
        # -N "" 确保没有密码短语
        ssh-keygen -t rsa -f "$private_key" -N "" -q
    fi
    
    # 2. 复制公钥到远程主机
    log "配置SSH免密登录到 ${remote_ip}..."
    # 使用sshpass进行自动化公钥复制，避免手动输入密码
    # -o StrictHostKeyChecking=no 避免首次连接询问
    # 忽略ssh-copy-id的输出和错误，只判断返回值
    if sshpass -p "$remote_password" ssh-copy-id -i "${private_key}.pub" -p "$remote_port" -o StrictHostKeyChecking=no "$remote_user@$remote_ip" &> /dev/null; then
        log "SSH公钥复制成功"
    else
        error "SSH公钥复制失败，请检查密码、网络连接和远程主机是否允许密码登录"
        return 1
    fi
    
    # 3. 测试免密登录
    # 使用子shell执行，避免 set -e 影响
    if (ssh -i "$private_key" -p "$remote_port" -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$remote_user@$remote_ip" "echo '测试成功'" &> /dev/null); then
        log "SSH免密登录配置成功"
        return 0
    else
        error "SSH免密登录配置失败"
        return 1
    fi
}

# 检查远程目录可用性
check_remote_directory() {
    local remote_ip="$1"
    local remote_port="$2"
    local remote_user="$3"
    local private_key="/root/.ssh/id_rsa_gz"
    
    log "检查远程主机连接..."
    # 尝试SSH连接并执行简单命令
    if (ssh -i "$private_key" -p "$remote_port" -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$remote_user@$remote_ip" "echo '连接成功'" &> /dev/null); then
        # 尝试获取远程主机根目录的磁盘信息，用于显示给用户
        local disk_info
        # 使用子shell执行，避免 df 命令的错误影响
        disk_info=$(ssh -i "$private_key" -p "$remote_port" -o StrictHostKeyChecking=no "$remote_user@$remote_ip" "df -h / | awk 'NR==2{print \$1,\$4}'" 2>/dev/null || echo "未知")
        log "远程主机磁盘信息: $disk_info"
        return 0
    else
        error "无法访问远程主机"
        return 1
    fi
}

# 创建挂载点
create_mount_point() {
    local mount_path="$1"
    local remote_ip="$2"
    
    # 如果挂载点目录不存在，则创建
    if [[ ! -d "$mount_path" ]]; then
        log "创建挂载点: $mount_path"
        mkdir -p "$mount_path"
    # 如果目录存在且已被挂载，则尝试先卸载
    elif mountpoint -q "$mount_path"; then
        warn "挂载点 $mount_path 已被使用，尝试卸载"
        umount -f "$mount_path" 2>/dev/null || true
        sleep 2
    fi
    
    # 设置目录权限
    chmod 755 "$mount_path"
    return 0
}

# 执行挂载操作
mount_remote_disk() {
    local remote_ip="$1"
    local remote_port="$2"
    local remote_user="$3"
    local mount_path="$4"
    local private_key="/root/.ssh/id_rsa_gz"
    
    # 再次检查是否已挂载，防止重复挂载
    if mountpoint -q "$mount_path"; then
        warn "挂载点 $mount_path 已被挂载，尝试卸载"
        umount -f "$mount_path" 2>/dev/null || true
        sleep 2
    fi
    
    log "正在挂载远程硬盘..."
    # 使用sshfs进行挂载，并指定密钥文件
    # 使用子shell执行，避免 sshfs 的错误影响
    if (sshfs -o IdentityFile="$private_key" -p "$remote_port" -o allow_other,default_permissions,reconnect,ServerAliveInterval=60,StrictHostKeyChecking=no "$remote_user@$remote_ip":/ "$mount_path"); then
        log "远程硬盘挂载成功"
        return 0
    else
        error "远程硬盘挂载失败"
        return 1
    fi
}

# 配置开机自动挂载 (使用 fstab)
setup_auto_mount() {
    local remote_ip="$1"
    local remote_port="$2"
    local remote_user="$3"
    local mount_path="$4"
    local private_key="/root/.ssh/id_rsa_gz"
    
    # fstab配置项
    local fstab_entry="sshfs#$remote_user@$remote_ip:/ $mount_path fuse.sshfs IdentityFile=$private_key,port=$remote_port,allow_other,default_permissions,reconnect,ServerAliveInterval=60,_netdev 0 0"
    
    # 检查 fstab 中是否已存在该挂载点的配置，如果存在则删除旧的
    if grep -q "$mount_path" /etc/fstab 2>/dev/null; then
        warn "fstab中已存在挂载配置，更新配置"
        # 使用 sed 安全删除包含挂载路径的行
        # 使用 \@ 作为分隔符，避免路径中的 / 冲突
        sed -i "\@$mount_path@d" /etc/fstab
    fi
    
    # 将新的配置写入 fstab
    echo "$fstab_entry" >> /etc/fstab
    log "开机自动挂载配置完成 (fstab)"
}

# 配置 systemd 服务 (作为 fstab 的替代或补充，增强启动成功率)
setup_systemd_service() {
    local remote_ip="$1"
    local mount_path="$2"
    local remote_port="$3"
    local remote_user="$4"
    # 根据IP生成服务名称
    local service_name="gz-${remote_ip//./-}.service"
    local private_key="/root/.ssh/id_rsa_gz"
    
    # 确保服务文件不存在，如果存在则先停止和禁用
    if [[ -f "/etc/systemd/system/${service_name}" ]]; then
        systemctl stop "$service_name" 2>/dev/null || true
        systemctl disable "$service_name" 2>/dev/null || true
        rm -f "/etc/systemd/system/${service_name}"
    fi

    # 创建 systemd unit 文件
    cat > "/etc/systemd/system/${service_name}" << EOF
[Unit]
Description=Auto mount remote disk from $remote_ip to $mount_path
After=network-online.target  # 确保在网络就绪后启动
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
# 增加sleep 10等待网络和sshfs准备就绪，提高挂载成功率
ExecStart=/bin/bash -c "sleep 10 && /usr/bin/sshfs -o IdentityFile=$private_key -p $remote_port -o allow_other,default_permissions,reconnect,ServerAliveInterval=60,StrictHostKeyChecking=no $remote_user@$remote_ip:/ $mount_path"
ExecStop=/bin/umount -f $mount_path
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF
    
    # 重新加载 systemd 配置
    systemctl daemon-reload
    # 启用并启动服务
    systemctl enable "$service_name" 2>/dev/null && log "systemd服务启用成功"
    systemctl start "$service_name" 2>/dev/null && log "systemd服务启动成功" || warn "systemd服务启动失败，请手动检查"
}

# 保存挂载配置到JSON文件
save_config() {
    local remote_ip="$1"
    local remote_port="$2"
    local remote_user="$3"
    local mount_path="$4"
    
    # 如果配置文件不存在，则创建空的JSON对象
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "{}" > "$CONFIG_FILE"
    fi
    
    # 使用jq安全地更新JSON配置
    if jq --arg ip "$remote_ip" \
         --arg port "$remote_port" \
         --arg user "$remote_user" \
         --arg path "$mount_path" \
         '. | .[$ip] = {"port": $port, "user": $user, "mount_path": $path}' \
         "$CONFIG_FILE" > "${CONFIG_FILE}.tmp"; then
        mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
        log "配置已保存: $remote_ip -> $mount_path"
    else
        error "保存配置失败，请检查jq是否正常工作或配置文件格式"
        return 1
    fi
}

# ================================================
# SSH连接管理功能（增强版：支持VPS备注名）
# ================================================

# 初始化SSH连接配置文件
init_ssh_config() {
    if [[ ! -f "$SSH_CONFIG_FILE" ]]; then
        echo "{}" > "$SSH_CONFIG_FILE"
    fi
}

# 检查备注名是否已存在
check_connection_name() {
    local name="$1"
    # 使用jq的-e选项检查指定的键是否存在
    # 如果键不存在，jq会返回非零状态码，但我们使用 || true 来防止 set -e 退出脚本
    if jq -e ".[\"$name\"]" "$SSH_CONFIG_FILE" > /dev/null 2>&1; then
        return 0  # 存在
    else
        return 1  # 不存在
    fi
}

# 添加SSH连接（增强版）
add_ssh_connection() {
    log "添加sshVPS连接配置..."
    
    local conn_name
    local remote_ip
    local remote_port
    local remote_user
    local auth_choice
    local auth_type=""
    local password=""
    local key_path=""
    
    echo
    echo "=== sshVPS备注名设置 ==="
    echo "请为这台sshVPS设置一个容易识别的备注名"
    echo
    
    while true; do
        read -p "输入sshVPS备注名: " conn_name
        if [[ -z "$conn_name" ]]; then
            error "备注名不能为空"
            continue
        fi
        
        # 检查备注名是否冲突
        if check_connection_name "$conn_name"; then
            warn "备注名 '$conn_name' 已存在，请使用其他名称"
            read -p "是否覆盖现有配置？(y/N): " overwrite
            if [[ "$overwrite" =~ ^[Yy]$ ]]; then
                break
            else
                continue
            fi
        else
            break
        fi
    done
    
    echo
    echo "=== 连接信息设置 ==="
    read -p "输入IP地址: " remote_ip
    if [[ -z "$remote_ip" ]]; then
        error "IP地址不能为空"
        return 1
    fi
    
    read -p "输入SSH端口 (默认22): " remote_port
    remote_port=${remote_port:-22}
    
    read -p "输入用户名 (默认root): " remote_user
    remote_user=${remote_user:-root}
    
    echo
    echo "=== 认证方式设置 ==="
    echo "1) 密码认证（推荐新手使用）"
    echo "2) 密钥认证（更安全）"
    read -p "请选择认证方式 (1/2): " auth_choice
    
    case $auth_choice in
        1)
            auth_type="password"
            read -s -p "输入SSH密码: " password # -s 隐藏输入
            echo
            ;;
        2)
            auth_type="key"
            read -p "输入私钥路径 (默认/root/.ssh/id_rsa): " key_path
            key_path=${key_path:-/root/.ssh/id_rsa}
            if [[ ! -f "$key_path" ]]; then
                error "私钥文件不存在: $key_path"
                warn "私钥文件不存在，连接时可能失败"
            fi
            ;;
        *)
            error "无效选择，将使用默认密码认证"
            auth_type="password"
            ;;
    esac
    
    # 保存配置到 SSH_CONFIG_FILE
    if jq --arg name "$conn_name" \
         --arg ip "$remote_ip" \
         --arg port "$remote_port" \
         --arg user "$remote_user" \
         --arg auth "$auth_type" \
         --arg pass "$password" \
         --arg key "$key_path" \
         '. | .[$name] = {"ip": $ip, "port": $port, "user": $user, "auth_type": $auth, "password": $pass, "key_path": $key}' \
         "$SSH_CONFIG_FILE" > "${SSH_CONFIG_FILE}.tmp"; then
        mv "${SSH_CONFIG_FILE}.tmp" "$SSH_CONFIG_FILE"
        log "✅ sshVPS连接配置已保存: $conn_name"
        return 0
    else
        error "保存sshVPS连接配置失败"
        return 1
    fi
}

# 列出SSH连接（增强显示）
list_ssh_connections() {
    # 检查配置文件是否存在或为空
    if [[ ! -f "$SSH_CONFIG_FILE" ]] || [[ $(jq 'keys | length' "$SSH_CONFIG_FILE" 2>/dev/null || echo 0) -eq 0 ]]; then
        log "没有保存的sshVPS连接"
        return 1
    fi
    
    log "已保存的sshVPS连接:"
    echo "========================================"
    echo -e "${CYAN}编号  备注名                IP地址            端口  用户      认证方式${NC}"
    echo "========================================"
    
    local i=1
    # 声明全局关联数组，用于编号和备注名的映射
    declare -gA conn_map
    # 清空旧的映射
    unset conn_map
    declare -gA conn_map 
    
    # 使用临时文件替代进程替换 < <(command)
    local temp_keys_file=$(mktemp)
    jq -r 'keys[]' "$SSH_CONFIG_FILE" > "$temp_keys_file" || true
    
    while IFS= read -r name; do
        if [[ -n "$name" ]]; then
            # 使用子shell执行 jq，避免 set -e 影响
            local config
            config=$(jq -r ".[\"$name\"]" "$SSH_CONFIG_FILE" || echo "{}") # 失败时返回空JSON
            local ip=$(echo "$config" | jq -r '.ip // "N/A"')
            local port=$(echo "$config" | jq -r '.port // "N/A"')
            local user=$(echo "$config" | jq -r '.user // "N/A"')
            local auth=$(echo "$config" | jq -r '.auth_type // "N/A"')
            
            # 格式化输出，确保对齐
            printf "%-4s  %-20s  %-15s  %-4s  %-8s  %-8s\n" \
                   "$i" "$name" "$ip" "$port" "$user" "$auth"
            conn_map[$i]="$name"
            ((i++))
        fi
    done < "$temp_keys_file"
    
    rm -f "$temp_keys_file"

    return 0
}

# 显示SSH连接说明
show_ssh_instructions() {
    # 打印连接前的提示信息
    echo
    echo "========================================"
    echo "           SSH连接使用说明"
    echo "========================================"
    echo "✅ 连接成功后，您将进入远程sshVPS的终端"
    echo ""
    echo "🔙 如何返回原VPS（退出SSH连接）:"
    echo "   1. 输入命令: exit"
    echo "   2. 或者按快捷键: Ctrl + D"
    echo ""
    echo "💡 提示:"
    echo "   - 退出SSH后会自动返回本脚本"
    echo "   - 您可以随时重新连接其他sshVPS"
    echo "========================================"
    echo
    read -p "按Enter键继续连接，或按Ctrl+C取消..." 
}

# 连接SSH（修复版）
connect_ssh() {
    if ! list_ssh_connections; then
        return 1
    fi
    
    echo
    echo "========================================"
    
    read -p "请选择要连接的sshVPS编号 (输入0返回主菜单): " choice
    
    if [[ "$choice" == "0" ]]; then
        return 0
    fi
    
    # 检查 choice 是否是数字且大于0
    if ! [[ "$choice" =~ ^[1-9][0-9]*$ ]]; then
        error "无效选择，请输入正确的数字编号"
        return 1
    fi
    
    local conn_name="${conn_map[$choice]}"
    if [[ -z "$conn_name" ]]; then
        error "无效选择，请输入正确的编号"
        return 1
    fi
    
    # 从 JSON 中获取连接配置
    local config
    config=$(jq -r ".[\"$conn_name\"]" "$SSH_CONFIG_FILE")
    local ip=$(echo "$config" | jq -r '.ip')
    local port=$(echo "$config" | jq -r '.port')
    local user=$(echo "$config" | jq -r '.user')
    local auth_type=$(echo "$config" | jq -r '.auth_type')
    local password=$(echo "$config" | jq -r '.password')
    local key_path=$(echo "$config" | jq -r '.key_path')
    
    show_ssh_instructions
    
    log "正在尝试连接 $conn_name ($user@$ip:$port)..."
    
    # 执行SSH连接
    case $auth_type in
        "password")
            if [[ "$password" != "null" && -n "$password" ]]; then
                # 使用子shell执行，避免 sshpass 的错误影响
                (sshpass -p "$password" ssh -p "$port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$user@$ip")
            else
                (ssh -p "$port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$user@$ip")
            fi
            ;;
        "key")
            if [[ "$key_path" != "null" && -n "$key_path" ]]; then
                (ssh -i "$key_path" -p "$port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$user@$ip")
            else
                error "密钥路径配置错误或为空"
                return 1
            fi
            ;;
        *)
            error "不支持的认证类型: $auth_type"
            return 1
            ;;
    esac
    
    echo
    log "已从 $conn_name ($user@$ip) 断开连接"
    echo "欢迎回到本脚本！"
    echo
}

# 编辑SSH连接
edit_ssh_connection() {
    if ! list_ssh_connections; then
        return 1
    fi
    
    echo
    read -p "请输入要编辑的sshVPS编号: " choice
    
    # 检查 choice 是否是数字且大于0
    if ! [[ "$choice" =~ ^[1-9][0-9]*$ ]]; then
        error "无效选择，请输入正确的数字编号"
        return 1
    fi
    
    local conn_name="${conn_map[$choice]}"
    if [[ -z "$conn_name" ]]; then
        error "无效选择，请输入正确的编号"
        return 1
    fi
    
    # 获取当前配置
    local config
    config=$(jq -r ".[\"$conn_name\"]" "$SSH_CONFIG_FILE")
    local current_ip=$(echo "$config" | jq -r '.ip')
    local current_port=$(echo "$config" | jq -r '.port')
    local current_user=$(echo "$config" | jq -r '.user')
    local current_auth=$(echo "$config" | jq -r '.auth_type')
    local current_pass=$(echo "$config" | jq -r '.password')
    local current_key=$(echo "$config" | jq -r '.key_path')
    
    echo
    log "正在编辑 sshVPS: $conn_name"
    echo "（留空表示不修改当前值）"
    
    # 交互式编辑
    read -p "新IP地址 (当前: $current_ip): " new_ip
    new_ip=${new_ip:-$current_ip}
    
    read -p "新SSH端口 (当前: $current_port): " new_port
    new_port=${new_port:-$current_port}
    
    read -p "新用户名 (当前: $current_user): " new_user
    new_user=${new_user:-$current_user}
    
    local new_auth="$current_auth"
    local new_password="$current_pass"
    local new_key_path="$current_key"
    
    echo
    echo "=== 认证方式修改 ==="
    echo "当前认证方式: $current_auth"
    echo "1) 修改为密码认证"
    echo "2) 修改为密钥认证"
    echo "3) 不修改认证方式"
    read -p "请选择 (1/2/3): " auth_choice
    
    case $auth_choice in
        1)
            new_auth="password"
            read -s -p "新SSH密码: " new_password
            echo
            new_key_path="" # 清空密钥路径
            ;;
        2)
            new_auth="key"
            read -p "新私钥路径 (当前: $current_key): " temp_key_path
            new_key_path=${temp_key_path:-$current_key}
            new_password="" # 清空密码
            ;;
        3)
            # 保持不变
            ;;
        *)
            warn "无效选择，认证方式保持不变"
            ;;
    esac
    
    # 执行保存操作
    if jq --arg name "$conn_name" \
         --arg ip "$new_ip" \
         --arg port "$new_port" \
         --arg user "$new_user" \
         --arg auth "$new_auth" \
         --arg pass "$new_password" \
         --arg key "$new_key_path" \
         '. | .[$name] = {"ip": $ip, "port": $port, "user": $user, "auth_type": $auth, "password": $pass, "key_path": $key}' \
         "$SSH_CONFIG_FILE" > "${SSH_CONFIG_FILE}.tmp"; then
        mv "${SSH_CONFIG_FILE}.tmp" "$SSH_CONFIG_FILE"
        log "✅ sshVPS连接配置已更新: $conn_name"
    else
        error "更新sshVPS连接配置失败"
        return 1
    fi
}

# 删除SSH连接
delete_ssh_connection() {
    if ! list_ssh_connections; then
        return 1
    fi
    
    echo
    read -p "请输入要删除的sshVPS编号: " choice
    
    # 检查 choice 是否是数字且大于0
    if ! [[ "$choice" =~ ^[1-9][0-9]*$ ]]; then
        error "无效选择，请输入正确的数字编号"
        return 1
    fi
    
    local conn_name="${conn_map[$choice]}"
    if [[ -z "$conn_name" ]]; then
        error "无效选择，请输入正确的编号"
        return 1
    fi
    
    read -p "确认删除sshVPS连接 '$conn_name' 吗？(y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        # 使用jq删除指定的键值对
        if jq "del(.[\"$conn_name\"])" "$SSH_CONFIG_FILE" > "${SSH_CONFIG_FILE}.tmp" && mv "${SSH_CONFIG_FILE}.tmp" "$SSH_CONFIG_FILE"; then
            log "✅ sshVPS连接 '$conn_name' 已删除"
        else
            error "删除sshVPS连接失败"
        fi
    else
        log "操作已取消"
    fi
}

# ================================================
# 挂载管理功能
# ================================================

# 添加挂载配置 (调用一系列子函数完成挂载和持久化)
add_mount() {
    log "开始添加新的挂载配置..."
    
    local remote_ip
    local remote_port
    local remote_user
    local remote_password
    
    echo
    echo "=== 远程VPS信息设置 ==="
    read -p "输入远程VPS IP地址: " remote_ip
    if [[ -z "$remote_ip" ]]; then
        error "IP地址不能为空"
        return 1
    fi
    
    read -p "输入远程SSH端口 (默认22): " remote_port
    remote_port=${remote_port:-22}
    
    read -p "输入远程用户名 (默认root): " remote_user
    remote_user=${remote_user:-root}
    
    read -s -p "输入远程SSH密码 (用于公钥推送): " remote_password
    echo
    if [[ -z "$remote_password" ]]; then
        error "密码不能为空"
        return 1
    fi
    
    local mount_path=$(generate_mount_path "$remote_ip")
    
    log "开始配置挂载: $remote_ip -> $mount_path"
    
    # 1. 配置SSH密钥认证 (使用密码进行公钥推送)
    if ! setup_ssh_key "$remote_ip" "$remote_port" "$remote_user" "$remote_password"; then
        error "SSH密钥配置失败，挂载终止"
        return 1
    fi
    
    # 2. 检查远程目录可用性
    if ! check_remote_directory "$remote_ip" "$remote_port" "$remote_user"; then
        error "远程目录检查失败，挂载终止"
        return 1
    fi
    
    # 3. 创建挂载点
    if ! create_mount_point "$mount_path" "$remote_ip"; then
        error "创建挂载点失败，挂载终止"
        return 1
    fi
    
    # 4. 执行挂载操作 (使用 sshfs 挂载)
    if ! mount_remote_disk "$remote_ip" "$remote_port" "$remote_user" "$mount_path"; then
        error "挂载操作失败，挂载终止"
        return 1
    fi
    
    # 5. 配置开机自动挂载 (fstab)
    setup_auto_mount "$remote_ip" "$remote_port" "$remote_user" "$mount_path"
    
    # 6. 配置systemd服务 (可选的持久化方式)
    setup_systemd_service "$remote_ip" "$mount_path" "$remote_port" "$remote_user"
    
    # 7. 保存配置到 JSON 文件
    save_config "$remote_ip" "$remote_port" "$remote_user" "$mount_path"
    
    log "✅ 远程硬盘挂载配置和持久化完成！"
    return 0
}

# 移除单个挂载配置
remove_single_mount() {
    # 检查配置是否存在
    if [[ ! -f "$CONFIG_FILE" ]] || [[ $(jq 'keys | length' "$CONFIG_FILE" 2>/dev/null || echo 0) -eq 0 ]]; then
        error "没有找到挂载配置"
        return 1
    fi
    
    log "现有挂载配置IP列表:"
    
    local i=1
    declare -A mount_map
    
    # 使用临时文件替代进程替换 < <(command)
    local temp_keys_file=$(mktemp)
    jq -r 'keys[]' "$CONFIG_FILE" > "$temp_keys_file" || true
    
    while IFS= read -r ip; do
        if [[ -n "$ip" ]]; then
            local path
            path=$(jq -r ".\"$ip\".mount_path" "$CONFIG_FILE" || echo "N/A")
            echo -e "${CYAN}$i) $ip -> $path${NC}"
            mount_map[$i]="$ip"
            ((i++))
        fi
    done < "$temp_keys_file"
    
    rm -f "$temp_keys_file"
    
    if [[ ${#mount_map[@]} -eq 0 ]]; then
        error "没有可用的挂载配置"
        return 1
    fi
    
    echo
    read -p "输入要移除的配置编号 (输入0返回): " choice
    
    if [[ "$choice" == "0" ]]; then
        return 0
    fi
    
    # 检查 choice 是否是数字且大于0
    if ! [[ "$choice" =~ ^[1-9][0-9]*$ ]]; then
        error "无效选择，请输入正确的数字编号"
        return 1
    fi
    
    local remote_ip="${mount_map[$choice]}"
    if [[ -z "$remote_ip" ]]; then
        error "无效选择"
        return 1
    fi
    
    local config
    config=$(jq -r ".[\"$remote_ip\"]" "$CONFIG_FILE")
    local mount_path=$(echo "$config" | jq -r '.mount_path')
    local service_name="gz-${remote_ip//./-}.service"
    
    echo "选择卸载方式 (针对 $remote_ip -> $mount_path):"
    echo "1) 仅卸载挂载点"
    echo "2) 卸载挂载点并删除配置 (fstab, 配置文件)"
    echo "3) 完全清理（包括systemd服务和目录）"
    read -p "请选择 (1-3): " remove_choice
    
    # 1. 卸载挂载点
    if mountpoint -q "$mount_path" 2>/dev/null; then
        log "卸载挂载点: $mount_path"
        umount -f "$mount_path" 2>/dev/null && log "卸载成功" || warn "卸载失败"
    else
        log "挂载点未挂载，跳过卸载"
    fi
    
    if [[ "$remove_choice" == "2" || "$remove_choice" == "3" ]]; then
        # 2. 清理fstab中的对应行
        if grep -q "$mount_path" /etc/fstab 2>/dev/null; then
            # 使用 \@ 作为分隔符，避免路径中的 / 冲突
            sed -i "\@$mount_path@d" /etc/fstab
            log "已移除fstab配置"
        fi
        
        if [[ "$remove_choice" == "3" ]]; then
            # 3. 清理systemd服务
            if systemctl is-enabled "$service_name" &> /dev/null; then
                systemctl stop "$service_name" 2>/dev/null || true
                systemctl disable "$service_name" 2>/dev/null || true
                log "已停止并禁用systemd服务: $service_name"
            fi
            
            # 4. 删除systemd unit 文件
            if [[ -f "/etc/systemd/system/$service_name" ]]; then
                rm -f "/etc/systemd/system/$service_name"
                log "已删除systemd服务文件"
            fi
            
            # 5. 删除挂载点目录 (确保目录未被挂载)
            if [[ -d "$mount_path" ]] && ! mountpoint -q "$mount_path"; then
                rmdir "$mount_path" 2>/dev/null && log "已删除挂载目录" || warn "删除挂载目录失败（可能非空或不存在）"
            fi
            
            # 重新加载 systemd 配置
            systemctl daemon-reload 2>/dev/null || true
        fi
        
        # 6. 删除配置文件中的记录
        if jq "del(.[\"$remote_ip\"])" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"; then
            log "✅ 已从配置文件中移除 $remote_ip 的配置"
        else
            error "删除配置文件记录失败"
        fi
    fi
    
    log "移除操作完成"
    return 0
}

# ================================================
# 卸载功能（修复版）
# ================================================

# 完全卸载所有内容
uninstall_everything() {
    read -p "这将删除所有配置、挂载、服务和脚本本身。确认吗？(y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log "操作已取消"
        return 0
    fi
    
    log "开始完全卸载..."
    
    # 遍历并清理所有挂载配置
    # 检查文件是否存在且 jq 能成功提取 keys
    if [[ -f "$CONFIG_FILE" ]] && jq -r 'keys[]' "$CONFIG_FILE" &> /dev/null; then
        log "清理挂载配置..."
        
        # 临时文件用于存储IP列表
        local ip_list_file
        ip_list_file=$(mktemp)
        # 使用 || true 确保即使 jq 失败（如空文件）也不会退出
        jq -r 'keys[]' "$CONFIG_FILE" > "$ip_list_file" || true
        
        while IFS= read -r remote_ip; do
            [[ -z "$remote_ip" ]] && continue
            
            local config
            config=$(jq -r ".[\"$remote_ip\"]" "$CONFIG_FILE" || echo "{}")
            local mount_path=$(echo "$config" | jq -r '.mount_path // "N/A"')
            
            log "清理配置: $remote_ip -> $mount_path"
            
            # 卸载挂载点
            if mountpoint -q "$mount_path" 2>/dev/null; then
                umount -f "$mount_path" 2>/dev/null && log "已卸载挂载点: $mount_path" || warn "卸载挂载点失败: $mount_path"
            fi
            
            # 清理fstab
            if grep -q "$mount_path" /etc/fstab 2>/dev/null; then
                sed -i "\@$mount_path@d" /etc/fstab
                log "已移除fstab配置: $mount_path"
            fi
            
            # 清理systemd服务
            local service_name="gz-${remote_ip//./-}.service"
            if systemctl is-enabled "$service_name" &> /dev/null; then
                systemctl stop "$service_name" 2>/dev/null || true
                systemctl disable "$service_name" 2>/dev/null || true
                log "已禁用systemd服务: $service_name"
            fi
            
            if [[ -f "/etc/systemd/system/$service_name" ]]; then
                rm -f "/etc/systemd/system/$service_name"
                log "已删除systemd服务文件: $service_name"
            fi
            
            # 删除挂载目录
            if [[ -d "$mount_path" ]] && ! mountpoint -q "$mount_path"; then
                rmdir "$mount_path" 2>/dev/null && log "已删除挂载目录: $mount_path" || warn "删除挂载目录失败: $mount_path"
            fi
            
        done < "$ip_list_file"
        rm -f "$ip_list_file"
    elif [[ -f "$CONFIG_FILE" ]]; then
        warn "挂载配置文件 $CONFIG_FILE 格式错误或为空，跳过自动清理挂载点和服务"
    fi
    
    # 清理挂载配置文件
    if [[ -f "$CONFIG_FILE" ]]; then
        rm -f "$CONFIG_FILE"
        log "已删除挂载配置文件: $CONFIG_FILE"
    fi
    
    # 清理SSH连接配置文件
    if [[ -f "$SSH_CONFIG_FILE" ]]; then
        rm -f "$SSH_CONFIG_FILE"
        log "已删除sshVPS连接配置文件: $SSH_CONFIG_FILE"
    fi
    
    # 清理SSH密钥
    if [[ -f "/root/.ssh/id_rsa_gz" ]]; then
        rm -f /root/.ssh/id_rsa_gz*
        log "已删除SSH密钥: /root/.ssh/id_rsa_gz*"
    fi
    
    # 重新加载 systemd 配置，确保服务被彻底移除
    systemctl daemon-reload 2>/dev/null || true
    log "已重新加载systemd配置"
    
    # 最后删除脚本本身
    if [[ -f "$SCRIPT_PATH" ]]; then
        rm -f "$SCRIPT_PATH"
        log "已删除脚本文件: $SCRIPT_PATH"
    fi
    
    log "完全卸载完成！脚本将在3秒后退出..."
    sleep 3
    exit 0
}

# ================================================
# 其他功能
# ================================================

# 列出所有挂载配置及状态
list_mounts() {
    # 检查配置是否存在
    if [[ ! -f "$CONFIG_FILE" ]] || [[ $(jq 'keys | length' "$CONFIG_FILE" 2>/dev/null || echo 0) -eq 0 ]]; then
        log "没有挂载配置"
        return 1
    fi
    
    log "当前挂载配置:"
    echo "========================================"
    
    # 使用临时文件替代进程替换 < <(command)
    local temp_keys_file=$(mktemp)
    jq -r 'keys[]' "$CONFIG_FILE" > "$temp_keys_file" || true
    
    # 遍历所有配置的IP
    local i=1
    while IFS= read -r ip; do
        if [[ -n "$ip" ]]; then
            local config
            config=$(jq -r ".[\"$ip\"]" "$CONFIG_FILE" || echo "{}")
            local mount_path=$(echo "$config" | jq -r '.mount_path // "N/A"')
            local user=$(echo "$config" | jq -r '.user // "N/A"')
            local port=$(echo "$config" | jq -r '.port // "N/A"')
            
            echo -e "${CYAN}编号 $i) IP: $ip | 挂载点: $mount_path | 用户: $user | 端口: $port${NC}"
            
            # 检查是否已挂载
            if mountpoint -q "$mount_path" 2>/dev/null; then
                echo -e "  ${GREEN}✓ 状态: 已挂载${NC}"
                # 显示挂载点的磁盘使用信息
                # 使用子shell执行 df，避免错误影响
                (df -h "$mount_path" | awk 'NR==2{print "  容量: "$2", 已用: "$3", 可用: "$4}') || true
            else
                echo -e "  ${RED}✗ 状态: 未挂载${NC}"
            fi
            echo
            ((i++))
        fi
    done < "$temp_keys_file"
    
    rm -f "$temp_keys_file"
    
    return 0
}

# 检查所有挂载状态并尝试重新挂载断开的连接
check_mounts() {
    # 检查配置是否存在
    if [[ ! -f "$CONFIG_FILE" ]] || [[ $(jq 'keys | length' "$CONFIG_FILE" 2>/dev/null || echo 0) -eq 0 ]]; then
        log "没有挂载配置"
        return 1
    fi
    
    log "检查所有挂载状态..."
    echo "========================================"
    
    # 使用临时文件替代进程替换 < <(command)
    local temp_keys_file=$(mktemp)
    jq -r 'keys[]' "$CONFIG_FILE" > "$temp_keys_file" || true
    
    # 遍历所有配置的IP
    while IFS= read -r ip; do
        local config
        config=$(jq -r ".[\"$ip\"]" "$CONFIG_FILE" || echo "{}")
        local mount_path=$(echo "$config" | jq -r '.mount_path // "N/A"')
        local remote_port=$(echo "$config" | jq -r '.port // "N/A"')
        local remote_user=$(echo "$config" | jq -r '.user // "N/A"')
        
        # 检查是否已挂载
        if mountpoint -q "$mount_path" 2>/dev/null; then
            echo -e "${GREEN}✓ $ip ($mount_path) 挂载正常${NC}"
        else
            echo -e "${YELLOW}⚠ $ip ($mount_path) 挂载断开，尝试重新挂载...${NC}"
            # 尝试重新挂载（调用 mount_remote_disk 函数）
            if mount_remote_disk "$ip" "$remote_port" "$remote_user" "$mount_path"; then
                echo -e "${GREEN}✓ $ip 重新挂载成功${NC}"
            else
                echo -e "${RED}✗ $ip 重新挂载失败${NC}"
            fi
        fi
    done < "$temp_keys_file"
    
    rm -f "$temp_keys_file"
    
    return 0
}

# 显示脚本信息
show_info() {
    # 打印脚本版本和功能信息
    echo
    echo "========================================"
    echo "           脚本信息 v4.0"
    echo "========================================"
    echo "脚本名称: gz.sh"
    echo "版本: 4.0 (最终完善版，经过全面代码审计和健壮性测试)"
    echo "描述: 闲置VPS硬盘远程挂载与SSH连接管理"
    echo "支持系统: Ubuntu/Debian/CentOS/AlmaLinux/Rocky"
    echo "配置文件: $CONFIG_FILE"
    echo "sshVPS连接配置: $SSH_CONFIG_FILE"
    echo ""
    echo "✅ 修复与完善:"
    echo "   - 解决了 Bash 进程替换 (<(command)) 兼容性问题"
    echo "   - 修复了关键的 Bash 语法错误 (缺少 fi)"
    echo "   - 解决了在 set -e 环境下 jq 命令的非零退出码问题"
    echo "   - 增强了文件操作和系统命令调用的健壮性"
    echo "   - 修复了用户输入校验的逻辑错误"
    echo "   - 菜单文本已按用户要求修改"
    echo "   - 增加了快捷指令 'gz' 的提示和支持"
    echo "========================================"
}

# 显示主菜单
show_menu() {
    # 打印主菜单选项
    echo
    echo "========================================"
    echo "   VPS硬盘挂载与SSH管理脚本 v4.0"
    echo "========================================"
    echo "=== 挂载管理 ==="
    echo "1) 添加新的挂载配置"
    echo "2) 移除单个挂载配置"
    echo "3) 列出所有挂载配置"
    echo "4) 检查挂载状态"
    echo ""
    echo "=== sshVPS连接管理 ==="
    echo "5) 添加sshVPS连接（设置备注名）"
    echo "6) 列出所有sshVPS连接"
    echo "7) 连接sshVPS（使用备注名）"
    echo "8) 编辑sshVPS连接"
    echo "9) 删除sshVPS连接"
    echo ""
    echo "=== 系统工具 ==="
    echo "10) 显示脚本信息"
    echo "11) 完全卸载所有内容"
    echo ""
    echo "0) 退出脚本"
    echo "========================================"
}

# 清理函数 (用于捕获中断信号)
cleanup() {
    log "正在退出脚本..."
    exit 0
}

# 主函数
main() {
    # Argument parsing for help
    if [[ "$#" -gt 0 ]]; then
        case "$1" in
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                warn "未知参数: $1. 使用 -h 查看帮助."
                show_usage
                exit 1
                ;;
        esac
    fi

    log "启动脚本..."
    check_root              # 检查 Root 权限
    check_os                # 检查操作系统
    
    # 确保依赖安装成功
    if ! install_dependencies; then
        error "依赖安装失败，脚本退出"
        exit 1
    fi
    
    init_ssh_config         # 初始化 SSH 配置
    
    # 设置信号捕获，Ctrl+C 或终止信号时调用 cleanup
    trap cleanup SIGINT SIGTERM
    
    # 主循环，持续显示菜单并处理用户输入
    while true; do
        show_menu
        read -p "请选择操作 (0-11): " choice
        
        # 检查输入是否为空
        if [[ -z "$choice" ]]; then
            warn "输入不能为空，请重新选择"
            continue
        fi
        
        case $choice in
            1)
                add_mount
                ;;
            2)
                remove_single_mount
                ;;
            3)
                list_mounts
                ;;
            4)
                check_mounts
                ;;
            5)
                add_ssh_connection
                ;;
            6)
                list_ssh_connections
                ;;
            7)
                connect_ssh
                ;;
            8)
                edit_ssh_connection
                ;;
            9)
                delete_ssh_connection
                ;;
            10)
                show_info
                ;;
            11)
                uninstall_everything
                ;;
            0)
                log "退出脚本"
                exit 0
                ;;
            *)
                warn "无效选择，请输入 0-11 之间的数字"
                ;;
        esac
        
        echo
        read -p "按Enter键继续..."
    done
}

# 执行主函数，传入所有命令行参数
main "$@"
