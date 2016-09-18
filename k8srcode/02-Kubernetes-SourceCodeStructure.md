# 2. Kubernetes 源码结构 #

![](imgs/k8s-slavemaster.jpg)

## 2.1 Kubernetes 源码目录结构 ##
 
| 目录 | 说明 |
| ----------- | ---------------------------------------- |
| api | 输出接口文档用 |
| build | 构建脚本 |
| cluster | 适配不同I层的云，例如亚马逊AWS，微软Azure，谷歌GCE的集群启动脚本 |
| cmd | 所有的二进制可执行文件入口代码，例如apiserver/scheduler/kubelet |
| contrib | 项目贡献者 |
| docs | 文档，包括了用户文档、管理员文档、设计、新功能提议 |
| example | 使用案例 |
| Godeps | 项目中依赖使用的Go第三方包，例如docker客户端SDK，rest等 |
| hack | 工具箱，各种编译、构建、测试、校验的脚本都在这里面 |
| hooks | git提交前后触发的脚本 |
| pkg | 项目代码主目录，cmd的只是个入口，这里是所有的具体实现 |
| plugin | 插件，k8s认为调度器是插件的一部分，所以调度器的代码在这里 |
| release | 应该是Google发版本用的？ |
| test | 测试相关的工具 |
| third_party | 一些第三方工具，应该不是强依赖的？ |
| www | UI，不过已经被移动到新项目了 |



## 2.2 Kubernetes Package功能概述 ##

Kubernetes源码总体分为pkg、cmd、plugin、test等顶级package。

其中：

- **pkg：** 为Kubernetes的主体代码
- **cmd:** 为Kubernetes所有后台进程的代码（kube-apiserver,kube-controller-manager,kube-proxy和kubelet等）
- **plugin:** 包括一些插件及kube-scheduler的代码
- **test：** Kubernetes的一些测试代码

Kubernetes主要的**package源码结构**及其说明如下：

- admission: 权限控制框架，采用了责任链模式、插件机制
- api: Kubernetes所提供的Rest API接口的相关类，如接口数据结构相关的metadata,endpoints,annotations,pod, service等等。API是分版本的，如v1beta,v1及latest等。
- apiserver:实现了HTTP Rest服务的一个基础性框架，用于Kubernetes的各种Rest API的实现。API包亦实现了HTTP proxy，用于转发请求到其它组件（如Minion节点）
- auth: 3A认证模块，包括用户认证、鉴权的相关组件。
- client：Kubernetes中公用的客户端部分的相关代码，实现协议为HTTP REST，用于提供一个具体的操作，如Pod、Service的增删改查。为了实现高效的对象查询，此模块亦实现了一个带缓存功能的存储接口Store。
- cloudprovider: 定义了云服务提供商运行Kubenetes所需的接口，包括TCPLoadBalance的获取和创建；获取当前环境中的节点（云主机）列表和节点的具体信息；获取Zone信息；获取和管理路由的接口等。默认实现了AWS、GCE、Mesos、OpenStack、RackSpace等云服务提供商的接口。
- controller:提供了资源控制器的简单框架，用于资源的添加、变更、删除等事件的派发和执行。实现了诸如Replication Controller，Service Controller等等。
- kubectl: Kubernetes的命令行工具kubectl的代码模块，包括创建Pod、服务、Pod扩容、Pod滚动升级等各种命令的具体实现代码。
- kubelet： Kubernetes的kubelet代码模块，定义了pod容器的接口，提供了Docker与Rkt两种容器的实现类，完成了容器与Pod的创建，以及容器状态的监控、销毁、垃圾回收等功能。
- label：定义了Kubernetes的标签label和selector等。
- master：Kubernetes的Master节点代码块，创建NodeRegistry,PodRegistry,ServiceRegistry,EndpointRegistry等组件，并且启动Kubenetes自身的相关服务。实现服务的ClusterIP地址分配及服务的NodePort端口分配。
- proxy:Kubernetes的服务代理和负载均衡相关功能的代码模块，目前实现了round-robin的负载均衡算法。
- registry: Kubernetes的NodeRegistry,PodRegistry,ServiceRegistry,EndpointRegistry等注册服务的接口及对应的Rest服务的相关代码。与etcd交互较多。
- runtime:为了让多个API版本共存，需要采用一些设计完成不同API版本的数据结构的转换，API中的数据对象的Encode/Decode逻辑也最好集中化，runtime包就是为了这个目的而设计的。
- volumn：实现了Kubernetes的各种volumn类型，分别对应ESB，GCE，iSCSI，NFS存储等，volumn包同时实现了Kubernetes容器的Volumn卷的挂载、卸载功能。
- cmd：包括了Kubernetes所有后台进程（如kube-apiserver,kube-controller-manager,kube-proxy和kubelet）的代码，而这些进程具体的业务逻辑代码都在pkg中实现了。
- plugin：子包cmd/kuber-scheduler实现了Scheduler Server的框架，用于执行具体的Scheduler的调度；pkg/admission子包实现了Admission权限框架的一些默认实现类，如alwaysAdmit、alwaysDeny等；pkg/auth子包实现了权限认证框架（auth包的）里定义的认证接口类，如HTTP BasicAuth、X509证书认证；pkg/scheduler子包定义了一些具体的Pod调度器（Scheduler）。