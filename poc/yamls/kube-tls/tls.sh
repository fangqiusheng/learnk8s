#! /bin/bash

#1. 自签 CA

# 创建证书存放目录
mkdir -p cert && cd cert
# 创建 CA 私钥
openssl genrsa -out ca-key.pem 2048
# 自签 CA
openssl req -x509 -new -nodes -key ca-key.pem -days 10000 -out ca.pem -subj "/CN=unionpay.com"


#2. 签署 apiserver 证书

# 生成 apiserver 私钥
openssl genrsa -out apiserver-key.pem 2048
# 生成签署请求
openssl req -new -key apiserver-key.pem -out apiserver.csr -subj "/CN=master" -config openssl.cnf
# 使用自建 CA 签署
openssl x509 -req -in apiserver.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial -out apiserver.pem -days 365 -extensions v3_req -extfile openssl.cnf

#3. 签署 node 证书

# 先声明两个变量方便引用
WORKER_FQDN=node1          # node 昵称
WORKER_IP=172.21.101.103    # node IP
# 生成 node 私钥
openssl genrsa -out ${WORKER_FQDN}-worker-key.pem 2048
# 生成 签署请求
openssl req -new -key ${WORKER_FQDN}-worker-key.pem -out ${WORKER_FQDN}-worker.csr -subj "/CN=${WORKER_FQDN}" -config worker-openssl.cnf
# 使用自建 CA 签署
openssl x509 -req -in ${WORKER_FQDN}-worker.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial -out ${WORKER_FQDN}-worker.pem -days 365 -extensions v3_req -extfile worker-openssl.cnf


# 先声明两个变量方便引用
WORKER_FQDN=node2          # node 昵称
WORKER_IP=172.21.101.104   # node IP
# 生成 node 私钥
openssl genrsa -out ${WORKER_FQDN}-worker-key.pem 2048
# 生成 签署请求
openssl req -new -key ${WORKER_FQDN}-worker-key.pem -out ${WORKER_FQDN}-worker.csr -subj "/CN=${WORKER_FQDN}" -config worker-openssl.cnf
# 使用自建 CA 签署
openssl x509 -req -in ${WORKER_FQDN}-worker.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial -out ${WORKER_FQDN}-worker.pem -days 365 -extensions v3_req -extfile worker-openssl.cnf


#4. 生成集群管理证书

openssl genrsa -out admin-key.pem 2048
openssl req -new -key admin-key.pem -out admin.csr -subj "/CN=kube-admin"
openssl x509 -req -in admin.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial -out admin.pem -days 365













