#!/usr/bin/env bash
Green_font_prefix="\033[32m"
Red_font_prefix="\033[31m"
Font_color_suffix="\033[0m"
Info="${Green_font_prefix}[信息]${Font_color_suffix}"
Error="${Red_font_prefix}[错误]${Font_color_suffix}"
Tip="${Green_font_prefix}[注意]${Font_color_suffix}"

copyright(){
    clear
echo "\
############################################################

Linux 网络优化脚本 (自适应版)
支持: Debian / Ubuntu
内核 >= 4.9 自动启用 BBR
TCP 缓冲区 & 系统资源限制 根据 VPS 内存自动调整

############################################################
"
}

tcp_tune(){ # TCP 窗口调优 (自适应内存)
MEM_TOTAL=$(grep MemTotal /proc/meminfo | awk '{print $2}') # KB
MEM_GB=$((MEM_TOTAL / 1024 / 1024))

if [ $MEM_GB -le 1 ]; then
  RMEM=4194304
  WMEM=4194304
elif [ $MEM_GB -le 3 ]; then
  RMEM=8388608
  WMEM=8388608
else
  RMEM=33554432
  WMEM=33554432
fi

sed -i '/^net.ipv4.tcp_/d' /etc/sysctl.conf
sed -i '/^net.core.rmem_max/d' /etc/sysctl.conf
sed -i '/^net.core.wmem_max/d' /etc/sysctl.conf
sed -i '/^net.ipv4.udp_rmem_min/d' /etc/sysctl.conf
sed -i '/^net.ipv4.udp_wmem_min/d' /etc/sysctl.conf
sed -i '/^net.core.default_qdisc/d' /etc/sysctl.conf
sed -i '/^net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf

cat >> /etc/sysctl.conf << EOF
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_ecn=0
net.ipv4.tcp_frto=2
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_rfc1337=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_fack=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_adv_win_scale=2
net.ipv4.tcp_moderate_rcvbuf=1
net.core.rmem_max=$RMEM
net.core.wmem_max=$WMEM
net.ipv4.tcp_rmem=4096 87380 $RMEM
net.ipv4.tcp_wmem=4096 16384 $WMEM
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

sysctl -p && sysctl --system
echo -e "${Info} 已根据内存 ${MEM_GB}G 设置 TCP 缓冲区: rmem=$RMEM wmem=$WMEM"
}

enable_forwarding(){ # 开启内核转发
sed -i '/^net.ipv4.conf.all.route_localnet/d' /etc/sysctl.conf
sed -i '/^net.ipv4.ip_forward/d' /etc/sysctl.conf
sed -i '/^net.ipv4.conf.all.forwarding/d' /etc/sysctl.conf
sed -i '/^net.ipv4.conf.default.forwarding/d' /etc/sysctl.conf
cat >> '/etc/sysctl.conf' << EOF
net.ipv4.conf.all.route_localnet=1
net.ipv4.ip_forward=1
net.ipv4.conf.all.forwarding=1
net.ipv4.conf.default.forwarding=1
EOF
sysctl -p && sysctl --system
}

banping(){ # 屏蔽 ICMP
sed -i '/^net.ipv4.icmp_echo_ignore_all/d' /etc/sysctl.conf
sed -i '/^net.ipv4.icmp_echo_ignore_broadcasts/d' /etc/sysctl.conf
cat >> '/etc/sysctl.conf' << EOF
net.ipv4.icmp_echo_ignore_all=1
net.ipv4.icmp_echo_ignore_broadcasts=1
EOF
sysctl -p && sysctl --system
}

unbanping(){ # 开放 ICMP，但保持广播保护
sed -i "s/net.ipv4.icmp_echo_ignore_all=1/net.ipv4.icmp_echo_ignore_all=0/g" /etc/sysctl.conf
sed -i '/^net.ipv4.icmp_echo_ignore_broadcasts/d' /etc/sysctl.conf
echo "net.ipv4.icmp_echo_ignore_broadcasts=1" >> /etc/sysctl.conf
sysctl -p && sysctl --system
}

ulimit_tune(){ # 系统资源限制 (自适应内存)
MEM_TOTAL=$(grep MemTotal /proc/meminfo | awk '{print $2}') # KB
MEM_GB=$((MEM_TOTAL / 1024 / 1024))

if [ $MEM_GB -le 1 ]; then
  LIMIT=65535
elif [ $MEM_GB -le 3 ]; then
  LIMIT=131072
else
  LIMIT=262144
fi

sed -i '/^fs.file-max/d' /etc/sysctl.conf
echo "fs.file-max=$LIMIT" >> /etc/sysctl.conf
sysctl -p

ulimit -SHn $LIMIT && ulimit -c unlimited

cat > /etc/security/limits.conf << EOF
root     soft   nofile    $LIMIT
root     hard   nofile    $LIMIT
root     soft   nproc     $LIMIT
root     hard   nproc     $LIMIT
root     soft   core      $LIMIT
root     hard   core      $LIMIT
root     hard   memlock   unlimited
root     soft   memlock   unlimited

*     soft   nofile    $LIMIT
*     hard   nofile    $LIMIT
*     soft   nproc     $LIMIT
*     hard   nproc     $LIMIT
*     soft   core      $LIMIT
*     hard   core      $LIMIT
*     hard   memlock   unlimited
*     soft   memlock   unlimited
EOF

if ! grep -q "ulimit" /etc/profile; then
  echo "ulimit -SHn $LIMIT" >>/etc/profile
fi
if ! grep -q "pam_limits.so" /etc/pam.d/common-session; then
  echo "session required pam_limits.so" >>/etc/pam.d/common-session
fi

sed -i '/DefaultLimitCORE/d' /etc/systemd/system.conf
sed -i '/DefaultLimitNOFILE/d' /etc/systemd/system.conf
sed -i '/DefaultLimitNPROC/d' /etc/systemd/system.conf

cat >>'/etc/systemd/system.conf' <<EOF
[Manager]
DefaultLimitCORE=infinity
DefaultLimitNOFILE=$LIMIT
DefaultLimitNPROC=$LIMIT
EOF

systemctl daemon-reload
echo -e "${Info} 已根据内存 ${MEM_GB}G 设置资源限制: nofile/nproc=$LIMIT file-max=$LIMIT"
}

restore_defaults(){ # 恢复系统默认配置
echo -e "${Info} 恢复系统默认配置中..."

sed -i '/^net.ipv4.tcp_/d' /etc/sysctl.conf
sed -i '/^net.core.rmem_max/d' /etc/sysctl.conf
sed -i '/^net.core.wmem_max/d' /etc/sysctl.conf
sed -i '/^net.ipv4.udp_rmem_min/d' /etc/sysctl.conf
sed -i '/^net.ipv4.udp_wmem_min/d' /etc/sysctl.conf
sed -i '/^net.core.default_qdisc/d' /etc/sysctl.conf
sed -i '/^net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
sed -i '/^net.ipv4.conf.all.route_localnet/d' /etc/sysctl.conf
sed -i '/^net.ipv4.ip_forward/d' /etc/sysctl.conf
sed -i '/^net.ipv4.conf.all.forwarding/d' /etc/sysctl.conf
sed -i '/^net.ipv4.conf.default.forwarding/d' /etc/sysctl.conf
sed -i '/^net.ipv4.icmp_echo_ignore_all/d' /etc/sysctl.conf
sed -i '/^net.ipv4.icmp_echo_ignore_broadcasts/d' /etc/sysctl.conf
sed -i '/^fs.file-max/d' /etc/sysctl.conf

> /etc/security/limits.conf

sed -i '/DefaultLimitCORE/d' /etc/systemd/system.conf
sed -i '/DefaultLimitNOFILE/d' /etc/systemd/system.conf
sed -i '/DefaultLimitNPROC/d' /etc/systemd/system.conf

sysctl --system
systemctl daemon-reexec

echo -e "${Info} 已恢复为系统默认参数。"
}

verify_settings(){ # 验证命令合集
echo "============ 验证网络调优状态 ============"
sysctl net.ipv4.tcp_congestion_control
sysctl net.core.default_qdisc
sysctl net.ipv4.tcp_rmem
sysctl net.ipv4.tcp_wmem
sysctl net.ipv4.icmp_echo_ignore_all
sysctl net.ipv4.icmp_echo_ignore_broadcasts
sysctl fs.file-max
ulimit -n
echo "=========================================="
}

menu() {
  echo -e "\
${Green_font_prefix}1.${Font_color_suffix} 安装BBR原版内核(已经是5.x的不需要)
${Green_font_prefix}2.${Font_color_suffix} TCP窗口调优 (自适应内存)
${Green_font_prefix}3.${Font_color_suffix} 开启内核转发
${Green_font_prefix}4.${Font_color_suffix} 系统资源限制调优 (自适应内存)
${Green_font_prefix}5.${Font_color_suffix} 屏蔽ICMP
${Green_font_prefix}6.${Font_color_suffix} 开放ICMP
${Green_font_prefix}7.${Font_color_suffix} 恢复系统默认参数
${Green_font_prefix}8.${Font_color_suffix} 验证当前设置
"

  read -p "请输入数字: " num
  case "$num" in
  2) tcp_tune ;;
  3) enable_forwarding ;;
  4) ulimit_tune ;;
  5) banping ;;
  6) unbanping ;;
  7) restore_defaults ;;
  8) verify_settings ;;
  *) echo -e "${Error}: 请输入正确数字 [1-8]"; sleep 3s; menu ;;
  esac
}

copyright
menu
