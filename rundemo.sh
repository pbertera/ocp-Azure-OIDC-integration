#!/bin/bash

. demo.sh

set -e

clear

#DEMO_DEBUG=yes
DEMO_AUTO_TYPE=yes
DEMO_NOWAIT=yes
OCPI=$(which openshift-install)
AZ=az
AZWI=azwi
INSTALL_DIR=install-dir
PULL_SECRET_FAKE='[...]'
PULL_SECRET='{THE REAL PULL SECRET HERE}'
SSH_KEY='YOUR SSH KEY HERE'

rm -rf "$INSTALL_DIR"

uu1_bg_color=${c['bg_CYAN']}
ps1_color=${c['ORANGE']}
ps1_demo="OIDC-Demo"

ps1() {
    echo -ne "${ps1_bg_color}${ps1_color}${ps1_demo}${c['reset']}${c['CYAN']} ${c['BLUE']}\$${c['reset']} "
}   

INSTALL_CONFIG=$(cat install-config.yaml.tpl | PULL_SECRET=$PULL_SECRET_FAKE SSH_KEY=$SSH_KEY envsubst)

pi "# Let's create the install-config.yaml"; sleep 1
pei mkdir -p "$INSTALL_DIR"
pi 'cat << EOF > install-dir/install-config.yaml'
echo "$INSTALL_CONFIG"
echo EOF

INSTALL_CONFIG=$(cat install-config.yaml.tpl | PULL_SECRET=$PULL_SECRET SSH_KEY=$SSH_KEY envsubst)
echo "$INSTALL_CONFIG" > ${INSTALL_DIR}/install-config.yaml

pi "# Tell the installer to create the manifests"; sleep 1
pei $OCPI create manifests --dir "$INSTALL_DIR"

pi '# Create the Azure Storage Container where the OIDC files will be stored'
pi '# The cluster RG can be taken from'
pi "# $INSTALL_DIR/manifests/cluster-infrastructure-02-config.yml"
pei 'RESOURCE_GROUP="pbertera-oidc-rg" #HINT: you can get the cluster RG with `jq -r .infraID install-dir/metadata.json`'
pei 'LOCATION="westeurope"'
pei 'AZURE_STORAGE_ACCOUNT="oidcissuer$(openssl rand -hex 4)"'
pei 'AZURE_STORAGE_CONTAINER="oidc-test"'

pi $AZ 'group create --name "${RESOURCE_GROUP}" --location "${LOCATION}" --only-show-errors'
$AZ group create --name "${RESOURCE_GROUP}" --location "${LOCATION}" --only-show-errors

pi $AZ 'storage account create --resource-group "${RESOURCE_GROUP}" --name "${AZURE_STORAGE_ACCOUNT}" --only-show-errors'
$AZ storage account create --resource-group "${RESOURCE_GROUP}" --name "${AZURE_STORAGE_ACCOUNT}" --only-show-errors

pi $AZ 'storage container create --account-name "${AZURE_STORAGE_ACCOUNT}" --name "${AZURE_STORAGE_CONTAINER}" --public-access container --only-show-errors'
$AZ storage container create --account-name "${AZURE_STORAGE_ACCOUNT}" --name "${AZURE_STORAGE_CONTAINER}" --public-access container --only-show-errors

DISCOVERY_DOCUMENT=$(cat <<EOF
{
  "issuer": "https://${AZURE_STORAGE_ACCOUNT}.blob.core.windows.net/${AZURE_STORAGE_CONTAINER}/",
  "jwks_uri": "https://${AZURE_STORAGE_ACCOUNT}.blob.core.windows.net/${AZURE_STORAGE_CONTAINER}/openid/v1/jwks",
  "response_types_supported": [
    "id_token"
  ],
  "subject_types_supported": [
    "public"
  ],
  "id_token_signing_alg_values_supported": [
    "RS256"
  ],
  "claims_supported": [
     "aud",
     "exp",
     "sub",
     "iat",
     "iss",
     "sub"
  ]
}
EOF
)

pi '# Create the OIDC Discovery document locally'
pi 'cat << EOF > discovery-document.json'
echo "$DISCOVERY_DOCUMENT"
echo EOF
echo "$DISCOVERY_DOCUMENT" > discovery-document.json

function az_upload(){
  src="$1"
  dst="$2"
  pei $AZ 'storage blob upload --only-show-errors --container-name "${AZURE_STORAGE_CONTAINER}" --account-name "${AZURE_STORAGE_ACCOUNT}" --file' "$src" '--overwrite=true --name' "$dst"
}

pi '# Upload the document on the Azure Storage Container'
az_upload discovery-document.json .well-known/openid-configuration

pi '# Test the download of the discovery document'
pei curl -s "https://${AZURE_STORAGE_ACCOUNT}.blob.core.windows.net/${AZURE_STORAGE_CONTAINER}/.well-known/openid-configuration"

pi '# Create the private and public keys'
pei openssl genrsa -out sa.key 4096
pei openssl rsa -in sa.key -pubout -out sa.pub

pi '# Convert the keys into a JWKS document'
pei $AZWI jwks --public-keys sa.pub --output-file jwks.json

pi '# Upload the document to the Azure Storage Container'
az_upload jwks.json openid/v1/jwks

pi '# Test the JWKS download'
pei curl -s "https://${AZURE_STORAGE_ACCOUNT}.blob.core.windows.net/${AZURE_STORAGE_CONTAINER}/openid/v1/jwks"

pi "# Copy the private key into ${INSTALL_DIR}/tls/bound-service-account-signing-key.key"
pei mkdir -p ${INSTALL_DIR}/tls
pei cp sa.key ${INSTALL_DIR}/tls/bound-service-account-signing-key.key

pi '# Create the Authentication CR manifest'
pei mkdir -p ${INSTALL_DIR}/manifests

MANIFEST=$(cat << EOF 
apiVersion: config.openshift.io/v1
kind: Authentication
metadata:
  name: cluster
spec:
  serviceAccountIssuer: https://${AZURE_STORAGE_ACCOUNT}.blob.core.windows.net/${AZURE_STORAGE_CONTAINER}
EOF
)
pi "cat << EOF > '${INSTALL_DIR}/manifests/cluster-authentication-02-config.yaml'"
echo "$MANIFEST"
echo EOF
echo "$MANIFEST" > "${INSTALL_DIR}/manifests/cluster-authentication-02-config.yaml"
pei chmod 640 "$INSTALL_DIR/manifests/cluster-authentication-02-config.yaml"

pi '# Start the cluster installation'
pei "$OCPI create cluster --dir $INSTALL_DIR"

pi '# Check the cluster'
pei "export KUBECONFIG=$INSTALL_DIR/auth/kubeconfig"
export KUBECONFIG=$INSTALL_DIR/auth/kubeconfig
pei oc get clusteroperators; oc get clusterversion

pi '# Deploy a test pod'
MANIFEST=$(cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ubi8
spec:
  containers:
  - image: registry.access.redhat.com/ubi8/ubi
    name: ubi
    command:
    - /bin/sh
    - -c
    - sleep inf
EOF
)

pi "cat << EOF | oc apply -f -"
echo "$MANIFEST"
echo EOF
echo "$MANIFEST" | oc apply -f -
pei "oc wait --for=condition=Ready --timeout=250s pod/ubi8"
pei sleep 5
pi '# Check the Service Account Token'
pei "oc rsh ubi8 cat /var/run/secrets/kubernetes.io/serviceaccount/token | jq -R ""'split(\".\") | { header: (.[0] | @base64d | fromjson), payload: (.[1] | @base64d | fromjson), signature: (.[2])}'"

#pi "# Let's verify the token:"

#pi "# Save the token header and the payload"

# TOKEN VERIFICATION
#pei 'TOKEN_CONTENT=$(oc rsh ubi8 cat /var/run/secrets/kubernetes.io/serviceaccount/token | cut -d . -f 1,2)'

#pi "# Save the token signature, needs some manipulation"
#pei "oc rsh ubi8 cat /var/run/secrets/kubernetes.io/serviceaccount/token | cut -d . -f 3 | perl -ne 'tr|-_|+/|; print" '"$1\n" while length>76 and s/(.{0,76})//; $_ .= ("", "", "==", "=")[length($_) % 4];' "print' | openssl enc -base64 -d > token_signature.dat"

#pi "# Verify the token signature"
#pei 'echo -ne "$TOKEN_CONTENT" | openssl dgst -sha256 -verify sa.pub -signature token_signature.dat'

################################################
# check the keys with:
# cat sa.pub | grep -v KEY-- | md5sum
# oc extract -n openshift-kube-apiserver secret/bound-service-account-signing-key --to=- --keys=service-account.pub | grep -v KEY--- | md5sum

# cat sa.key | grep -v KEY--- | md5sum
# oc extract -n openshift-kube-apiserver secret/bound-service-account-signing-key --to=- --keys=service-account.key | grep -v KEY-- | md5sum
