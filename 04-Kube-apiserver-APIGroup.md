# 4. Kube-apiserver--APIGroup #
## 4.1 Adding APIs to Kubernetes##

Every API that is added to Kubernetes carries with it increased cost and complexity for all parts of the Kubernetes ecosystem. New APIs imply new code to maintain, new tests that may flake, new documentation that users are required to understand, increased cognitive load for kubectl users and many other incremental costs.

Of course, the addition of new APIs also enables new functionality that empowers users to simply do things that may have been previously complex, costly or both.

Given this **balance between increasing the complexity of the project versus the reduction of complexity in user actions**, we have set out to set up a set of **criteria to guide how we as a development community decide when an API should be added to the set of core Kubernetes APIs.**

The criteria for inclusion are as follows:

- Within the Kubernetes ecosystem, there is a single well known definition of such an API.
- The API object is expected to be generally useful to greater than 50% of the Kubernetes users.
- There is general consensus in the Kubernetes community that the API object is in the "Kubernetes layer".

Of course for every set of rules, we need to ensure that we are not hamstrung or limited by slavish devotion to those rules. Thus we also introduce two exceptions for adding APIs in Kubernetes that violate these criteria.

These exceptions are:

- There is no other way to implement the functionality in Kubernetes. 
- Exceptional circumstances, as judged by the Kubernetes committers and discussed in community meeting prior to inclusion of the API.


## 4.2 API changes ##

In our experience, any system that is successful needs to grow and change as new use cases emerge or existing ones change. Therefore, **we expect the Kubernetes API to continuously change and grow. However, we intend to not break compatibility with existing clients, for an extended period of time.**In general, new API resources and new resource fields can be expected to be added frequently. Elimination of resources or fields will require following a deprecation process. The precise deprecation policy for eliminating features is TBD, but once we reach our 1.0 milestone, there will be a specific policy.

### 4.2.1 API versioning ###
To make it easier to eliminate fields or restructure resource representations, Kubernetes supports multiple API versions, each at a different API path, such as `/api/v1` or `/apis/extensions/v1beta1`.

We chose to version at the API level rather than at the resource or field level to ensure that the API presents a clear, consistent view of system resources and behavior, and to enable controlling access to end-of-lifed and/or experimental APIs.

Note that API versioning and Software versioning are only indirectly related. The API and release versioning proposal describes the relationship between API versioning and software versioning.

Different API versions imply different levels of stability and support. The criteria for each level are described in more detail in the API Changes documentation. They are summarized here:

- Alpha level:
	- The version names contain alpha (e.g. v1alpha1).
	- May be buggy. Enabling the feature may expose bugs. Disabled by default.
	- Support for feature may be dropped at any time without notice.
	- The API may change in incompatible ways in a later software release without notice.
	- Recommended for use only in short-lived testing clusters, due to increased risk of bugs and lack of long-term support.	
- Beta level:
	- The version names contain beta (e.g. v2beta3).
	- Code is well tested. Enabling the feature is considered safe. Enabled by default.
	- Support for the overall feature will not be dropped, though details may change.
	- The schema and/or semantics of objects may change in incompatible ways in a subsequent beta or stable release. When this happens, we will provide instructions for migrating to the next version. This may require deleting, editing, and re-creating API objects. The editing process may require some thought. This may require downtime for applications that rely on the feature.
	- Recommended for only non-business-critical uses because of potential for incompatible changes in subsequent releases. If you have multiple clusters which can be upgraded independently, you may be able to relax this restriction.
	- **Please do try our beta features and give feedback on them! Once they exit beta, it may not be practical for us to make more changes.**
- Stable level:
	- The version name is vX where X is an integer.
	- Stable versions of features will appear in released software for many subsequent versions.

### 4.2.2 API groups ###
To make it easier to extend the Kubernetes API, we are in the process of implementing API groups. These are simply different interfaces to read and/or modify the same underlying resources. The API group is specified in a REST path and in the `apiVersion` field of a serialized object.
Currently there are two API groups in use:

- the "core" group, which is at REST path `/api/v1` and is not specified as part of the apiVersion field, e.g. apiVersion: v1.
- the "extensions" group, which is at REST path `/apis/extensions/$VERSION`, and which uses apiVersion: `extensions/$VERSION` (e.g. currently apiVersion: `extensions/v1beta1`). This holds types which will probably move to another API group eventually.
- the "componentconfig" and "metrics" API groups.

In the future we expect that there will be more API groups, all at REST path `/apis/$API_GROUP` and using `apiVersion: $API_GROUP/$VERSION`. We expect that there will be a way for third parties to create their own API groups, and to avoid naming collisions.

## 4.3 APIGroup多版本API REST服务##
###  4.3.1 APIGroup注册源码解析###
- api注册入口

		kubernetes/pkg/master/master.go

- 根据Config往APIGroupsInfo内增加组信息(然后通过InstallAPIGroups进行注册)
	
		func New(c *Config) (*Master, error) { m.InstallAPIs(c)
				}
- 转换为APIGroupVersion这个关键数据结构(然后进行注册)

		func (m *Master) InstallAPIs(c *Config) { if err := m.InstallAPIGroups(apiGroupsInfo); err != nil {
		glog.Fatalf(&quot;Error in registering group versions: %v&quot;, err)
		}
		}
- 通过InstallAPIGroups进行注册

		func (s *GenericAPIServer) installAPIGroup(apiGroupInfo *APIGroupInfo) error {
    		apiGroupVersion, err := s.getAPIGroupVersion(apiGroupInfo, groupVersion, apiPrefix)

    		if err := apiGroupVersion.InstallREST(s.HandlerContainer); err != nil {
        		return fmt.Errorf("Unable to setup API %v: %v", apiGroupInfo, err)
    		}
		}       

- 关键数据结构

		kubernetes/pkg/apiserver/apiserver.go

		type APIGroupVersion struct {
		Storage map[string]rest.Storage
		...
		...
		Serializer     runtime.NegotiatedSerializer
		ParameterCodec runtime.ParameterCodec

		Typer     runtime.ObjectTyper
		Creater   runtime.ObjectCreater
		Convertor runtime.ObjectConvertor
		Copier    runtime.ObjectCopier
		Linker    runtime.SelfLinker


		Root string

		// GroupVersion is the external group version
		GroupVersion unversioned.GroupVersion
		}

APIGroupVersion是与rest.Storage map捆绑的，并且绑定了相应版本的Codec、Converter用于版本转换。
这样Kubernetes就很容易区分多版本的API和Rest服务。

- 首先，用API的version变量构造WebService的Path前缀（不同版本的方式不同）

		/ NewWebService creates a new restful webservice with the api installer's prefix and version.
			func (a *APIInstaller) NewWebService() *restful.WebService {
			ws := new(restful.WebService)
			ws.Path(a.prefix)
			// a.prefix contains "prefix/group/version"
			ws.Doc("API at " + a.prefix)
			// Backwards compatibility, we accepted objects with empty content-type at V1.
			// If we stop using go-restful, we can default empty content-type to application/json on an
			// endpoint by endpoint basis
			ws.Consumes("*/*")
			ws.Produces(a.group.Serializer.SupportedMediaTypes()...)
			ws.ApiVersion(a.group.GroupVersion.String())
			
			return ws
		}
- 在master.go中根据Config通过InstallAPIs（）注册API时，通过VersionedResourcesStorageMap: map[string]map[string]rest.Storage区分不同的API版本。

		func New(c *Config) (*Master, error) {
		m.InstallAPIs(c)
		}

		//add APIGroupInfo based on the `config`
		func (m *Master) InstallAPIs(c *Config) {
			apiGroupsInfo := []genericapiserver.APIGroupInfo{}

			// Install v1 unless disabled.
			if c.APIResourceConfigSource.AnyResourcesForVersionEnabled(apiv1.SchemeGroupVersion) {
				// Install v1 API.
				m.initV1ResourcesStorage(c)
				apiGroupInfo := genericapiserver.APIGroupInfo{
					GroupMeta: *registered.GroupOrDie(api.GroupName),
					VersionedResourcesStorageMap: map[string]map[string]rest.Storage{
						"v1": m.v1ResourcesStorage,
					},
				}


### 4.3.2 APIGroup restful服务的实现 ###

那么，这里的map[string]rest.Storage最后是怎么变成一个具体的API来提供服务的呢？例如这么一个URL:
	
	GET /api/v1/namespaces/{namespace}/pods/{name}


k8s使用的一个第三方库github.com/emicklei/go-restful，里面提供了一组核心的对象，看例子

| 数据结构 | 功能 | 在k8s内的位置 |
| ------------------ | ---------------------------------------- | ---------------------------------------- |
| restful.Container | 代表一个http rest服务对象，包括一组restful.WebService | genericapiserver.go - GenericAPIServer.HandlerContainer |
| restful.WebService | 由多个restful.Route组成，处理这些路径下所有的特殊的MIME类型等 | api_installer.go - NewWebService() |
| restful.Route | 路径——处理函数映射map | api_installer.go - registerResourceHandlers() |

- 实际注册的Storage的map如下：

		kubernetes/pkg/master/master.go

		m.v1ResourcesStorage = map[string]rest.Storage{
    		"pods":             podStorage.Pod,
    		"pods/attach":      podStorage.Attach,
    		"pods/status":      podStorage.Status,
    		"pods/log":         podStorage.Log,
    		"pods/exec":        podStorage.Exec,
    		"pods/portforward": podStorage.PortForward,
    		"pods/proxy":       podStorage.Proxy,
    		"pods/binding":     podStorage.Binding,
    		"bindings":         podStorage.Binding,

- 实际注册过程

		kubernetes/pkg/apiserver/api_installer.go

		func (a *APIInstaller) registerResourceHandlers(path string, storage rest.Storage, ws
		 *restful.WebService, proxyHandler http.Handler) (*unversioned.APIResource, error) { }

最终的API注册过程是在这个函数中完成的，把一个path对应的rest.Storage对象转换为实际的restful.Route（getter, lister等处理函数）并添加到指针restful.WebService中，并和实际的url关联起来。

	switch action.Verb {
		case "GET": // Get a resource.
			var handler restful.RouteFunction
			if isGetterWithOptions {
				handler = GetResourceWithOptions(getterWithOptions, reqScope)
			} else {
				handler = GetResource(getter, exporter, reqScope)
			}
			handler = metrics.InstrumentRouteFunc(action.Verb, resource, handler)
			doc := "read the specified " + kind
			if hasSubresource {
				doc = "read " + subresource + " of the specified " + kind
			}
			route := ws.GET(action.Path).To(handler).
				Doc(doc).
				Param(ws.QueryParameter("pretty", "If 'true', then the output is pretty printed.")). 
				Operation("read"+namespaced+kind+strings.Title(subresource)). 
				Produces(append(storageMeta.ProducesMIMETypes(action.Verb),   a.group.Serializer.SupportedMediaTypes()...)...).  
				Returns(http.StatusOK, "OK", versionedObject).
				Writes(versionedObject)
			...
			addParams(route, action.Params)
			ws.Route(route)

