#!/bin/bash
#
# This file is part of the KubeVirt project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Copyright 2017 Red Hat, Inc.
#

# CI considerations: $TARGET is used by the jenkins build, to distinguish what to test
# Currently considered $TARGET values:
#     vagrant-dev: Runs all functional tests on a development vagrant setup (deprecated)
#     vagrant-release: Runs all possible functional tests on a release deployment in vagrant (deprecated)
#     kubernetes-dev: Runs all functional tests on a development kubernetes setup
#     kubernetes-release: Runs all functional tests on a release kubernetes setup
#     openshift-release: Runs all functional tests on a release openshift setup
#     TODO: vagrant-tagged-release: Runs all possible functional tests on a release deployment in vagrant on a tagged release

set -ex

export WORKSPACE="${WORKSPACE:-$PWD}"

if [[ $TARGET =~ openshift-.* ]]; then
  if [[ $TARGET =~ .*-crio-.* ]]; then
    export KUBEVIRT_PROVIDER="os-3.10.0-crio"
  else
    export KUBEVIRT_PROVIDER="os-3.10.0"
  fi
elif [[ $TARGET =~ .*-1.10.4-.* ]]; then
  export KUBEVIRT_PROVIDER="k8s-1.10.4"
else
  export KUBEVIRT_PROVIDER="k8s-1.11.0"
fi

export KUBEVIRT_NUM_NODES=2
export WINDOWS_NFS_DIR=${WINDOWS_NFS_DIR:-/var/lib/stdci/shared/kubevirt-images/windows2016}
export WINDOWS_LOCK_PATH=${WINDOWS_LOCK_PATH:-/var/lib/stdci/shared/download_windows_image.lock}

wait_for_windows_lock() {
  local max_lock_attempts=60
  local lock_wait_interval=60

  for ((i = 0; i < $max_lock_attempts; i++)); do
      if (set -o noclobber; > $WINDOWS_LOCK_PATH) 2> /dev/null; then
          echo "Acquired lock: $WINDOWS_LOCK_PATH"
          return
      fi
      sleep $lock_wait_interval
  done
  echo "Timed out waiting for lock: $WINDOWS_LOCK_PATH" >&2
  exit 1
}

release_windows_lock() {      
  if [[ -e "$WINDOWS_LOCK_PATH" ]]; then
      rm -f "$WINDOWS_LOCK_PATH"
      echo "Released lock: $WINDOWS_LOCK_PATH"
  fi
}

if [[ $TARGET =~ windows.* ]]; then
  # Create images directory
  if [[ ! -d $WINDOWS_NFS_DIR ]]; then
    mkdir -p $WINDOWS_NFS_DIR
  fi

  # Download windows image
  if wait_for_windows_lock; then
    if [[ ! -f "$WINDOWS_NFS_DIR/disk.img" ]]; then
      curl http://templates.ovirt.org/kubevirt/win01.img > $WINDOWS_NFS_DIR/disk.img
    fi
    release_windows_lock
  else
    exit 1
  fi
fi

kubectl() { cluster/kubectl.sh "$@"; }

export NAMESPACE="${NAMESPACE:-kube-system}"

# Make sure that the VM is properly shut down on exit
trap '{ release_windows_lock; make cluster-down; }' EXIT SIGINT SIGTERM SIGSTOP

make cluster-down
make cluster-up

# Wait for nodes to become ready
set +e
kubectl get nodes --no-headers
kubectl_rc=$?
while [ $kubectl_rc -ne 0 ] || [ -n "$(kubectl get nodes --no-headers | grep NotReady)" ]; do
    echo "Waiting for all nodes to become ready ..."
    kubectl get nodes --no-headers
    kubectl_rc=$?
    sleep 10
done
set -e

echo "Nodes are ready:"
kubectl get nodes

make cluster-sync

# OpenShift is running important containers under default namespace
namespaces=(kube-system default)
if [[ $NAMESPACE != "kube-system" ]]; then
  namespaces+=($NAMESPACE)
fi

timeout=300
sample=30

for i in ${namespaces[@]}; do
  # Wait until kubevirt pods are running
  current_time=0
  while [ -n "$(kubectl get pods -n $i --no-headers | grep -v Running)" ]; do
    echo "Waiting for kubevirt pods to enter the Running state ..."
    kubectl get pods -n $i --no-headers | >&2 grep -v Running || true
    sleep $sample

    current_time=$((current_time + sample))
    if [ $current_time -gt $timeout ]; then
      exit 1
    fi
  done

  # Make sure all containers are ready
  current_time=0
  while [ -n "$(kubectl get pods -n $i -o'custom-columns=status:status.containerStatuses[*].ready' --no-headers | grep false)" ]; do
    echo "Waiting for KubeVirt containers to become ready ..."
    kubectl get pods -n $i -o'custom-columns=status:status.containerStatuses[*].ready' --no-headers | grep false || true
    sleep $sample

    current_time=$((current_time + sample))
    if [ $current_time -gt $timeout ]; then
      exit 1
    fi
  done
  kubectl get pods -n $i
done

kubectl version

ginko_params="--ginkgo.noColor --junit-output=$WORKSPACE/junit.xml"

# Prepare PV for windows testing
if [[ $TARGET =~ windows.* ]]; then
  kubectl create -f - <<EOF
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: disk-windows
  labels:
    kubevirt.io/test: "windows"
spec:
  capacity:
    storage: 30Gi
  accessModes:
    - ReadWriteOnce
  nfs:
    server: "nfs"
    path: /
  storageClassName: local
EOF
  # Run only windows tests
  ginko_params="$ginko_params --ginkgo.focus=Windows"
fi

# Run functional tests
FUNC_TEST_ARGS=$ginko_params make functest
