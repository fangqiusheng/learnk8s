#! /bin/bash

#curl https://172.21.101.102:443/api/v1/ --cert /etc/kubernetes/ssl/apiserver.pem --key /etc/kubernetes/ssl/apiserver-key.pem --cacert /etc/kubernetes/ssl/ca.pem
curl https://kubernetes:443/api/v1/ --cert /etc/kubernetes/ssl/apiserver.pem --key /etc/kubernetes/ssl/apiserver-key.pem --cacert /etc/kubernetes/ssl/ca.pem

