#!/bin/bash

SUBID=""
REGION="westus2"
RESOURCEGROUP="kube"
VNET="kubernetes-vnet"
SUBNET="kubernetes-subnet"
NSG="kubernetes-nsg"
PUBLICIP="kubernetes-pip"
LOADBALANCER="kubernetes-lb"
LOADBALANCERPOOL="kubernetes-lb-pool"
UBUNTULTS="Canonical:UbuntuServer:18.04-LTS:18.04.201909030"

echo 'Logging into Azure'
az login
az account set --subscription $SUBID
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

# Create Certificates
echo "Creating certs"

echo 'Generating CA'

cfssl gencert -initca ./pki/ca-csr.json | cfssljson -bare ca 

EXTERNALIP=$(az network public-ip show -g vturecek-kube -n $PUBLICIP --query ipAddress -otsv)

# Admin
cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=./pki/ca-config.json -profile=kubernetes ./pki/admin-csr.json | cfssljson -bare admin

# Kubelets
for i in 0 1 2; do
    INTERNALIP=$(az vm show -d -n worker-${i} -g $RESOURCEGROUP --query privateIps -otsv)
    cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=./pki/ca-config.json -hostname=worker-${i},${EXTERNALIP},${INTERNALIP} -profile=kubernetes ./pki/worker-${i}-csr.json | cfssljson -bare worker-${i}
done

# Controller
cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=./pki/ca-config.json -profile=kubernetes ./pki/kube-controller-manager-csr.json | cfssljson -bare kube-controller-manager

# Kube proxy client
cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=./pki/ca-config.json -profile=kubernetes ./pki/kube-proxy-csr.json | cfssljson -bare kube-proxy

# Scheduler client
cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=./pki/ca-config.json -profile=kubernetes ./pki/kube-scheduler-csr.json | cfssljson -bare kube-scheduler

# API Server
cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=./pki/ca-config.json -hostname=10.32.0.1,10.240.0.10,10.240.0.11,10.240.0.12,${EXTERNALIP},127.0.0.1,kubernetes.default -profile=kubernetes ./pki/kubernetes-csr.json | cfssljson -bare kubernetes

# Service accounts
cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=./pki/ca-config.json -profile=kubernetes ./pki/service-account-csr.json | cfssljson -bare service-account

# Connect to VPN before running this - using internal VM IP
for i in 0 1 2; do
    WORKER_INTERNALIP=$(az vm show -d -n worker-${i} -g $RESOURCEGROUP --query privateIps -otsv)
    scp -o StrictHostKeyChecking=no ca.pem worker-${i}-key.pem worker-${i}.pem kuberoot@${WORKER_INTERNALIP}:~/
done

for i in 0 1 2; do
    CONTROLLER_INTERNALIP=$(az vm show -d -n controller-${i} -g $RESOURCEGROUP --query privateIps -otsv)
    scp -o StrictHostKeyChecking=no ca.pem ca-key.pem kubernetes-key.pem kubernetes.pem service-account-key.pem service-account.pem kuberoot@${CONTROLLER_INTERNALIP}:~/
done

# Kubernetes config files
CLUSTER_IP=$(az network public-ip show -g $RESOURCEGROUP -n $PUBLICIP --query ipAddress -otsv)

# Kubelets for worker nodes
for i in 0 1 2; do
    kubectl config set-cluster vturecek-kube --certificate-authority=ca.pem --embed-certs=true --server=https://${CLUSTER_IP}:6443 --kubeconfig=worker-${i}.kubeconfig
    kubectl config set-credentials system:node:worker-${i} --client-certificate=worker-${i}.pem --client-key=worker-${i}-key.pem --embed-certs=true --kubeconfig=worker-${i}.kubeconfig
    kubectl config set-context default --cluster=vturecek-kube --user=system:node:worker-${i} --kubeconfig=worker-${i}.kubeconfig
    kubectl config use-context default --kubeconfig=worker-${i}.kubeconfig
done

# Kubeproxy for worker nodes
kubectl config set-cluster vturecek-kube --certificate-authority=ca.pem --embed-certs=true --server=https://${CLUSTER_IP}:6443 --kubeconfig=kube-proxy.kubeconfig
kubectl config set-credentials kube-proxy --client-certificate=kube-proxy.pem --client-key=kube-proxy-key.pem --embed-certs=true --kubeconfig=kube-proxy.kubeconfig
kubectl config set-context default --cluster=vturecek-kube --user=kube-proxy --kubeconfig=kube-proxy.kubeconfig
kubectl config use-context default --kubeconfig=kube-proxy.kubeconfig

# Controller manager for controller nodes
kubectl config set-cluster vturecek-kube --certificate-authority=ca.pem --embed-certs=true --server=https://127.0.0.1:6443 --kubeconfig=kube-controller-manager.kubeconfig
kubectl config set-credentials system:kube-controller-manager --client-certificate=kube-controller-manager.pem --client-key=kube-controller-manager-key.pem --embed-certs=true --kubeconfig=kube-controller-manager.kubeconfig
kubectl config set-context default --cluster=vturecek-kube --user=system:kube-controller-manager --kubeconfig=kube-controller-manager.kubeconfig
kubectl config use-context default --kubeconfig=kube-controller-manager.kubeconfig

# Scheduler for controller nodes
kubectl config set-cluster vturecek-kube --certificate-authority=ca.pem --embed-certs=true --server=https://127.0.0.1:6443 --kubeconfig=kube-scheduler.kubeconfig
kubectl config set-credentials system:kube-scheduler --client-certificate=kube-scheduler.pem --client-key=kube-scheduler-key.pem --embed-certs=true --kubeconfig=kube-scheduler.kubeconfig
kubectl config set-context default --cluster=vturecek-kube --user=system:kube-scheduler --kubeconfig=kube-scheduler.kubeconfig
kubectl config use-context default --kubeconfig=kube-scheduler.kubeconfig

# Admin for controller nodes
kubectl config set-cluster vturecek-kube --certificate-authority=ca.pem --embed-certs=true --server=https://127.0.0.1:6443 --kubeconfig=admin.kubeconfig
kubectl config set-credentials admin --client-certificate=admin.pem --client-key=admin-key.pem --embed-certs=true --kubeconfig=admin.kubeconfig
kubectl config set-context default --cluster=vturecek-kube --user=admin --kubeconfig=admin.kubeconfig
kubectl config use-context default --kubeconfig=admin.kubeconfig

# Connect to VPN before running this - using internal VM IP
for i in 0 1 2; do
    WORKER_INTERNALIP=$(az vm show -d -n worker-${i} -g $RESOURCEGROUP --query privateIps -otsv)
    scp -o StrictHostKeyChecking=no worker-${i}.kubeconfig kube-proxy.kubeconfig kuberoot@${WORKER_INTERNALIP}:~/
done

for i in 0 1 2; do
    CONTROLLER_INTERNALIP=$(az vm show -d -n controller-${i} -g $RESOURCEGROUP --query privateIps -otsv)
    scp -o StrictHostKeyChecking=no admin.kubeconfig kube-controller-manager.kubeconfig kube-scheduler.kubeconfig kuberoot@${CONTROLLER_INTERNALIP}:~/
done

# data encryption 
# get a key
ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)
cat > encryption-config.yaml <<EOF
kind: EncryptionConfig
apiVersion: v1
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: ${ENCRYPTION_KEY}
      - identity: {}
EOF


for i in 0 1 2; do
    CONTROLLER_INTERNALIP=$(az vm show -d -n controller-${i} -g $RESOURCEGROUP --query privateIps -otsv)
    scp -o StrictHostKeyChecking=no encryption-config.yaml kuberoot@${CONTROLLER_INTERNALIP}:~/
done

# Run etcd set up script on each controller
for i in 0 1 2; do
    CONTROLLER_INTERNALIP=$(az vm show -d -n controller-${i} -g $RESOURCEGROUP --query privateIps -otsv)
    scp -o StrictHostKeyChecking=no ./azure/setup-etcd.sh kuberoot@${CONTROLLER_INTERNALIP}:~/
    ssh -f kuberoot@${CONTROLLER_INTERNALIP} "nohup ./setup-etcd.sh > /dev/null 2>&1"
done