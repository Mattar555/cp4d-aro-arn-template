#!/bin/sh

set -x 

export LOCATION=$1
export DOMAINNAME=$2
export SUDOUSER=$3
export WORKERNODECOUNT=$4
export CPDNAMESPACE=$5
export STORAGEOPTION=$6
export APIKEY=$7
export OPENSHIFTUSER=$8
export OPENSHIFTPASSWORD=$9
export CUSTOMDOMAIN=$10
export CLUSTERNAME=${11}
export CHANNEL=${12}
export VERSION=${13}

export OPERATORNAMESPACE=ibm-common-services
export INSTALLERHOME=/home/$SUDOUSER/.ibm
export OCPTEMPLATES=/home/$SUDOUSER/.openshift/templates
export CPDTEMPLATES=/home/$SUDOUSER/.cpd/templates

# Set url
if [[ $CUSTOMDOMAIN == "true" || $CUSTOMDOMAIN == "True" ]];then
export SUBURL="${CLUSTERNAME}.${DOMAINNAME}"
else
export SUBURL="${DOMAINNAME}.${LOCATION}.aroapp.io"
fi

#Login
var=1
while [ $var -ne 0 ]; do
echo "Attempting to login $OPENSHIFTUSER to https://api.${SUBURL}:6443"
oc login "https://api.${SUBURL}:6443" -u $OPENSHIFTUSER -p $OPENSHIFTPASSWORD --insecure-skip-tls-verify=true
var=$?
echo "exit code: $var"
done

# IIS case package download  and CR creation 


runuser -l $SUDOUSER -c "cat > $CPDTEMPLATES/ibm-iis-ocs-cr.yaml <<EOF
apiVersion: iis.cpd.ibm.com/v1alpha1
kind: IIS
metadata:
  name: iis-cr
  namespace: $CPDNAMESPACE
spec:
  storageVendor: \"ocs\"
  license:
    accept: true
    license: Enterprise
  docker_registry_prefix: cp.icr.io/cp/cpd
  use_dynamic_provisioning: true
EOF"

runuser -l $SUDOUSER -c "cat > $CPDTEMPLATES/ibm-iis-nfs-cr.yaml <<EOF
apiVersion: iis.cpd.ibm.com/v1alpha1
kind: IIS
metadata:
  name: iis-cr
  namespace: $CPDNAMESPACE
spec:
  storageClass: \"nfs\"
  license:
    accept: true
    license: Enterprise
  docker_registry_prefix: cp.icr.io/cp/cpd
  use_dynamic_provisioning: true
EOF"

## Creating IIS SC yaml 

runuser -l $SUDOUSER -c "cat > $CPDTEMPLATES/ibm-iis-scc.yaml <<EOF
allowHostDirVolumePlugin: false
allowHostIPC: false
allowHostNetwork: false
allowHostPID: false
allowHostPorts: false
allowPrivilegeEscalation: true
allowPrivilegedContainer: false
allowedCapabilities: null
apiVersion: security.openshift.io/v1
defaultAddCapabilities: null
fsGroup:
  type: RunAsAny
kind: SecurityContextConstraints
metadata:
  annotations:
    kubernetes.io/description: WKC/IIS provides all features of the restricted SCC
      but runs as user 10032.
  name: wkc-iis-scc
readOnlyRootFilesystem: false
requiredDropCapabilities:
- KILL
- MKNOD
- SETUID
- SETGID
runAsUser:
  type: MustRunAs
  uid: 10032
seLinuxContext:
  type: MustRunAs
supplementalGroups:
  type: RunAsAny
volumes:
- configMap
- downwardAPI
- emptyDir
- persistentVolumeClaim
- projected
- secret
users:
- system:serviceaccount:$CPDNAMESPACE:wkc-iis-sa
EOF"

runuser -l $SUDOUSER -c "cat > $CPDTEMPLATES/ibm-iis-sub.yaml <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ibm-cpd-iis-operator
  namespace: $CPDNAMESPACE
spec: 
  channel: $VERSION
  installPlanApproval: Automatic 
  name: ibm-cpd-iis
  source: ibm-operator-catalog
  sourceNamespace: openshift-marketplace
EOF"

runuser -l $SUDOUSER -c "oc create -f $CPDTEMPLATES/ibm-iis-scc.yaml"
runuser -l $SUDOUSER -c "echo 'Sleeping for 1m' "
runuser -l $SUDOUSER -c "sleep 1m"

# Check ibm-cpd-iis-operator pod status

runuser -l $SUDOUSER -c "oc create -f $CPDTEMPLATES/ibm-iis-sub.yaml"

runuser -l $SUDOUSER -c "echo 'Sleeping 2m for operator to install'"
runuser -l $SUDOUSER -c "sleep 2m"


podname="ibm-cpd-iis-operator"
name_space=$OPERATORNAMESPACE
status="unknown"
while [ "$status" != "Running" ]
do
  pod_name=$(oc get pods -n $name_space | grep $podname | awk '{print $1}' )
  ready_status=$(oc get pods -n $name_space $pod_name  --no-headers | awk '{print $2}')
  pod_status=$(oc get pods -n $name_space $pod_name --no-headers | awk '{print $3}')
  echo $pod_name State - $ready_status, podstatus - $pod_status
  if [ "$ready_status" == "1/1" ] && [ "$pod_status" == "Running" ]
  then 
  status="Running"
  else
  status="starting"
  sleep 10 
  fi
  echo "$pod_name is $status"
done

## Creating ibm-iis cr

if [[ $STORAGEOPTION == "nfs" ]];then 

    runuser -l $SUDOUSER -c "oc project $CPDNAMESPACE; oc create -f $CPDTEMPLATES/ibm-iis-nfs-cr.yaml"

elif [[ $STORAGEOPTION == "ocs" ]];then 

    runuser -l $SUDOUSER -c "oc project $CPDNAMESPACE; oc create -f $CPDTEMPLATES/ibm-iis-ocs-cr.yaml"
fi

# Check CR Status

SERVICE="IIS"
CRNAME="iis-cr"
SERVICE_STATUS="iisStatus"

STATUS=$(oc get $SERVICE $CRNAME -n $CPDNAMESPACE -o json | jq .status.$SERVICE_STATUS | xargs) 

while  [[ ! $STATUS =~ ^(Completed|Complete)$ ]]; do
    echo "$CRNAME is Installing!!!!"
    sleep 60 
    STATUS=$(oc get $SERVICE $CRNAME -n $CPDNAMESPACE -o json | jq .status.$SERVICE_STATUS | xargs) 
    if [ "$STATUS" == "Failed" ]
    then
        echo "**********************************"
        echo "$CRNAME Installation Failed!!!!"
        echo "**********************************"
        exit
    fi
done 
echo "*************************************"
echo "$CRNAME Installation Finished!!!!"
echo "*************************************"

echo "$(date) - ############### Script Complete #############"