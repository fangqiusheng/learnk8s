# 6. KUbe-apiserver-Serializer #
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