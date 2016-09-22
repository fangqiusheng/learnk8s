#nodelist=("node1" node2)

scp cert/node1-worker-key.pem cert/node1-worker.pem cert/ca.pem  root@172.21.101.103:/etc/kubernetes/ssl
scp cert/node2-worker-key.pem cert/node2-worker.pem cert/ca.pem  root@172.21.101.104:/etc/kubernetes/ssl
#chown kube:kube -R /etc/kubernetes/ssl
#echo "127.0.0.1 172-21-101-104" >> /etc/hosts


