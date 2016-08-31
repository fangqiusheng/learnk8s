# 11 Kube-controller-manager-ReplicationManager #

Kube-controller-manager进程的启动过程的主要逻辑就是启动一系列的“控制器”，然后各个控制器开始独立工作。下面分析ReplicationManager是如何实现Pod副本（Pod Replica）的数量控制的。

## 11.1 ReplicationManager结构体定义 ##

ReplicationManager实际应该称作“ReplicationController”,主要是为了区分API object "ReplicationController"，后续可能会做修改。

首先分析ReplicationManager结构体的定义：

	// ReplicationManager is responsible for synchronizing ReplicationController objects stored
	// in the system with actual running pods.
	// TODO: this really should be called ReplicationController. The only reason why it's a Manager
	// is to distinguish this type from API object "ReplicationController". We should fix this.
	type ReplicationManager struct {
		kubeClient clientset.Interface
		podControl controller.PodControlInterface
	
		// internalPodInformer is used to hold a personal informer.  If we're using
		// a normal shared informer, then the informer will be started for us.  If
		// we have a personal informer, we must start it ourselves.   If you start
		// the controller using NewReplicationManager(passing SharedInformer), this
		// will be null
		internalPodInformer framework.SharedIndexInformer
	
		// An rc is temporarily suspended after creating/deleting these many replicas.
		// It resumes normal action after observing the watch events for them.
		burstReplicas int
		// To allow injection of syncReplicationController for testing.
		syncHandler func(rcKey string) error
	
		// A TTLCache of pod creates/deletes each rc expects to see.
		expectations *controller.UIDTrackingControllerExpectations
	
		// A store of replication controllers, populated by the rcController
		rcStore cache.StoreToReplicationControllerLister
		// Watches changes to all replication controllers
		rcController *framework.Controller
		// A store of pods, populated by the podController
		podStore cache.StoreToPodLister
		// Watches changes to all pods
		podController framework.ControllerInterface
		// podStoreSynced returns true if the pod store has been synced at least once.
		// Added as a member to the struct to allow injection for testing.
		podStoreSynced func() bool
	
		lookupCache *controller.MatchingCache
	
		// Controllers that need to be synced
		queue workqueue.RateLimitingInterface
	
		// garbageCollectorEnabled denotes if the garbage collector is enabled. RC
		// manager behaves differently if GC is enabled.
		garbageCollectorEnabled bool
	}

在上述结构体中，比较关键的几个属性如下：

- kubeClient：用于访问Kubernetes API Server的Rest客户端，这里用于访问注册表中定义的ReplicationController对象并操作Pod。
- podControl：PodControlInterface is an interface that knows how to add or delete pods。实现了CreatePods（），DeletePod（），PatchPod（）等函数，详细可参考`pkg/controller/controller_utils.go`文件中PodControlInterface接口的定义。
- internalPodInformer： SharedInformer has advantages over the broadcaster since it allows us to share a common cache across many controllers. Extending the broadcaster would have required us keep duplicate caches for each watch.
- burstReplicas：int,RC在create/delete burstReplicas个replicas之后会暂时终止，在watch到对应的events后恢复。
- syncHandler：是RC的同步实现方法，完成具体的RC同步逻辑（创建Pod副本时调用PodControl方法），在代码中被赋值ReplicationManager.sycReplicationController方法。
- expectations：是Pod副本在创建、删除过程中的流控制机制的重要组成部分。
- rcStore：cache.StoreToReplicationControllerLister,是一个具有本地缓存功能的通用资源存储服务，这里存放的是framework.Controller运行过程中从Kubernetes API Server同步过来的资源数据，目的是减轻资源同步过程中对Kubernetes API Server造成的访问压力并提高资源同步的效率。
- rcController：framework.Controller实例，用于实现RC同步的任务调度逻辑。framework.Controller是kube-controller-manager设计用于资源对象同步逻辑的专用任务调度框架，详见`pkg/controller/framework/controller.go`。
- podStore:类似rcStore，也是一个是一个具有本地缓存功能的通用资源存储服务。用于获取Pod资源对象。
- podController：watch所有pods的变化，而不是同步（此处应是新版本源码的修改，watch pod变化可提高效率）。
- lookupCache：MatchingCache， save label and selector matching relationship。
- queue：需要被同步的控制器。

## 11.2 NewReplicationManager()函数 ##

controller-manager调用NewReplicationManager()函数启动ReplicationManager（Replication Controller）控制器，相应的代码在文件`pkg/controller/replication/replication_controller.go`中，具体实现如下：

	// NewReplicationManager creates a replication manager
	func NewReplicationManager(podInformer framework.SharedIndexInformer, kubeClient 
	clientset.Interface, resyncPeriod controller.ResyncPeriodFunc, burstReplicas int, 
	lookupCacheSize int, garbageCollectorEnabled bool) *ReplicationManager {
		eventBroadcaster := record.NewBroadcaster()                     					...(1)
		eventBroadcaster.StartLogging(glog.Infof)											...(2)
		eventBroadcaster.StartRecordingToSink(&unversionedcore.EventSinkImpl{Interface:
		kubeClient.Core().Events("")})                                                      ...(3)
		return newReplicationManager(
			eventBroadcaster.NewRecorder(api.EventSource{Component: "replication-controller"}),
			podInformer, kubeClient, resyncPeriod, burstReplicas, lookupCacheSize, garbageCollectorEnabled)														...(4)
	}

分析如下：  
（1）Creates a new event broadcaster.  
（2）StartLogging（写日志） starts sending events received from this EventBroadcaster to the given logging function, which calls StartEventWatcher() function to starts sending events received from this EventBroadcaster to the given event handler function.  
（3）StartRecordingToSink starts sending events received from this EventBroadcaster to the given sink.  
（4）Call eventBroadcaster.NewRecorder() function to return an EventRecorder that records events with the given event source. And calls newReplicationManager() function to configures a replication manager with the specified event recorder.

ReplicationManager（）函数根据特定的event recorder配置Replication Manager, 其详细代码如下：

	// newReplicationManager configures a replication manager with the specified event recorder
	func newReplicationManager(...) *ReplicationManager {
		...
		rm := &ReplicationManager{
			...
		}																		...(1)
	
		rm.rcStore.Indexer, rm.rcController = framework.NewIndexerInformer(
			...
		)																		...(2)
		podInformer.AddEventHandler(framework.ResourceEventHandlerFuncs{
			AddFunc: rm.addPod,
			...
		})																		...(3)
		rm.podStore.Indexer = podInformer.GetIndexer()
		rm.podController = podInformer.GetController()
		...
		return rm
	}


（1）根据参数，实例化ReplicationManager。  
（2）通过调用framework.NewIndexerInformer() 调用framework.NewIndexerInformer()方法，创建用于RC同步的framework.Controller（rcController）及同步缓存rcStore的Index。  
（3）添加Pod的处理函数AddEventHandler

下面是framework.NewIndexerInformer()方法的源码：

	// NewIndexerInformer returns a cache.Indexer and a controller for populating the index
	// while also providing event notifications. You should only used the returned
	// cache.Index for Get/List operations; Add/Modify/Deletes will cause the event
	// notifications to be faulty.
	func NewIndexerInformer(
		lw cache.ListerWatcher,
		objType runtime.Object,
		resyncPeriod time.Duration,
		h ResourceEventHandler,
		indexers cache.Indexers,
	) (cache.Indexer, *Controller) {
		// This will hold the client state, as we know it.
		clientState := cache.NewIndexer(DeletionHandlingMetaNamespaceKeyFunc, indexers)
	
		// This will hold incoming changes. Note how we pass clientState in as a
		// KeyLister, that way resync operations will result in the correct set
		// of update/delete deltas.
		fifo := cache.NewDeltaFIFO(cache.MetaNamespaceKeyFunc, nil, clientState)
		...
		return clientState, New(cfg)
	}


上述代码中：

- *lw（cache.ListerWatcher）is list and watch functions for the source of the resource you want to be informed of，用于获取和监测资源对象的变化
- fifo则是一个DeltaFIFO的Queue，用于存放变化的资源。
- * objType is an object of the type that you expect to receive.
- * resyncPeriod: if non-zero, will re-list this often (you will get OnUpdatecalls, even if nothing changed). Otherwise, re-list will be delayed as long as possible (until the upstream source closes the watch or times out, or you stop the controller).
- * h is the object you want notifications sent to.

当Controller框架发现有变化的资源需要处理时，就会将新资源与本地缓存clientState中的资源进行对比，然后调用相应的资源处理函数ResourceEventHandler的方法，完成具体的处理逻辑操作。下面是针对RC的ResourceEventHandler的具体实现：
  
	framework.ResourceEventHandlerFuncs{
				AddFunc:    rm.enqueueController,
				UpdateFunc: rm.updateRC,
				// This will enter the sync loop and no-op, because the controller has been deleted 
				from the store.
				// Note that deleting a controller immediately after scaling it to 0 will not work. 
				The recommended
				// way of achieving this is by performing a `stop` operation on the controller.
				DeleteFunc: rm.enqueueController,
			},

上述代码中，我们看到RC里的Pod的副本数量属性发生变化以后，ResourceEventHandler就将此RC放入ReplicationManager的queue队列中等待处理。为什么没有在这个handler函数中直接处理，而是先放入队列再异步处理呢？最主要的一个原因是Pod副本创建的过程比较耗时。Controller框架把需要同步的RC放入queue以后，接下来是谁在“消费”这个队列呢？答案在ReplicationManager的Run（）方法中：

	// Run begins watching and syncing.
	func (rm *ReplicationManager) Run(workers int, stopCh <-chan struct{}) {
		defer utilruntime.HandleCrash()
		glog.Infof("Starting RC Manager")
		go rm.rcController.Run(stopCh)
		go rm.podController.Run(stopCh)
		for i := 0; i < workers; i++ {
			// Until loops until stop channel is closed, running f every period.
			go wait.Until(rm.worker, time.Second, stopCh)  //  pkg/util/wait/wait.go
		}
	
		if rm.internalPodInformer != nil {
			go rm.internalPodInformer.Run(stopCh)
		}
	
		<-stopCh
		glog.Infof("Shutting down RC Manager")
		rm.queue.ShutDown()
	}

这个run的方法是先启动两个controller，启动方法如下,调用Controller.Run()方法:

	// Run begins processing items, and will continue until a value is sent down stopCh.
	// It's an error to call Run more than once.
	// Run blocks; call via go.
	func (c *Controller) Run(stopCh <-chan struct{}) {
		defer utilruntime.HandleCrash()
		r := cache.NewReflector(
			c.config.ListerWatcher,
			c.config.ObjectType,
			c.config.Queue,
			c.config.FullResyncPeriod,
		)
	
		c.reflectorMutex.Lock()
		c.reflector = r
		c.reflectorMutex.Unlock()
	
		r.RunUntil(stopCh)
	
		wait.Until(c.processLoop, time.Second, stopCh)
	}

上述代码首先启动rcController与podController这两个Controller，启动之后，这两个Controller就分别开始拉取RC与Pod的变动信息，随后又启动N个协程并发处理RC的队列，其中`func Until(f func(), period time.Duration, stopCh <-chan struct{})`。下面是ReplicationManager的worker方法的源码,负责从RC队列中拉取RC并调用rm的`syncHandler()`方法完成具体处理：

	// worker runs a worker thread that just dequeues items, processes them, and marks them done.
	// It enforces that the syncHandler is never invoked concurrently with the same key.
	func (rm *ReplicationManager) worker() {
		workFunc := func() bool {
			key, quit := rm.queue.Get()
			if quit {
				return true
			}
			defer rm.queue.Done(key)
	
			err := rm.syncHandler(key.(string))
			if err == nil {
				rm.queue.Forget(key)
				return false
			}
	
			rm.queue.AddRateLimited(key)
			utilruntime.HandleError(err)
			return false
		}
		for {
			if quit := workFunc(); quit {
				glog.Infof("replication controller worker shutting down")
				return
			}
		}
	}

从ReplicationManager的构造函数newReplicationManager()中`rm.syncHandler = rm.syncReplicationController`得知：syncHandler()在这里其实是`func (rm *ReplicationManager) syncReplicationController(key string)`方法。下面是该方法的源码：

	// syncReplicationController will sync the rc with the given key if it has had its expectations fulfilled, meaning
	// it did not expect to see any more of its pods created or deleted. This function is not meant to be invoked
	// concurrently with the same key.
	func (rm *ReplicationManager) syncReplicationController(key string) error {
		trace := util.NewTrace("syncReplicationController: " + key)
		defer trace.LogIfLong(250 * time.Millisecond)
	
		startTime := time.Now()
		defer func() {
			glog.V(4).Infof("Finished syncing controller %q (%v)", key, time.Now().Sub(startTime))
		}()
	
		if !rm.podStoreSynced() {
			// Sleep so we give the pod reflector goroutine a chance to run.
			time.Sleep(PodStoreSyncedPollPeriod)
			glog.Infof("Waiting for pods controller to sync, requeuing rc %v", key)
			rm.queue.Add(key)
			return nil
		}
	
		obj, exists, err := rm.rcStore.Indexer.GetByKey(key)
		if !exists {
			glog.Infof("Replication Controller has been deleted %v", key)
			rm.expectations.DeleteExpectations(key)
			return nil
		}
		if err != nil {
			return err
		}
		rc := *obj.(*api.ReplicationController)
	
		// Check the expectations of the rc before counting active pods, otherwise a new pod can sneak in
		// and update the expectations after we've retrieved active pods from the store. If a new pod enters
		// the store after we've checked the expectation, the rc sync is just deferred till the next relist.
		rcKey, err := controller.KeyFunc(&rc)
		if err != nil {
			glog.Errorf("Couldn't get key for replication controller %#v: %v", rc, err)
			return err
		}
		trace.Step("ReplicationController restored")
		rcNeedsSync := rm.expectations.SatisfiedExpectations(rcKey)
		trace.Step("Expectations restored")
	
		// NOTE: filteredPods are pointing to objects from cache - if you need to
		// modify them, you need to copy it first.
		// TODO: Do the List and Filter in a single pass, or use an index.
		var filteredPods []*api.Pod
		if rm.garbageCollectorEnabled {
			// list all pods to include the pods that don't match the rc's selector
			// anymore but has the stale controller ref.
			pods, err := rm.podStore.Pods(rc.Namespace).List(labels.Everything())
			if err != nil {
				glog.Errorf("Error getting pods for rc %q: %v", key, err)
				rm.queue.Add(key)
				return err
			}
			cm := controller.NewPodControllerRefManager(rm.podControl, rc.ObjectMeta, labels.Set(rc.Spec.Selector).AsSelector(), getRCKind())
			matchesAndControlled, matchesNeedsController, controlledDoesNotMatch := cm.Classify(pods)
			for _, pod := range matchesNeedsController {
				err := cm.AdoptPod(pod)
				// continue to next pod if adoption fails.
				if err != nil {
					// If the pod no longer exists, don't even log the error.
					if !errors.IsNotFound(err) {
						utilruntime.HandleError(err)
					}
				} else {
					matchesAndControlled = append(matchesAndControlled, pod)
				}
			}
			filteredPods = matchesAndControlled
			// remove the controllerRef for the pods that no longer have matching labels
			var errlist []error
			for _, pod := range controlledDoesNotMatch {
				err := cm.ReleasePod(pod)
				if err != nil {
					errlist = append(errlist, err)
				}
			}
			if len(errlist) != 0 {
				aggregate := utilerrors.NewAggregate(errlist)
				// push the RC into work queue again. We need to try to free the
				// pods again otherwise they will stuck with the stale
				// controllerRef.
				rm.queue.Add(key)
				return aggregate
			}
		} else {
			pods, err := rm.podStore.Pods(rc.Namespace).List(labels.Set(rc.Spec.Selector).AsSelector())
			if err != nil {
				glog.Errorf("Error getting pods for rc %q: %v", key, err)
				rm.queue.Add(key)
				return err
			}
			filteredPods = controller.FilterActivePods(pods)
		}
	
		var manageReplicasErr error
		if rcNeedsSync && rc.DeletionTimestamp == nil {
			manageReplicasErr = rm.manageReplicas(filteredPods, &rc)
		}
		trace.Step("manageReplicas done")
	
		// Count the number of pods that have labels matching the labels of the pod
		// template of the replication controller, the matching pods may have more
		// labels than are in the template. Because the label of podTemplateSpec is
		// a superset of the selector of the replication controller, so the possible
		// matching pods must be part of the filteredPods.
		fullyLabeledReplicasCount := 0
		readyReplicasCount := 0
		templateLabel := labels.Set(rc.Spec.Template.Labels).AsSelector()
		for _, pod := range filteredPods {
			if templateLabel.Matches(labels.Set(pod.Labels)) {
				fullyLabeledReplicasCount++
			}
			if api.IsPodReady(pod) {
				readyReplicasCount++
			}
		}
	
		// Always updates status as pods come up or die.
		if err := updateReplicaCount(rm.kubeClient.Core().ReplicationControllers(rc.Namespace), rc, len(filteredPods), fullyLabeledReplicasCount, readyReplicasCount); err != nil {
			// Multiple things could lead to this update failing.  Returning an error causes a requeue without forcing a hotloop
			return err
		}
	
		return manageReplicasErr
	}

上述代码中有一个重要的流控变量rcNeedSync。为了限流，在RC同步逻辑的过程中，一个RC每次最多执行N个Pod的创建/删除，如果某个RC同步过程中涉及的Pod副本数量超过burstReplicas这个阈值，就会采用RCExpectations机制进行限流。RCExpectations对象可以理解为一个简单的规则：即在规定的时间内执行N次操作，每次操作都使计数器减一，计数器为零标识N个操作已经完成，可以进行下一批次的操作了。

Kubernetes为什么会设计这一一个流程控制机制呢？其实答案很简单--为了公平。因为谷歌的卡啊Kubernetes的资深大牛们早已预见到某个RC的Pod副本以此扩容至100倍的极端情况可能真实发生，如果没有留空机制，这个巨无霸的RC同步操作会导致其它众多“散户”崩溃！这绝对不是谷歌的理念。

接着看上述代码里所调用的ReplicationManager的manageReplicas方法，这是RC同步的具体逻辑实现，此方法采用了并发调用的方式执行批量的Pod副本操作任务。相关代码如下：

	var wg sync.WaitGroup
			wg.Add(diff)
			glog.V(2).Infof("Too few %q/%q replicas, need %d, creating %d", rc.Namespace, rc.Name, rc.Spec.Replicas, diff)
			for i := 0; i < diff; i++ {
				go func() {
					defer wg.Done()
					var err error
					if rm.garbageCollectorEnabled {
						var trueVar = true
						controllerRef := &api.OwnerReference{
							APIVersion: getRCKind().GroupVersion().String(),
							Kind:       getRCKind().Kind,
							Name:       rc.Name,
							UID:        rc.UID,
							Controller: &trueVar,
						}
						err = rm.podControl.CreatePodsWithControllerRef(rc.Namespace, rc.Spec.Template, rc, controllerRef)
					} else {
						err = rm.podControl.CreatePods(rc.Namespace, rc.Spec.Template, rc)
					}
					...
			}
		wg.Wait()


追踪至此，我们才看到Pod副本的真正代码在`pkg/controller/controller_utils.go`源文件中的`podControl.CreatePodsWithControllerRef()`或`podControl.CreatePods()`方法里，并根据`garbageCollectorEnabled`属性选择使用不同的方法新建Pod。而此方法的具体实现方法则是`RealPodControl.createPods()`。删除Pod的原理与Create的方法类似，在此不再赘述。  

下面分析`RealPodControl.createPods()`方法，其源码如下：

	func (r RealPodControl) createPods(nodeName, namespace string, template *api.PodTemplateSpec, object runtime.Object, controllerRef *api.OwnerReference) error {
		pod, err := GetPodFromTemplate(template, object, controllerRef)
		if err != nil {
			return err
		}
		if len(nodeName) != 0 {
			pod.Spec.NodeName = nodeName
		}
		if labels.Set(pod.Labels).AsSelector().Empty() {
			return fmt.Errorf("unable to create pods, no labels")
		}
		if newPod, err := r.KubeClient.Core().Pods(namespace).Create(pod); err != nil {
			r.Recorder.Eventf(object, api.EventTypeWarning, "FailedCreate", "Error creating: %v", err)
			return fmt.Errorf("unable to create pods: %v", err)
		} else {
			accessor, err := meta.Accessor(object)
			if err != nil {
				glog.Errorf("parentObject does not have ObjectMeta, %v", err)
				return nil
			}
			glog.V(4).Infof("Controller %v created pod %v", accessor.GetName(), newPod.Name)
			r.Recorder.Eventf(object, api.EventTypeNormal, "SuccessfulCreate", "Created pod: %v", newPod.Name)
		}
		return nil
	}

由上述源码可知，创建Pod副本的过程就是创建一个Pod资源对象，并把RC中定义的Pod模板赋值给该Pod对象，并且Pod的名字用RC的名字做前缀。最后通过调用Kubernetes Client将Pod对象通过Kubernetes API Server写入后端的etcd存储中。

