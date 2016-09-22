#! /bin/bash
chown kube:kube -R /etc/kubernetes/ssl
echo "127.21.101.103 node1" >> /etc/hosts
echo "172.21.101.102 master" >> /etc/hosts

cat /etc/kubernetes/kubelet

cat /etc/kubernetes/config

cat /etc/kubernetes/worker-kubeconfig.yaml

cat /etc/kubernetes/proxy

bash run-k8s-node.sh
