# 8. Kube-apiserver-Auth #

## 8.1 API认证 ##
`cmd/kube-apiserver/app/server.go`run函数中，可以找到认证组件的实现:

	authenticator, err := authenticator.New(authenticator.AuthenticatorConfig{
			BasicAuthFile:               s.BasicAuthFile,
			ClientCAFile:                s.ClientCAFile,
			TokenAuthFile:               s.TokenAuthFile,
			OIDCIssuerURL:               s.OIDCIssuerURL,
			OIDCClientID:                s.OIDCClientID,
			OIDCCAFile:                  s.OIDCCAFile,
			OIDCUsernameClaim:           s.OIDCUsernameClaim,
			OIDCGroupsClaim:             s.OIDCGroupsClaim,
			ServiceAccountKeyFile:       s.ServiceAccountKeyFile,
			ServiceAccountLookup:        s.ServiceAccountLookup,
			ServiceAccountTokenGetter:   serviceAccountGetter,
			// 支持OpenStack KeyStone
			KeystoneURL:                 s.KeystoneURL,  
			WebhookTokenAuthnConfigFile: s.WebhookTokenAuthnConfigFile,
			WebhookTokenAuthnCacheTTL:   s.WebhookTokenAuthnCacheTTL,
		})

之后在生成master实例的时候，这个认证器 authenticator 会作为Master实例的初始参数传入：

	m := &Master{
			GenericAPIServer:        s,
			...
		}
	//
	type GenericAPIServer struct {
		...
		authenticator         authenticator.Request
		authorizer            authorizer.Authorizer
		AdmissionControl      admission.Interface
		...
	}

	m := master.New(config)

下面大致了解一下生成认证器的这几个参数，具体的使用在后面再进行具体的说明:

- s.BasicAuthFile:指定basicauthfile文件所在的位置，当这个参数不为空的时候，会开启basicauth的认证方式，这是一个.csv文件，三列分别是password,username,useruid。
- s.ClientCAFile：用于给客户端签名的根证书，当这个参数不为空的时候，会启动https的认证方式，会通过这个根证书对客户端的证书进行身份认证。
- s.TokenAuthFile：用于指定token文件所在的位置，当这个参数不为空的时候，会采用token的认证方式，token文件也是csv的格式，三列分别是”token,username,useruid”。
- s.ServiceAccountKeyFile：当不为空的时候，采用ServiceAccount的认证方式，这个其实是一个公钥密钥。注释里说要包含：PEM-encoded x509 RSA private or public key，发送过来的信息是在客户端使用对应的私钥加密过的，服务端使用指定的公钥来解密信息。
- s.ServiceAccountLookup：这个参数值一个bool值，默认为false，如果为true的话，就会从etcd中取出对应的ServiceAccount与传过来的信息进行对比验证，反之则不会。
- helper：这是一个用于与etcd交互的客户端实例，具体生成过程这里不进行具体分析。

下面结合认证器的具体生成过程对这些参数的使用进行具体分析，先总体看一下认证器部分的代码结构：
	
	//pkg/apiserver/authenticator/authn.go
	func New(config AuthenticatorConfig) (authenticator.Request, error) {
		var authenticators []authenticator.Request

		if len(config.BasicAuthFile) > 0 {
			basicAuth, err := newAuthenticatorFromBasicAuthFile(config.BasicAuthFile)
			if err != nil {
				return nil, err
			}
			authenticators = append(authenticators, basicAuth)
		}
	
		if len(config.ClientCAFile) > 0 {
			certAuth, err := newAuthenticatorFromClientCAFile(config.ClientCAFile)
			if err != nil {
				return nil, err
			}
			authenticators = append(authenticators, certAuth)
		}
	
		if len(config.TokenAuthFile) > 0 {
			tokenAuth, err := newAuthenticatorFromTokenFile(config.TokenAuthFile)
			if err != nil {
				return nil, err
			}
			authenticators = append(authenticators, tokenAuth)
		}
	
		...
		switch len(authenticators) {
		case 0:
			return nil, nil
		case 1:
				return authenticators[0], nil
		default:
			return union.New(authenticators...), nil
		}
	}


结合上面的分析，这部分的代码结构就比较清楚了，返回的结果是一个 authenticator.Request 对象数组，每一个元素都是一个认证器，根据传入的参数是否为空来判断最后要生成多少个认证器，最后的union.New函数实际上返回的就是一个authenticator.Request数组：

	// plugin/pkg/auth/authenticator/request/union/union.go
	package union

	// unionAuthRequestHandler authenticates requests using a chain of authenticator.Requests
	type unionAuthRequestHandler []authenticator.Request

	// New returns a request authenticator that validates credentials using a chain of authenticator.Request objects
	func New(authRequestHandlers ...authenticator.Request) authenticator.Request {
		return unionAuthRequestHandler(authRequestHandlers)
	}

我们可以看一下authenticator.Request接口的实现：

	//pkg/auth/authenticator/interfaces.go	
	package authenticator

	// Request attempts to extract authentication information from a request and returns
	// information about the current user and true if successful, false if not successful,
	// or an error if the request could not be checked.
	type Request interface {
		AuthenticateRequest(req *http.Request) (user.Info, bool, error)
	}
	
其中的方法 AuthenticateRequest 的主要功能就是把userinfo从request中提取出来，并返回是否认证成功，以及对应的错误信息。

## 8.2 生成带有认证器的handler ##

下面我们直接跳到对于api请求的认证部分，看一下当某个请求过来的时候，apiserver是如何对其进行认证的。mster.go调用genericapiserver.go中的代码，具体代码在`pkg/genericapiserver/genericapiserver.go`的 `func (s *GenericAPIServer) init(c *Config) ` 函数中：

	// init initializes GenericAPIServer.
	func (s *GenericAPIServer) init(c *Config) {
	...
	// Install Authenticator
		if c.Authenticator != nil {
			authenticatedHandler, err := handlers.NewRequestAuthenticator(s.RequestContextMapper, c.Authenticator, handlers.Unauthorized(c.SupportsBasicAuth), handler)
			if err != nil {
				glog.Fatalf("Could not initialize authenticator: %v", err)
			}
			handler = authenticatedHandler
		}
	...
	}

实现细节暂不讨论，从功能上讲，这一段就是对handler进行一层包装，生成一个带有认证器的handler。 其中 handlers.Unauthorized(c.SupportsBasicAuth) 函数是一个返回Unauthorized信息的函数，如果认证失败，这个函数就会被调用。

我们大致看一下NewRequestAuthenticator函数：

	//  pkg/auth/handlers/handlers.go
	package handlers

	// NewRequestAuthenticator creates an http handler that tries to authenticate the given request as a user, and then
	// stores any such user found onto the provided context for the request. If authentication fails or returns an error
	// the failed handler is used. On success, handler is invoked to serve the request.
	func NewRequestAuthenticator(mapper api.RequestContextMapper, auth authenticator.Request, failed http.Handler, handler http.Handler) (http.Handler, error) {
		return api.NewRequestContextFilter(
			mapper,
			http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
				user, ok, err := auth.AuthenticateRequest(req)
				if err != nil || !ok {
					if err != nil {
						glog.Errorf("Unable to authenticate the request due to an error: %v", err)
					}
					failed.ServeHTTP(w, req)
					return
				}
	
				if ctx, ok := mapper.Get(req); ok {
					mapper.Update(req, api.WithUser(ctx, user))
				}
	
				authenticatedUserCounter.WithLabelValues(compressUsername(user.GetName())).Inc()
	
				handler.ServeHTTP(w, req)
			}),
		)
	}

可以看到HandleFunc中调用的函数，就是要调用我们之前提到的AuthenticateRequest函数，使用其提取用户信息，判断验证是否成功，如果有错误或者认证失败，返回Unauthorized新的的函数就会被调用。结合之前的分析，我们只要把每种认证器的AuthenticateRequest函数分析一下，就可以了解认证操作的具体实现过程了。

## 8.3 每种认证操作的具体实现过程 ##

结合上面的 NewAuthenticator 源码可以知道，最多一共有多种种authenticators:即 basicAuth 、 certAuth 、 tokenAuth 、 serviceAccountAuth ，KeyStone, 还有通过Union.New生成的 unionAuthRequestHandler等等。相应的认证器的实现代码存存储在`plugin/pkg/auth/authenticator/`下。下面我们结合几种简单的认证器的生成过程具体看一下每个 authenticators 的 AuthenticateRequest 函数：

- unionAuthRequestHandler实例

		// AuthenticateRequest authenticates the request using a chain of authenticator.Request objects.  The first
		// success returns that identity.  Errors are only returned if no matches are found.
		func (authHandler unionAuthRequestHandler) AuthenticateRequest(req *http.Request) (user.Info, bool, error) {
			var errlist []error
			for _, currAuthRequestHandler := range authHandler {
				info, ok, err := currAuthRequestHandler.AuthenticateRequest(req)
				if err != nil {
					errlist = append(errlist, err)
					continue
					}

				if ok {
					return info, true, nil
				}
			}

			return nil, false, utilerrors.NewAggregate(errlist)
		}

- tokenAuth：是用token的方式，具体代码的结构与basic auth file的方式比较类似，代码不再赘述，主要功能是先从指定的.csv文件中把信息加载进来，存在服务端TokenAuthenticator实例的一个tokens的map中 tokens map[string]*user.DefaultInfo ，之后用户信息发送过来，会从Authorization中提取出携带token值，只不过这里标记token的关键字使用的是”bearer”，把token值提取出来之后，进行对比，看是否ok。

- Keystone实例：

		// AuthenticatePassword checks the username, password via keystone call
		func (keystoneAuthenticator *KeystoneAuthenticator) AuthenticatePassword(username string, password string) (user.Info, bool, error) {
			opts := gophercloud.AuthOptions{
				IdentityEndpoint: keystoneAuthenticator.authURL,
				Username:         username,
				Password:         password,
			}
	
			_, err := openstack.AuthenticatedClient(opts)
			if err != nil {
				glog.Info("Failed: Starting openstack authenticate client")
				return nil, false, errors.New("Failed to authenticate")
			}
		
			return &user.DefaultInfo{Name: username}, true, nil
		}

		// NewKeystoneAuthenticator returns a password authenticator that validates credentials using openstack keystone
		func NewKeystoneAuthenticator(authURL string) (*KeystoneAuthenticator, error) {
			if !strings.HasPrefix(authURL, "https") {
				return nil, errors.New("Auth URL should be secure and start with https")
			}
			if authURL == "" {
				return nil, errors.New("Auth URL is empty")
			}
	
			return &KeystoneAuthenticator{authURL}, nil
		}

- **...**

## 8.4 Authorizer-AdmissionControl等 ##

相关的授权Authorizer和AdmissionControl等操作，可参照Authenticator认证的流程阅读`cmd/kube-apiserver/app/server.go`代码，在此不再赘述。以此类推，从函数`func Run(s *options.APIServer) error {}`入手，自上而下阅读代码，可了解API-Server相关的各种配置。。

	genericConfig.StorageFactory = storageFactory
	genericConfig.Authenticator = authenticator
	genericConfig.SupportsBasicAuth = len(s.BasicAuthFile) > 0
	genericConfig.Authorizer = authorizer
	genericConfig.AuthorizerRBACSuperUser = s.AuthorizationRBACSuperUser
	genericConfig.AdmissionControl = admissionController
	genericConfig.APIResourceConfigSource = storageFactory.APIResourceConfigSource
	genericConfig.MasterServiceNamespace = s.MasterServiceNamespace
	genericConfig.ProxyDialer = proxyDialerFn
	genericConfig.ProxyTLSClientConfig = proxyTLSClientConfig
	genericConfig.Serializer = api.Codecs
	genericConfig.OpenAPIInfo.Title = "Kubernetes"