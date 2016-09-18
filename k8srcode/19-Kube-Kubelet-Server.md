# 19 Kube-Kubelet-Server #

Kubelet是运行在Node节点上的重要守护进程，是工作在一线的重要“工人”，它才是负责“实例化”和“启动”一个具体的Pod的幕后主导，并且掌管着本节点上的Pod和容器的全生命周期过程，定时向Master汇报工作情况。此外，Kubelet进程也是一个Server进程，它默认监听10250端口，接收并执行远程Master发来的指令。

## 19.1 Kubelet启动流程 ##

kubelet相关代码的主入口在`cmd/kublet`下，调用方法的实现可在`pkg/kubelet`下。入口main()函数的逻辑如下：

	func main() {
		s := options.NewKubeletServer() //创建一个KubeletServer实例
		s.AddFlags(pflag.CommandLine) //根据命令行参数加载flag
	
		flag.InitFlags()
		logs.InitLogs()
		defer logs.FlushLogs()
	
		verflag.PrintAndExitIfRequested()
	
		//启动该kubeletServer
		if err := app.Run(s, nil); err != nil {
			fmt.Fprintf(os.Stderr, "error: %v\n", err)
			os.Exit(1)
		}
	}

kubelet.go#main 函数的主要流程包括如下三个步骤：

- 创建一个KubeletServer实例
- 根据命令行参数加载flag
- 启动该kubeletServer。


### 19.1.1 options.NewKubeletServer ###

首先查看KubeletServer数据结构，如下所示：

	type KubeletServer struct {
		componentconfig.KubeletConfiguration //Kubelet配置结构体
	
		KubeConfig          util.StringFlag  //找到用于访问API Server的证书
		BootstrapKubeconfig string
	
		...
	}

其中componentconfig.KubeletConfiguration结构体如下：

	type KubeletConfiguration struct {
		unversioned.TypeMeta	
		PodManifestPath string `json:"podManifestPath"`		
		SyncFrequency unversioned.Duration `json:"syncFrequency"`		
		FileCheckFrequency unversioned.Duration `json:"fileCheckFrequency"`		
		HTTPCheckFrequency unversioned.Duration `json:"httpCheckFrequency"`、		
		ManifestURL string `json:"manifestURL"`		
		ManifestURLHeader string `json:"manifestURLHeader"`		
		Address string `json:"address"`		
		Port int32 `json:"port"`
		MaxPerPodContainerCount int32 `json:"maxPerPodContainerCount"`		
		MaxContainerCount int32 `json:"maxContainerCount"`		
		CAdvisorPort int32 `json:"cAdvisorPort"`		
		HealthzPort int32 `json:"healthzPort"`
		...
				
		NetworkPluginName string `json:"networkPluginName"`
		NetworkPluginDir string `json:"networkPluginDir"`
		VolumePluginDir string `json:"volumePluginDir"`
		CloudProvider string `json:"cloudProvider,omitempty"`
		CloudConfigFile string `json:"cloudConfigFile,omitempty"`
		...
		PodsPerCore int32 `json:"podsPerCore"`
		...
		MasterServiceNamespace string `json:"masterServiceNamespace"`
		ClusterDNS string `json:"clusterDNS"`
		...
	}

- **podManifestPath**：is the path to the directory containing pod manifests to run, or the path to a single manifest file
- **syncFrequency**： is the max period between synchronizing running containers and config
- **fileCheckFrequency**: is the duration between checking config files for new data
- **httpCheckFrequency**： is the duration between checking http for new data
- **manifestURL**： is the URL for accessing the container manifest
- **manifestURLHeader**： is the HTTP header to use when accessing the manifest URL, with the key separated from the value with a ':', as in 'key:value'
- **address**： is the IP address for the Kubelet to serve on (set to 0.0.0.0 for all interfaces)
- **port**： is the port for the Kubelet to serve on.
- **maxPerPodContainerCount**： is the maximum number of old instances to retain per container. Each container takes up some disk space.
- **maxContainerCount**： is the maximum number of old instances of containers to retain globally. Each container takes up some disk space.
- **cAdvisorPort**： is the port of the localhost cAdvisor endpoint
- **healthzPort**： is the port of the localhost healthz endpoint
- **networkPluginName**： is the name of the network plugin to be invoked for various events in kubelet/pod lifecycle
- **networkPluginDir**： is the full path of the directory in which to search for network plugins.
- **volumePluginDir**： is the full path of the directory in which to search for additional third party volume plugins
- **cloudProvider**： is the provider for cloud services.
- **cloudConfigFile**： is the path to the cloud provider configuration file.
- **PodsPerCore**： Maximum number of pods per core. Cannot exceed MaxPods
- **masterServiceNamespace**： is The namespace from which the kubernetes master services should be injected into pods.
- **clusterDNS**： is the IP address for a cluster DNS server.  If set, kubelet will configure all containers to use this for DNS resolution in addition to the host's DNS servers
- ...

KubeletConfiguration包含了Kubelet的所有相关配置信息。本部分只列举了KubeletConfiguration的部分重要属性，详细可参考源代码。

options.NewKubeletServer源码如下：

	// NewKubeletServer will create a new KubeletServer with default values.
	func NewKubeletServer() *KubeletServer {
		config := componentconfig.KubeletConfiguration{}
		api.Scheme.Convert(&v1alpha1.KubeletConfiguration{}, &config, nil)
		return &KubeletServer{
			AuthPath:             util.NewStringFlag("/var/lib/kubelet/kubernetes_auth"), // deprecated
			KubeConfig:           util.NewStringFlag("/var/lib/kubelet/kubeconfig"),
			RequireKubeConfig:    false, // in 1.5, default to true
			KubeletConfiguration: config,
		}
	}

