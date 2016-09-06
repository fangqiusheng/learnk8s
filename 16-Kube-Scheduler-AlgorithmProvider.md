# 16 Kube-Scheduler-Algorithm-Provider #

## 16.1 Kube-Scheduler算法注册流程 ##

在源码文件`plugin/cmd/kube-scheduler/app/server.go`中的Run(s *options.SchedulerServer)函数中通过如下代码实现Scheduler 算法的注册（register）和配置(config)：

	configFactory := factory.NewConfigFactory(kubeClient, s.SchedulerName, s.HardPodAffinitySymmetricWeight, s.FailureDomains)
	config, err := createConfig(s, configFactory)

下面看下createConfig函数的源码：

	func createConfig(s *options.SchedulerServer, configFactory *factory.ConfigFactory) (*scheduler.Config, error) {
		if _, err := os.Stat(s.PolicyConfigFile); err == nil {
			var (
				policy     schedulerapi.Policy
				configData []byte
			)
			configData, err := ioutil.ReadFile(s.PolicyConfigFile)
			if err != nil {
				return nil, fmt.Errorf("unable to read policy config: %v", err)
			}
			if err := runtime.DecodeInto(latestschedulerapi.Codec, configData, &policy); err != nil {
				return nil, fmt.Errorf("invalid configuration: %v", err)
			}
			return configFactory.CreateFromConfig(policy)
		}
	
		// if the config file isn't provided, use the specified (or default) provider
		return configFactory.CreateFromProvider(s.AlgorithmProvider)
	}

其中用到两个重要的参数：

- AlgorithmProvider：对应参数algorithm-provider，是AlgorithmProviderConfig的名称。
- PolicyConfigFile：用来加载调度策略配置文件。

从代码上看这两个参数的作用其实是一样的，都是加载一组调度规则，这组调度规则要么在程序里定义为一个AlgorithmProviderConfig，要么保存到文件PolicyConfigFile中。

其中 CreateFromConfig函数实现Creates a scheduler from the configuration file。其实现原理如下：
	
	func (f *ConfigFactory) CreateFromConfig(policy schedulerapi.Policy) (*scheduler.Config, error) {
		glog.V(2).Infof("Creating scheduler from configuration: %v", policy)
	
		// validate the policy configuration
		if err := validation.ValidatePolicy(policy); err != nil {
			return nil, err
		}
	
		predicateKeys := sets.NewString()
		for _, predicate := range policy.Predicates {
			glog.V(2).Infof("Registering predicate: %s", predicate.Name)
			predicateKeys.Insert(RegisterCustomFitPredicate(predicate))
		}
	
		priorityKeys := sets.NewString()
		for _, priority := range policy.Priorities {
			glog.V(2).Infof("Registering priority: %s", priority.Name)
			priorityKeys.Insert(RegisterCustomPriorityFunction(priority))
		}
	
		extenders := make([]algorithm.SchedulerExtender, 0)
		if len(policy.ExtenderConfigs) != 0 {
			for ii := range policy.ExtenderConfigs {
				glog.V(2).Infof("Creating extender with config %+v", policy.ExtenderConfigs[ii])
				if extender, err := scheduler.NewHTTPExtender(&policy.ExtenderConfigs[ii], policy.APIVersion); err != nil {
					return nil, err
				} else {
					extenders = append(extenders, extender)
				}
			}
		}
		return f.CreateFromKeys(predicateKeys, priorityKeys, extenders)
	}

由以上源码可知，`CreateFromConfig`函数通过调用**`RegisterCustomFitPredicate`**函数实现 Registers a custom fit predicate with the algorithm registry. Returns the name, with which the predicate was registered.通过调用**`RegisterCustomPriorityFunction`**函数实现Registers a custom priority function with the algorithm registry. Returns the name, with which the priority function was registered.

而`CreateFromProvider`函数实现Creates a scheduler from the name of a registered algorithm provider。其通过如下代码调用实现：

	provider, err := GetAlgorithmProvider(providerName)

而GetAlgorithmProvider函数通过`algorithmProviderMap = make(map[string]AlgorithmProviderConfig)`实现AlgorithmProvider name到实现AlgorithmProvider的映射。

这两个函数均通过解析配置调用CreateFromKeys函数实现Creates a scheduler from a set of registered fit predicate keys and priority keys. 而CreateFromKeys函数的相关代码如下：

	predicateFuncs, err := f.GetPredicates(predicateKeys)
	if err != nil {
		return nil, err
	}

	priorityConfigs, err := f.GetPriorityFunctionConfigs(priorityKeys)
	if err != nil {
		return nil, err
	}

	f.Run()

	algo := scheduler.NewGenericScheduler(f.schedulerCache, predicateFuncs, priorityConfigs, extenders)

大致流程为：通过`GetPredicates`和`GetPriorityFunctionConfigs`函数分别获取Predicates算法和Priority算法的配置，并通过NewGenericScheduler新建一个generalScheduler，相应的结构体如下：

	type genericScheduler struct {
		cache             schedulercache.Cache
		predicates        map[string]algorithm.FitPredicate
		prioritizers      []algorithm.PriorityConfig
		extenders         []algorithm.SchedulerExtender
		pods              algorithm.PodLister
		lastNodeIndexLock sync.Mutex
		lastNodeIndex     uint64
	
		cachedNodeInfoMap map[string]*schedulercache.NodeInfo
	}

易知该genericScheduler结构体包含了predicates和prioritizers（包含对应priority函数的权重信息weight）的具体算法配置。从而实现了从KubeSchedulerConfiguration配置的AlgorithmProvider参数或者PolicyConfigFile参数到具体的predicates和prioritizers算法函数的映射。


## 16.2 Kube-Scheduler Algorithm ##

### 16.2.1 算法注册/配置的存储设计 ###
查看文件`plugin/pkg/scheduler/algorithmprovider/defaults/defaults.go`中的init()函数，

	func init() {
		factory.RegisterAlgorithmProvider(factory.DefaultProvider, defaultPredicates(), defaultPriorities())
		factory.RegisterAlgorithmProvider(ClusterAutoscalerProvider, defaultPredicates(),
			replace(defaultPriorities(), "LeastRequestedPriority", "MostRequestedPriority"))
		factory.RegisterPriorityFunction("EqualPriority", scheduler.EqualPriority, 1)
		factory.RegisterPriorityConfigFactory(
			"ServiceSpreadingPriority",
			factory.PriorityConfigFactory{
				Function: func(args factory.PluginFactoryArgs) algorithm.PriorityFunction {
					return priorities.NewSelectorSpreadPriority(args.PodLister, args.ServiceLister, algorithm.EmptyControllerLister{}, algorithm.EmptyReplicaSetLister{})
				},
				Weight: 1,
			},
		)
		factory.RegisterFitPredicate("PodFitsPorts", predicates.PodFitsHostPorts)
		factory.RegisterPriorityFunction("ImageLocalityPriority", priorities.ImageLocalityPriority, 1)
		factory.RegisterFitPredicate("PodFitsHostPorts", predicates.PodFitsHostPorts)
		factory.RegisterFitPredicate("PodFitsResources", predicates.PodFitsResources)
		factory.RegisterFitPredicate("HostName", predicates.PodFitsHost)
		factory.RegisterFitPredicate("MatchNodeSelector", predicates.PodSelectorMatches)
		factory.RegisterPriorityFunction("MostRequestedPriority", priorities.MostRequestedPriority, 1)
	}

可知Kube-Scheduler默认注册了Algorithm Provider具体是通过factory.RegisterAlgorithmProvider函数注册factory.DefaultProvider，并执行 defaultPredicates()和defaultPriorities()分别注册一组Predicate和Priority算法。**Kubernetes默认的调度指导原则是尽量均匀分布Pod到不同的Node上，并且确保每个Node上的资源利用率基本一致。**

RegisterAlgorithmProvider通过algorithmProviderMap = make(map[string]AlgorithmProviderConfig)存储name-->AlgorithmProviderConfig的映射关系。相应的存储结构如下：

	var (
		schedulerFactoryMutex sync.Mutex
	
		// maps that hold registered algorithm types
		fitPredicateMap      = make(map[string]FitPredicateFactory)
		priorityFunctionMap  = make(map[string]PriorityConfigFactory)
		algorithmProviderMap = make(map[string]AlgorithmProviderConfig)
	)

即Kubernetes通过map结构实现了name到相应算法函数的映射，对应的子结构如下所示：
	
	// A FitPredicateFactory produces a FitPredicate from the given args.
	type FitPredicateFactory func(PluginFactoryArgs) algorithm.FitPredicate
	
	// A PriorityFunctionFactory produces a PriorityConfig from the given args.
	type PriorityFunctionFactory func(PluginFactoryArgs) algorithm.PriorityFunction
	
	// A PriorityConfigFactory produces a PriorityConfig from the given function and weight
	type PriorityConfigFactory struct {
		Function PriorityFunctionFactory
		Weight   int   //表示对应PriorityFunction的权重
	}

	const (
		DefaultProvider = "DefaultProvider"
	)
	
	type AlgorithmProviderConfig struct {
		FitPredicateKeys     sets.String
		PriorityFunctionKeys sets.String
	}

Kube-Scheduler总的存储映射关系如下：

**algorithmProviderMap-->name-->AlgorithmProviderConfig-->FitPredicateKeys/PriorityFunctionKeys-->predicateFuncs/priorityConfigs-->Algorithm（NewGenericScheduler）**

### 16.2.2 Scheduler算法的设计和实现###

Scheduler的各种predicateFuncs和priorityConfigs算法的具体实现在目录`plugin/pkg/scheduler/algorithm`下，个算法的原理在此不做赘述。在此先简单查看一个数据结构：


	// podMetadata is a type that is passed as metadata for predicate functions
	type predicateMetadata struct {
		podBestEffort             bool
		podRequest                *schedulercache.Resource
		podPorts                  map[int]bool
		matchingAntiAffinityTerms []matchingPodAntiAffinityTerm
	}

一个Pod资源请求是schedulercache.Resource的指针。

相应的predicate和Priority函数示例如下：

	func NoDiskConflict(pod *api.Pod, meta interface{}, nodeInfo *schedulercache.NodeInfo) 

	func calculateUnusedPriority(pod *api.Pod, podRequests *schedulercache.Resource, node *api.Node, nodeInfo *schedulercache.NodeInfo) 

此类函数均涉及到schedulercache。换言之，schedulercache存储的是节点级别的Pod聚合（资源）信息，相应的算法计算也依据scheduelercache中的资源信息。详细内容在此不做赘述。




## 16.3 Kube-Scheduler Extender扩展算法 ##

查看CreateFromConfig函数源码如下：

	// Creates a scheduler from the configuration file
	func (f *ConfigFactory) CreateFromConfig(policy schedulerapi.Policy) (*scheduler.Config, error) {
		...
	
		extenders := make([]algorithm.SchedulerExtender, 0)
		if len(policy.ExtenderConfigs) != 0 {
			for ii := range policy.ExtenderConfigs {
				glog.V(2).Infof("Creating extender with config %+v", policy.ExtenderConfigs[ii])
				if extender, err := scheduler.NewHTTPExtender(&policy.ExtenderConfigs[ii], policy.APIVersion); err != nil {
					return nil, err
				} else {
					extenders = append(extenders, extender)
				}
			}
		}
		return f.CreateFromKeys(predicateKeys, priorityKeys, extenders)
	}

可知Scheduler可以从配置文件PolicyConfigFile中读取扩展算法的extenders，然后通过CreateFromKeys函数调用NewGenericScheduler函数配置到Scheduler.Algorithm属性中，从而影响Scheduler的调度选择。代码如下：

	func (f *ConfigFactory) CreateFromKeys(predicateKeys, priorityKeys sets.String, extenders []algorithm.SchedulerExtender) (*scheduler.Config, error) {
		...
	
		algo := scheduler.NewGenericScheduler(f.schedulerCache, predicateFuncs, priorityConfigs, extenders)
		...
	}

	// plugin/pkg/scheduler/scheduler.go
	func (s *Scheduler) scheduleOne() {
		...
		dest, err := s.config.Algorithm.Schedule(pod, s.config.NodeLister)
		...
		}
而CreateFromProvider中相应的extenders扩展为空，表明无法通过CreateFromProvider函数获取extender信息：

	// Creates a scheduler from the name of a registered algorithm provider.
	func (f *ConfigFactory) CreateFromProvider(providerName string) (*scheduler.Config, error) {
		glog.V(2).Infof("Creating scheduler from algorithm provider '%v'", providerName)
		provider, err := GetAlgorithmProvider(providerName)
		if err != nil {
			return nil, err
		}
	
		return f.CreateFromKeys(provider.FitPredicateKeys, provider.PriorityFunctionKeys, []algorithm.SchedulerExtender{})
	}


首先查看

	type genericScheduler struct {
		...
		predicates        map[string]algorithm.FitPredicate
		prioritizers      []algorithm.PriorityConfig
		extenders         []algorithm.SchedulerExtender
		...
	}

对应的SchedulerExtender接口如下：


	type SchedulerExtender interface {		
		Filter(pod *api.Pod, nodes []*api.Node) (filteredNodes []*api.Node, failedNodesMap schedulerapi.FailedNodesMap, err error)
		Prioritize(pod *api.Pod, nodes []*api.Node) (hostPriorities *schedulerapi.HostPriorityList, weight int, err error)
	}

 SchedulerExtender is an interface for external processes to influence scheduling decisions made by Kubernetes. This is typically needed for resources not directly managed by Kubernetes. 

- Filter based on extender-implemented predicate functions. The filtered list is expected to be a subset of the supplied list. failedNodesMap optionally contains the list of failed nodes and failure reasons.
-  Prioritize based on extender-implemented priority functions. The returned scores & weight are used to compute the weighted score for an extender. The weighted scores are added to the scores computed  by Kubernetes scheduler. The total scores are used to do the host selection.

ScheduleAlgorithm is an interface implemented by things that know how to schedule pods onto machines.
type ScheduleAlgorithm interface {
	Schedule(*api.Pod, NodeLister) (selectedMachine string, err error)
}

接下来查看scheduler.NewGenericScheduler()方法，extenders是如何具体实现的？代码如下：


	func (g *genericScheduler) Schedule(pod *api.Pod, nodeLister algorithm.NodeLister) (string, error) {
		...
		filteredNodes, failedPredicateMap, err := findNodesThatFit(pod, g.cachedNodeInfoMap, nodes, g.predicates, g.extenders)
		priorityList, err := PrioritizeNodes(pod, g.cachedNodeInfoMap, g.prioritizers, filteredNodes, g.extenders)
		...
		return g.selectHost(priorityList)
	}

Schedule tries to schedule the given pod to one of node in the node list.If it succeeds, it will return the name of the node. If it fails, it will return a Fiterror error with reasons.

由上述代码可以看出,extenders影响了节点的filter和priority的计算过程，对应的方法为：findNodesThatFit和PrioritizeNodes函数，源码如下：
	
	func findNodesThatFit(
		pod *api.Pod,
		nodeNameToInfo map[string]*schedulercache.NodeInfo,
		nodes []*api.Node,
		predicateFuncs map[string]algorithm.FitPredicate,
		extenders []algorithm.SchedulerExtender) ([]*api.Node, FailedPredicateMap, error) {
	
		...
		if len(filtered) > 0 && len(extenders) != 0 {
			for _, extender := range extenders {
				filteredList, failedMap, err := extender.Filter(pod, filtered)
				...
		return filtered, failedPredicateMap, nil
	}

 Filters the nodes to find the ones that fit based on the given predicate functions Each node is passed through the predicate functions to determine if it is a fit.同时，由上述代码可以看出当extenders非空时，会调用extender.Filter()方法继续过滤备选节点。从而相应备选节点的选取。


	func PrioritizeNodes(
		pod *api.Pod,
		nodeNameToInfo map[string]*schedulercache.NodeInfo,
		priorityConfigs []algorithm.PriorityConfig,
		nodes []*api.Node,
		extenders []algorithm.SchedulerExtender,
	) (schedulerapi.HostPriorityList, error) {
		result := make(schedulerapi.HostPriorityList, 0, len(nodeNameToInfo))

	if len(extenders) != 0 && nodes != nil {
			for _, extender := range extenders {
				wg.Add(1)
				go func(ext algorithm.SchedulerExtender) {
					defer wg.Done()
					prioritizedList, weight, err := ext.Prioritize(pod, nodes)
				...
		for host, score := range combinedScores {
			glog.V(10).Infof("Host %s Score %d", host, score)
			result = append(result, schedulerapi.HostPriority{Host: host, Score: score})
		}
		return result, nil
	}

 Prioritizes the nodes by running the individual priority functions in parallel. Each priority function is expected to set a score of 0-10. 0 is the lowest priority score (least preferred node) and 10 is the highest. Each priority function can also have its own weight. The node scores returned by the priority function are multiplied by the weights to get weighted scores. All scores are finally combined (added) to get the total weighted scores of all nodes.
	
 类似地，当extenders非空时，PrioritizeNodes会额外调用ext.Prioritize(pod, nodes)计算相应的prioritizedList,和weight，从而影响PrioritizeNodes的结果。

至此，extenders的理解完毕。