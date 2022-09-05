apiVersion: v1
baseDomain: az.example.com
controlPlane: 
  hyperthreading: Enabled   
  name: master
  platform:
    azure:
      osDisk:
        diskSizeGB: 1024 
        diskType: Premium_LRS
      type: Standard_D8s_v3
  replicas: 3
compute: 
- hyperthreading: Enabled 
  name: worker
  platform:
    azure:
      type: Standard_D2s_v3
      osDisk:
        diskSizeGB: 512 
        diskType: Standard_LRS
      zones: 
      - "1"
      - "2"
      - "3"
  replicas: 3
metadata:
  name: test
platform:
  azure:
    baseDomainResourceGroupName: pbertera-oidc-rg
    region: westeurope
    cloudName: AzurePublicCloud
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: 10.0.0.0/16
  networkType: OpenShiftSDN
  serviceNetwork:
  - 172.30.0.0/16
pullSecret: '$PULL_SECRET'
sshKey: '$SSH_KEY'
