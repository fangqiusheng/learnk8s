# 9. Kubernetes TLS(https) 双向认证配置 #

kubernetes 提供了多种安全认证机制，其中对于集群间通讯可采用 TLS(https) 双向认证机制，也可采用基于 Token 或用户名密码的单向 tls 认证。由于 kubernetes 某些组件只支持双向 TLS 认证，，本文详细介绍Kubernetes的双向认证配置。

为方便，本文将配置过程写成几个shell脚本文件，并已上传至GiltLab:[http://172.17.249.122/qsfang/learnk8s/tree/master/poc/yamls/kube-tls](http://172.17.249.122/qsfang/learnk8s/tree/master/poc/yamls/kube-tls)

包含以下脚本,可根据需要修改集群对应的Node或者IP信息等：

- tls.sh: 签发证书，包括自签 CA，apiserver 证书，node证书，集群管理证书等。
- run-master-tls.sh： 将签发的APIserver证书和密钥拷贝到APIServer,ControllerManager配置指定的文件目录，并重启Master节点上的Kubernetes服务
- node-tls.sh：将node证书拷贝到kubernetes中的其它Node节点中Kubelet,kube-proxy配置文件指定的文件目录。
- worker-kubeconfig.yaml：kube-proxy和kubelet公用的配置文件，通过--kubeconfig参数制定
- run-node-tls.sh：增加etc/hosts，并重启node节点的Kubernetes服务。
- test-api.sh：测试APIServer的Https配置是否正确。



## 9.1. 签发证书 ##

大部分 kubernetes 应该基于内网部署，而内网应该都会采用私有 IP 地址通讯，权威 CA 只能签署域名证书，对于签署到 IP 无法实现，因此权威 CA 机构的证书应该不可用。**TLS 双向认证需要预先自建 CA 签发证书。**

- 自签 CA：对于私有证书签发首先要自签署 一个 CA 根证书。
- 签署 apiserver 证书：自签 CA 后就需要使用这个根 CA 签署 apiserver 相关的证书，用于APIServer认证。
- 签署 node 证书： 签署每个节点 node 的证书，每个节点的证书均不相同，用于节点认证。
- 生成集群管理证书： 签署一个集群管理证书，用于集群管理认证。

## 9.2 使用脚本配置KUbernetes双向认证 ##

**1、签发证书：**

- **修改 openssl 的配置文件：**
	- cert/openssl.cnf:用于签署apiserver证书。

			//主要修改内容如下
			req_extensions = v3_req # The extensions to add to a certificate request
			[ v3_req ]
			
			# Extensions to add to a certificate request
			
			basicConstraints = CA:FALSE
			keyUsage = nonRepudiation, digitalSignature, keyEncipherment
			
			subjectAltName = @alt_names  //域名解析，可同时实现对DNS.#指定的域名和IP.#指定的IP的认证
			[alt_names]
			DNS.1 = kubernetes
			DNS.2 = kubernetes.default
			DNS.3 = kubernetes.default.svc
			DNS.4 = kubernetes.default.svc.cluster.local
			DNS.5 = master
			#IP.1 = 172.21.101.102  # # kubernetes server ip(如果都在一台机器上写一个就行)
			IP.1 = 10.254.0.1  # kubernetes sevice IP
			IP.2 = 172.21.101.102  # # master ip(如果都在一台机器上写一个就行)


	- cert/worker-openssl.cnf：用于签署Kubernetes集群中的node证书。
		
			//主要修改内容如下
			req_extensions = v3_req # The extensions to add to a certificate request
			
			[ v3_req ]
			
			# Extensions to add to a certificate request
			
			basicConstraints = CA:FALSE
			keyUsage = nonRepudiation, digitalSignature, keyEncipherment
			
			subjectAltName = @alt_names  //域名解析，可同时实现对DNS.#指定的域名和IP.#指定的IP的认证
			[alt_names]
			DNS.1 = node1         #此处填写集群的Node名称 /etc/hosts:  172.21.101.103  node1,以此类推
			DNS.2 = node2
			IP.1 = 172.21.101.103 # 此处填写 node 的内网 ip，多个 node ip 地址以此类推 IP.2 = NODE2-IP
			IP.2 = 172.21.101.104 # 此处填写 node 的内网 ip，多个 node ip 地址以此类推 IP.2 = NODE2-IP

- **生成证书文件：**
	- 执行tls.sh脚本文件：

			bash tls.sh   //在 cert/目录下生成所需的证书和密钥

	
**2. 配置 kubernetes**

- **配置 master：**
	- 修改apiserver配置
	
			# 编辑 master apiserver 配置文件
			vi /etc/kubernetes/apiserver
			# 主要修改配置如下
		
			KUBE_API_PORT="--secure-port=443 --insecure-port=8080"   ##APIServer同时监听在https://master:443和http://master:8080端口
			KUBE_ADMISSION_CONTROL="--admission-control=NamespaceLifecycle,NamespaceExists,LimitRanger,SecurityContextDeny,ServiceAccount,ResourceQuota"
			## --client-ca-file：  指向根证书文件
			## --tls-cert-file:  指向服务端证书文件
			## --tls-private-key-file：  指向私钥文件
			## --basic-auth-file：  指向基本认证文件，用户名，密码
			KUBE_API_ARGS="--tls-cert-file=/etc/kubernetes/ssl/apiserver.pem --tls-private-key-file=/etc/kubernetes/ssl/apiserver-key.pem --client-ca-file=/etc/kubernetes/ssl/ca.pem --service-account-key-file=/etc/kubernetes/ssl/apiserver-key.pem  --basic-auth-file=/etc/kubernetes/ssl/basic_auth.csv"

	- 修改controller manager配置

			# 编辑 controller manager 配置
			vi /etc/kubernetes/controller-manager 
			# 修改配置如下
			KUBE_CONTROLLER_MANAGER_ARGS="--service-account-private-key-file=/etc/kubernetes/ssl/apiserver-key.pem  --root-ca-file=/etc/kubernetes/ssl/ca.pem --master=http://127.0.0.1:8080"

	- 重启kubernetes master节点的k8s服务
			
			bash run-master-tls.sh

- **配置 node：** 集群中所有node均需配置，以下以Node1为例。
	-  将所需证书文件分别拷贝至集群各node节点中的/etc/kubernetes/ssl目录下：
	   
			bash node-tls.sh
	-  修改 kubelet 配置：
			
			vi /etc/kubernetes/kubelet
			# 修改配置如下
		
			KUBELET_HOSTNAME="--hostname-override=node1"
			#KUBELET_API_SERVER="--api-servers=http://master:8080"
			KUBELET_API_SERVER="--api-servers=https://master:443"
			KUBELET_ARGS="--cluster_dns=10.254.0.99 --cluster_domain=cluster.local --tls-cert-file=/etc/kubernetes/ssl/node1-worker.pem --tls-private-key-file=/etc/kubernetes/ssl/node1-worker-key.pem --kubeconfig=/etc/kubernetes/worker-kubeconfig.yaml"


	-  修改 config 配置：

			vi /etc/kubernetes/config
			# 修改配置如下
			KUBE_MASTER="--master=https://master:443"

	-  配置 kube-proxy 使其使用证书：
		
			vi /etc/kubernetes/proxy
			# 修改配置如下
			#使用配置文件worker-kubeconfig.yaml
			KUBE_PROXY_ARGS="--master=https://master:443 --kubeconfig=/etc/kubernetes/worker-kubeconfig.yaml"


	-  重启kubernetes node节点的k8s服务

			bash run-node-tls.sh

**3. 使用管理证书配置kubectl**

使用到如下命令，详细可使用--help参数查看：

	kubectl - kubectl controls the Kubernetes cluster manager
	kubectl config set - Sets an individual value in a kubeconfig file
	kubectl config set-cluster - Sets a cluster entry in kubeconfig
	kubectl config set-context - Sets a context entry in kubeconfig
	kubectl config set-credentials - Sets a user entry in kubeconfig
	kubectl config unset - Unsets an individual value in a kubeconfig file
	kubectl config use-context - Sets the current-context in a kubeconfig file
	kubectl config view - displays Merged kubeconfig settings or a specified kubeconfig file.


配置kubectl使用管理证书示例：


	kubectl config set-cluster secure --server=https://master:443 --certificate-authority=cert/ca.pem
	kubectl config set-context secure --cluster secure --user admin
	kubectl config set-credentials admin --certificate-authority=cert/ca.pem --client-key=cert/admin-key.pem --client-certificate=cert/admin.pem 
	kubectl config set-context secure --cluster=secure --user=admin
	kubectl config use-context secure

kubectl的配置会保存在文件：`${HOME}/.kube/config`中，可通过如下命令查看或直接修改kubectl的配置。

	vi ${HOME}/.kube/config

可以看到如下配置：

	apiVersion: v1
	clusters:
	- cluster:
	    certificate-authority: /root/kubernetes/kube-tls/cert/ca.pem
	    server: https://master:443
	  name: secure
	contexts:
	- context:
	    cluster: secure
	    user: admin
	  name: secure
	current-context: secure
	kind: Config
	preferences: {}
	users:
	- name: admin
	  user:
	    client-certificate: /root/kubernetes/kube-tls/cert/admin.pem
	    client-key: /root/kubernetes/kube-tls/cert/admin-key.pem