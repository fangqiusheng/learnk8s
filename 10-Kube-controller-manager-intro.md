# 10 Kube-controller-manager-intro #

## 10.1 Controller Manager概述 ##

Controller Manager作为集群内部的管理控制中心，负责集群内的Node、Pod副本、服务端点（Endpoint）、命名空间（NameSpace）、服务账号（ServiceAccount）、资源定额（ResourceQuota)等的管理并执行自动修复流程，确保集群处于预期的工作状态。比如出现某个Node意外宕机时，Controller会在集群的其他节点上自动补齐Pod副本。

Controller Manager内部包含以下控制器：

- **Replication Controller:**确保在任何时候集群中一个RC所关联的Pod都保持一定数量的Pod副本处于正常运行状态。
- **Node Controller:**负责发现、管理和监控集群中的各个Node节点。
- **ResourceQuota Controller：**确保指定对象任何时候都不会超量占用系统资源、避免了由于某些业务进程的设计或实现的缺陷导致整个系统进行紊乱甚至意外宕机，对整个吸引的平稳运行和稳定性具有非常重要的作用。
- **NameSpace Controller:**定时通过API Server读取NameSpace信息，并可根据API标识优雅删除NameSpace。
- **ServiceAccount Controller:**安全相关控制器，在Controller Manager启动时被创建。今天Service Account的删除事件和NameSpace的创建修改事件。
- **Token Controller：**安全相关控制器，负责监听Service Account和Secret的创建、修改和删除事件，并根据事件的不同做不同的处理。
- **Service Controller:**负责监听Service的变化，如果发生变化的Service是LoadBalancer类型的，则Service Controller确保外部的LoadBalancer被相应地创建和删除。
- **Endpoint Controller:**通过Store缓存Service和Pod信息，它监控Service和Pod的变化。如果检测到Service被删除，则删除和该Service同名的Endpoint对象；根据该Service获取相关的Pod列表，根据Service和Pod对象列表创建一个新的Endpoint的subsets对象。如果判断出是新建或修改Service，那么用Service的name和labels及上面创建的subsets对象创建出一个Endpoint对象，并同步到etcd。

Kubernetes集群中，每个Controller就是一个操作系统，它通过API Server监控系统的共享状态，并尝试着将系统状态从“现有状态”修正到“期望状态”。

## 10.2 Kube-controller-manager 进程启动过程 ##

kube-controller-manager进程的入口源码位置如下：

	// cmd/kube-controller-manager/controller-manager.go
	func main() {
		s := options.NewCMServer() //创建CMServer
		s.AddFlags(pflag.CommandLine)
	
		flag.InitFlags()
		logs.InitLogs()
		defer logs.FlushLogs()
	
		verflag.PrintAndExitIfRequested()
		//启动服务
		if err := app.Run(s); err != nil {
			fmt.Fprintf(os.Stderr, "%v\n", err)
			os.Exit(1)
		}
	}

从源码可以看出，关键代码只有两行，创建一个CMServer并调用Run方法启动服务。下面分析CMServer这个结构体，他是Controller Manager进程的主要上下文数据结构，存放一些关键参数。

	//  pkg/apis/componentconfig/types.go
	type KubeControllerManagerConfiguration struct {
		unversioned.TypeMeta

		// port is the port that the controller-manager's http service runs on.
		Port int32 `json:"port"`
		// address is the IP address to serve on (set to 0.0.0.0 for all interfaces).
		Address string `json:"address"`
		// cloudProvider is the provider for cloud services.
		CloudProvider string `json:"cloudProvider"`
		// cloudConfigFile is the path to the cloud provider configuration file.
		...
		ConcurrentEndpointSyncs int32 `json:"concurrentEndpointSyncs"`
		// concurrentRSSyncs is the number of replica sets that are  allowed to sync
		// concurrently. Larger number = more responsive replica  management, but more
		// CPU (and network) load.
		ConcurrentRSSyncs int32 `json:"concurrentRSSyncs"`
		// concurrentRCSyncs is the number of replication controllers that are
		// allowed to sync concurrently. Larger number = more responsive replica
		// management, but more CPU (and network) load.
		ConcurrentRCSyncs int32 `json:"concurrentRCSyncs"`
		// concurrentServiceSyncs is the number of services that are
		// allowed to sync concurrently. Larger number = more responsive service
		// management, but more CPU (and network) load.
		ConcurrentServiceSyncs int32 `json:"concurrentServiceSyncs"`
			...
			...
		// lookupCacheSizeForRC is the size of lookup cache for replication controllers.
		// Larger number = more responsive replica management, but more MEM load.
		LookupCacheSizeForRC int32 `json:"lookupCacheSizeForRC"`
		...
		ServiceSyncPeriod unversioned.Duration `json:"serviceSyncPeriod"`
		// nodeSyncPeriod is the period for syncing nodes from cloudprovider. Longer
		// periods will result in fewer calls to cloud provider, but may delay addition
		// of new nodes to cluster.
		NodeSyncPeriod unversioned.Duration `json:"nodeSyncPeriod"`
		// resourceQuotaSyncPeriod is the period for syncing quota usage status
		// in the system.
		ResourceQuotaSyncPeriod unversioned.Duration `json:"resourceQuotaSyncPeriod"`
		// namespaceSyncPeriod is the period for syncing namespace life-cycle
		// updates.
		NamespaceSyncPeriod unversioned.Duration `json:"namespaceSyncPeriod"`
		// pvClaimBinderSyncPeriod is the period for syncing persistent volumes
		// and persistent volume claims.
		PVClaimBinderSyncPeriod unversioned.Duration `json:"pvClaimBinderSyncPeriod"`
			...
		// serviceAccountKeyFile is the filename containing a PEM-encoded private RSA key
		// used to sign service account tokens.
		ServiceAccountKeyFile string `json:"serviceAccountKeyFile"`
		// clusterSigningCertFile is the filename containing a PEM-encoded
		// X509 CA certificate used to issue cluster-scoped certificates
		ClusterSigningCertFile string `json:"clusterSigningCertFile"`
	
		// Zone is treated as unhealthy in nodeEvictionRate and secondaryNodeEvictionRate when at least
		// unhealthyZoneThreshold (no less than 3) of Nodes in the zone are NotReady
		UnhealthyZoneThreshold float32 `json:"unhealthyZoneThreshold"`
	}

	//  cmd/kube-controller-manager/app/options/options.go
	// CMServer is the main context object for the controller manager.
	type CMServer struct {
		componentconfig.KubeControllerManagerConfiguration

		Master     string // Kubernetes API Server的访问地址
		Kubeconfig string  
	}

从上述这些变量来看，Controller Manager Server其实就是一个“超级调度中心”，它负责定期同步Node节点状态、资源使用配额信息、Replication Controller、NameSpace、Pod的PV绑定等信息，也包括诸如监控Node 节点状态、清除失败的Pod容器记录等一系列定时任务。

在controller-manager.go里创建CMServer实例并把参数从命令行传递到CMServer后，就调用`cmd/kube-controller-manager/app/controllermanager.go`中的`func Run(s *options.CMServer) error {}`方法进入关键流程，首先创建一个Rest Client对象用于访问Kubernetes API Server提供的API服务：

	kubeClient, err := client.New(kubeconfig)
	if err != nil {
		glog.Fatalf("Invalid API configuration: %v", err)
	}

随后，创建一个HTTP Server以提供必要的性能分析（Performance Profile）和性能指标度量（Metrics）的REST服务：

	go func() {
		mux := http.NewServeMux()
		healthz.InstallHandler(mux)
		if s.EnableProfiling {
			mux.HandleFunc("/debug/pprof/", pprof.Index)
			mux.HandleFunc("/debug/pprof/profile", pprof.Profile)
			mux.HandleFunc("/debug/pprof/symbol", pprof.Symbol)
		}
		configz.InstallHandler(mux)
		mux.Handle("/metrics", prometheus.Handler())

		server := &http.Server{
			Addr:    net.JoinHostPort(s.Address, strconv.Itoa(int(s.Port))),
			Handler: mux,
		}
		glog.Fatal(server.ListenAndServe())
	}()

注意到性能分析的REST路径都是以`/debug`开头的，表面是为了程序调试所用。这里的几个profile都是针对当前Go进程的Profile数据，比如在Master节点上执行curl命令（地址为`http://localhost:10252/debug/pprof/heap`）可以获取进程的当前堆栈信息。其它还有GC回收、SYmbol查看、进程30秒内的CPU利用率、goroutine的阻塞状态等Profile功能，输出的数据格式符合google-perftools这个红菊的要求，因此可以做运行期的可视化Profile，以便排查当前进程潜在的问题或性能瓶颈。  

性能指标度量目前主要收集和统计Kubernetes API Server的Rest API的调用情况，执行curl(`http://localhost:10252/metrics`)，可以看到输出中的信息有助于发现Controller Manager Server在调度方面的性能瓶颈，因此会被包含到进程代码中去。

接下来，启动流程进入到关键代码部分。在这里，启动进程分别创建如下控制器，这些控制器的主要目的是实现资源在Kubernetes API Server的注册表中的周期性同步工作：  

	// NewRecorder returns an EventRecorder that records events with the given event source.
	recorder := eventBroadcaster.NewRecorder(api.EventSource{Component: "controller-manager"})

	run := func(stop <-chan struct{}) {
		//启动创建控制器
		err := StartControllers(s, kubeClient, kubeconfig, stop, recorder)
		glog.Fatalf("error running controllers: %v", err)
		panic("unreachable")
	}
	
- EndpointController: 负责对注册表中的Kubernetes Service的Endpoints信息的同步工作；
- ReplicationManager: 根据注册表中对Replication Controller的定义，完成Pod的复制或者移除，以确保复制数量的一致性；
- NodeController:通过CloudProvider的接口完成Node实例的同步工作；
- ServiceController:通过CloudProvider的接口完成云平台中的服务的同步工作，这些服务目前主要是外部的负载均衡服务；
- ResourceQuotaManager:负责资源配额使用情况的同步工作；
- NameSpaceManager:负责Namespace的同步工作；
- PersistentVolumeClaimBinder:与PersistentVolumeRecycler分别完成PersistentVolum的绑定和回收工作；
- TokensController、ServiceAccountsController分别完成Kubernetes服务的Token、Account的同步工作。

相应的StartControllers（）代码如下：

	func StartControllers(s *options.CMServer, kubeClient *client.Client, kubeconfig *restclient.Config, stop <-chan struct{}, recorder record.EventRecorder) error {
		sharedInformers := informers.NewSharedInformerFactory(clientset.NewForConfigOrDie(restclient.AddUserAgent(kubeconfig, "shared-informers")), ResyncPeriod(s)())
	
		go endpointcontroller.NewEndpointController(sharedInformers.Pods().Informer(), clientset.NewForConfigOrDie(restclient.AddUserAgent(kubeconfig, "endpoint-controller"))).
			Run(int(s.ConcurrentEndpointSyncs), wait.NeverStop)
		time.Sleep(wait.Jitter(s.ControllerStartInterval.Duration, ControllerStartJitter))
	
		go replicationcontroller.NewReplicationManager(
			sharedInformers.Pods().Informer(),
			clientset.NewForConfigOrDie(restclient.AddUserAgent(kubeconfig, "replication-controller")),
			ResyncPeriod(s),
			replicationcontroller.BurstReplicas,
			int(s.LookupCacheSizeForRC),
			s.EnableGarbageCollector,
		).Run(int(s.ConcurrentRCSyncs), wait.NeverStop)
		time.Sleep(wait.Jitter(s.ControllerStartInterval.Duration, ControllerStartJitter))

		...
		nodeController, err := nodecontroller.NewNodeController(sharedInformers.Pods().Informer(), cloud, clientset.NewForConfigOrDie(restclient.AddUserAgent(kubeconfig, "node-controller")),
			s.PodEvictionTimeout.Duration, s.NodeEvictionRate, s.SecondaryNodeEvictionRate, s.LargeClusterSizeThreshold, s.UnhealthyZoneThreshold, s.NodeMonitorGracePeriod.Duration,
			s.NodeStartupGracePeriod.Duration, s.NodeMonitorPeriod.Duration, clusterCIDR, serviceCIDR,
			int(s.NodeCIDRMaskSize), s.AllocateNodeCIDRs)
		if err != nil {
			glog.Fatalf("Failed to initialize nodecontroller: %v", err)
		}
		nodeController.Run(s.NodeSyncPeriod.Duration)
		time.Sleep(wait.Jitter(s.ControllerStartInterval.Duration, ControllerStartJitter))
	
		serviceController, err := servicecontroller.New(cloud, clientset.NewForConfigOrDie(restclient.AddUserAgent(kubeconfig, "service-controller")), s.ClusterName)
		if err != nil {
			glog.Errorf("Failed to start service controller: %v", err)
		} else {
			serviceController.Run(int(s.ConcurrentServiceSyncs))
		}
		time.Sleep(wait.Jitter(s.ControllerStartInterval.Duration, ControllerStartJitter))

		...
		...

创建并启动完成上述的控制器后，各个控制器就开始独立工作，Controller Manager Server启动完毕。