# 开发中心内部源设置 for centos

## 下载脚本及运行

> wget http://172.17.249.122/xhlin/mirrors/repository/archive.tar.gz

> tar xzvf archive.tar.gz

> cd mirrors.git

> cp config.sh config_run.sh

> chmod +x config_run.sh


查看运行方式

> ./config_run.sh -h


```
usage: ./config_run.sh options

options is -yflpei

This script will config the mirror of local for dev

if options is -yflpei, then will config all repos

BASIC OPTIONS:
   -y      config centos repo and epel repo
   -f      config forman repo
   -l      config openstack Liberty repo
   -p      config puppet repo
   -e      config elk repo
   -i      config pip repo
   -h      print help


```

## 禁用fastestmirror

修改 `/etc/yum.conf`文件,把 `plugins=1` 修改为 `plugins=0` 禁用插件，或者卸载 yum-fastmirror rpm也行。

## 运行 yum update

> yum clean

> yum update


## 配置内容说明

- centos yum 源配置
- rhel epel 源配置
- python pip 源配置
