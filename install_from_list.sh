#!/bin/bash

CONFIG_FILE="install_list.conf"
LOG_FILE="install_log.txt"
MAX_RETRIES=3
MODE="install"

set -e

# --- 识别包管理器 ---
detect_package_manager() {
    if command -v zypper &> /dev/null; then echo "zypper"
    elif command -v apt &> /dev/null; then echo "apt"
    elif command -v yum &> /dev/null; then echo "yum"
    else echo "Unsupported package manager" >&2; exit 1
    fi
}

PKG_MANAGER=$(detect_package_manager)

# --- 校验配置文件合法性 ---
validate_config() {
    echo "[CHECK] 检查配置文件格式..." | tee -a $LOG_FILE
    lineno=0
    while IFS= read -r line; do
        ((lineno++))
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "$line" =~ ^custom:[a-zA-Z0-9_\-]+=\|.*$ ]]; then
            continue
        elif [[ "$line" =~ ^[a-zA-Z0-9_\-]+=[a-zA-Z0-9.\-]*$ ]]; then
            continue
        else
            echo "[ERROR] 配置文件第 $lineno 行格式错误：$line" | tee -a $LOG_FILE
            exit 1
        fi
    done < "$CONFIG_FILE"
    echo "[OK] 配置文件校验通过"
}

# --- 安装包 ---
install_package() {
    local pkg="$1"
    local version="$2"

    if [[ "$pkg" == custom:* ]]; then
        name="${pkg#custom:}"
        cmd="${version#| }"
        echo "[CUSTOM] 安装 $name ..." | tee -a $LOG_FILE
        eval "$cmd"
        return
    fi

    if [[ "$pkg" == "awscli" ]]; then
        if command -v aws &> /dev/null && [[ -n "$version" ]]; then
            current=$(aws --version | grep -oP 'aws-cli/\K[0-9.]+' || echo "")
            [[ "$current" == "$version" ]] && { echo "[SKIP] AWS CLI $version 已安装" | tee -a $LOG_FILE; return; }
        fi
        echo "[INFO] 安装 AWS CLI v${version:-latest}" | tee -a $LOG_FILE
        tmpdir=$(mktemp -d)
        cd "$tmpdir"
        curl -s -Lo awscliv2.zip "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-${version:-latest}.zip"
        unzip -q awscliv2.zip
        sudo ./aws/install --update
        rm -rf "$tmpdir"
        return
    fi

    for attempt in $(seq 1 $MAX_RETRIES); do
        echo "[INFO] 安装 $pkg ${version:+version $version} (第 $attempt 次)" | tee -a $LOG_FILE
        case "$PKG_MANAGER" in
            zypper)
                sudo zypper --non-interactive install "${pkg}=${version:-}" && break ;;
            apt)
                sudo apt update -y
                sudo apt install -y "${pkg}=${version:-}" && break ;;
            yum)
                sudo yum install -y "${pkg}-${version:-}" && break ;;
        esac
        echo "[WARN] 安装失败，重试..." | tee -a $LOG_FILE
        sleep 2
    done
}

# --- 卸载包 ---
uninstall_package() {
    local pkg="$1"

    if [[ "$pkg" == custom:* ]]; then
        echo "[SKIP] 不支持卸载自定义工具: $pkg" | tee -a $LOG_FILE
        return
    fi

    if [[ "$pkg" == "awscli" ]]; then
        echo "[SKIP] 暂不自动卸载 awscli，请手动运行 /usr/local/bin/aws/install --remove" | tee -a $LOG_FILE
        return
    fi

    echo "[INFO] 卸载 $pkg ..." | tee -a $LOG_FILE
    case "$PKG_MANAGER" in
        zypper) sudo zypper --non-interactive remove "$pkg" ;;
        apt) sudo apt remove -y "$pkg" ;;
        yum) sudo yum remove -y "$pkg" ;;
    esac
}

# --- 主入口 ---
[[ "$1" == "--uninstall" ]] && MODE="uninstall"

validate_config

while IFS='=' read -r pkg version; do
    [[ -z "$pkg" || "$pkg" == \#* ]] && continue
    if [[ "$MODE" == "install" ]]; then
        install_package "$pkg" "$version"
    else
        uninstall_package "$pkg"
    fi
done < "$CONFIG_FILE"

# 安装完成后版本信息
if [[ "$MODE" == "install" ]]; then
    echo -e "\n==== 安装完成，版本信息 ====" | tee -a $LOG_FILE
    for tool in apache2 php java aws node docker; do
        if command -v $tool &> /dev/null; then
            echo -n "$tool: " | tee -a $LOG_FILE
            case $tool in
                apache2) apache2 -v | head -n1 | tee -a $LOG_FILE ;;
                php) php -v | head -n1 | tee -a $LOG_FILE ;;
                java) java -version 2>&1 | head -n1 | tee -a $LOG_FILE ;;
                aws) aws --version | tee -a $LOG_FILE ;;
                node) node -v | tee -a $LOG_FILE ;;
                docker) docker --version | tee -a $LOG_FILE ;;
            esac
        fi
    done
else
    echo -e "\n==== 卸载完成 ====" | tee -a $LOG_FILE
fi
