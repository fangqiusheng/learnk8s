# 9. Kube-apiserver-APISummary#
[https://github.com/kubernetes/kubernetes/blob/956501b1f0923786c404c062d8ba001a10b3a784/docs/devel/api-conventions.md#types-kinds](https://github.com/kubernetes/kubernetes/blob/956501b1f0923786c404c062d8ba001a10b3a784/docs/devel/api-conventions.md#types-kinds)
## 9.1 Kubernetes API概述 ##

### 9.1.1 API 综述 ###
Kubernetes API是集群系统中的重要组成部分，Kubernetes中各种资源（对象）的数据通过该API接口被提交到后端的持久化存储（etcd）中，Kubernetes集群中的各部件之间通过该API接口实现解耦合，同时Kubernetes集群中一个重要且便捷的管理工具kubectl也是通过访问该API接口实现其强大的管理功能的。Kubernetes API中的资源对象都拥有通用的元数据，资源对象也可能存在嵌套现象，比如在一个Pod里面嵌套多个Container。创建一个API对象是指通过API调用创建一条有意义的记录，该记录一旦被创建，Kubernetes将确保对应的资源对象会被自动创建并托管维护。

在Kubernetes系统中，大多数情况下，API定义和实现都符合标准的HTTP REST格式， 比如通过标准的HTTP动词（POST、PUT、GET、DELETE）来完成对相关资源对象的查询、创建、修改、删除等操作。但同时Kubernetes 也为某些非标准的REST行为实现了附加的API接口，例如Watch某个资源的变化、进入容器执行某个操作等。另外，某些API接口可能违背严格的REST模式，因为接口不是返回单一的JSON对象，而是返回其他类型的数据，比如JSON对象流（Stream）或非结构化的文本日志数据等。

Kubernetes开发人员认为，任何成功的系统都会经历一个不断成长和不断适应各种变更的过程。因此，他们期望Kubernetes API是不断变更和增长的。同时，他们在设计和开发时，有意识地兼容了已存在的客户需求。通常，新的API资源（Resource）和新的资源域不希望被频繁地加入系统。资源或域的删除需要一个严格的审核流程。

为了方便查阅API接口的详细定义，Kubernetes使用了swagger-ui提供API在线查询功能，其官网为[http://kubernetes.io/third_party/swagger-ui/](http://kubernetes.io/third_party/swagger-ui/)，Kubernetes开发团队会定期更新、生成UI及文档。Swagger UI是一款REST API文档在线自动生成和功能测试软件，关于Swagger的内容请访问官网[http://swagger.io](http://swagger.io)。

运行在Master节点上的API Server进程同时提供了swagger-ui的访问地址：http://master:/swagger-ui/。假设我们的API Server安装在192.168.1.128服务器上，绑定了8080端口，则可以通过访问[http://192.168.1.128:8080/swagger-ui/](http://192.168.1.128:8080/swagger-ui/)来查看API信息，如图9-1所示。

![](imgs/kube-apiserver-APISwaggerUI-1.png)  
图9-1 swagger-ui

单击api/v1可以查看所有API的列表，如图9-2所示。

![](imgs/kube-apiserver-APISwaggerUI-2.png)
图9-2 查看API列表

以create a Pod为例，找到Rest API的访问路径为：/api/v1/namespaces/{namespace}/pods，如图9-3所示。

![](imgs/kube-apiserver-APISwaggerUI-3.png)
图9-3 create a Pod API详细说明

单击Model链接，则可以查看文本格式显示的API接口描述，如图9-4所示。

![](imgs/kube-apiserver-APISwaggerUI-4.png)

图9-3 create a Pod API 文本详细说明

### 9.1.2 API 结构简介 ###
我们看到，在Kubernetes API中，一个API的顶层（Top Level）元素由**kind、apiVersion、metadata、spec和status**等几个部分组成，接下来，我们分别对这几个部分进行说明。


The following terms are defined:

- **Kind** the name of a particular object schema (e.g. the "Cat" and "Dog" kinds would have different attributes and properties)
- **Resource** a representation of a system entity, sent or retrieved as JSON via HTTP to the server. - Resources are exposed via:
	- Collections - a list of resources of the same type, which may be queryable
	- Elements - an individual resource, addressable via a URL


 **kind**表明对象有以下三大类别。  

（1）对象（objects）：代表在系统中的一个永久资源（实体），例如Pod、RC、Service、Namespace及Node等。通过操作这些资源的属性，客户端可以对该对象做创建、修改、删除和获取操作。
  
（2）列表（list）：一个或多个资源类别的集合。列表有一个通用元数据的有限集合。所有列表（lists）通过“items”域获得对象数组。例如**PodLists、ServiceLists、NodeLists**。大部分定义在系统中的对象都有一个返回所有资源（resource）集合的端点，以及零到多个返回所有资源集合的子集的端点。某些对象有可能是单例对象（singletons），例如当前用户、系统默认用户等，这些对象没有列表。 除此之外，所有的列表在返回携带标签的对象时应该支持标签过滤（label filtering），并且大多数列表都应该支持基于field的过滤。  

（3）简单类别（simple）：该类别包含作用在对象上的特殊行为和非持久实体。该类别限制了使用范围，它有一个通用元数据的有限集合。例如，当错误发生时会返回“Status” Kind,其在系统中是非持久的实体。

Many simple resources are "subresources", which are rooted at API paths of specific resources. When resources wish to expose alternative actions or views that are closely coupled to a single resource, they should do so using new sub-resources. Common subresources include:

- `/binding`: Used to bind a resource representing a user request (e.g., Pod, PersistentVolumeClaim) to a cluster infrastructure resource (e.g., Node, PersistentVolume).
- `/status`: Used to write just the status portion of a resource. For example, the `/pods` endpoint only allows updates to `metadata` and `spec`, since those reflect end-user intent. An automated process should be able to modify status for users to see by sending an updated Pod kind to the server to the "/pods/<name>/status" endpoint - the alternate endpoint allows different rules to be applied to the update, and access to be appropriately restricted.
- `/scale`: Used to read and write the count of a resource in a manner that is independent of the specific resource schema.

Two additional subresources, `proxy` and `portforward`, provide access to cluster resources as described in [docs/user-guide/accessing-the-cluster.md](http://kubernetes.io/docs/user-guide/accessing-the-cluster/).

**Resources**,所有API返回的JSON对象必须包含以下域：

- `kind`:识别对象模式（schema）的字符串
- `apiVesion`:识别对象版本模式的字符串

这些域用于对象的解码(decoding)。Server可以默认地根据默认的特定URL路径定位对象，但是客户端需要知道这些域的值用于构建URL路径。


**apiVersion**表明API的版本号，当前版本默认只支持v1。

**Metadata**是资源对象的元数据定义，是集合类的元素类型，包含一组由不同名称定义的属性。在Kubernetes中每个资源对象都必须包含以下3种Metadata。

（1）`namespace`：对象所属的命名空间，如果不指定，系统则会将对象置于名为“default”的系统命名空间中。  
（2）`name`：对象的名字，在一个命名空间中名字应具备唯一性。  
（3）`uid`：系统为每个对象生成的唯一ID，符合RFC 4122规范的定义。  

此外，每种对象还应该包含以下几个重要元数据。

- `labels`：用户可定义的“标签”，键和值都为字符串的map，是对象进行组织和分类的一种手段，通常用于标签选择器（Label Selector），用来匹配目标对象。
- `annotations`：用户可定义的“注解”，键和值都为字符串的map，被Kubernetes内部进程或者某些外部工具使用，用于存储和获取关于该对象的特定元数据。
- `resourceVersion`：用于识别该资源内部版本号的字符串，在用于Watch操作时，可以避免在GET操作和下一次Watch操作之间造成的信息不一致，客户端可以用它来判断资源是否改变。该值应该被客户端看作不透明，且不做任何修改就返回给服务端。客户端不应该假定版本信息具有跨命名空间、跨不同资源类别、跨不同服务器的含义。
- `creationTimestamp`：系统记录创建对象时的时间戳，符合RFC 3339规范。
- `deletionTimestamp`：系统记录删除对象时的时间戳，符合RFC 3339规范。
- `selfLink`：通过API访问资源自身的URL，例如一个Pod的link可能是`/api/v1/namespaces/default/pods/frontend-o8bg4`。

**spec**是集合类的元素类型，用户对需要管理的对象进行详细描述的主体部分都在spec里给出，它会被Kubernetes持久化到etcd中保存，系统通过spec的描述来创建或更新对象，以达到用户期望的对象运行状态。spec的内容既包括用户提供的配置设置、默认值、属性的初始化值，也包括在对象创建过程中由其他相关组件（例如schedulers、auto-scalers）创建或修改的对象属性，比如Pod的Service IP地址。如果spec被删除，那么该对象将会从系统中被删除。

**Status**用于记录对象在系统中的当前状态信息，它也是集合类元素类型，status在一个自动处理的进程中被持久化，可以在流转的过程中生成。如果观察到一个资源丢失了它的状态（Status），则该丢失的状态可能被重新构造。以Pod为例，Pod的status信息主要包括conditions、containerStatuses、hostIP、phase、podIP、startTime等。其中比较重要的两个状态属性如下。

（1）phase：描述对象所处的生命周期阶段，phase的典型值是“Pending”（创建中）“Running”“Active”（正在运行中）或“Terminated”（已终结），这几种状态对于不同的对象可能有轻微的差别，此外，关于当前phase附加的详细说明可能包含在其他域中。

（2）condition：表示条件，由条件类型和状态值组成，目前仅有一种条件类型Ready，对应的状态值可以为True、False或Unknown。一个对象可以具备多种condition，而condition的状态值也可能不断发生变化，condition可能附带一些信息，例如最后的探测时间或最后的转变时间。



## 9.2 API版本 ##

为了在兼容旧版本的同时不断升级新的API，Kubernetes 提供了多版本API的支持能力，每个版本的API通过一个版本号路径前缀进行区分，例如/api/v1beta3。通常情况下，新旧几个不同的API版本都能涵盖所有的Kubernetes资源对象，在不同的版本之间这些API接口存在一些细微差别。Kubernetes开发团队基于API级别选择版本而不是基于资源和域级别，是为了确保API能够描述一个清晰的连续的系统资源和行为的视图，能够控制访问的整个过程和控制实验性API的访问。

API及版本发布建议描述了版本升级的当前思路。版本v1beta1、v1beta2和 v1beta3 为不建议使用（Deprecated）的版本，请尽快转到v1版本。在2015年6月4日，Kubernetes v1版本API正式发布。版本v1beta1和v1beta2 API在2015年6月1日被删除，版本v1beta3 API在2015年7月6日被删除。

## 9.3 API详细说明 ##

API 资源使用REST模式，具体说明如下。

- GET /<资源名的复数格式>：获得某一类型的资源列表，例如GET /pods 返回一个Pod资源列表。
- POST /<资源名的复数格式>：创建一个资源，该资源来自用户提供的JSON对象。
- GET /<资源名复数格式>/<名字>：通过给出的名称（Name）获得单个资源，例如GET /pods/first 返回一个名称为“first”的Pod。
- DELETE /<资源名复数格式>/<名字>：通过给出的名字删除单个资源，删除选项（DeleteOptions）中可以指定的优雅删除（Grace Deletion）的时间（GracePeriodSeconds），该可选项表明了从服务端接收到删除请求到资源被删除的时间间隔（单位为秒）。不同的类别（Kind）可能为优雅删除时间（Grace Period）申明默认值。用户提交的优雅删除时间将覆盖该默认值，包括值为0的优雅删除时间。
- PUT /<资源名复数格式>/<名字>：通过给出的资源名和客户端提供的JSON对象来更新或创建资源。
- PATCH /<资源名复数格式>/<名字>：选择修改资源详细指定的域。  
对于PATCH操作，目前Kubernetes API通过相应的HTTP首部“Content-Type”对其进行识别。
目前支持以下三种类型的PATCH操作。

(1)JSON Patch, Content-Type: application/json-patch+json。在RFC6902的定义中，JSON Patch是执行在资源对象上的一系列操作，例如 {＂op＂: ＂add＂, ＂path＂: ＂/a/b/c＂, ＂value＂: [ ＂foo＂, ＂bar＂ ]}。详情请查看RFC6902说明，网址为HTTPs://tools.ietf.org/html/rfc6902。  
(2)Merge Patch, Content-Type: application/merge-json-patch+json。在RFC7386的定义中，Merge Patch必须包含对一个资源对象的部分描述，这个资源对象的部分描述就是一个JSON对象。该JSON对象被提交到服务端，并和服务端的当前对象合并，从而创建一个新的对象。详情请查看RFC73862说明，网址为HTTPs://tools.ietf.org/html/rfc7386。
Strategic Merge Patch, Content-Type: application/strategic-merge-patch+json。
(3)Strategic Merge Patch是一个定制化的Merge Patch实现。接下来将详细讲解Strategic Merge Patch。
在标准的JSON Merge Patch中，JSON对象总是被合并（merge）的，但是资源对象中的列表域总是被替换的。通常这不是用户所希望的。例如，我们通过下列定义创建一个Pod资源对象：

	spec:
  	containers:
    	- name: nginx
    	  image: nginx-1.0
接着我们希望添加一个容器到这个Pod中，代码和上传的JSON对象如下所示：

	PATCH /api/v1/namespaces/default/pods/pod-name
	spec:
  	containers:
    	- name: log-tailer
    	  image: log-tailer-1.0
如果我们使用标准的Merge Patch，则其中的整个容器列表将被单个的“log-tailer”容器所替换。然而我们的目的是两个容器列表能够合并。

为了解决这个问题，Strategic Merge Patch通过添加元数据到API对象中，并通过这些新元数据来决定哪个列表被合并，哪个列表不被合并。当前这些元数据作为结构标签，对于API对象自身来说是合法的。对于客户端来说，这些元数据作为Swagger annotations也是合法的。在上述例子中，向“containers”中添加“patchStrategy”域，且它的值为“merge”，通过添加“patchMergeKey”，它的值为“name”。也就是说，“containers”中的列表将会被合并而不是替换，合并的依据为“name”域的值。

此外，Kubernetes API添加了资源变动的“观察者”模式的API接口。

- GET /watch/<资源名复数格式>：随时间变化，不断接收一连串的JSON对象，这些JSON对象记录了给定资源类别内所有资源对象的变化情况。
- GET /watch/<资源名复数格式>/：随时间变化，不断接收一连串的JSON对象，这些JSON对象记录了某个给定资源对象的变化情况。

上述接口改变了返回数据的基本类别，watch动词返回的是一连串的JSON对象，而不是单个的JSON对象。并不是所有的对象类别都支持“观察者”模式的API接口，在后续的章节中将会说明哪些资源对象支持这种接口。
                                                                                                                                                    
另外，Kubernetes还增加了HTTP Redirect与HTTP Proxy这两种特殊的API接口，前者实现资源重定向访问，后者则实现HTTP请求的代理。

## 9.4 API响应说明 ##

API Server响应用户请求时附带一个状态码，该状态码符合HTTP规范。图9-4列出了API Server可能返回的状态码。

![](imgs/kube-apiserver-APIHTTPStatusCode.png)


![](imgs/kube-apiserver-APIHTTPStatusCode2.png)

图9-4 API server可能返回的状态码

在调用API接口发生错误时，Kubernetes 将会返回一个状态类别（Status Kind）。下面是两种常见的错误场景：  
（1）当一个操作不成功时（例如，当服务端返回一个非2xx HTTP 状态码时）；  
（2）当一个HTTP DELETE方法调用失败时。  
状态对象被编码成JSON格式，同时该JSON对象被作为请求的响应体。该状态对象包含人和机器使用的域，这些域中包含来自API的关于失败原因的详细信息。状态对象中的信息补充了对HTTP状态码的说明。 例如：

	$ curl -v -k -H ＂Authorization: Bearer WhCDvq4VPpYhrcfmF6ei7V9qlbqTubUc＂ HTTPs://10.240.122.184:443/api/v1/namespaces/default/pods/grafana
	> GET /api/v1/namespaces/default/pods/grafana HTTP/1.1
	> User-Agent: curl/7.26.0
	> Host: 10.240.122.184
	> Accept: */*
	> Authorization: Bearer WhCDvq4VPpYhrcfmF6ei7V9qlbqTubUc
	> 
	< HTTP/1.1 404 Not Found
	< Content-Type: application/json
	< Date: Wed, 20 May 2015 18:10:42 GMT
	< Content-Length: 232
	< 
	{
	  ＂kind＂: ＂Status＂,
	  ＂apiVersion＂: ＂v1＂,
	  ＂metadata＂: {},
	  ＂status＂: ＂Failure＂,
	  ＂message＂: ＂pods \＂grafana\＂ not found＂,
	  ＂reason＂: ＂NotFound＂,
	  ＂details＂: {
	    ＂name＂: ＂grafana＂,
		    ＂kind＂: ＂pods＂
	  },
	  ＂code＂: 404
	}

- “status”域包含两个可能的值：Success和Failure。  
- “message”域包含对错误的可读描述。
- “reason”域包含说明该操作失败原因的可读描述。如果该域的值为空，则表示该域内没有任何说明信息。“reason”域澄清HTTP状态码，但没有覆盖该状态码。

“details”可能包含和“reason”域相关的扩展数据。每个“reason”域可以定义它的扩展的“details”域。该域是可选的，返回数据的格式是不确定的，不同的reason类型返回的“details”域的内容不一样。