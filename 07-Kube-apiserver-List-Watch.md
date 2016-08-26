# 7. Kube-apiserver-List-Watch #
[http://dockone.io/article/1538](http://dockone.io/article/1538)  
list-watch，作为k8s系统中统一的异步消息传递方式，对系统的性能、数据一致性起到关键性的作用。本文从代码这边探究一下list-watch的实现方式。并看是否能在后面的工作中优化这个过程。