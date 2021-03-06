#!/bin/bash
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

set -e
set -u

DEVSTACK_HOME=${HOME}/devstack
STRATOS_BASE=${HOME}/stratosbase
TOMCAT_BASE=${HOME}/tomcatbase
KEYPAIR_NAME='openstack-demo-keypair'
DOWNLOAD_DIR=/vagrant/downloads/openstack-docker

progname=$0
progdir=$(dirname $progname)
progdir=$(cd $progdir && pwd -P || echo $progdir)
progarg=''

function finish {
   echo "\n\nReceived SIGINT. Exiting..."
   exit
}

trap finish SIGINT

function main() {
  while getopts 'odh' flag; do
    progarg=${flag}
    case "${flag}" in
      o) openstack_setup ; exit $? ;;
      d) docker_setup ; exit $? ;;
      h) usage ; exit $? ;;
      \?) usage ; exit $? ;;
      *) usage ; exit $? ;;
    esac
  done
  usage
}

function usage () {
   cat <<EOF
Usage: $progname -[o|d|h]

Where:

    -o openstack devstack setup

    -d docker setup

    -h show this help message

All commands can be re-run as often as required.
EOF
   exit 0
}

function openstack_setup() {
   
   echo -e "\e[32mPerforming initial setup.\e[39m"

   sudo apt-get update
   sudo apt-get upgrade -y

   # install 3.8.0-26 kernel if isn't already installed
   dpkg -s "linux-image-3.8.0-26-generic" >/dev/null || 
   { 
     sudo apt-get install -y linux-image-3.8.0-26-generic linux-headers-3.8.0-26-generic linux-image-extra-3.8.0-26-generic

     sudo groupadd docker
     sudo usermod -a -G docker vagrant

     echo "Reboot required."
     echo "Exit ssh, perform 'vagrant reload' then ssh back in and re-run this script." 
     exit 0
   } 

   sudo apt-get install -y git

   if [ ! -d devstack ]
   then
     git clone https://github.com/openstack-dev/devstack.git
   fi

   cd devstack
   git checkout stable/havana

   NOVA_DOCKER_CFG=${HOME}/devstack/lib/nova_plugins/hypervisor-docker

   # Patch to user newer docker version

   grep -q '^DOCKER_PACKAGE_VERSION=' $NOVA_DOCKER_CFG
   if [ $? -eq 0 ]
   then
      sed -i -e s/^DOCKER_PACKAGE_VERSION.*$/DOCKER_PACKAGE_VERSION=0.7.6/g $NOVA_DOCKER_CFG
   else
      sed -i -e s/^\(DOCKER_DIR=.*\)$/DOCKER_PACKAGE_VERSION=0.7.6\n\1/g $NOVA_DOCKER_CFG
   fi

   # Patch devstack broken scripts

   sed -i -e "s/lxc-docker;/lxc-docker-\$\{DOCKER_PACKAGE_VERSION\};/g" $NOVA_DOCKER_CFG
   sed -i -e "s/lxc-docker=/lxc-docker-/g" ${HOME}/devstack/tools/docker/install_docker.sh

   # Use Damitha's scripts for the actuall install
   # Source: http://damithakumarage.wordpress.com/2014/01/31/how-to-setup-openstack-havana-with-docker-driver/

   cp -f /vagrant/openstack-docker/install_docker0.sh ${HOME}/devstack/tools/docker/
   cp -f /vagrant/openstack-docker/install_docker1.sh ${HOME}/devstack/tools/docker/

   chmod +x ${HOME}/devstack/tools/docker/install_docker0.sh
   chmod +x ${HOME}/devstack/tools/docker/install_docker1.sh

   # docker scripts need curl 
   sudo apt-get install -y curl

   wget -N -nv -c http://get.docker.io/images/openstack/docker-registry.tar.gz -P ${DOWNLOAD_DIR}/
   cp -f ${DOWNLOAD_DIR}/docker-registry.tar.gz ${DEVSTACK_HOME}/files/

   wget -N -nv -c http://get.docker.io/images/openstack/docker-ut.tar.gz -P ${DOWNLOAD_DIR}/
   cp -f ${DOWNLOAD_DIR}/docker-ut.tar.gz ${DEVSTACK_HOME}/files 

   ./tools/docker/install_docker0.sh

   sudo chown vagrant:docker /var/run/docker.sock

   ./tools/docker/install_docker1.sh

   sudo service docker restart

   # need to wait for docker to start, or following
   # chown will be overwritten
   sleep 3

   sudo chown vagrant:docker /var/run/docker.sock

   docker import - docker-registry < ${DEVSTACK_HOME}/files/docker-registry.tar.gz
   docker import - docker-busybox < ${DEVSTACK_HOME}/files/docker-ut.tar.gz

   sudo sed -i 's/#net.ipv4.ip_forward/net.ipv4.ip_forward/g' /etc/sysctl.conf
   sudo sysctl -p /etc/sysctl.conf

   sudo apt-get install -y lxc wget bsdtar curl
   sudo apt-get install -y linux-image-extra-3.8.0-26-generic

   sudo modprobe aufs

   set +e 
   grep -q 'modprobe aufs' /etc/rc.local
   if [ $? == 1 ]
   then
      read -d '' REPLACE << EOF
modprobe aufs
sudo killall dnsmasq
sudo chown vagrant:docker /var/run/docker.sock
exit 0
EOF
     sudo perl -i.bak -pe 's~^exit 0~'"${REPLACE}"'~g' /etc/rc.local
   fi
   set -e

   cat > ${HOME}/devstack/localrc <<'EOF'
HOST_IP=192.168.92.30
FLOATING_RANGE=192.168.92.8/29
FIXED_RANGE=10.11.12.0/24
FIXED_NETWORK_SIZE=256
FLAT_INTERFACE=eth2
ADMIN_PASSWORD=g
# stratos_dev.sh script uses 'password' for mysql
MYSQL_PASSWORD=password
RABBIT_PASSWORD=g
SERVICE_PASSWORD=g
SERVICE_TOKEN=g
SCHEDULER=nova.scheduler.filter_scheduler.FilterScheduler
VIRT_DRIVER=docker
SCREEN_LOGDIR=$DEST/logs/screen
#OFFLINE=True
EOF

   cd ${HOME}/devstack
   ./stack.sh

}

function docker_setup() {

   set +u
   . ${DEVSTACK_HOME}/openrc admin admin
   set -u

   # setup security rules as per the stratos wiki

   if ! $(nova secgroup-list-rules default | grep -q 'tcp'); then
     nova secgroup-add-rule default tcp 22 22 0.0.0.0/0
   fi

   if ! $(nova secgroup-list-rules default | grep -q 'icmp'); then
     nova secgroup-add-rule default icmp -1 -1 0.0.0.0/0
   fi

   # add a pre-created keypair to openstack
   if ! $(nova keypair-list | grep -q "$KEYPAIR_NAME"); then
     chmod 600 openstack-demo-keypair.pem
     ssh-keygen -f ${HOME}/openstack-demo-keypair.pem -y > ${HOME}/openstack-demo-keypair.pub
     nova keypair-add --pub_key ${HOME}/openstack-demo-keypair.pub "$KEYPAIR_NAME"
   fi

   # Patch docker driver, see
   # http://damithakumarage.wordpress.com/2014/01/31/how-to-setup-openstack-havana-with-docker-driver/
   sed -i -e 's/destroy_disks=True)/destroy_disks=True, context=None)/g' /opt/stack/nova/nova/virt/docker/driver.py

   # see http://damithakumarage.wordpress.com/2014/02/01/docker-driver-for-openstack-havana/#comment-1000
   if [[ ! -e ${DOWNLOAD_DIR}/ubuntu64-docker-ssh.tar.gz ]]; then
      wget -N -nv -c https://www.dropbox.com/sh/dmmey60kvdihc31/F73PRm6B8q/ubuntu64-docker-ssh.tar.gz -P ${DOWNLOAD_DIR}
   fi
   cp -f ${DOWNLOAD_DIR}/ubuntu64-docker-ssh.tar.gz ${DEVSTACK_HOME}/files


   docker import - ubuntu64base < ${DEVSTACK_HOME}/files/ubuntu64-docker-ssh.tar.gz

   [ -d $STRATOS_BASE ] || mkdir $STRATOS_BASE

   cp -f /vagrant/openstack-docker/Dockerfile $STRATOS_BASE/
   cp -f /vagrant/openstack-docker/metadata_svc_bugfix.sh $STRATOS_BASE/
   cp -f /vagrant/openstack-docker/file_edit_patch.sh $STRATOS_BASE/
   cp -f /vagrant/openstack-docker/run_scripts.sh $STRATOS_BASE/

   cd $STRATOS_BASE
   docker build -t stratosbase .

   docker tag stratosbase 192.168.92.30:5042/stratosbase
   docker push 192.168.92.30:5042/stratosbase

   [ -d $TOMCAT_BASE ] || mkdir $TOMCAT_BASE

   cp -f /vagrant/openstack-docker/Dockerfile_tomcat $TOMCAT_BASE/Dockerfile
   cp -f /vagrant/openstack-docker/init.sh $TOMCAT_BASE/
   cp -f /vagrant/openstack-docker/puppet.conf $TOMCAT_BASE/
   cp -f /vagrant/openstack-docker/stratos_sendinfo.rb $TOMCAT_BASE/
   cp -f /vagrant/openstack-docker/run_scripts_tomcat.sh $TOMCAT_BASE/

   cd $TOMCAT_BASE
   docker build -t tomcatbase .

   docker tag tomcatbase 192.168.92.30:5042/tomcatbase
   docker push 192.168.92.30:5042/tomcatbase

   echo "================================"
   echo "Openstack installation finished."
   echo "Login using:"
   echo ""
   echo "URL http://192.168.92.30/"
   echo "Username: admin or demo"
   echo "Passsword: g"
   echo "================================"
}

main "$@"
