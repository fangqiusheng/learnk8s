#! /bin/bash

# 1、配置 master
# 先把证书 copy 到配置目录
mkdir -p /etc/kubernetes/ssl
#rm /etc/kubernetes/ssl/*.pem
cp cert/ca.pem cert/apiserver.pem cert/apiserver-key.pem /etc/kubernetes/ssl
# rpm 安装的 kubernetes 默认使用 kube 用户，需要更改权限
chown kube:kube -R /etc/kubernetes/ssl

cat /etc/kubernetes/apiserver

cat /etc/kubernetes/controller-manager 

bash run-k8s-master.sh


