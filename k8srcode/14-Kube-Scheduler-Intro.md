# 14 Kube-Scheduler-Intro #

## 14.1 Kubernetes Scheduler 工作流程 ##
本节对Kubernetes中负责Pod调度的重要功能模块--Kubernetes Scheduler的工作原理和运行机制做深入分析。Kebernetes Scheduler在整个系统中承担了“承上启下”的重要功能，“承上”是指它负责接收Controller Manager创建的新Pod，为其安排一个落脚的“家”--目标Node，“启下”是指安置工作完成后，目标Node上的Kubelet服务进程接管后续工作，负责Pod生命周期的“下半生”。

具体来说，Kubernetes Scheduler的作用是将带调度的Pod(API新创建的Pod、Controller Manager为补足副本而创建的Pod等)按照特定的调度算法和调度策略绑定（binding）到集群中的某个合适的Node上，并将绑定信息写入etcd中。在整个调度过程中涉及三个对象，分别是：待调度Pod列表、可用Node列表及调度算法和策略。简单地说，就是通过调度算法调度为待调度Pod列表的每个Pod从Node列表中选择一个最合适的Node。随后，目标节点上的Kubelet通过API Server监听到Kubernetes Scheduler产生的Pod绑定事件，然后获取相应的Pod清单，下载Image镜像，并启动容器。

完整的流程如下图14-1所示：

![](imgs/kube-scheduler-workflow.JPG)
图14-1 Scheduler 流程

Kubernetes Scheduler当前提供的默认调度流程分为以下两步：  
（1）预选调度过程，即遍历所有目标Node，筛选出符合要求的候选节点。为此Kubernetes内置了多种预选策略（xxx Predicates）供用户选择。   
（2）确定最优节点，在第一步的基础上，采用优选策略(xxx Priority)计算每个候选节点的积分，积分最高者胜出。

Kubernetes的调度过程是通过插件方式加载的“调度算法提供者”（AlgorithmProvider）具体实现的。一个AlgorithmProvider其实就是包含了一组预选策略与一组优先选择策略的结构体。此处是V1版本的，xianyouV1.3版本可能已经更改。详细内容在后续源码分析处解析。

## 14.2 工作节点发现 ##

Node节点作为Kubernetes调度器的输入之一，是待调度pod的最终运行宿主机，因此Node节点的发现和管理对Kubernetes scheduler调度决策非常重要。下面将简要分析Kubernetes对工作节点管理机制。

### 14.2.1 工作节点状态信息 ###
Kubernetes将工作节点也看作是资源对象的一种，用户可以像创建pod那样通过资源配置文件或kubectl命令行工具来创建。Kubernetes主要使用两个两个字段——spec和status来描述一个工作节点的期望状态和当前状态。对调度器来说，工作节点的当前状态信息更有意义，因此下文将重点分析该字段的构成。当前状态status信息由三个部分组成（后续版本可能会有变化）：HostIP，Node Phase和Node Condition。

- **HostIP：**
	- 如果工作节点是由IaaS平台创建的虚拟机，那么其主机IP地址（HostIP）可以通过调用IaaS API来获取。如果Kubernetes集群没有运行在底层IaaS平台之上，那么HostIP将被填入工作节点的ID（见下文14.2.2）字段的值。HostIP不是固定的，可能会随着集群运行过程而动态变化，而且HostIP的种类也可能多样化，例如：公有IP、私有IP、动态IP、静态IP和IPv6等。因此将HostIP作为status字段的组成部分比作为spec字段的组成部分更有意义。

- **Node Phase：** 

	- Node Phase即工作节点的生命周期，它由Kubernetes Controller Manager管理。工作节点的生命周期可以分为三个阶段：Pending，Running和Terminated。刚创建的工作节点处于Pending状态，直到它被Kubernetes发现和检查。如果工作节点的检查结果是符合条件的（譬如：工作节点上的服务进程都在运行），则会被标记成Running状态。工作节点的生命周期一旦结束就会被标记为Terminated状态，处于Terminated状态的工作节点不会接受任何调度请求而且在其上运行的pod都会被移除。不过，一个工作节点处于Running状态是可调度pod的必要而非充分条件。如果一个工作节点要成为一个调度候选节点，它需要满足一些合适的条件，见下文。

- **Node Condition：**

	- Node Condition描述了一个处于Running状态的工作节点的健康状况。合法的Condition值包括：NodeReady和NodeSchedulable，其中NodeReady意味着Kubelet处于健康状态且已经准备好接收pod了，而NodeSchedulable则意味着工作节点被允许用于调度新的pod。不同的Condition值代表着工作节点健康状况的不同级别，Kubernetes scheduler将会综合这些信息做出一个调度决策。Node Condition用一个JSON对象表示，以下的这个例子表明工作节点处于健康状态但是还不被允许接收新的pod。


			"conditions": [
			  {
			    "kind": "Ready",
			    "status": "True",
			    },
			  {
			    "kind": "Schedulable",
			    "status": "False",
			  },


### 14.2.2 工作节点管理 ###
与pod和service不同的是，工作节点并不是真正由Kubernetes创建的——它是由IaaS平台（譬如GCE）创建或者来自你自己管理的物理机或者是虚拟机。这意味着，当Kubernetes创建一个工作节点时，它只是创建了一个工作节点的“代表“，即只是在数据库中创建了代表工作节点的资源对象。工作节点被创建之后，Kubernetes会检查该工作节点是否合法。例如，以下资源配置文件描述了一个工作节点的具体信息，可以通过该文件创建一个工作节点对象。

	{
	  "id": "10.1.2.3",
	  "kind": "Minion",
	  "apiVersion": "v1beta1",
	  "resources": {
	    "capacity": {
	      "cpu": 1000,
	      "memory": 1073741824
	    },
	  },
	  "labels": {
	    "name": "my-first-k8s-node",
	  },
	}
Kubernetes将在内部创建一个Minion对象（工作节点的代表）并根据其id字段检验该工作节点的健康状况（Kubernetes假设id字段是可解析的，故一般会使用工作节点IP地址作为id字段的值）。如果经检查工作节点是合法的（譬如所有必要的服务进程都在运行），那么它就被认为是适合运行pod的，否则它就会被集群忽略直到它变成合法状态。**需要注意的是，Kubernetes会保留不合法的工作节点对象除非客户端显式地删除他们，而且Kubernetes会持续检查不合法的工作节点状态直到他们变成合法的为止。**Kubernetes提供两种与工作节点接口交互的方式：使用Node Controller和手动操作，下面将逐一进行介绍:

- **Node Controller :**是由Kubernetes Controller Manager统一管理的一个控制器，用来管理Kubernetes node（minion）对象，它主要执行两个操作：集群范围内的节点信息同步和单个节点的生命周期管理。
	- 集群范围内工作节点同步 
	
		Node controller有一个同步循环，在该循环中执行在Kubernetes集群中创建和删除工作节点的操作，同步的时间周期可以由Kubernetes Controller Manager启动时传入的--node_sync_period参数控制。如果有一个工作节点被创建，Node Controller会为其创建一个minion对象，如果现有的一个工作节点被删除，Node Controller就会删除对应的minion对象。不过，需要注意的是Node Controller不会在工作节点上安装一些必要的服务程序。因此，如果想把创建的工作节点加入到Kubernetes集群中，集群管理员还需要确保必要的服务进程在工作节点上正常运行。以上所有操作的前提是Kubernetes集群部署在有底层IaaS平台支持的环境中，如果没有IaaS支持，Node Controller只会地简单注册所有在Kubernetes Controller Manager启动时通过--machines参数传入的节点。当然，如果你愿意，也可以将--machines参数留空然后使用客户端命令行工具kubectl手动地向Kubernetes集群逐一添加工作节点。以上两种创建工作节点的方式是完全等价的。更为极端的情况是，你可以通过在Kubernetes Controller Manager启动时传入--sync_nodes=false参数来跳过集群范围内的节点同步并使用REST API或kubectl命令行来动态地创建和删除工作节点。
	- 单个节点生命周期管理 
- **手动操作:** 手动使用客户端命令行工具kubectl动态地创建和删除工作节点。


## 14.3 Scheduler预选策略--Predicates ##

Scheduler中可用的预选策略包含：NoDiskConflict、PodFitsResources、PodSelectorMatches、PodFitsHost、CheckNodeLabelPresence、CheckServiceAffinity和PodFitsPorts策略。Scheduler默认加载的预选策略包括：“PodFitsPorts”、“PodFitsResources”、“NoDiskConflict”、“PodSelectorMatches”和“PodFitsHost”，即每个节点只有通过前面提及的5个默认预选策略后，才能初步被选中，进入下一个流程。

下面列出的是对所有预选策略的详细说明：

**1.  NoDiskConflict**

判断备选Pod的GCEPersistentDisk或AWSElasticBlockStore和备选节点中已存在的Pod是否存在冲突，检测过程如下：

(1)、 首先，读取备选Pod的所有Volume的信息（即pod.Spec.Volumes，对每个Volume执行以下步骤进行冲突检测。  
(2)、相应的冲突检测流程如下：

- 如果该Volume是GCEPersistentDisk，则将Volume和备选节点上的所有Pod的每个Volume进行比较，如果发现相同的GCEPersistentDisk，则返回false，表明存在磁盘冲突，检查结束，反馈给Scheduler该备选节点不适合作为该备选Pod的宿主机。
- 如果该Volume是AWSElasticBlockStore,则将Volume和备选节点上的所有Pod的每个Volume进行比较，如果发现相同的AWSElasticBlockStore，则返回false，表明存在磁盘冲突，检查结束，反馈给Scheduler该备选节点不适合作为该备选Pod的宿主机。
  
(3)、如果检查完备选Pod的所有Volumes均为发现冲突，则返回True，表示不存在磁盘冲突，反馈给Scheduler该备选节点适合作为该备选Pod的宿主机。

**2. PodFitsResources**  

判断备选节点的资源是否满足备选Pod的需求，检测过程如下：

（1）计算备选Pod和节点中已存在Pod的所有容器的需求资源（内存和CPU）的总和。  
（2）获得该备选节点的状态信息，其中包含节点的资源信息。   
（3）如果备选Pod和节点中已存在Pod的所有容器的需求资源（内存和CPU）的总和，超出了备选节点拥有的资源，则返回false，表面备选节点不适合备选Pod；否则返回True，表面备选节点适合备选Pod。


**3. PodSelectorMatches**   
判断备选节点是否包含备选Pod的标签选择器指定的标签。  
（1）如果Pod没有指定spec.nodeSelector，则返回True；
（2）否则，获得备选节点的标签信息，判断节点是否包含备选Pod的标签选择器（spec.nodeSelector）所指定的标签，如果包含，则返回True；否则返回False。

**4. PodFitsHost**  
判断备选Pod的spec.nodeName域所指定的节点名称和备选节点的名称是否一致，如果一直则返回true，否则返回false。

**5. CheckNodeLabelPresence**  
如果用户在配置文件中指定了该策略，则Scheduler会通过RegisterCustomFitPredicate方法注册该策略。该策略用于判断策略列出的标签在备选节点中存在时，是否选择该备选节点。  
（1）读取备选节点的标签列表信息。
（2）如果策略配置的标签列表存在于备选节点的标签列表中，且策略配置的presence值为false，则返回false；否则返回true。如果策略配置的标签列表不存在于备选节点的标签列表中，且策略配置的presence值为true，则返回false；否则返回true。

**6. CheckServiceAffinity**  
如果用户在配置文件中指定了该策略，则Scheduler会通过RegisterCustomFitPredicate方法注册该策略。该策略用于判断备选节点是否包含策略指定的标签，或包含和备选Pod在相同Service和NameSpace下的Pod所在节点的标签列表。如果存在，则返回true，否则返回false。

**7 PodFitsPorts**  
判断备选Pod所用的端口列表中的端口是否在备选节点中已被占用，如果被占用，则返回false；否则返回True。


## 14.4 Scheduler优选策略--Priority ##

Scheduler中的优选策略包含：LeastRequestedPriority、CalculateNodeLabelPriority和BalanceResourceAllocation等。每个节点通过优先选择策略时都会算出一个得分，计算各项得分，最终选出得分值最大的节点作为优选的而结果。下面是对所有优选策略的详细说明。

**1. LeastRequestedPriority**  
该优选策略从备选节点列表中选出资源消耗最小的节点。  
（1）计算出所有备选节点上运行的Pod和备选Pod的CPU占用量totalMilliCPU。  
（2）计算出所有备选节点上运行的Pod和备选Pod的内存占用量totalMemory。  
（3）计算每个节点的得分，计算规则大致如下：  

	NodeCpuCapacity为节点CPU计算能力；NodeMemoryCapacity为节点内存大小。
	score = (((NodeCpuCapacity-totalMilliCPU)*10/NodeCpuCapacity + ((NodeMemoryCapacity-totalMemory)
	*10)/NodeMemoryCapacit）/2)

**2. CalculateNodeLabelPriority**  
如果用户在配置文件中指定了该策略，则scheduler会通过RegisterCustomPriorityFunction方法注册该策略。该策略用于判断策略列出的标签在备选节点中存在时，是否选择该备选节点。如果备选节点的标签在优选策略的标签列表中且优选策略的presence值为true，或者备选节点的标签不在优选策略的标签列表中且优选策略的presence值为false，则备选节点score=10,否则备选节点score=0。  

**3. BalancedResourceAllocation**  
该优选策略用于从备选节点列表中选出各项资源使用率最均衡的节点：  
（1）计算出所有备选节点上运行的Pod和备选Pod的CPU占用量totalMilliCPU。   
（2）计算出所有备选节点上运行的Pod和备选Pod的内存占用量totalMemory。   
（3）计算每个节点的得分，计算规则大致如下：

	score = int(10-math.abs(totalMilliCPU/NodeCpuCapacity-totalMemory/NodeMemoryCapacity)*10)