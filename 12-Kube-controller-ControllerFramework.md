# 12 Kube-controller Controller Framework #
下面分析Controller框架中如何实现资源对象的的查询和监听逻辑，并且在资源发生变动时回调Controller.Config对象中的Process方法：func(obj interface{}),最终完成整个Controller框架的闭环过程。


## 12.1 Reflector ##
`pkg/client/cache/reflector.go`  
在Controller框架中构建了Reflector对象以实现资源对象的查询和监听逻辑，它的源码位于`pkg/client/cache/reflector.go`中。首先查看Reflector的数据结构，如下：
	
	// Reflector watches a specified resource and causes all changes to be reflected in the given store.
	type Reflector struct {
		// name identifies this reflector.  By default it will be a file:line if possible.
		name string
	
		// The type of object we expect to place in the store.
		expectedType reflect.Type
		// The destination to sync up with the watch source
		store Store
		// listerWatcher is used to perform lists and watches.
		listerWatcher ListerWatcher
		// period controls timing between one watch ending and
		// the beginning of the next one.
		period       time.Duration
		resyncPeriod time.Duration
		// now() returns current time - exposed for testing purposes
		now func() time.Time
		// lastSyncResourceVersion is the resource version token last
		// observed when doing a sync with the underlying store
		// it is thread safe, but not synchronized with the underlying store
		lastSyncResourceVersion string
		// lastSyncResourceVersionMutex guards read/write access to lastSyncResourceVersion
		lastSyncResourceVersionMutex sync.RWMutex
	}

	// ListerWatcher is any object that knows how to perform an initial list and start a watch on a resource.
	type ListerWatcher interface {
		// List should return a list type object; the Items field will be extracted, and the
		// ResourceVersion field will be used to start the watch in the right place.
		List(options api.ListOptions) (runtime.Object, error)
		// Watch should begin a watch at the specified version.
		Watch(options api.ListOptions) (watch.Interface, error)
	}



Reflector结构体的各属性的含义详见注释，在此不一一介绍。其核心思路是通过listerWatcher去获取资源列表并监听资源的变化，然后存储到store中。**下面详细分析Reflector的这一过程是如何实现的？**

**1、新建`Reflector`,代码如下：**

	func NewReflector(lw ListerWatcher, expectedType interface{}, store Store, resyncPeriod time.Duration) *Reflector {
		return NewNamedReflector(getDefaultReflectorName(internalPackages...), lw, expectedType, store, resyncPeriod)
	}
	
	// NewNamedReflector same as NewReflector, but with a specified name for logging
	func NewNamedReflector(name string, lw ListerWatcher, expectedType interface{}, store Store, resyncPeriod time.Duration) *Reflector {
		r := &Reflector{
			name:          name,
			listerWatcher: lw,
			store:         store,
			expectedType:  reflect.TypeOf(expectedType),
			period:        time.Second,
			resyncPeriod:  resyncPeriod,
			now:           time.Now,
		}
		return r
	}

 NewReflector creates a new Reflector object which will keep the given `store` up to date with the server's contents for the given resource. Reflector promises to only put things in the store that have the type of expectedType, unless expectedType is nil. If resyncPeriod is non-zero, then lists will be executed after every esyncPeriod, so that you can use reflectors to periodically process everything as well as incrementally processing the things that change.

**2、运行Reflector**  

运行Reflector的方法为`func (r *Reflector) Run() `或者`func (r *Reflector) RunUntil(stopCh <-chan struct{}) `,下面以`RunUntil（）`方法为例，简单介绍该函数，代码如下：

	func (r *Reflector) RunUntil(stopCh <-chan struct{}) {
		glog.V(3).Infof("Starting reflector %v (%s) from %s", r.expectedType, r.resyncPeriod, r.name)
		go wait.Until(func() {
			if err := r.ListAndWatch(stopCh); err != nil {
				utilruntime.HandleError(err)
			}
		}, r.period, stopCh)
	}


`Run()` 和`RunUntil()`方法类似，其功能描述如下：
Run/RunUntil starts a watch and handles watch events. Will restart the watch if it is closed. Run/RunUntil starts a goroutine and returns immediately. 
区别在于：`Run()`方法不会退出，`RunUntil()`方法会在通道chan关闭后退出。

由`RunUntil()`方法代码可以看出，其首先调用`wait.Until()`方法周期性地执行函数`f()`,在`f()`通过调用Reflector方法`Reflector.ListAndWatch(stopCh)`实现对资源的周期性ListAndWatch。

**3. Reflector.ListAndWatch() 如何实现获取资源列表并监听资源的变化**


	func (r *Reflector) ListAndWatch(stopCh <-chan struct{}) error {
		...
		options := api.ListOptions{ResourceVersion: "0"}
		list, err := r.listerWatcher.List(options)
		...
		resourceVersion = listMetaInterface.GetResourceVersion()
		...
		r.setLastSyncResourceVersion(resourceVersion)
	
		...
	
		for {
			timemoutseconds := int64(minWatchTimeout.Seconds() * (rand.Float64() + 1.0))
			options = api.ListOptions{
				ResourceVersion: resourceVersion,
				// We want to avoid situations of hanging watchers. Stop any wachers that do not
				// receive any events within the timeout window.
				TimeoutSeconds: &timemoutseconds,
			}
	
			w, err := r.listerWatcher.Watch(options)
			if err != nil {
				switch err {
				case io.EOF:
					// watch closed normally
				case io.ErrUnexpectedEOF:
					glog.V(1).Infof("%s: Watch for %v closed with unexpected EOF: %v", r.name, r.expectedType, err)
				default:
					utilruntime.HandleError(fmt.Errorf("%s: Failed to watch %v: %v", r.name, r.expectedType, err))
				}
				
				...
	
			if err := r.watchHandler(w, &resourceVersion, resyncerrc, stopCh); err != nil {
				if err != errorStopRequested {
					glog.Warningf("%s: watch of %v ended with: %v", r.name, r.expectedType, err)
				}
				return nil
			}
		}
	}


由此可以看出ListAndWatch first lists all items and get the resource version at the moment of call, and then use the resource version to watch. It returns error if ListAndWatch didn't even try to initialize watch.最后，ListAndWatch（）方法会调用Reflector的 `watchHandler(w watch.Interface, resourceVersion *string, ..., stopCh <-chan struct{})`方法实现资源的更新。
 

**4、 func (r \*Reflector) watchHandler()**


	// watchHandler watches w and keeps *resourceVersion up to date.
	func (r *Reflector) watchHandler(w watch.Interface, resourceVersion *string, errc chan error, stopCh <-chan struct{}) error {
		...
	
	loop:
		for {
			select {
			case <-stopCh:
				return errorStopRequested
			case err := <-errc:
				return err
			case event, ok := <-w.ResultChan():
				...
				newResourceVersion := meta.GetResourceVersion()
				switch event.Type {
				case watch.Added:
					r.store.Add(event.Object)
				case watch.Modified:
					r.store.Update(event.Object)
				case watch.Deleted:
					// TODO: Will any consumers need access to the "last known
					// state", which is passed in event.Object? If so, may need
					// to change this.
					r.store.Delete(event.Object)
				default:
					utilruntime.HandleError(fmt.Errorf("%s: unable to understand watch event %#v", r.name, event))
				}
				*resourceVersion = newResourceVersion
				r.setLastSyncResourceVersion(newResourceVersion)
				eventCount++
			}
		}
	
		...
	}
	
由此可以看出，watchHandler()根据对应的event执行对应的操作如Add,Modified,Delete，以保持Store更新。A generic store is provided, which allows Reflector to be used as a local caching system, and an LRU store, which allows Reflector to work like a queue of items yet to be processed.换言之，Reflector实现了本地缓存和APIServer数据的同步更新。


## 12.2 Informer ##
以ReplcationManager调用的Informer为例，自上而下阅读代码。

**1、PodInformer**  

	//pkg/controller/replication/replication_controller.go
	podInformer := informers.NewPodInformer(kubeClient, resyncPeriod())

可以看出ReplicationController调用`pkg/controller/framework/informers/factory.go`文件中的NewPodInformer（）函数生成一个podInformer实例。	
	
	func NewPodInformer(client clientset.Interface, resyncPeriod time.Duration) framework.SharedIndexInformer {
		sharedIndexInformer := framework.NewSharedIndexInformer(
			&cache.ListWatch{
				ListFunc: func(options api.ListOptions) (runtime.Object, error) {
					return client.Core().Pods(api.NamespaceAll).List(options)
				},
				WatchFunc: func(options api.ListOptions) (watch.Interface, error) {
					return client.Core().Pods(api.NamespaceAll).Watch(options)
				},
			},
			&api.Pod{},
			resyncPeriod,
			cache.Indexers{cache.NamespaceIndex: cache.MetaNamespaceIndexFunc},
		)
	
		return sharedIndexInformer
	}

 NewPodInformer通过调用`framework.NewSharedIndexInformer()`方法获取一个`SharedIndexInformer`实例用于获取所有pods的资源列表并监听资源的变化，i.e. lists and watches all pods。 `framework.NewSharedIndexInformer()`代码如下：

	// NewSharedIndexInformer creates a new instance for the listwatcher.
	func NewSharedIndexInformer(lw cache.ListerWatcher, objType runtime.Object, resyncPeriod time.Duration, indexers cache.Indexers) SharedIndexInformer {
		sharedIndexInformer := &sharedIndexInformer{
			processor:        &sharedProcessor{},
			indexer:          cache.NewIndexer(DeletionHandlingMetaNamespaceKeyFunc, indexers),
			listerWatcher:    lw,
			objectType:       objType,
			fullResyncPeriod: resyncPeriod,
		}
		return sharedIndexInformer
	}

回到ReplicationManager可以看到podController和podStore均可以通过podInformer的方法获取，代码如下：

	// pkg/controller/replication/replication_controller.go, newReplicationManager()函数
	rm.podStore.Indexer = podInformer.GetIndexer()
	rm.podController = podInformer.GetController()


顺便看一下`sharedIndexInformer。Run()`方法：

	func (s *sharedIndexInformer) Run(stopCh <-chan struct{}) {
		defer utilruntime.HandleCrash()
	
		fifo := cache.NewDeltaFIFO(cache.MetaNamespaceKeyFunc, nil, s.indexer)
	
		//配置控制器
		cfg := &Config{
			Queue:            fifo,
			ListerWatcher:    s.listerWatcher,
			ObjectType:       s.objectType,
			FullResyncPeriod: s.fullResyncPeriod,
			RetryOnError:     false,
	
			Process: s.HandleDeltas,
		} 
	
		func() {
			s.startedLock.Lock()
			defer s.startedLock.Unlock()
			//新建一个控制器并标志为启动
			s.controller = New(cfg)
			s.started = true
		}()
	
		s.stopCh = stopCh
		s.processor.run(stopCh)
		s.controller.Run(stopCh)//启动控制器
	}
不难发现，其启动过程包括配置控制器，新建一个控制器，启动控制器等。

**2. rcController()**

ReplcationManager（）中的rcController实例的生成代码如下：

	// pkg/controller/replication/replication_controller.go, newReplicationManager()函数
	rm.rcStore.Indexer, rm.rcController = framework.NewIndexerInformer(
			&cache.ListWatch{
				ListFunc: func(options api.ListOptions) (runtime.Object, error) {
					return rm.kubeClient.Core().ReplicationControllers(api.NamespaceAll).List(options)
				},
				WatchFunc: func(options api.ListOptions) (watch.Interface, error) {
					return rm.kubeClient.Core().ReplicationControllers(api.NamespaceAll).Watch(options)
				},
			},
			&api.ReplicationController{},
			// TODO: Can we have much longer period here?
			FullControllerResyncPeriod,
			framework.ResourceEventHandlerFuncs{
				AddFunc:    rm.enqueueController,
				UpdateFunc: rm.updateRC,
				// This will enter the sync loop and no-op, because the controller has been deleted from the store.
				// Note that deleting a controller immediately after scaling it to 0 will not work. The recommended
				// way of achieving this is by performing a `stop` operation on the controller.
				DeleteFunc: rm.enqueueController,
			},
			cache.Indexers{cache.NamespaceIndex: cache.MetaNamespaceIndexFunc},
		)

可知其调用framework.NewIndexerInformer（）方法创建用于RC同步的framework.Controller（rcController）及同步缓存rcStore的Index。  
下面是framework.NewIndexerInformer()方法的源码：

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

		cfg := &Config{
		Queue:            fifo,
		ListerWatcher:    lw,
		...
		}
		...
		return clientState, New(cfg)
	}

NewIndexerInformer returns a cache.Indexer and a controller for populating the index while also providing event notifications. You should only used the returned cache.Index for Get/List operations; Add/Modify/Deletes will cause the event notifications to be faulty.

NewIndexerInformer调用cache.NewIndexer（）方法生成一个cache.Indexer索引，调用controller.New()-`New(cfg)`方法根据配置生成一个控制器的实例。其配置中采用cache.DeltaFIFO队列（cache.NewDeltaFIFO）。


**NewIndexerInformer和sharedIndexInformer方法的区别是什么？**

一个是私有informer，一个是公有共享的informer？PodController采用的是共享的informer，podController与其它控制器如rcController,endpointsController等共享pods资源的监听和变化，而rcController监听到的rc变化只有ReplicationController自己知道。从而rcController实现各个rcs之间的同步，而其通过podController的共享Informer监听pods资源变化，从而根据对应的event实现不同的操作？？

SharedInformerFactory结构体如下所示：

	// SharedInformerFactory provides interface which holds unique informers for pods, nodes, namespaces, persistent volume
	// claims and persistent volumes
	type SharedInformerFactory interface {
		// Start starts informers that can start AFTER the API server and controllers have started
		Start(stopCh <-chan struct{})
	
		Pods() PodInformer
		Nodes() NodeInformer
		Namespaces() NamespaceInformer
		PersistentVolumeClaims() PVCInformer
		PersistentVolumes() PVInformer
	}
	
	type sharedInformerFactory struct {
		client        clientset.Interface
		lock          sync.Mutex
		defaultResync time.Duration
	
		informers map[reflect.Type]framework.SharedIndexInformer
		// startedInformers is used for tracking which informers have been started
		// this allows calling of Start method multiple times
		startedInformers map[reflect.Type]bool
	}

由此可推断K8S将所有的共享Informer集合（可共享的资源Informer有Pods，Nodes，Namespaces，PersistentVolumeClaims，PersistentVolumes等）在一起封装了一个更高层次的`SharedInformerFactory`结构体，其相关的方法和函数放在`pkg/controller/framework/informers/factory.go`文件中。而对应的特殊实例 unique informers 如pods, nodes, namespaces等的对应Informer在文件`pkg/controller/framework/informers/core.go`中，实现了诸如podInformer，namespaceInformer等结构体的方法和接口等。

## 12.3 Event Broadcaster ##
Broadcaster distributes event notifications among any number of watchers. Every event is delivered to every watcher. 本部分仍然以ReplicationManager为例，介绍Event Broadcaster。在NewReplicationManager（）方法中第一步新建Broadcaster，代码如下：

	// pkg/controller/replication/replication_controller.go
	func NewReplicationManager(...) *ReplicationManager {
		eventBroadcaster := record.NewBroadcaster()
		...

函数`NewReplicationManager()`调用record.NewBroadcaster()函数新建一个Broadcaster。

	// Creates a new event broadcaster.
	func NewBroadcaster() EventBroadcaster {
		return &eventBroadcasterImpl{watch.NewBroadcaster(maxQueuedEvents, watch.DropIfChannelFull), defaultSleepDuration}
	}

可以看出NewBroadcaster()函数实现了一个eventBroadcasterImpl实例，对应的结构体如下：

	type eventBroadcasterImpl struct {
		*watch.Broadcaster
		sleepDuration time.Duration
	}

	type Broadcaster struct {
		// TODO: see if this lock is needed now that new watchers go through
		// the incoming channel.
		lock sync.Mutex
	
		watchers     map[int64]*broadcasterWatcher
		nextWatcher  int64
		distributing sync.WaitGroup
	
		incoming chan Event
	
		// How large to make watcher's channel.
		watchQueueLength int
		// If one of the watch channels is full, don't wait for it to become empty.
		// Instead just deliver it to the watchers that do have space in their
		// channels and move on to the next event.
		// It's more fair to do this on a per-watcher basis than to do it on the
		// "incoming" channel, which would allow one slow watcher to prevent all
		// other watchers from getting new events.
		fullChannelBehavior FullChannelBehavior
	}


在此着重区别三个概念：

- **EventSink** knows how to store events (client.Client implements it.) EventSink must respect the namespace that will be embedded in 'event'. It is assumed that EventSink will return the same sorts of errors as pkg/client's REST client.EventSink和APIServer交互。

		type EventSink interface {
			Create(event *api.Event) (*api.Event, error)
			Update(event *api.Event) (*api.Event, error)
			Patch(oldEvent *api.Event, data []byte) (*api.Event, error)
		}
- **EventRecorder** knows how to record events on behalf of an EventSource.EventRecorder是一个event的记录接口，包含event的一些详细信息。

		type EventRecorder interface {
			// The resulting event will be created in the same namespace as the reference object.
			Event(object runtime.Object, eventtype, reason, message string)
		
			// Eventf is just like Event, but with Sprintf for the message field.
			Eventf(object runtime.Object, eventtype, reason, messageFmt string, args ...interface{})
		
			// PastEventf is just like Eventf, but with an option to specify the event's 'timestamp' field.
			PastEventf(object runtime.Object, timestamp unversioned.Time, eventtype, reason, messageFmt string, args ...interface{})
		}
-  **EventBroadcaster** knows how to receive events and send them to any EventSink, watcher, or log.  

		type EventBroadcaster interface {
			// StartEventWatcher starts sending events received from this EventBroadcaster to the given
			// event handler function. The return value can be ignored or used to stop recording, if
			// desired.
			StartEventWatcher(eventHandler func(*api.Event)) watch.Interface
		
			// StartRecordingToSink starts sending events received from this EventBroadcaster to the given
			// sink. The return value can be ignored or used to stop recording, if desired.
			StartRecordingToSink(sink EventSink) watch.Interface
		
			// StartLogging starts sending events received from this EventBroadcaster to the given logging
			// function. The return value can be ignored or used to stop recording, if desired.
			StartLogging(logf func(format string, args ...interface{})) watch.Interface
		
			// NewRecorder returns an EventRecorder that can be used to send events to this EventBroadcaster
			// with the event source set to the given event source.
			NewRecorder(source api.EventSource) EventRecorder
		}


**问题：Broadcast如何实现将每一个event通知给每一个watcher??**   
通过StartRecordingToSink告知APIserver，然后上层可通过ListWatch监听到event??

## 12.4 Controller Framework ##

从以上分析可知，控制器可以选择在`pkg/controller/framework/shared_informer.go`和`pkg/controller/framework/controller.go`文件中配置和启动。

**1. controller.go**

`controller.go`中的相关源码如下：

	// Controller is a generic controller framework.
	type Controller struct {
		config         Config
		reflector      *cache.Reflector
		reflectorMutex sync.RWMutex
	}
	
	// TODO make the "Controller" private, and convert all references to use ControllerInterface instead
	type ControllerInterface interface {
		Run(stopCh <-chan struct{})
		HasSynced() bool
	}
可以看出，K8S旨在通过`controller.go`中的`NewInformer()`根据控制器配置函数新建一个私有的控制器，调用run函数启动。run函数的代码如下：

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

Run begins processing items, and will continue until a value is sent down stopCh. It's an error to call Run more than once. Run blocks; call via go. Controller调用Controller.processLoop（）方法,其源码如下：

	func (c *Controller) processLoop() {
		for {
			obj, err := c.config.Queue.Pop(cache.PopProcessFunc(c.config.Process))
			if err != nil {
				if c.config.RetryOnError {
					// This is the safe way to re-enqueue.
					c.config.Queue.AddIfNotPresent(obj)
				}
			}
		}
	}

Controller从队列Queue中拉取资源对象并且交给Controller.Config对象中的ProcessFunc方法func(obj interface{}处理。


**2. shared_informer.go**

shared_informer可理解为公有的控制器，详见12.3节第2部分rcController描述，在此简要介绍，不再赘述。下面简要看一下`sharedIndexInformer`的Run函数,代码如下：

	func (s *sharedIndexInformer) Run(stopCh <-chan struct{}) {
		defer utilruntime.HandleCrash()
	
		...
	
		func() {
			s.startedLock.Lock()
			defer s.startedLock.Unlock()
	
			s.controller = New(cfg)
			s.started = true
		}()
	
		s.stopCh = stopCh
		s.processor.run(stopCh)
		s.controller.Run(stopCh)
	}

`s.controller.Run(stopCh)`即为启动控制器，那么`s.processor.run(stopCh)`是做什么工作呢？

首选看一下s.process的属性为：`processor *sharedProcessor`，相应的结构体源码如下：

	type sharedProcessor struct {
		listeners []*processorListener
	}

	type processorListener struct {
	// lock/cond protects access to 'pendingNotifications'.
	lock sync.RWMutex
	cond sync.Cond

	// pendingNotifications is an unbounded slice that holds all notifications not yet distributed
	// there is one per listener, but a failing/stalled listener will have infinite pendingNotifications

	// added until we OOM.
	pendingNotifications []interface{}

	nextCh chan interface{}

	handler ResourceEventHandler
}

`sharedProcessor.run()`方法源码如下：
	
	func (p *processorListener) run(stopCh <-chan struct{}) {
		defer utilruntime.HandleCrash()
	
		for {
			var next interface{}
			select {
			case <-stopCh:
				func() {
					p.lock.Lock()
					defer p.lock.Unlock()
					p.cond.Broadcast()
				}()
				return
			case next = <-p.nextCh:
			}
	
			switch notification := next.(type) {
			case updateNotification:
				p.handler.OnUpdate(notification.oldObj, notification.newObj)
			case addNotification:
				p.handler.OnAdd(notification.newObj)
			case deleteNotification:
				p.handler.OnDelete(notification.oldObj)
			default:
				utilruntime.HandleError(fmt.Errorf("unrecognized notification: %#v", next))
			}
		}
	}

由此可看出run函数根据不同的event消息调用相应的ResourceEventHandler接口处理。

	type ResourceEventHandler interface {
		OnAdd(obj interface{})
		OnUpdate(oldObj, newObj interface{})
		OnDelete(obj interface{})
	}

 ResourceEventHandler can handle notifications for events that happen to a resource.  The events are informational only, so you can't return an error.

 - **OnAdd** is called when an object is added.
 - **OnUpdate** is called when an object is modified. Note that oldObj is the last known state of the object-- it is possible that several changes were combined together, so you can't use this to see every single change. OnUpdate is also called when a re-list happens, and it will
   get called even if nothing changed. This is useful for periodically
     evaluating or syncing something.
- **OnDelete** will get the final state of the item if it is known, otherwise
      it will get an object of type cache.DeletedFinalStateUnknown. This can happen if the watch is closed and misses the delete event and we don't notice the deletion until the subsequent re-list.