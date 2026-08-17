#!/bin/sh
# Collect read-only platform information before installation or firmware changes.
set -u

echo '== OpenWrt release =='
cat /etc/openwrt_release 2>/dev/null || true
echo '== Board =='
ubus call system board 2>/dev/null || true
echo '== Radios and interfaces =='
iw dev 2>/dev/null || true
echo '== Radio capabilities =='
iw list 2>/dev/null || true
echo '== Storage =='
df -h 2>/dev/null || true
echo '== Network addresses =='
ip -brief address 2>/dev/null || ip address 2>/dev/null || true
