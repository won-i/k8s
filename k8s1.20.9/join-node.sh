#!/bin/bash

harbor=HARBORADDR

init_os(){
	# 添加yum源，安装基础组件
	cp *.repo /etc/yum.repos.d/
	yum -y install epel-release docker-ce-20.10.14 kubeadm-1.20.9  kubelet-1.20.9  kubectl-1.20.9 ipvsadm ntpdate wget
	systemctl enable docker kubelet keepalived
	# 清理防火墙和安全组
	iptables -F
	iptables -X
	iptables -Z
	systemctl stop firewalld
	setenforce 0
	sed -i s/SELINUX=enforcing/SELINUX=disabled/g /etc/selinux/config
	# 关闭swap分区
	swapoff -a
	sed -i '/swap/d' /etc/fstab
	# 添加时区同步
	cat >> /var/spool/cron/root <<EOF
00 00 * * * /usr/sbin/ntpdate -u ntp.aliyun.com
EOF
	# 添加系统参数
	cat > /etc/sysctl.d/k8s.conf << EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
EOF
	sysctl --system
	# 修改最大句柄数
	cat >> /etc/security/limits.conf << EOF
root soft nofile 65535
root hard nofile 65535
* soft nofile 65535
* hard nofile 65535
EOF
	# 关闭首次登录提示
	echo "StrictHostKeyChecking no" >> /etc/ssh/ssh_config
	systemctl restart sshd
	# 创建文件下载目录
	mkdir -p /data/res

}

config_docker(){
	# 修改docker配置
	mkdir /etc/docker/
	cat > /etc/docker/daemon.json <<EOF
{
    "graph": "/data/docker",
    "log-driver":"json-file",
    "log-opts": {"max-size":"100m", "max-file":"3"},
    "registry-mirrors": [ "https://registry.docker-cn.com"],
    "insecure-registries": ["${harbor}:8090","36.134.8.95:8090"],
    "exec-opts": ["native.cgroupdriver=systemd"]
}
EOF
	systemctl restart docker
}

join_master(){       
	JOIN_CMD
}

init_os
config_docker
join_master
