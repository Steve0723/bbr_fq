# BBR + FQ + TCP 优化脚本说明

## 项目简介

本目录包含一个用于 Linux 服务器（尤其是海外服务器）的网络优化脚本，用来一键开启 BBR 拥塞控制、`fq` 队列调度，并根据服务器内存大小与使用场景自动调整常用 TCP 参数。

目标场景：

- 海外线路直连，追求稳健的网络表现；
- 海外机房之间互联（大带宽、高延迟），需要更激进一些的参数。

## 目录结构

- `bbr_fq_tuning.sh`：推荐使用的主脚本，支持交互模式和命令行模式；

## 环境要求

- 操作系统：主流 Linux 发行版（Debian/Ubuntu/CentOS 等）；
- 内核版本：建议 **4.9 及以上**，以确保对 BBR 的良好支持；
- 权限要求：执行启用/写入配置时需要 root（使用 `sudo`）。

## 脚本功能概览

脚本主要功能：

- 检测内核是否支持 BBR，必要时尝试加载 `tcp_bbr` 模块；
- 启用 BBR 拥塞控制 + `fq` 默认队列：
  - `net.ipv4.tcp_congestion_control = bbr`
  - `net.core.default_qdisc = fq`
- 开启常用 TCP 优化：
  - `tcp_fastopen`、`tcp_mtu_probing`、`tcp_window_scaling` 等；
- 自动检测物理内存大小（MB），按档位选择缓冲区和队列参数；
- 提供两种场景档位：
  - `direct`：线路直连稳健版（更保守，适合大部分海外直连）；
  - `interconnect`：海外服务器互联版（更激进，适合机房互联/大带宽高 RTT）。

配置会写入：

- `/etc/sysctl.d/99-bbr-fq.conf`
- 如该文件已存在，会自动生成时间戳备份 `99-bbr-fq.conf.YYYYMMDDHHMMSS.bak`。

## 使用说明

### 1. 交互式模式（推荐）

在当前目录执行：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/Steve0723/bbr_fq/refs/heads/main/bbr_fq_tuning.sh)
```

交互流程：

1. 选择操作：
   - `0`：退出；
   - `1`：启用优化（写入并应用配置）；
   - `2`：仅预览配置（dry-run，不修改系统）；
   - `3`：查看当前状态（status）。
2. 若选择了 `1` 或 `2`，继续选择使用场景：
   - `0`：返回上一级；
   - `1`：线路直连稳健版（`direct`，默认，推荐）；
   - `2`：海外服务器互联版（`interconnect`，适合机房互联、大带宽高 RTT）。

### 2. 命令行模式

直接指定操作与场景：

```bash
# 开启线路直连稳健版
sudo ./bbr_fq_tuning.sh enable direct

# 开启海外服务器互联版
sudo ./bbr_fq_tuning.sh enable interconnect

# 预览对应场景将写入的配置（不修改系统）
sudo ./bbr_fq_tuning.sh dry-run direct
sudo ./bbr_fq_tuning.sh dry-run interconnect

# 查看当前 TCP/队列相关状态（无需 root）
./bbr_fq_tuning.sh status
```

## 配置位置与回滚说明

- 实际生效的配置文件：`/etc/sysctl.d/99-bbr-fq.conf`；
- 应用方式：由脚本自动执行 `sysctl -p /etc/sysctl.d/99-bbr-fq.conf`；
- 回滚方式（示例）：
  - 删除或重命名该配置文件，或用脚本生成的 `.bak` 备份覆盖；
  - 然后执行 `sudo sysctl --system` 或重启服务器。

在生产环境使用前，建议先在测试节点上验证带宽、延迟和连接数表现，确认无异常后再推广到更多服务器。

