#!/bin/bash

RESOURCEGROUP="vturecek-kube"
VNET="kubernetes-vnet"
NSG="kubernetes-nsg"

az network vnet update -g $RESOURCEGROUP -n $VNET --address-prefixes 10.240.0.0/16 192.168.200.0/24
az network vnet subnet create -g $RESOURCEGROUP --vnet-name $VNET -n GatewaySubnet --address-prefixes 192.168.200.0/24
az network public-ip create -g $RESOURCEGROUP -n gateway-pip --allocation-method dynamic
az network vnet-gateway create -g $RESOURCEGROUP -n vnet-gateway --public-ip-addresses gateway-pip --vnet $VNET --client-protocol "SSTP" --address-prefixes 172.16.201.0/24
az network vnet-gateway root-cert create -g $RESOURCEGROUP -n rootcert --gateway-name vnet-gateway --public-cert-data ./azure/windows/out/rootcert.cer
az network vnet-gateway vpn-client generate -g $RESOURCEGROUP -n vnet-gateway --authentication-method EAPTLS | xargs curl -o vpnclient.zip 
