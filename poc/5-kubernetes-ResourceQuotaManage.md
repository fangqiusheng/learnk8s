# 5. Kubernetes资源配额管理 #

## 5.1 资源配额管理基本概念 ##

作为容器集群的管理平台，Kubernetes提供了资源管理配置这一高级功能。资源配置管理确保了指定对象在任何时候都不会超量占用系统资源，避免了由于某些业务进程的设计或实现的缺陷导致整个系统运行紊乱甚至意外宕机，对整个系统的平稳运行和文定性有非常重要的作用。

目前Kubernetes支持如下三个层次的资源配额管理：

- 容器级别：可对指定容器的CPU和Memory进行限制
- Pod级别：可以对一个Pod内所有容器的可用资源进行限制
- Namespace级别：为Namespace级别的资源限制，可用于多租户资源配额管理，包括：
	- Pod数量
	- Replication Controller数量
	- Service 数量
	- ResourceQuota数量
	- Secret数量
	- 可持有的PV（Persistent Volume）数量

Kubernetes的配额管理是通过准入机制（Admission Control）来实现的，与配额相关的两种准入控制器是LimitRanger与ResourceQuota,其中LimitRanger作用于Pod和Container上，ResourceQuota作用Namespace上。此外，如果定义了资源配额，则kube-scheduler在Pod调度过程中也会考虑这一因素，确保Pod调度不会超出配额限制。

为了开启资源配额管理，首先要设置kube-apiserver的--admission_control参数，使之加载这两个准入控制器：

	--admission_control=LimitRanger,ResourceQuota..



## 5.2 指定容器配额 ##

对指定的容器实施配额管理，只要在Pod或ReplicationController的定义文件中设定resources属性即可为某个容器指定配额。目前容器只支持CPU和Memory两类资源的配额限制。

如下面这个RC定义文件中增加了redis-master的资源配额声明，表示系统将对命名为master的容器限制CPU为0.5(500m)，可用内存限制为128MiB字节。

	 apiVersion: v1
	      kind: ReplicationController 
	      metadata: 
	           name: redis-master 
	           labels: 
	              name: redis-master 
	      spec: 
	           replicas: 1 
	           selector: 
	               name: redis-master 
	           template: 
	               metadata: 
	                     labels: 
	                        name: redis-master 
	               spec: 
	                   containers: 
	                   - name: master 
	                      image: docker.io/kubeguide/redis-master 
	                      ports: 
	                      - containerPort: 6379
	                      #********#
	                      resources:
							limits:
							  cpu: 0.5
							  memory: 128Mi 
						  #********#
**Kubernetes资源配额是通过Docker中Linux的底层cgroup具体实现的。**Kubernetes启动一个容器时，会将CPU数值诚意1024并转为证书传递给docker run的--cpu-shares参数，最终转化为CPU运行时间的比重。Docker是以1024为基数计算CPU时间的。Memory配额也会转换为证书传递给docker run的--memory参数。如果一个容器在运行过程中超出了指定的内存配额，则它可能会被杀掉重启。

## 5.3 全局默认配额 ##

通过创建LimitRange对象可以定义一个全局默认配额模板，作用到集群中的每个Pod及容器上，从而避免为每个Pod和容器重复设置。LimitRange可以同时在Pod和Container两个级别上进行对资源配额的设置。当LimitRange创建生效后，其后创建的Pod都将使用LimitRange设置的资源配额进行约束。

1. 定义一个名为limit-range-1的LimitRange,配置文件名为pod-container-linits.yaml,如下：

		apiVersion: v1
		kind: LimitRange
		metadata:
		  name: limit-range-1
		spec:
		  limits:
			- type: "Pod" 
			  max:
		  		cpu: "2"
		  		memory: 1Gi
			  min:
		  		cpu: 250m
		  		memory: 32Mi
			- type: "Container" 
			  max:
		  		cpu: "2"
		  		memory: 1Gi
			  min:
		  		cpu: 250m
		  		memory: 32Mi
			  default:
				cpu: 250m
		  		memory: 64Mi
	上述设置表明：
	- 任意Pod内的所有容器的CPU使用限制在0.25~2；
	- 任意Pod内的所有容器的内存使用限制在32Mi~1GMi；
	- 任意容器的CPU使用限制在0.25~2，默认值为0.25；
	- 任意容器的内存使用限制在32Mi~1GMi，默认值64Mi。
2. 使用kubectl create创建上述LimitRange，使其在Kubernetes集群中生效：

		#  kubectl replace -f pod-container-linits.yaml
		#  kubectl describe limits limit-range-1
3. 检验上述配额是否起作用
   
	- 创建一个Pod，不指定资源配额，则该Pod使用LimitRange中的默认值；
	- 如果在Pod的定义文件中指定了配额参数，则遵循局部覆盖全局的原则，此时配额参数会覆盖全局参数的值。若用户指定的配额超过了全局设定的资源配额最大值，则会被禁止。

> 说明：LimitRange是和Namespace绑定的，每个Namespace都可以关联一个不同的LimitRange作为其全局默认配额配置。

创建LimitRange时可以指定--namespace=<yournamespace>的方式关联到指定的namespace上，也可以在定义文件中直接指定namespace:
	
	//方法1：kubectl 指定namespace
	kubectl replace -f pod-container-linits.yaml --namespace=<yournamespace>

	//方法2：定义文件指定namespace
	apiVersion: v1
		kind: LimitRange
		metadata:
		  name: limit-range-1
		  namespace: development
		spec:
		  limits:
			- type: "Pod" 
			  max:
		  		cpu: "2"
		  		memory: 1Gi
			  min:
		  		cpu: 250m
		  		memory: 32Mi

查看指定namespace的LimitRange:
	
	kubectl describe limts <limit-range-name> --namespace=<yournamespace>

## 5.4 多租户配额管理 ##

多租户可以是多个用户、多个业务系统或者相互隔离的多种作业环境。多租户在Kubernetes中以Namespace来体现。集群资源是有限的，为了更好地协调集群资源在多租户之间的共享使用，徐江资源配额管理单元提升到租户级别。对应到Kubernetes中，只需要在不同租户对应的Namespace上加载对应的ResourceQuota配置即可达到多租户配额管理的目的。

下面举例说明如何使用ResouceQuota实现基于租户的配额管理，场景如下:集群拥有的总资源为128core CPU，1024GiB内存。有两个租户，分别是开发组合测试组，开发组的资源配额为32core CPU及256GiB内存；测试组的资源配额为96core CPU及768GiB内存。对应Kubernetes中Namespace级别的资源配额步骤如下：

1. 创建开发组对应的命名空间

		//namespae-development.yaml
		apiVersion: v1
		kind: Namespace
		metadata:
		  name: development
		
		#  kubectl create -f namespae-development.yaml
		#  kubectl get namespaces

2. 创建用于限定开发组的ResourceQuota对象，注意metadata.namespace属性设置为开发组的命名空间：

		//resource-development.yaml
		apiVersion: v1
		kind: ResourceQuota
		metadata:
		  name: quota-development
		  namespace: development
		spec:
		  hard:
		    cpu: "32"
			memory: 256Gi
			persistentvolumeclaims: "10"
			pods: "100"
			replicationcontrollers: "50"
			resourcequotas: "1"
			secrets: "20"
			services: "50"	
		
		//创建ResourceQuota
		#  kubectl create -f resource-development.yaml
		//查看ResourceQuota详细信息
		#  kubectl describe quota quota --namespace=development

	**创建完ResourceQuota之后，对于所有需要创建的Pod都必须知道具体的资源配额设置。否则，Pod创建会失败**

3. 重复步骤1-2，创建测试组对应的namespace与ResourceQuota。操作省略。
4. 查看某个租户的配额使用情况：
	
		//统计development租户的配额使用情况
		#  kubectl describe resourcequota  quota-development --namespace=development
	
5. 查看一个namespace内所包括的ResourceQuota和LimitRange信息

		//  development namespace
		#  kubectl describe namespace development
