#! /bin/bash

curl https://master:6443/api/v1/nodes --cert /etc/kubernetes/ssl/apiserver.pem --key /etc/kubernetes/ssl/apiserver-key.pem --cacert /etc/kubernetes/ssl/ca.pem

