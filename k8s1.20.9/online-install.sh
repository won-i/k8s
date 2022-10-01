#!/bin/bash
# CentOS
# 在线安装

current_ip=$(hostname -I|awk '{print $1}')
harbor_pass=Fqs@15792
registry=ajsh-pro
virtual_ip=10.4.7.55
api01=${current_ip}
api02=10.4.7.42
api03=10.4.7.43

sed -i "s#APISERVER01#${api01}#g" join-master.sh
sed -i "s#APISERVER02#${api02}#g" join-master.sh
sed -i "s#APISERVER03#${api03}#g" join-master.sh

init_os(){
	# 添加yum源，安装基础组件
	cp *.repo /etc/yum.repos.d/
	yum -y install epel-release docker-ce-20.10.14 kubeadm-1.20.9  kubelet-1.20.9  kubectl-1.20.9 ipvsadm ntpdate wget
	chmod +x docker-compose
	systemctl enable docker kubelet keepalived
	mv docker-compose /usr/bin
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
    "insecure-registries": ["${current_ip}:8090","36.134.8.95:8090"],
    "exec-opts": ["native.cgroupdriver=systemd"]
}
EOF
	systemctl restart docker
}

install_harbor(){
	# 安装harbor2.0
	sed -i "s#HARBORADDR#${current_ip}#g" join-master.sh
	cd /data/res/
	wget 36.134.8.95:8001/harbor2.0.tar.gz
	tar -xf harbor2.0.tar.gz
	cd harbor
	mv harbor.yml.tmpl harbor.yml
	sed -i "s#reg.mydomain.com#${current_ip}#g" harbor.yml
	sed -i "s#port: 80#port: 8090#g" harbor.yml
	sed -i "/https/d" harbor.yml
	sed -i "/port: 443/d" harbor.yml
	sed -i "/certificate/d" harbor.yml
	sed -i "/private_key/d" harbor.yml
	sed -i "s#data_volume: /data#data_volume: /data/harbor#g" harbor.yml
	sed -i "s#location: /var/log/harbor#location: /data/harbor/log#g" harbor.yml
	sed -i "s#Harbor12345#${harbor_pass}#g" harbor.yml
	bash -x install.sh
	sleep 3
	# 初始化仓库
	cd ~/install/
	yum -y install jq
	docker login --password=${harbor_pass} --username=admin http://${current_ip}:8090
	sed -i "s#REGISTRY#${registry}#g" project.json
	curl -su "admin:${harbor_pass}" -X POST -H "Content-Type: application/json" "http://${current_ip}:8090/api/v2.0/projects" -d @project.json
	curl -su "admin:${harbor_pass}" -X POST -H "Content-Type: application/json" "http://${current_ip}:8090/api/v2.0/projects" -d @paas.json
	# 修改镜像保存策略
	registry_id=$(curl -su "admin:${harbor_pass}" -X GET -H "Content-Type: application/json" "http://${current_ip}:8090/api/v2.0/projects/${registry}"|jq -r ".project_id")
	sed -i "s#PROJECT_ID#${registry_id}#g" retentions.json
	curl -su "admin:${harbor_pass}" -X POST -H "Content-Type: application/json" "http://${current_ip}:8090/api/v2.0/retentions" -d@retentions.json
}

install_keepalived(){
	yum -y install keepalived net-tools
	rm -rf /etc/keepalived.conf
	chmod +x  ~/install/check.sh
	cp  ~/install/check.sh /etc/keepalived/
	interface=$(ifconfig |grep -B 1  ${current_ip} |head -n 1|awk -F : '{print $1}')
	sed -i "s#INTERFACE_NAME#${interface}#g" ~/install/keepalived*.conf
	sed -i "s#CURRENT_IP#${api01}#g" ~/install/keepalived-master.conf
	sed -i "s#CURRENT_IP#${api02}#g" ~/install/keepalived-backup01.conf
	sed -i "s#CURRENT_IP#${api03}#g" ~/install/keepalived-backup02.conf
	sed -i "s#VIRTUAL_IP#${virtual_ip}#g" ~/install/keepalived*.conf
	cp ~/install/keepalived-master.conf /etc/keepalived/keepalived.conf
	systemctl start keepalived
}

install_haproxy(){
	yum -y install haproxy
	rm -rf /etc/haproxy/haproxy.cfg
	sed -i "s#VIRTUAL_IP#${virtual_ip}#g" ~/install/haproxy.cfg
	sed -i "s#API01#${api01}#g" ~/install/haproxy.cfg
	sed -i "s#API02#${api02}#g" ~/install/haproxy.cfg
	sed -i "s#API03#${api03}#g" ~/install/haproxy.cfg
	cp ~/install/haproxy.cfg /etc/haproxy/
	systemctl start haproxy
	systemctl enable haproxy
	systemctl status haproxy &> /dev/null
	while [[ 1 -eq 1 ]]; do
		if [ $? -ne 0 ];then
			sleep 2
			echo "haproxy重启..."
			systemctl restart haproxy
		else 
			break
		fi
	done
}

copy_pki(){
	mkdir -p ~/install/pki/etcd 
	cp /etc/kubernetes/pki/ca.crt               ~/install/pki/
	cp /etc/kubernetes/pki/ca.key               ~/install/pki/
	cp /etc/kubernetes/pki/sa.key               ~/install/pki/
	cp /etc/kubernetes/pki/sa.pub               ~/install/pki/
	cp /etc/kubernetes/pki/front-proxy-ca.crt   ~/install/pki/
	cp /etc/kubernetes/pki/front-proxy-ca.key   ~/install/pki/
	cp /etc/kubernetes/pki/etcd/ca.crt          ~/install/pki/etcd/
	cp /etc/kubernetes/pki/etcd/ca.key          ~/install/pki/etcd/
	cp /etc/kubernetes/admin.conf               ~/install/
}

install_k8s(){
	multiple=${1}
	mkdir /data/res/k8s
	cd /data/res/k8s
	kubeadm config print init-defaults > init.yaml
	# 双主
	if [ ${multiple} ];then
		install_keepalived
		install_haproxy
		echo "controlPlaneEndpoint: ${virtual_ip}:8443" >> init.yaml
	fi
	sed -i '/networking:/a\  podSubnet: 10.244.0.0/16' init.yaml
	sed -i "s#1.2.3.4#${current_ip}#g" init.yaml
	sed -i "s#k8s.gcr.io#${current_ip}:8090/paas#g" init.yaml
	cat >> init.yaml <<EOF
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: ipvs
EOF
	images_list=$(kubeadm config images list --config=init.yaml)
	for img in ${images_list[@]}
	do
		img_name=$(echo $img|awk -F / '{print $NF}')
		docker pull registry.aliyuncs.com/google_containers/${img_name}
		docker tag registry.aliyuncs.com/google_containers/${img_name} ${img}
		docker push ${img}
	done
	kubeadm init --config=init.yaml
	mkdir -p $HOME/.kube
	cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
	chown $(id -u):$(id -g) $HOME/.kube/config
	kubectl taint node $(hostname) node-role.kubernetes.io/master-
	join_cmd=$(kubeadm token create --print-join-command)
	install_flannel
	if [ ${multiple} ];then
		copy_pki
		sed -i "s#JOIN_CMD#${join_cmd}#g" ~/install/join-master.sh
	fi
}

install_flannel(){
	cd /data/res/k8s
	docker pull harbor.data4truth.com:8443/paas/flannel:v0.14.0
	docker pull harbor.data4truth.com:8443/paas/flannel-cni-plugin:v1.1.0
	docker tag harbor.data4truth.com:8443/paas/flannel:v0.14.0  ${current_ip}:8090/paas/flannel:v0.14.0
	docker tag harbor.data4truth.com:8443/paas/flannel-cni-plugin:v1.1.0  ${current_ip}:8090/paas/flannel-cni-plugin:v1.1.0
	docker push ${current_ip}:8090/paas/flannel:v0.14.0
	docker push ${current_ip}:8090/paas/flannel-cni-plugin:v1.1.0
	cp  ~/install/flannel.yaml .
	sed -i "s#FLANNELIMG#${current_ip}:8090/paas/flannel:v0.14.0#g" flannel.yaml
	sed -i "s#CNIIMG#${current_ip}:8090/paas/flannel-cni-plugin:v1.1.0#g" flannel.yaml
	kubectl apply -f flannel.yaml
}

init_os
config_docker
install_harbor
install_k8s $1
