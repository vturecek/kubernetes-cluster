#!/bin/bash

SUBID=""
REGION="westus2"
RESOURCEGROUP="vturecek-kube"
VNET="kubernetes-vnet"
SUBNET="kubernetes-subnet"
NSG="kubernetes-nsg"
PUBLICIP="kubernetes-pip"
LOADBALANCER="kubernetes-lb"
LOADBALANCERPOOL="kubernetes-lb-pool"
UBUNTULTS="Canonical:UbuntuServer:18.04-LTS:18.04.201909030"

. ./setup-infra.sh
. ./setup-pki.sh

# Run etcd set up script on each controller
for i in 0 1 2; do
    CONTROLLER_INTERNALIP=$(az vm show -d -n controller-${i} -g $RESOURCEGROUP --query privateIps -otsv)
    scp -o StrictHostKeyChecking=no ./azure/setup-etcd.sh kuberoot@${CONTROLLER_INTERNALIP}:~/
    ssh -f kuberoot@${CONTROLLER_INTERNALIP} "nohup ./setup-etcd.sh > /dev/null 2>&1"
done

for i in 0 1 2; do
    CONTROLLER_INTERNALIP=$(az vm show -d -n controller-${i} -g $RESOURCEGROUP --query privateIps -otsv)
    scp -o StrictHostKeyChecking=no ./azure/setup-controlplane.sh kuberoot@${CONTROLLER_INTERNALIP}:~/
    ssh -f kuberoot@${CONTROLLER_INTERNALIP} "nohup ./setup-controlplane.sh > /dev/null 2>&1"
done
