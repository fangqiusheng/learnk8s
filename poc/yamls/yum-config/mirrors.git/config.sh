#!/usr/bin/env bash

BASE_DIR=`pwd`

copy_yum_repo()
{
  # yum centos
  if [[ -f /etc/yum.repos.d/CentOS-Base.repo ]]; then
    mv /etc/yum.repos.d/CentOS-Base.repo /etc/yum.repos.d/CentOS-Base.repo.backup
  fi
  cp $BASE_DIR/CentOS7-Base-up.repo /etc/yum.repos.d/CentOS7-Base-up.repo
  # yum epel
  if [[ -f /etc/yum.repos.d/epel.repo ]]; then
    mv /etc/yum.repos.d/epel.repo /etc/yum.repos.d/epel.repo.backup
  fi

  if [[ -f /etc/yum.repos.d/epel-testing.repo ]]; then
    mv /etc/yum.repos.d/epel-testing.repo /etc/yum.repos.d/epel-testing.repo.backup
  fi

  cp $BASE_DIR/epel.repo /etc/yum.repos.d/epel.repo
}

copy_forman()
{
  cp $BASE_DIR/172.17.141.161-44444-foreman-plugins.repo /etc/yum.repos.d/172.17.141.161-44444-foreman-plugins.repo
  cp $BASE_DIR/172.17.141.161-44444-foreman.repo /etc/yum.repos.d/172.17.141.161-44444-foreman.repo
}

copy_openstackL()
{
  cp $BASE_DIR/172.17.141.161-44444-openstack-liberty.repo /etc/yum.repos.d/172.17.141.161-44444-openstack-liberty.repo
}

copy_puppet()
{
  cp $BASE_DIR/172.17.254.218-80-puppet.repo /etc/yum.repos.d/172.17.254.218-80-puppet.repo
}

copy_ceph()
{
  cp $BASE_DIR/ceph.repo /etc/yum.repos.d/ceph.repo
}


copy_elk()
{
  cp $BASE_DIR/elk.repo /etc/yum.repos.d/elk.repo
}

copy_pip_conf()
{
  # pip
  if [[ ! -d $HOME/.pip ]] ;then
    mkdir $HOME/.pip
  elif [[ -f $HOME/.pip/pip.conf  ]]; then
    mv $HOME/.pip/pip.conf $HOME/.pip/pip.conf.bk
  fi

  cp $BASE_DIR/pip.conf $HOME/.pip/pip.conf

}

usage()
{
cat << EOF
usage: $0 options

options is -yflpei

This script will config the mirror of local for dev

if options is -yflpei, then will config all repos

BASIC OPTIONS:
   -c      config ceph repo
   -y      config centos repo and epel repo
   -f      config forman repo
   -l      config openstack Liberty repo
   -p      config puppet repo
   -e      config elk repo
   -i      config pip repo
   -h      print help

EOF
}

if [[ $# == 0 ]]; then
  usage
fi

while getopts "cyflpeih" OPTION
do
     case $OPTION in
         c)
             echo config ceph
             copy_ceph
             ;;
         y)
             echo config yum
             copy_yum_repo
             ;;
         f)
             echo config forman
             copy_forman
             ;;
         l)
             echo config openstack
             copy_openstackL
             ;;
         p)
             echo config puppet
             copy_puppet
             ;;
         e)
             echo config elk
             copy_elk
             ;;
         i)
            echo config pip
            copy_pip_conf
            ;;
         h)
            usage
            ;;
         [?])
            usage
            exit 1;;
     esac
done
