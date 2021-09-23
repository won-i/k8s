#!/bin/bash

# 脚本默认安装kubernetes 1.20.9版本
# 默认安装metrics、dashboard
# 脚本会生成加入集群的脚本

K8S_V=1.20.9
RES_URL=http://36.134.8.95:8001
PUB_REGISRRY=36.134.8.95:8090
RES_USER=admin
RES_PASSWD=aa12345

myip=$(hostname -I|awk '{print $1}')
registry_url=${myip}:8090

intall_cmds(){
	cat > /etc/yum.repos.d/95.repo <<EOF
[95]
name=95
baseurl=http://36.134.8.95:8001/
gpgcheck=0
EOF
	yum -y install gcc-c++ wget vim tar chattr docker-compose kubeadm-${K8S_V}  kubelet-${K8S_V}  kubectl-${K8S_V} ipvsadm keepalived
	wget ${RES_URL}/kubeadm1.20.9_10y.tar.gz --http-user=${RES_USER} --http-password=${RES_PASSWD}
	tar -xf kubeadm1.20.9_10y.tar.gz
	mv kubeadm /usr/bin/
	systemctl enable kubelet
}

# 环境初始化
init_os_env(){
	iptables -F
	iptables -X
	iptables -Z
	systemctl stop firewalld
	setenforce 0
	sed -i s/SELINUX=enforcing/SELINUX=disabled/g /etc/selinux/config

	swapoff -a
	sed -i '/swap/d' /etc/fstab

	cat > /etc/sysctl.d/k8s.conf << EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
EOF
	cat >> /var/spool/cron/root <<EOF
00 00 * * * /usr/sbin/ntpdate -u ntp.aliyun.com
EOF
	sysctl --system
	
	# 取消ssh首次登录提示
	echo "StrictHostKeyChecking no" >> /etc/ssh/ssh_config
	systemctl restart sshd

	# 最大文件句柄数
	cat >> /etc/security/limits.conf << EOF
root soft nofile 65535
root hard nofile 65535
* soft nofile 65535
* hard nofile 65535
EOF
	wget ${RES_URL}/auto_parted.sh --http-user=${RES_USER} --http-password=${RES_PASSWD}
	bash -x auto_parted.sh
	mkdir -p /data/res
}

# 安装docker
install_docker(){
	cd /data/res/
	wget ${RES_URL}/docker.tar.gz --http-user=${RES_USER} --http-password=${RES_PASSWD}
	tar -xf docker.tar.gz
	# ====================================
	mkdir -p /etc/docker/
	cat > /etc/docker/daemon.json <<EOF
{
    "graph": "/data/docker",
    "log-driver":"json-file",
    "log-opts": {"max-size":"100m", "max-file":"3"},
    "registry-mirrors": [ "https://registry.docker-cn.com"],
    "insecure-registries": ["${registry_url}","${PUB_REGISRRY}"]
}
EOF
	# ====================================
	cd docker
	bash -x install.sh
	systemctl enable docker
}

# 安装本地Harbor
install_harbor(){
	cd /data/res/
	wget ${RES_URL}/harbor2.0.tar.gz --http-user=${RES_USER} --http-password=${RES_PASSWD}
	tar -xf harbor2.0.tar.gz
	cd harbor
	mv harbor.yml.tmpl harbor.yml
	sed -i "s#reg.mydomain.com#${myip}#g" harbor.yml
	sed -i "s#port: 80#port: 8090#g" harbor.yml
	sed -i "/https/d" harbor.yml
	sed -i "/port: 443/d" harbor.yml
	sed -i "/certificate/d" harbor.yml
	sed -i "/private_key/d" harbor.yml
	sed -i "s#data_volume: /data#data_volume: /data/harbor#g" harbor.yml
	sed -i "s#location: /var/log/harbor#location: /data/harbor/log#g" harbor.yml
	bash -x install.sh
	cat > create.json <<EOF
{
  "project_name": "paas",
  "public": true
}
EOF
	sleep 3
	docker login --password=Harbor12345 --username=admin http://${registry_url}
	curl -su "admin:Harbor12345" -X POST -H "Content-Type: application/json" "http://${registry_url}/api/v2.0/projects" -d @create.json
}

# 生成init.yaml文件,安装 k8s master节点
install_k8s(){
	mkdir /data/res/k8s
	cd /data/res/k8s
	kubeadm config print init-defaults > init.yaml
	sed -i '/networking:/a\  podSubnet: 10.244.0.0/16' init.yaml
	sed -i "s#1.2.3.4#${myip}#g" init.yaml
	sed -i "s#k8s.gcr.io#${registry_url}/paas#g" init.yaml
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
		docker pull ${PUB_REGISRRY}/paas/${img_name}
		docker tag ${PUB_REGISRRY}/paas/${img_name} ${img}
		docker push ${img}
	done
	kubeadm init --config=init.yaml
	mkdir -p $HOME/.kube
	cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
	chown $(id -u):$(id -g) $HOME/.kube/config
	kubectl taint node $(hostname) node-role.kubernetes.io/master-
	join_cmd=$(kubeadm token create --print-join-command)
}

set_network(){
	cd /data/res/k8s
	docker pull ${PUB_REGISRRY}/paas/flannel:v0.14.0
	docker tag ${PUB_REGISRRY}/paas/flannel:v0.14.0  ${registry_url}/paas/flannel:v0.14.0
	docker push ${registry_url}/paas/flannel:v0.14.0
	
	wget ${RES_URL}/flannel_0.14.0.tar.gz --http-user=${RES_USER} --http-password=${RES_PASSWD}
	tar -xf flannel_0.14.0.tar.gz
	sed -i "s#FLANNEL_IMG#${registry_url}/paas/flannel:v0.14.0#g" flannel.yaml
	kubectl apply -f flannel.yaml
}

install_metrics(){
	cd /data/res/k8s/

	docker pull ${PUB_REGISRRY}/paas/metrics-server-amd64:v0.3.6
	docker tag ${PUB_REGISRRY}/paas/metrics-server-amd64:v0.3.6  ${registry_url}/paas/metrics-server-amd64:v0.3.6
	docker push ${registry_url}/paas/metrics-server-amd64:v0.3.6

	docker pull ${PUB_REGISRRY}/paas/addon-resizer:1.8.11
	docker tag ${PUB_REGISRRY}/paas/addon-resizer:1.8.11  ${registry_url}/paas/addon-resizer:1.8.11
	docker push ${registry_url}/paas/addon-resizer:1.8.11

	wget ${RES_URL}/metrics_0.3.6.tar.gz --http-user=${RES_USER} --http-password=${RES_PASSWD}
	tar -xf metrics_0.3.6.tar.gz
	cd metrics
	sed -i "s#METRICS_IMG#${registry_url}/paas/metrics-server-amd64:v0.3.6#g" metrics-server-deployment.yaml
	sed -i "s#ADDON_IMG#${registry_url}/paas/addon-resizer:1.8.11#g" metrics-server-deployment.yaml
	kubectl apply -f .
}

install_dashboard(){
	cd /data/res/k8s/
	wget ${RES_URL}/dashboard_1.20.9.tar.gz --http-user=${RES_USER} --http-password=${RES_PASSWD}
	tar -xf dashboard_1.20.9.tar.gz
	kubectl apply -f dashboard.yaml
	kubectl create serviceaccount dashboard-admin -n kube-system
	kubectl create clusterrolebinding dashboard-admin --clusterrole=cluster-admin --serviceaccount=kube-system:dashboard-admin
	dashboard_tocken=$(kubectl describe secrets -n kube-system $(kubectl -n kube-system get secret | awk '/dashboard-admin/{print $1}')|grep token|tail -n 1|awk '{print $2}')
	echo "访问面板Token: ${dashboard_tocken}"
}

install_node_sh(){
	cat > install_node.sh <<EOF
#!/bin/bash
K8S_V=1.20.9
RES_URL=http://36.134.8.95:8001
PUB_REGISRRY=36.134.8.95:8090
RES_USER=admin
RES_PASSWD=aa12345

myip=$(hostname -I|awk '{print $1}')

intall_cmds(){
	cat > /etc/yum.repos.d/95.repo <<EOF
[95]
name=95
baseurl=http://36.134.8.95:8001/
gpgcheck=0
EOF
	echo 'EOF' >> install_node.sh

	cat >> install_node.sh << EOF
	yum -y install gcc-c++ wget vim tar chattr  kubeadm-${K8S_V}  kubelet-${K8S_V}  kubectl-${K8S_V} ipvsadm keepalived
	systemctl enable kubelet
}

# 环境初始化
init_os_env(){
	iptables -F
	iptables -X
	iptables -Z
	systemctl stop firewalld
	setenforce 0
	sed -i s/SELINUX=enforcing/SELINUX=disabled/g /etc/selinux/config

	swapoff -a
	sed -i '/swap/d' /etc/fstab

	cat > /etc/sysctl.d/k8s.conf << EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
EOF
	echo 'EOF' >> install_node.sh

	cat >> install_node.sh << EOF
	cat >> /var/spool/cron/root <<EOF
00 00 * * * /usr/sbin/ntpdate -u ntp.aliyun.com
EOF
	echo 'EOF' >> install_node.sh
	cat >> install_node.sh << EOF
	sysctl --system
	
	# 取消ssh首次登录提示
	echo "StrictHostKeyChecking no" >> /etc/ssh/ssh_config
	systemctl restart sshd

	# 最大文件句柄数
	cat >> /etc/security/limits.conf << EOF
root soft nofile 65535
root hard nofile 65535
* soft nofile 65535
* hard nofile 65535
EOF
	echo 'EOF' >> install_node.sh
	cat >> install_node.sh << EOF
	wget ${RES_URL}/auto_parted.sh --http-user=${RES_USER} --http-password=${RES_PASSWD}
	bash -x auto_parted.sh
	mkdir -p /data/res
}

# 安装docker
install_docker(){
	cd /data/res/
	wget ${RES_URL}/docker.tar.gz --http-user=${RES_USER} --http-password=${RES_PASSWD}
	tar -xf docker.tar.gz
	# ====================================
	mkdir -p /etc/docker/
	cat > /etc/docker/daemon.json <<EOF
{
   "graph": "/data/docker", 
    "log-driver":"json-file",
    "log-opts": {"max-size":"100m", "max-file":"3"},
    "registry-mirrors": [ "https://registry.docker-cn.com"],
    "insecure-registries": ["${registry_url}","${PUB_REGISRRY}"]
}
EOF
	echo 'EOF' >> install_node.sh
	cat >> install_node.sh << EOF
	# ====================================
	cd docker
	bash -x install.sh
	systemctl enable docker
}

start_install(){
	intall_cmds
	init_os_env
	install_docker
	${join_cmd}
}

start_install
EOF
}

start_install(){
	start_time=$(date +'%Y-%m-%d %T')
	# ======
	intall_cmds
	init_os_env
	install_docker
	install_harbor
	install_k8s
	set_network
	install_metrics
	install_dashboard
	install_node_sh
	# ======
	end_time=$(date +'%Y-%m-%d %T')
	used_time=$(($(($(date +%s -d "${end_time}")-$(date +%s -d "${start_time}")))))
	echo 脚本耗时: ${used_time}s
}

start_install
