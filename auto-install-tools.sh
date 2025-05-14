#!/bin/bash

# ------------------------------------------------------
# 通用安装/卸载脚本（增强版）
# - 支持 install / uninstall 参数
# - 支持模块化安装、跳过已安装项、失败回滚
# - 支持自动启动服务和记录日志
# ------------------------------------------------------

ACTION="$1"  # install 或 uninstall
CONFIG_FILE="install_list.conf"
LOG_FILE="${ACTION}_log.txt"
OS=""
PHP_VERSION=""
FAILED_MODULES=()

# 获取系统类型
get_os_type() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo "$ID"
  else
    echo "unknown"
  fi
}

# 输出日志
log() {
  echo -e "$1" | tee -a "$LOG_FILE"
}

# 检查是否已安装软件包（仅限 dnf/apt 包）
is_installed() {
  local pkg="$1"
  if command -v rpm &>/dev/null; then
    rpm -q "$pkg" &>/dev/null && return 0
  elif command -v dpkg &>/dev/null; then
    dpkg -s "$pkg" &>/dev/null && return 0
  fi
  return 1
}

# 安装主软件包并记录版本号
install_package() {
  local name="$1"
  if is_installed "$name"; then
    log "[跳过] $name 已安装"
    return 0
  fi
  if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
    sudo apt update && sudo apt install -y "$name"
  else
    sudo dnf install -y "$name"
  fi
  # 输出安装后的版本号
  version=$(dpkg -l | grep "$name" | awk '{print $3}' || rpm -q "$name")
  log "[已安装] $name 版本: $version"
}

# 安装 PHP 扩展并记录版本号
install_php_ext() {
  local module="$1"
  local pkg=""
  if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
    pkg="php-$module"
  else
    [[ -n "$PHP_VERSION" ]] && pkg="php$PHP_VERSION-php-$module" || pkg="php-$module"
  fi
  if is_installed "$pkg"; then
    log "[跳过] PHP 扩展 $pkg 已安装"
    return 0
  fi
  sudo dnf install -y "$pkg"
  # 输出安装后的版本号
  version=$(php -m | grep "$module" && php -v | head -n 1 || echo "未找到版本")
  log "[已安装] PHP 扩展 $pkg 版本: $version"
}

# 安装 RPM 包并记录版本号
install_rpm_package() {
  local full_pkg="$1"
  if is_installed "$full_pkg"; then
    log "[跳过] RPM 包 $full_pkg 已安装"
    return 0
  fi
  sudo dnf install -y "$full_pkg"
  # 输出安装后的版本号
  version=$(rpm -q "$full_pkg")
  log "[已安装] RPM 包 $full_pkg 版本: $version"
}

# 执行自定义安装命令
process_custom_install() {
  local cmd="$1"
  bash -c "$cmd"
  # 记录自定义安装完成后的版本信息（如果需要）
  log "[已安装] 自定义模块安装完成"
}

# 启动并启用服务
start_service() {
  local svc="$1"
  sudo systemctl daemon-reexec
  sudo systemctl enable --now "$svc"
}

# 卸载主软件包
uninstall_package() {
  local name="$1"
  [[ "$OS" == "ubuntu" || "$OS" == "debian" ]] && sudo apt remove -y "$name" || sudo dnf remove -y "$name"
}

# 卸载 PHP 扩展
uninstall_php_ext() {
  local module="$1"
  local pkg=""
  if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
    pkg="php-$module"
  else
    [[ -n "$PHP_VERSION" ]] && pkg="php$PHP_VERSION-php-$module" || pkg="php-$module"
  fi
  sudo dnf remove -y "$pkg"
}

# 卸载 RPM 包
uninstall_rpm_package() {
  local full_pkg="$1"
  sudo dnf remove -y "$full_pkg"
}

# 提示手动卸载自定义命令
process_custom_uninstall() {
  local name="$1"
  log "[提示] 请手动卸载 $name 所对应的文件或服务"
}

# 执行失败时记录并可后续回滚
record_failure() {
  local name="$1"
  FAILED_MODULES+=("$name")
}

# 回滚已安装模块（仅安装模式）
rollback_failed() {
  if [[ "$ACTION" != "install" || ${#FAILED_MODULES[@]} -eq 0 ]]; then
    return
  fi
  log "[回滚] 安装失败，开始回滚: ${FAILED_MODULES[*]}"
  for item in "${FAILED_MODULES[@]}"; do
    uninstall_package "$item" 2>/dev/null || true
    uninstall_php_ext "$item" 2>/dev/null || true
    uninstall_rpm_package "$item" 2>/dev/null || true
  done
  log "[回滚] 已尝试回滚失败模块"
}

# 处理每一行配置
process_line() {
  local line="$1"

  if [[ "$line" =~ ^(.*)=(.*)$ ]]; then
    name="${BASH_REMATCH[1]}"
    version="${BASH_REMATCH[2]}"
    PHP_VERSION="$version"
    log "$ACTION 主程序: $name $version"
    if [[ "$ACTION" == "install" ]]; then
      install_package "$name" || { record_failure "$name"; return; }
      [[ "$name" =~ apache ]] && start_service apache2 || start_service httpd
      [[ "$name" =~ php ]] && start_service php-fpm || start_service php$version-fpm
    else
      uninstall_package "$name"
    fi

  elif [[ "$line" =~ ^php-ext:(.*)$ ]]; then
    module="${BASH_REMATCH[1]}"
    log "$ACTION PHP 扩展: $module"
    [[ "$ACTION" == "install" ]] && install_php_ext "$module" || uninstall_php_ext "$module"

  elif [[ "$line" =~ ^rpm:(.*)$ ]]; then
    full_pkg="${BASH_REMATCH[1]}"
    log "$ACTION RPM 包: $full_pkg"
    [[ "$ACTION" == "install" ]] && install_rpm_package "$full_pkg" || uninstall_rpm_package "$full_pkg"

  elif [[ "$line" =~ ^custom:(.*)=\|[[:space:]]*(.*)$ ]]; then
    name="${BASH_REMATCH[1]}"
    cmd="${BASH_REMATCH[2]}"
    log "$ACTION 自定义模块: $name"
    [[ "$ACTION" == "install" ]] && process_custom_install "$cmd" || process_custom_uninstall "$name"

  else
    log "[警告] 未识别的行: $line"
  fi
}

# 主函数
main() {
  if [[ "$ACTION" != "install" && "$ACTION" != "uninstall" ]]; then
    echo "用法: $0 [install|uninstall]"
    exit 1
  fi

  OS=$(get_os_type)
  log "开始 $ACTION 操作，系统类型: $OS"

  while IFS= read -r line; do
    [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
    process_line "$line"
  done < "$CONFIG_FILE"

  rollback_failed
  log "$ACTION 完成于: $(date)"
}

main
