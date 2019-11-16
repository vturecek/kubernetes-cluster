#!/bin/bash

SUBID="Ignite Demo"
REGION="westus2"
RESOURCEGROUP="vturecek-kube"
VNET="kubernetes-vnet"
SUBNET="kubernetes-subnet"
NSG="kubernetes-nsg"
PUBLICIP="kubernetes-pip"
LOADBALANCER="kubernetes-lb"
LOADBALANCERPOOL="kubernetes-lb-pool"
UBUNTULTS="Canonical:UbuntuServer:18.04-LTS:18.04.201909030"

echo 'Logging into Azure'
az login
az account set --subscription "${SUBID}"
az group create -n $RESOURCEGROUP -l $REGION

# Network basics: VNET, subnet, NSG
echo 'Setting up networks'
az network vnet create -g $RESOURCEGROUP -n $VNET --address-prefix 10.240.0.0/16 --subnet-name $SUBNET
az network nsg create -g $RESOURCEGROUP -n $NSG
az network vnet subnet update -g $RESOURCEGROUP -n $SUBNET --vnet-name $VNET --network-security-group $NSG

# Configure NSG
az network nsg rule create -g $RESOURCEGROUP -n kubernetes-allow-api-server --access allow --destination-address-prefix "*" --destination-port-range 6443 --direction inbound --nsg-name $NSG --protocol tcp --source-address-prefix "*" --source-port-range "*" --priority 1001

# LB, public IP, and back-end pool 
az network lb create -g $RESOURCEGROUP -n $LOADBALANCER --backend-pool-name $LOADBALANCERPOOL --public-ip-address $PUBLICIP --public-ip-address-allocation static
az network lb probe create -g $RESOURCEGROUP --lb-name $LOADBALANCER --name kubernetes-apiserver-probe --port 6443 --protocol tcp
az network lb rule create -g $RESOURCEGROUP --lb-name $LOADBALANCER --name kubernetes-apiserver-rule --protocol tcp --frontend-ip-name LoadBalancerFrontEnd --frontend-port 6443 --backend-pool-name $LOADBALANCERPOOL --backend-port 6443 --probe-name kubernetes-apiserver-probe

# Controller nodes
echo 'Setting up VMs'
az vm availability-set create -g $RESOURCEGROUP -n controller-as

for i in 0 1 2; do
    echo "[Controller ${i}] Creating public IP"
    az network public-ip create -n controller-${i}-pip -g $RESOURCEGROUP > /dev/null

    echo "[Controller ${i}] Creating NIC"
    az network nic create -g $RESOURCEGROUP -n controller-${i}-nic --private-ip-address 10.240.0.1${i} --public-ip-address controller-${i}-pip --vnet $VNET --subnet $SUBNET --ip-forwarding --lb-name $LOADBALANCER --lb-address-pools $LOADBALANCERPOOL > /dev/null

    echo "[Controller ${i}] Creating VM"
    az vm create -g $RESOURCEGROUP -n controller-${i} --image $UBUNTULTS --generate-ssh-keys --nics controller-${i}-nic --availability-set controller-as --nsg '' --admin-username 'kuberoot' > /dev/null
done

# Worker nodes
az vm availability-set create -g $RESOURCEGROUP -n worker-as

for i in 0 1 2; do
    echo "[Worker ${i}] Creating public IP"
    az network public-ip create -g $RESOURCEGROUP -n worker-${i}-pip > /dev/null

    echo "[Worker ${i}] Creating NIC"
    az network nic create -g $RESOURCEGROUP -n worker-${i}-nic --private-ip-address 10.240.0.2${i} --public-ip-address worker-${i}-pip --vnet $VNET --subnet $SUBNET --ip-forwarding > /dev/null

    echo "[Worker ${i}] Creating VM"
    az vm create -g $RESOURCEGROUP -n worker-${i} --image $UBUNTULTS --generate-ssh-keys --nics worker-${i}-nic --tags pod-cidr=10.200.${i}.0/24 --availability-set worker-as --nsg '' --admin-username 'kuberoot' > /dev/null
done
