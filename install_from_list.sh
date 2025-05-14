#!/bin/bash

CONFIG_FILE="install_list.conf"
LOG_FILE="install_log.txt"
INSTALLED_LOG="installed_success.log"
UNINSTALLED_LOG="uninstalled_success.log"
MAX_RETRIES=3
MODE="install"

set -e

# --- 识别包管理器 ---
detect_package_manager() {
    if command -v dnf &>/dev/null; then echo "dnf"
    elif command -v yum &>/dev/null; then echo "yum"
    elif command -v apt &>/dev/null; then echo "apt"
    elif command -v zypper &>/dev/null; then echo "zypper"
    elif command -v brew &>/dev/null; then echo "brew"
    else echo "Unsupported package manager" >&2; exit 1
    fi
}

PKG_MANAGER=$(detect_package_manager)

# --- 检测系统类型 ---
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        echo "$ID"
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macos"
    else
        echo "unknown"
    fi
}

OS_TYPE=$(detect_os)

# --- 校验配置文件格式 ---
validate_config() {
    echo "[CHECK] 检查配置文件格式..." | tee -a $LOG_FILE
    lineno=0
    while IFS= read -r line; do
        ((lineno++))
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "$line" =~ ^custom:[a-zA-Z0-9_\-]+=\|.*$ ]]; then
            continue
        elif [[ "$line" =~ ^php-ext:[a-zA-Z0-9_\-]+$ ]]; then
            continue
        elif [[ "$line" =~ ^python-pkg:[a-zA-Z0-9_\-]+$ ]]; then
            continue
        elif [[ "$line" =~ ^rpm:[a-zA-Z0-9._\-]+$ ]]; then
            continue
        elif [[ "$line" =~ ^[a-zA-Z0-9_\-]+(=[a-zA-Z0-9.\-]*)?$ ]]; then
            continue
        else
            echo "[ERROR] 配置文件第 $lineno 行格式错误：$line" | tee -a $LOG_FILE
            exit 1
        fi
    done < "$CONFIG_FILE"
    echo "[OK] 配置文件校验通过"
}

# --- 获取当前版本 ---
get_version() {
    local cmd="$1"
    case "$cmd" in
        apache2) apache2 -v | head -n1 ;;
        php) php -v | head -n1 ;;
        java) java -version 2>&1 | head -n1 ;;
        aws) aws --version ;;
        node) node -v ;;
        docker) docker --version ;;
        python) python --version ;;
        pip) pip show "$2" | grep Version || echo "(version unknown)" ;;
        *) $cmd --version 2>/dev/null | head -n1 || echo "$cmd (version unknown)" ;;
    esac
}

# --- 安装包 ---
install_package() {
    local raw_pkg="$1"
    local version="$2"

    if [[ "$raw_pkg" == custom:* ]]; then
        name="${raw_pkg#custom:}"
        cmd="${version#| }"
        echo "[CUSTOM] 安装 $name ..." | tee -a $LOG_FILE
        eval "$cmd" && echo "$name (custom)" >> "$INSTALLED_LOG"
        return
    fi

    if [[ "$raw_pkg" == php-ext:* ]]; then
        ext="${raw_pkg#php-ext:}"
        pkg="php-${ext}"
        raw_pkg="$pkg"
        echo "[PHP EXT] 安装 PHP 扩展 $ext ..." | tee -a $LOG_FILE
    elif [[ "$raw_pkg" == python-pkg:* ]]; then
        mod="${raw_pkg#python-pkg:}"
        echo "[PYTHON] 安装 Python 模块 $mod ..." | tee -a $LOG_FILE
        python -m pip install "$mod" && echo "$mod (python) - $(get_version pip "$mod")" >> "$INSTALLED_LOG"
        return
    elif [[ "$raw_pkg" == rpm:* ]]; then
        rpm_pkg="${raw_pkg#rpm:}"
        echo "[RPM] 安装 RPM 包 $rpm_pkg ..." | tee -a $LOG_FILE
        sudo $PKG_MANAGER install -y "$rpm_pkg" && echo "$rpm_pkg (rpm)" >> "$INSTALLED_LOG"
        return
    else
        pkg="$raw_pkg"
    fi

    for attempt in $(seq 1 $MAX_RETRIES); do
        echo "[INFO] 安装 $pkg ${version:+version $version} (第 $attempt 次)" | tee -a $LOG_FILE
        case "$PKG_MANAGER" in
            zypper)
                sudo zypper --non-interactive install "${pkg}=${version:-}" && break ;;
            apt)
                sudo apt update -y
                sudo apt install -y "${pkg}=${version:-}" && break ;;
            yum|dnf)
                sudo $PKG_MANAGER install -y "${pkg}-${version:-}" && break ;;
            brew)
                brew install "${pkg}@${version}" || brew install "$pkg" && break ;;
        esac
        echo "[WARN] 安装失败，回滚并重试..." | tee -a $LOG_FILE
        uninstall_package "$pkg"
        sleep 2
    done

    if command -v "$pkg" &>/dev/null; then
        get_version "$pkg" >> "$INSTALLED_LOG"
    fi
}

# --- 卸载包 ---
uninstall_package() {
    local raw_pkg="$1"

    if [[ "$raw_pkg" == custom:* ]]; then
        echo "[SKIP] 不支持卸载自定义工具: $raw_pkg" | tee -a $LOG_FILE
        return
    fi

    if [[ "$raw_pkg" == php-ext:* ]]; then
        pkg="php-${raw_pkg#php-ext:}"
    elif [[ "$raw_pkg" == python-pkg:* ]]; then
        mod="${raw_pkg#python-pkg:}"
        version_before=$(python -m pip show "$mod" | grep Version || echo "unknown")
        echo "[PYTHON] 卸载 Python 模块 $mod ..." | tee -a $LOG_FILE
        python -m pip uninstall -y "$mod"
        echo "$mod - $version_before (python)" >> "$UNINSTALLED_LOG"
        return
    elif [[ "$raw_pkg" == rpm:* ]]; then
        pkg="${raw_pkg#rpm:}"
    else
        pkg="$raw_pkg"
    fi

    echo "[INFO] 卸载 $pkg ..." | tee -a $LOG_FILE
    version_before=$(get_version "$pkg")

    case "$PKG_MANAGER" in
        zypper) sudo zypper --non-interactive remove "$pkg" ;;
        apt) sudo apt remove -y "$pkg" ;;
        yum|dnf) sudo $PKG_MANAGER remove -y "$pkg" ;;
        brew) brew uninstall --ignore-dependencies "$pkg" ;;
    esac

    echo "$pkg - $version_before" >> "$UNINSTALLED_LOG"
}

# --- 主入口 ---
[[ "$1" == "--uninstall" ]] && MODE="uninstall"

> "$INSTALLED_LOG"
> "$UNINSTALLED_LOG"
validate_config

while IFS='=' read -r pkg version; do
    [[ -z "$pkg" || "$pkg" == \#* ]] && continue
    if [[ "$MODE" == "install" ]]; then
        install_package "$pkg" "$version"
    else
        uninstall_package "$pkg"
    fi
done < "$CONFIG_FILE"

if [[ "$MODE" == "install" ]]; then
    echo -e "\n==== 安装完成 ====" | tee -a $LOG_FILE
    cat "$INSTALLED_LOG"
else
    echo -e "\n==== 卸载完成 ====" | tee -a $LOG_FILE
    cat "$UNINSTALLED_LOG"
fi

