# 12 Kubernetes Calico Network #

Calico/Kubernetes集成3个组件：

- calico/node： Calico per-node docker container	 
- calico-cni network plugin binaries: 包含两个可执行文件calico和calcio-ipam，及一个配置文件（存储calico启动的参数配置）。注：需额外添加loopback二进制文件，包含在`containernetworking/cni`项目里。
- Calico policy controller： Kubernetes NetworkPolicy管理。	

其中：

- calico/node docker容器包含Calcio路由必须的BGP代理，必须运行在Kubernetes Master节点和各Node节点上。
- calico-cni与Kubelet集成，用于发现Pod创建，并将Pod添加至Calico网络。
- calico/kube-policy-controller容器以Pod方式运行在Kubernetes集群中，并实现NetworkPolicy API。 版本要求Kubernetes >= 1.3.0.


## 12.1 Calico 安装配置 ##
所需文件部分已上传至[http://172.17.249.122/qsfang/learnk8s/tree/master/poc/yamls1.4/kube-network](http://172.17.249.122/qsfang/learnk8s/tree/master/poc/yamls1.4/kube-network)


**1、镜像准备**

- calico/node
- calico/kube-policy-controller

**2、下载所需二进制文件**

- calicoctl
	
		# Download and install `calicoctl`
		wget https://github.com/projectcalico/calico-containers/releases/download/v0.22.0/calicoctl 
		sudo chmod +x calicoctl
		cp calicoctl /usr/bin
- calico & calico-ipam： 

		#Download and install calico & calico-ipam		
		wget https://github.com/projectcalico/calico-cni/releases/download/v1.4.2/calico
		wget https://github.com/projectcalico/calico-cni/releases/download/v1.4.2/calico-ipam
		sudo chmod +x calico calico-ipam

- loopback:
	
		wget https://github.com/containernetworking/cni/releases/download/v0.3.0/cni-v0.3.0.tgz

3、在Master和Node节点上启动并配置`calico/node`

- 添加calico配置文件：

		# vi /etc/calico/config

		# This host's IPv4 address (the source IP address used to reach other nodes
		# in the Kubernetes cluster).
		#DEFAULT_IPV4=172.21.12.152  ##OpenStack floating IP会出错
		DEFAULT_IPV4=192.168.66.8   ##填写内网IP
		
		# The Kubernetes master IP
		#KUBERNETES_MASTER=172.21.12.151
		KUBERNETES_MASTER=192.168.66.8  ## K8s master节点IP
		
		# IP and port of etcd instance used by Calico
		ETCD_AUTHORITY=192.168.66.94:2379  ##  etcd存储
		#ETCD_AUTHORITY=172.21.12.154:2379


- 添加calico-node.service文件：

		# vi /lib/systemd/system/calico-node.service 

		[Unit]
		Description=Calico per-node agent
		Documentation=https://github.com/projectcalico/calico-docker
		Requires=docker.service
		After=docker.service
		
		[Service]
		User=root
		EnvironmentFile=/etc/calico/config  ## calico/node配置
		PermissionsStartOnly=true
		ExecStart=/usr/bin/calicoctl node --ip=${DEFAULT_IPV4} --detach=false  ##启动calico/node容器
		Restart=always
		RestartSec=10
		
		[Install]
		WantedBy=multi-user.target

- 启动calico-node Service：

		systemctl restart calico-node
    	systemctl enable calico-node
    	systemctl status calico-node

**4、配置Node节点的Calico CNI plugins**

- Kubernetes会调用`calico`,`calico-ipam`,及`loopback`plugins，默认放在目录`/opt/cni/bin`下。
		
		cp calico calico-ipam loopback /opt/cni/bin
- 编写Calico CNI plugins标准CNI 配置文件

	配置文件默认存放在目录`/etc/cni/net.d`下。

		# vi /etc/cni/net.d/kubeconfig    ##K8S配置文件
		 
		apiVersion: v1
		kind: Config
		clusters:
		- name: local
		  cluster:
		    certificate-authority: /etc/kubernetes/ssl/ca.pem
		    server: https://master:6443
		users:
		- name: kubelet
		  user:
		    client-certificate: /etc/kubernetes/ssl/node1-worker.pem
		    client-key: /etc/kubernetes/ssl/node1-worker-key.pem
		contexts:
		- context:
		    cluster: local
		    user: kubelet
		  name: kubelet-context
		current-context: kubelet-context

		#  vi /etc/cni/net.d/10-calico.conf ## CNI配置文件
		{
		    "name": "calico-k8s-network",
		    "type": "calico",
		    "etcd_authority": "192.168.66.94:2379",   ## etcd存储
		    "etcd_endpoints": "http://192.168.66.94:2379",
		    "log_level": "debug",
		    "kubernetes": {
		        "kubeconfig": "/etc/cni/net.d/kubeconfig"  ##K8S 配置文件
		    },
		    "policy": {
		        "type": "k8s"   #部署calico/kube-policy-controller需要，用于NetworkPolicy
		    },
		    "ipam": {
		        "type": "calico-ipam"
		    }
		}

**5、部署Calico network policy controller**

	kubectl create -f policy-controller.yaml  #修改<ETCD_ENDPOINTS>
	#  kubectl get pods
	NAME                                    READY     STATUS    RESTARTS   AGE
	calico-policy-controller-cshcq          1/1       Running   8          1d



**6、 修改Kubelet启动参数配置**

	vi /etc/kubernetes/kubelet
	KUBELET_ARGS="--network-plugin=cni --network-plugin-dir=/etc/cni/net.d ..."  

**7、配置kube-proxy启动方式为**： `--proxy-mode=iptables`

**8、重启Kubelet和kube-proxy Service，使配置生效**

## 12.2 Calico网络测试 ##

**1、Calico网络功能测试** 

重启K8S服务，若Calico网络配置正确，则Kubernetes原有Pod会重新启动并正常运行。此过程大概3-5min。

	kubectl get pods


**2 NetworkPolicy测试**

NetworkPolicy测试详细参考K8S官方网站[http://kubernetes.io/docs/getting-started-guides/network-policy/walkthrough/](http://kubernetes.io/docs/getting-started-guides/network-policy/walkthrough/)

注：busybox中k8s DNS无法使用,测试时将Service Name替换为 Cluster IP即可