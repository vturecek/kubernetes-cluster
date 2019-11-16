#!/bin/bash

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
