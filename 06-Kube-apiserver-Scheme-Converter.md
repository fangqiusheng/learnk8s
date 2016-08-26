# 6. KUbe-apiserver-Scheme-Converter #
Kubernetes需兼容多版本的APIServer，不同版本中接口的输入输出的参数格式是有差别的，Kubernetes是如何解决这个问题的？首先研究Kubernetes API的序列化/反序列化问题。

为了同时解决数据对象的序列化/反序列化与多版本数据对象的兼容和转换问题，Kubernetes设计了一套复杂的机制。

## 6.1 Scheme ##

Scheme defines methods for serializing and deserializing API objects, a type registry for converting group, version, and kind information to and from Go schemas, and mappings between Go schemas of different versions. A scheme is the foundation for a versioned API and versioned configuration over time.

In a Scheme:

- a **Type** is a particular Go struct
- a **Version** is a point-in-time identifier for a particular representation of that Type (typically backwards compatible)
- a **Kind** is the unique name for that Type within the Version
- a **Group** identifies a set of Versions, Kinds, and Types that evolve over time. 
- An **Unversioned Type** is one that is not yet formally bound to a type and is promised to be backwards compatible (effectively a "v1" of a Type that does not expect to break in the future).

Schemes are not expected to change at runtime and are only threadsafe after registration is complete.

	type Scheme struct {
		// versionMap allows one to figure out the go type of an object with
		// the given version and name.
		gvkToType map[unversioned.GroupVersionKind]reflect.Type

		// typeToGroupVersion allows one to find metadata for a given go object.
		// The reflect.Type we index by should *not* be a pointer.
		typeToGVK map[reflect.Type][]unversioned.GroupVersionKind
	
		// unversionedTypes are transformed without conversion in ConvertToVersion.
		unversionedTypes map[reflect.Type]unversioned.GroupVersionKind

		// unversionedKinds are the names of kinds that can be created in the context of any group
		// or version
		// TODO: resolve the status of unversioned types.
		unversionedKinds map[string]reflect.Type

		// Map from version and resource to the corresponding func to convert
		// resource field labels in that version to internal version.
		fieldLabelConversionFuncs map[string]map[string]FieldLabelConversionFunc

		// converter stores all registered conversion functions. It also has
		// default coverting behavior.
		converter *conversion.Converter
	
		// cloner stores all registered copy functions. It also has default
		// deep copy behavior.
		cloner *conversion.Cloner
	}


由上述代码可以看到scheme结构体的`gvkToType`与`typeToGVK`属性是为了解决数据对象的序列化与反序列化问题。fieldLabelConversionFuncs这个属性用于解决数据对象的属性名称的兼容性转换和校验，比如将需要兼容Pod的spec.host属性改为spec.nodeName的情况。converter属性是负责不同版本的数据对象转换问题。Kubernetes的这个设计思路简单方便地解决了多版本的序列化和数据转换问题。`runtime.Scheme`里序列化和反序列化的核心方法是New()的代码如下：
	
	// New returns a new API object of the given version and name, or an error if it hasn't
	// been registered. The version and kind fields must be specified.
	func (s *Scheme) New(kind unversioned.GroupVersionKind) (Object, error) {
		if t, exists := s.gvkToType[kind]; exists {
			return reflect.New(t).Interface().(Object), nil
		}
	
		if t, exists := s.unversionedKinds[kind.Kind]; exists {
			return reflect.New(t).Interface().(Object), nil
		}
		return nil, &notRegisteredErr{gvk: kind}
	}	
通过查找gvkToType里匹配的注册类型，以**反射**方式生成一个空的数据对象。

'pkg/runtime/scheme.go'中，提供`convertToVersion`函数实现最终的序列化与反序列化的功能。

	func (s *Scheme) convertToVersion(copy bool, in Object, target GroupVersioner) (Object, error) {
		// determine the incoming kinds with as few allocations as possible.
		t := reflect.TypeOf(in)
		...
		out, err := s.New(gvk)
		...
		setTargetKind(out, gvk)
		return out, nil
	}

convertToVersion attempts to convert an input object to its matching Kind in another version within this scheme. Will return an error if the provided version does not contain the inKind (or a mapping by name defined with AddKnownTypeWithName). Will also return an error if the conversion does not result in a valid Object being returned. Passes target down to the conversion methods as the Context on the scope.

NewScheme()函数调用了`pkg/conversion/converter.go`中的功能实现了数据类型的转换。
	func NewScheme() *Scheme {
		s := &Scheme{
			gvkToType:        map[unversioned.GroupVersionKind]reflect.Type{},
			...
			cloner:           conversion.NewCloner(),
			fieldLabelConversionFuncs: map[string]map[string]FieldLabelConversionFunc{},
		}	
		s.converter = conversion.NewConverter(s.nameFunc)
	
		//
		s.AddConversionFuncs(DefaultEmbeddedConversions()...)

		...
		return s
	}


## 6.2 Converter ##
pkg/conversion/converter.go中实现了Kubernetes数据类型转换的具体实现方法，其结构体如下：

	// Converter knows how to convert one type to another.
	type Converter struct {
		// Map from the conversion pair to a function which can
		// do the conversion.
		conversionFuncs          ConversionFuncs
		generatedConversionFuncs ConversionFuncs
		...

		// nameFunc is called to retrieve the name of a type; this name is used for the
		// purpose of deciding whether two types match or not (i.e., will we attempt to
		// do a conversion). The default returns the go type name.
		nameFunc func(t reflect.Type) string
	}


Convert will translate src to dest if it knows how. Both must be pointers.If no conversion func is registered and the default copying mechanism doesn't work on this type pair, an error will be returned. Read the comments on the various FieldMatchingFlags constants to understand what the 'flags' parameter does. 'meta' is given to allow you to pass information to conversion functions,it is not used by Convert() other than storing it in the scope. Not safe for objects with cyclic references!

	func (c *Converter) Convert(src, dest interface{}, flags FieldMatchingFlags, meta *Meta) error {
		if len(c.genericConversions) > 0 {
			// TODO: avoid scope allocation
			s := &scope{converter: c, flags: flags, meta: meta}
			for _, fn := range c.genericConversions {
				if ok, err := fn(src, dest, s); ok {
					return err
				}
			}
		}
		return c.doConversion(src, dest, flags, meta, c.convert)
	}	


## 6.3 资源对象转换实现 ##

runtime.scheme只是实现了一个序列化与数据类型转换的框架API，提供了注册资源数据类型与转换函数的功能，那么具体的资源数据对象类型、转换函数又是在哪个包里实现的呢？答案是`pkg/api`。Kubernetes为不同的API版本提供了独立的数据类型和相关的转换函数，并按照版本号命名package，如`pkg/api/v1`、`pkg/api/v1beta3`等，而当前默认版本则存在于`pkg/api`目录下。  

以`pkg/api/v1`为例，每个目录里都包含如下关键源码：

- types.go：定义了REST API接口里所涉及的所有数据类型。
- conversion.go与conversion_generated.go中定义了conversion.Scheme所需的从内部版本到v1版本的类型转换函数。
- register.go：负责将types.go里定义的数据类型与conversion.go里定义的数据类型转换函数注入到runtime.scheme中。

`pkg/api`里的register.go初始化生成并持有一个全局的rumtime.Scheme对象，并将当前默认版本的数据类型(`pkg/api/types.go`)注册进去，相关代码如下：

	// Scheme is the default instance of runtime.Scheme to which types in the Kubernetes API are already registered.
	var Scheme = runtime.NewScheme()

	var (
	SchemeBuilder = runtime.NewSchemeBuilder(addKnownTypes, addDefaultingFuncs)
	AddToScheme   = SchemeBuilder.AddToScheme
	)

	func init() {
		//注入数据类型转换函数
		if err := addConversionFuncs(Scheme); err != nil {
			// Programmer error.
			panic(err)
		}
	}


	//注册默认数据类型
	func addKnownTypes(scheme *runtime.Scheme) error {
		if err := scheme.AddIgnoredConversionType(&unversioned.TypeMeta{}, &unversioned.TypeMeta{}); err != nil {
		return err
		}
		scheme.AddKnownTypes(SchemeGroupVersion,
			&Pod{},
			&PodList{},
			...
			&ConfigMap{},
			&ConfigMapList{},
		)

		// Register Unversioned types under their own special group
			scheme.AddUnversionedTypes(Unversioned,
			&unversioned.ExportOptions{},
			&unversioned.Status{},
			&unversioned.APIVersions{},
			&unversioned.APIGroupList{},
			&unversioned.APIGroup{},
			&unversioned.APIResourceList{},
		)

而`pkg/api/v1/register.go`在初始化过程中分别把与版本相关的数据类型和转换函数注入到全局的runtime.Scheme中，代码如下：

	// SchemeGroupVersion is group version used to register these objects
	//添加对应版本信息
	var SchemeGroupVersion = unversioned.GroupVersion{Group: GroupName, Version: "v1"}

	var (
		SchemeBuilder = runtime.NewSchemeBuilder(addKnownTypes, addDefaultingFuncs, addConversionFuncs, addFastPathConversionFuncs)
		AddToScheme   = SchemeBuilder.AddToScheme
	)

	// Adds the list of known types to api.Scheme.
	func addKnownTypes(scheme *runtime.Scheme) error {
		scheme.AddKnownTypes(SchemeGroupVersion,
			&Pod{},
			&PodList{},
			&PodStatusResult{},
			&PodTemplate{},
			&PodTemplateList{},
	
			&ConfigMap{},
			&ConfigMapList{},
		)

		// Add common types
		scheme.AddKnownTypes(SchemeGroupVersion, &unversioned.Status{})
	
		// Add the watch version that applies
		versionedwatch.AddToGroupVersion(scheme, SchemeGroupVersion)
		return nil
	}	


这样一来，其它地方就可以通过`runtime.Scheme`这个全局变量来完成Kubernetes API中的数据对象的序列化和反序列化逻辑了，比如Kubernetes API Client包就大量使用了它，下面是`pkg/client/pods.go`里pod删除的Delete（）方法的代码:

此处新版本源码已更改。

最新版本貌似不再使用rumtime.Scheme这个全局变量，而是通过list-watch+ VersionedParams(&opts, api.ParameterCodec)实现？？源码如下：

	/ List takes label and field selectors, and returns the list of pods that match those selectors.
	func (c *pods) List(opts api.ListOptions) (result *api.PodList, err error) {
		result = &api.PodList{}
		err = c.r.Get().Namespace(c.ns).Resource("pods").VersionedParams(&opts, api.ParameterCodec).Do().Into(result)
		return
	}

	// VersionedParams will take the provided object, serialize it to a map[string][]string using the
	// implicit RESTClient API version and the default parameter codec, and then add those as parameters
	// to the request. Use this to provide versioned query parameters from client libraries.
	func (r *Request) VersionedParams(obj runtime.Object, codec runtime.ParameterCodec) *Request {
		if r.err != nil {
			return r
		}

	func (c *pods) Watch(opts api.ListOptions) (watch.Interface, error) {
	return c.r.Get().
		Prefix("watch").
		Namespace(c.ns).
		Resource("pods").
		VersionedParams(&opts, api.ParameterCodec).
		Watch()
	}




















