#!/bin/bash
set -e
set -u

# 基于内存大小与使用场景（海外服务器互联 / 线路直连稳健版）自动调整 BBR+FQ+TCP 参数
# 支持命令行参数与交互式选择两种使用方式：
#   - 直接指定：
#       稳健版（推荐普通直连线路、中小型业务）：
#           sudo ./bbr_fq_tuning.sh enable direct
#       海外服务器互联（数据中心互联、大带宽长延迟链路，略偏激进）：
#           sudo ./bbr_fq_tuning.sh enable interconnect
#       仅预览将要写入的参数：
#           sudo ./bbr_fq_tuning.sh dry-run direct
#           sudo ./bbr_fq_tuning.sh dry-run interconnect
#       查看当前系统参数：
#           ./bbr_fq_tuning.sh status
#   - 交互式选择（推荐日常使用）：
#           sudo ./bbr_fq_tuning.sh

CONFIG_FILE="/etc/sysctl.d/99-bbr-fq.conf"

# 内存与参数档位相关全局变量
mem_mb=0                  # 物理内存大小（MB）
mem_size_profile=""       # small / medium / large / xlarge
tune_profile=""           # direct / interconnect
selected_action=""        # enable / dry-run / status（交互模式下使用）

core_rmem_max=0
core_wmem_max=0
tcp_rmem_mid=0
tcp_rmem_max=0
tcp_wmem_mid=0
tcp_wmem_max=0
netdev_max_backlog=0
somaxconn=0

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "请以 root 身份运行本脚本，例如：sudo $0 enable direct"
        exit 1
    fi
}

check_kernel_version() {
    # 只做简单版本提示，不强制终止
    local ver
    ver=$(uname -r | awk -F. '{printf "%d%02d\n", $1, $2}')
    if (( ver < 409 )); then
        echo "当前内核版本为 $(uname -r)，可能不完全支持 BBR（推荐 >= 4.9）。"
        echo "继续执行可能失败，请自行评估风险。"
    fi
}

check_bbr_support() {
    if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
        return 0
    fi

    echo "系统当前未报告支持 bbr，尝试加载 tcp_bbr 模块..."
    if modprobe tcp_bbr 2>/dev/null; then
        echo "已尝试加载 tcp_bbr 模块。"
    else
        echo "无法加载 tcp_bbr 模块，可能是内核不支持 BBR。"
        return 1
    fi

    if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
        return 0
    else
        echo "仍未检测到 bbr 拥塞控制，请检查内核配置。"
        return 1
    fi
}

detect_memory_mb() {
    local mem_kb
    mem_kb=$(grep -i "MemTotal" /proc/meminfo | awk '{print $2}')
    mem_mb=$((mem_kb / 1024))
}

detect_memory_profile() {
    detect_memory_mb
    echo "检测到物理内存约为 ${mem_mb} MB"

    if (( mem_mb <= 1024 )); then
        mem_size_profile="small"
    elif (( mem_mb <= 4096 )); then
        mem_size_profile="medium"
    elif (( mem_mb <= 16384 )); then
        mem_size_profile="large"
    else
        mem_size_profile="xlarge"
    fi

    echo "内存大小档位：${mem_size_profile}"
}

set_params_for_profile() {
    # 根据 mem_size_profile 与 tune_profile 组合设定具体参数
    # direct       ：线路直连稳健版（推荐大部分海外直连场景）
    # interconnect ：海外服务器互联版（大带宽、高 RTT，参数略偏激进）
    local profile="$1"
    tune_profile="${profile}"

    case "${mem_size_profile}" in
        small)
            if [[ "${profile}" == "interconnect" ]]; then
                # 小内存互联版：略放大，但控制在安全范围内
                core_rmem_max=12582912           # 12MB
                core_wmem_max=12582912           # 12MB
                tcp_rmem_mid=262144
                tcp_rmem_max=12582912
                tcp_wmem_mid=262144
                tcp_wmem_max=12582912
                netdev_max_backlog=24576
                somaxconn=1536
            else
                # 小内存稳健版
                core_rmem_max=8388608            # 8MB
                core_wmem_max=8388608            # 8MB
                tcp_rmem_mid=131072
                tcp_rmem_max=8388608
                tcp_wmem_mid=131072
                tcp_wmem_max=8388608
                netdev_max_backlog=16384
                somaxconn=1024
            fi
            ;;
        medium)
            if [[ "${profile}" == "interconnect" ]]; then
                core_rmem_max=33554432           # 32MB
                core_wmem_max=33554432           # 32MB
                tcp_rmem_mid=524288
                tcp_rmem_max=33554432
                tcp_wmem_mid=524288
                tcp_wmem_max=33554432
                netdev_max_backlog=65535
                somaxconn=4096
            else
                core_rmem_max=16777216           # 16MB
                core_wmem_max=16777216           # 16MB
                tcp_rmem_mid=262144
                tcp_rmem_max=16777216
                tcp_wmem_mid=262144
                tcp_wmem_max=16777216
                netdev_max_backlog=32768
                somaxconn=2048
            fi
            ;;
        large)
            if [[ "${profile}" == "interconnect" ]]; then
                core_rmem_max=67108864           # 64MB
                core_wmem_max=67108864           # 64MB
                tcp_rmem_mid=1048576
                tcp_rmem_max=67108864
                tcp_wmem_mid=1048576
                tcp_wmem_max=67108864
                netdev_max_backlog=131072
                somaxconn=8192
            else
                core_rmem_max=33554432           # 32MB
                core_wmem_max=33554432           # 32MB
                tcp_rmem_mid=524288
                tcp_rmem_max=33554432
                tcp_wmem_mid=524288
                tcp_wmem_max=33554432
                netdev_max_backlog=65535
                somaxconn=4096
            fi
            ;;
        xlarge)
            if [[ "${profile}" == "interconnect" ]]; then
                core_rmem_max=134217728          # 128MB
                core_wmem_max=134217728          # 128MB
                tcp_rmem_mid=2097152
                tcp_rmem_max=134217728
                tcp_wmem_mid=2097152
                tcp_wmem_max=134217728
                netdev_max_backlog=262144
                somaxconn=16384
            else
                core_rmem_max=67108864           # 64MB
                core_wmem_max=67108864           # 64MB
                tcp_rmem_mid=1048576
                tcp_rmem_max=67108864
                tcp_wmem_mid=1048576
                tcp_wmem_max=67108864
                netdev_max_backlog=131072
                somaxconn=8192
            fi
            ;;
        *)
            echo "无法识别的内存档位：${mem_size_profile}"
            exit 1
            ;;
    esac

    echo "使用场景档位：${tune_profile}（direct=线路直连稳健版，interconnect=海外服务器互联版）"
}

prepare_params() {
    detect_memory_profile
    set_params_for_profile "${tune_profile}"
}

write_config() {
    local backup_file

    # 先根据当前内存与场景准备参数
    prepare_params

    if [[ -f "${CONFIG_FILE}" ]]; then
        backup_file="${CONFIG_FILE}.$(date +%Y%m%d%H%M%S).bak"
        cp "${CONFIG_FILE}" "${backup_file}"
        echo "已备份原有配置为: ${backup_file}"
    fi

    cat > "${CONFIG_FILE}" << EOF
# BBR + FQ 与 TCP 优化配置（自动生成）
# 使用场景：${tune_profile} （direct=线路直连稳健版，interconnect=海外服务器互联版）
# 检测到内存：${mem_mb} MB，内存档位：${mem_size_profile}
#
# 注意：若需切换场景，可重新运行本脚本：
#   海外服务器互联版：sudo $0 enable interconnect
#   线路直连稳健版：sudo $0 enable direct

# 使用 BBR 拥塞控制 + fq 队列
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# 开启 TCP Fast Open（客户端+服务端）
net.ipv4.tcp_fastopen = 3

# 启用 MTU 探测，减小路径 MTU 问题
net.ipv4.tcp_mtu_probing = 1

# 显式开启窗口扩展（通常默认开启）
net.ipv4.tcp_window_scaling = 1

# 根据内存与场景自动调整的缓冲区与队列参数
net.core.rmem_max = ${core_rmem_max}
net.core.wmem_max = ${core_wmem_max}
net.ipv4.tcp_rmem = 4096 ${tcp_rmem_mid} ${tcp_rmem_max}
net.ipv4.tcp_wmem = 4096 ${tcp_wmem_mid} ${tcp_wmem_max}
net.core.netdev_max_backlog = ${netdev_max_backlog}
net.core.somaxconn = ${somaxconn}
EOF

    echo "已写入配置到 ${CONFIG_FILE}"
}

apply_config() {
    echo "正在通过 sysctl 应用配置..."
    sysctl -p "${CONFIG_FILE}"
    echo "配置已应用完成。"
}

show_status() {
    echo "=== 当前 TCP 拥塞控制算法 ==="
    sysctl net.ipv4.tcp_congestion_control

    echo "=== 当前默认队列算法 ==="
    sysctl net.core.default_qdisc

    echo "=== TCP 关键参数（缓冲区与队列） ==="
    sysctl net.ipv4.tcp_fastopen
    sysctl net.ipv4.tcp_mtu_probing
    sysctl net.ipv4.tcp_window_scaling
    sysctl net.core.rmem_max
    sysctl net.core.wmem_max
    sysctl net.ipv4.tcp_rmem
    sysctl net.ipv4.tcp_wmem
    sysctl net.core.netdev_max_backlog
    sysctl net.core.somaxconn
}

dry_run() {
    # 仅预览将要写入的配置，不真正修改系统
    prepare_params

    echo "如果执行 enable，将写入如下配置到 ${CONFIG_FILE}："
    cat << EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_window_scaling = 1
net.core.rmem_max = ${core_rmem_max}
net.core.wmem_max = ${core_wmem_max}
net.ipv4.tcp_rmem = 4096 ${tcp_rmem_mid} ${tcp_rmem_max}
net.ipv4.tcp_wmem = 4096 ${tcp_wmem_mid} ${tcp_wmem_max}
net.core.netdev_max_backlog = ${netdev_max_backlog}
net.core.somaxconn = ${somaxconn}
EOF
}

print_usage() {
    cat << 'EOF'
用法:
  # 交互式选择（推荐）：
  sudo ./bbr_fq_tuning.sh

  # 直接指定模式：
  sudo ./bbr_fq_tuning.sh enable direct        # 开启线路直连稳健版（推荐默认）
  sudo ./bbr_fq_tuning.sh enable interconnect  # 开启海外服务器互联版（更适合大带宽高延迟）

  sudo ./bbr_fq_tuning.sh dry-run direct       # 预览直连稳健版将写入的参数
  sudo ./bbr_fq_tuning.sh dry-run interconnect # 预览互联版将写入的参数

  ./bbr_fq_tuning.sh status                    # 查看当前相关 TCP/队列参数
EOF
}

interactive_select() {
    while true; do
        echo "============== BBR + FQ + TCP 优化助手 =============="
        echo "请选择要执行的操作："
        echo "  0) 退出"
        echo "  1) 启用优化（写入并应用配置）"
        echo "  2) 仅预览配置（dry-run，不修改系统）"
        echo "  3) 查看当前状态（status）"
        read -rp "请输入数字 [0-3]（默认 3）: " choice

        case "${choice}" in
            0)
                echo "已退出。"
                exit 0
                ;;
            1)
                selected_action="enable"
                ;;
            2)
                selected_action="dry-run"
                ;;
            3|"")
                selected_action="status"
                ;;
            *)
                echo "输入无效，请重新选择。"
                continue
                ;;
        esac

        # enable / dry-run 需要选择使用场景
        if [[ "${selected_action}" == "enable" || "${selected_action}" == "dry-run" ]]; then
            if ! select_profile; then
                # 用户选择返回上一级，重新选择操作
                continue
            fi
        fi

        # 选择完成，退出交互循环
        break
    done
}

select_profile() {
    # 选择使用场景：0 返回上一级，1/2 选择不同档位
    while true; do
        echo
        echo "请选择使用场景（影响参数强度）："
        echo "  0) 返回上一级"
        echo "  1) 线路直连稳健版（direct，适合大部分海外直连场景，推荐）"
        echo "  2) 海外服务器互联版（interconnect，适合机房互联/大带宽高 RTT）"
        read -rp "请输入数字 [0-2]（默认 1）: " pchoice

        case "${pchoice}" in
            0)
                # 返回上一层菜单
                return 1
                ;;
            2)
                tune_profile="interconnect"
                return 0
                ;;
            1|"")
                tune_profile="direct"
                return 0
                ;;
            *)
                echo "输入无效，请重新选择。"
                ;;
        esac
    done
}

main() {
    local action="${1:-}"
    local profile="${2:-}"

    # 未提供任何参数时，进入交互模式
    if [[ -z "${action}" ]]; then
        interactive_select
        action="${selected_action}"
    fi

    # 如果通过命令行传入 profile，则覆盖交互模式中的选择
    if [[ -n "${profile}" ]]; then
        case "${profile}" in
            direct|interconnect)
                tune_profile="${profile}"
                ;;
            *)
                echo "第二个参数必须是 direct 或 interconnect。"
                print_usage
                exit 1
                ;;
        esac
    fi

    # 对于需要 profile 的操作，如果仍未设置，默认 direct
    if [[ ( "${action}" == "enable" || "${action}" == "dry-run" ) && -z "${tune_profile}" ]]; then
        tune_profile="direct"
    fi

    case "${action}" in
        enable)
            require_root
            check_kernel_version
            if ! check_bbr_support; then
                echo "未检测到 BBR 支持，终止。"
                exit 1
            fi
            write_config
            apply_config
            show_status
            echo "已尝试开启 BBR + FQ 以及按内存和场景自动调整的 TCP 优化。"
            echo "若出现异常，可删除 ${CONFIG_FILE} 或恢复同目录下的 .bak 文件后重启。"
            ;;
        status)
            show_status
            ;;
        dry-run)
            dry_run
            ;;
        *)
            print_usage
            exit 1
            ;;
    esac
}

main "$@"
