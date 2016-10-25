#nodelist=("node1" node2)

scp cert/node1-worker-key.pem cert/node1-worker.pem cert/ca.pem  root@node1:/etc/kubernetes/ssl
scp cert/node2-worker-key.pem cert/node2-worker.pem cert/ca.pem  root@node2:/etc/kubernetes/ssl
#chown kube:kube -R /etc/kubernetes/ssl
#echo "127.0.0.1 172-21-101-104" >> /etc/hosts


