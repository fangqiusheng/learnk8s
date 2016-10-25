# 11 Kubernetes Nginx Ingress Controller#

Ingress Controller是一个后台进程，以Kubernetes Pod方式部署，监控Apiserver的 `/ingress` endpoint 以及时更新Ingress资源的信息。它的任务是满足ingress的请求。

## 11.1 Nginx Ingress Controller配置过程 ##

