#!/bin/bash

# Copyright 2018 The Kubernetes Authors.
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

# A small smoke test to run against a just-deployed kube-up cluster with Windows
# nodes. Performs checks such as:
#   1) Verifying that all Windows nodes have status Ready.
#   2) Verifying that no system pods are attempting to run on Windows nodes.
#   3) Verifying pairwise connectivity between most of the following: Linux
#      pods, Windows pods, K8s services, and the Internet.
#   4) Verifying that basic DNS resolution works in Windows pods.
#
# This script assumes that it is run from the root of the kubernetes repository
# and that kubectl is present at client/bin/kubectl.
#
# TODOs:
#   - Implement the node-to-pod checks.
#   - Capture stdout for each command to a file and only print it when the test
#     fails.
#   - Move copy-pasted code into reusable functions.
#   - Continue running all checks after one fails.
#   - Test service connectivity by running a test pod with an http server and
#     exposing it as a service (rather than curl-ing from existing system
#     services that don't serve http requests).
#   - Add test retries for transient errors, such as:
#     "error: unable to upgrade connection: Authorization error
#     (user=kube-apiserver, verb=create, resource=nodes, subresource=proxy)"

# Override this to use a different kubectl binary.
kubectl=kubectl
linux_deployment_timeout=60
windows_deployment_timeout=120
output_file=/tmp/k8s-smoke-test.out

function check_windows_nodes_are_ready {
  # kubectl filtering is the worst.
  statuses=$(${kubectl} get nodes -l beta.kubernetes.io/os=windows \
    -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}')
  for status in $statuses; do
    if [[ $status == "False" ]]; then
      echo "ERROR: some Windows node has status != Ready"
      echo "kubectl get nodes -l beta.kubernetes.io/os=windows"
      ${kubectl} get nodes -l beta.kubernetes.io/os=windows
      exit 1
    fi
  done
  echo "Verified that all Windows nodes have status Ready"
}

function check_no_system_pods_on_windows_nodes {
  windows_system_pods=$(${kubectl} get pods --namespace kube-system \
    -o wide | egrep "Pending|windows" | wc -w)
  if [[ $windows_system_pods -ne 0 ]]; then
    echo "ERROR: there are kube-system pods trying to run on Windows nodes"
    echo "kubectl get pods --namespace kube-system -o wide"
    ${kubectl} get pods --namespace kube-system -o wide
    exit 1
  fi
  echo "Verified that all system pods are running on Linux nodes"
}

function run_iis_deployment {
  echo "Writing example deployment to windows-iis-deployment.yaml"
  cat <<EOF > windows-iis-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: iis-deployment
  labels:
    app: iis
spec:
  replicas: 2
  selector:
    matchLabels:
      app: iis
  template:
    metadata:
      labels:
        app: iis
    spec:
      containers:
      - name: iis-servercore
        image: microsoft/iis:windowsservercore-1803
      nodeSelector:
        beta.kubernetes.io/os: windows
EOF

  ${kubectl} create -f windows-iis-deployment.yaml

  # It may take a while for the IIS pods to start running because the IIS
  # container (based on the large windowsservercore container) must be fetched
  # on the Windows nodes.
  timeout=120
  while [[ $timeout -gt 0 ]]; do
    echo "Waiting for IIS pods to become Ready"
    statuses=$(${kubectl} get pods -l app=iis \
      -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' \
      | grep "False" | wc -w)
    if [[ $statuses -eq 0 ]]; then
      break
    else
      sleep 10
      let timeout=timeout-10
    fi
  done

  if [[ $timeout -gt 0 ]]; then
    echo "All IIS pods became Ready"
  else
    echo "ERROR: Not all IIS pods became Ready"
    echo "kubectl get pods -l app=iis"
    ${kubectl} get pods -l app=iis
    ${kubectl} delete deployment iis-deployment
    exit 1
  fi

  echo "Removing iis-deployment"
  ${kubectl} delete deployment iis-deployment
}

linux_webserver_deployment=linux-nginx
linux_webserver_pod_label=nginx

function deploy_linux_webserver_pod {
  echo "Writing example deployment to $linux_webserver_deployment.yaml"
  cat <<EOF > $linux_webserver_deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $linux_webserver_deployment
  labels:
    app: $linux_webserver_pod_label
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $linux_webserver_pod_label
  template:
    metadata:
      labels:
        app: $linux_webserver_pod_label
    spec:
      containers:
      - name: nginx
        image: nginx:1.7.9
      nodeSelector:
        beta.kubernetes.io/os: linux
EOF

  ${kubectl} create -f $linux_webserver_deployment.yaml
  if [[ $? -ne 0 ]]; then
    exit $?
  fi

  timeout=$linux_deployment_timeout
  while [[ $timeout -gt 0 ]]; do
    echo "Waiting for Linux $linux_webserver_pod_label pods to become Ready"
    statuses=$(${kubectl} get pods -l app=$linux_webserver_pod_label \
      -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' \
      | grep "False" | wc -w)
    if [[ $statuses -eq 0 ]]; then
      break
    else
      sleep 10
      let timeout=timeout-10
    fi
  done

  if [[ $timeout -gt 0 ]]; then
    echo "All $linux_webserver_pod_label pods became Ready"
  else
    echo "ERROR: Not all $linux_webserver_pod_label pods became Ready"
    echo "kubectl get pods -l app=$linux_webserver_pod_label"
    ${kubectl} get pods -l app=$linux_webserver_pod_label
    cleanup_deployments
    exit 1
  fi
}

# Returns the name of an arbitrary Linux webserver pod.
function get_linux_webserver_pod_name {
  $kubectl get pods -l app=$linux_webserver_pod_label \
    -o jsonpath='{.items[0].metadata.name}'
}

# Returns the IP address of an arbitrary Linux webserver pod.
function get_linux_webserver_pod_ip {
  $kubectl get pods -l app=$linux_webserver_pod_label \
    -o jsonpath='{.items[0].status.podIP}'
}

function undeploy_linux_webserver_pod {
  ${kubectl} delete deployment $linux_webserver_deployment
}

linux_command_deployment=linux-ubuntu
linux_command_pod_label=ubuntu

function deploy_linux_command_pod {
  echo "Writing example deployment to $linux_command_deployment.yaml"
  cat <<EOF > $linux_command_deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $linux_command_deployment
  labels:
    app: $linux_command_pod_label
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $linux_command_pod_label
  template:
    metadata:
      labels:
        app: $linux_command_pod_label
    spec:
      containers:
      - name: ubuntu
        image: ubuntu
        command: ["sleep", "123456"]
      nodeSelector:
        beta.kubernetes.io/os: linux
EOF

  ${kubectl} create -f $linux_command_deployment.yaml
  if [[ $? -ne 0 ]]; then
    exit $?
  fi

  timeout=$linux_deployment_timeout
  while [[ $timeout -gt 0 ]]; do
    echo "Waiting for Linux $linux_command_pod_label pods to become Ready"
    statuses=$(${kubectl} get pods -l app=$linux_command_pod_label \
      -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' \
      | grep "False" | wc -w)
    if [[ $statuses -eq 0 ]]; then
      break
    else
      sleep 10
      let timeout=timeout-10
    fi
  done

  if [[ $timeout -gt 0 ]]; then
    echo "All $linux_command_pod_label pods became Ready"
  else
    echo "ERROR: Not all $linux_command_pod_label pods became Ready"
    echo "kubectl get pods -l app=$linux_command_pod_label"
    ${kubectl} get pods -l app=$linux_command_pod_label
    cleanup_deployments
    exit 1
  fi
}

# Returns the name of an arbitrary Linux command pod.
function get_linux_command_pod_name {
  $kubectl get pods -l app=$linux_command_pod_label \
    -o jsonpath='{.items[0].metadata.name}'
}

# Returns the IP address of an arbitrary Linux command pod.
function get_linux_command_pod_ip {
  $kubectl get pods -l app=$linux_command_pod_label \
    -o jsonpath='{.items[0].status.podIP}'
}

# Installs test executables (ping, curl) in the Linux command pod.
# NOTE: this assumes that there is only one Linux "command pod". TODO fix this.
function prepare_linux_command_pod {
  local linux_command_pod="$(get_linux_command_pod_name)"
  echo "Installing test utilities in Linux command pod, may take a minute"
  $kubectl exec $linux_command_pod -- apt-get update > /dev/null
  $kubectl exec $linux_command_pod -- \
    apt-get install -y iputils-ping curl > /dev/null
}

function undeploy_linux_command_pod {
  ${kubectl} delete deployment $linux_command_deployment
}

windows_webserver_deployment=windows-nettest
windows_webserver_pod_label=nettest

function deploy_windows_webserver_pod {
  echo "Writing example deployment to $windows_webserver_deployment.yaml"
  cat <<EOF > $windows_webserver_deployment.yaml
# You can run a pod with the e2eteam/nettest:1.0 image (which should listen on
# <podIP>:8080) and create another pod on a different node (linux would be
# easier) to curl the http server:
#   curl http://<pod_ip>:8080/read
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $windows_webserver_deployment
  labels:
    app: $windows_webserver_pod_label
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $windows_webserver_pod_label
  template:
    metadata:
      labels:
        app: $windows_webserver_pod_label
    spec:
      containers:
      - name: nettest
        image: e2eteam/nettest:1.0
      nodeSelector:
        beta.kubernetes.io/os: windows
EOF

  ${kubectl} create -f $windows_webserver_deployment.yaml
  if [[ $? -ne 0 ]]; then
    exit $?
  fi

  timeout=$windows_deployment_timeout
  while [[ $timeout -gt 0 ]]; do
    echo "Waiting for Windows $windows_webserver_pod_label pods to become Ready"
    statuses=$(${kubectl} get pods -l app=$windows_webserver_pod_label \
      -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' \
      | grep "False" | wc -w)
    if [[ $statuses -eq 0 ]]; then
      break
    else
      sleep 10
      let timeout=timeout-10
    fi
  done

  if [[ $timeout -gt 0 ]]; then
    echo "All $windows_webserver_pod_label pods became Ready"
  else
    echo "ERROR: Not all $windows_webserver_pod_label pods became Ready"
    echo "kubectl get pods -l app=$windows_webserver_pod_label"
    ${kubectl} get pods -l app=$windows_webserver_pod_label
    cleanup_deployments
    exit 1
  fi
}

function get_windows_webserver_pod_name {
  $kubectl get pods -l app=$windows_webserver_pod_label \
    -o jsonpath='{.items[0].metadata.name}'
}

function get_windows_webserver_pod_ip {
  $kubectl get pods -l app=$windows_webserver_pod_label \
    -o jsonpath='{.items[0].status.podIP}'
}

function undeploy_windows_webserver_pod {
  ${kubectl} delete deployment $windows_webserver_deployment
}

windows_command_deployment=windows-powershell
windows_command_pod_label=powershell

function deploy_windows_command_pod {
  echo "Writing example deployment to $windows_command_deployment.yaml"
  cat <<EOF > $windows_command_deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $windows_command_deployment
  labels:
    app: $windows_command_pod_label
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $windows_command_pod_label
  template:
    metadata:
      labels:
        app: $windows_command_pod_label
    spec:
      containers:
      - name: nettest
        image: e2eteam/nettest:1.0
      nodeSelector:
        beta.kubernetes.io/os: windows
EOF

  ${kubectl} create -f $windows_command_deployment.yaml
  if [[ $? -ne 0 ]]; then
    exit $?
  fi

  timeout=$windows_deployment_timeout
  while [[ $timeout -gt 0 ]]; do
    echo "Waiting for Windows $windows_command_pod_label pods to become Ready"
    statuses=$(${kubectl} get pods -l app=$windows_command_pod_label \
      -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' \
      | grep "False" | wc -w)
    if [[ $statuses -eq 0 ]]; then
      break
    else
      sleep 10
      let timeout=timeout-10
    fi
  done

  if [[ $timeout -gt 0 ]]; then
    echo "All $windows_command_pod_label pods became Ready"
  else
    echo "ERROR: Not all $windows_command_pod_label pods became Ready"
    echo "kubectl get pods -l app=$windows_command_pod_label"
    ${kubectl} get pods -l app=$windows_command_pod_label
    cleanup_deployments
    exit 1
  fi
}

function get_windows_command_pod_name {
  $kubectl get pods -l app=$windows_command_pod_label \
    -o jsonpath='{.items[0].metadata.name}'
}

function get_windows_command_pod_ip {
  $kubectl get pods -l app=$windows_command_pod_label \
    -o jsonpath='{.items[0].status.podIP}'
}

function undeploy_windows_command_pod {
  ${kubectl} delete deployment $windows_command_deployment
}

function test_linux_node_to_linux_pod {
  echo "TODO: ${FUNCNAME[0]}"
}

function test_linux_node_to_windows_pod {
  echo "TODO: ${FUNCNAME[0]}"
}

function test_linux_pod_to_linux_pod {
  echo "TEST: ${FUNCNAME[0]}"
  local linux_command_pod="$(get_linux_command_pod_name)"
  local linux_webserver_pod_ip="$(get_linux_webserver_pod_ip)"

  $kubectl exec $linux_command_pod -- curl -m 20 \
    http://$linux_webserver_pod_ip &> $output_file
  if [[ $? -ne 0 ]]; then
    cleanup_deployments
    echo "Failing output:\n$(cat $output_file)"
    echo "FAILED: ${FUNCNAME[0]}"
    exit $?
  fi
}

# TODO(pjh): this test flakily fails on brand-new clusters, not sure why.
# % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
#                                Dload  Upload   Total   Spent    Left  Speed
# 0     0    0     0    0     0      0      0 --:--:-- --:--:-- --:--:--     0
# curl: (6) Could not resolve host:
# command terminated with exit code 6
function test_linux_pod_to_windows_pod {
  echo "TEST: ${FUNCNAME[0]}"
  local linux_command_pod="$(get_linux_command_pod_name)"
  local windows_webserver_pod_ip="$(get_windows_webserver_pod_ip)"

  $kubectl exec $linux_command_pod -- curl -m 20 \
    http://$windows_webserver_pod_ip:8080/read &> $output_file
  if [[ $? -ne 0 ]]; then
    cleanup_deployments
    echo "Failing output:\n$(cat $output_file)"
    echo "FAILED: ${FUNCNAME[0]}"
    echo "This test seems to be flaky. TODO: investigate."
    exit $?
  fi
}

function test_linux_pod_to_internet {
  echo "TEST: ${FUNCNAME[0]}"
  local linux_command_pod="$(get_linux_command_pod_name)"
  local internet_ip="8.8.8.8"  # Google DNS

  # This is expected to return 404 (not found).
  $kubectl exec $linux_command_pod -- curl -m 20 \
    http://$internet_ip > $output_file
  if [[ $? -ne 0 ]]; then
    cleanup_deployments
    echo "Failing output:\n$(cat $output_file)"
    echo "FAILED: ${FUNCNAME[0]}"
    exit $?
  fi
}

function test_linux_pod_to_k8s_service {
  echo "TEST: ${FUNCNAME[0]}"
  local linux_command_pod="$(get_linux_command_pod_name)"
  local service="heapster"
  local service_ip=$($kubectl get service --namespace kube-system $service \
    -o jsonpath='{.spec.clusterIP}')
  local service_port=$($kubectl get service --namespace kube-system $service \
    -o jsonpath='{.spec.ports[?(@.protocol=="TCP")].port}')
  echo "curl-ing $service address from Linux pod: $service_ip:$service_port"

  # curl-ing the heapster service results in an expected 404 response code. The
  # curl command does not set a failure return code in this case.
  $kubectl exec $linux_command_pod -- \
    curl -m 20 http://$service_ip:$service_port &> $output_file
  if [[ $? -ne 0 ]]; then
    cleanup_deployments
    echo "Failing output:\n$(cat $output_file)"
    echo "FAILED: ${FUNCNAME[0]}"
    exit $?
  fi
}

function test_windows_node_to_linux_pod {
  echo "TODO: ${FUNCNAME[0]}"
}

function test_windows_node_to_windows_pod {
  echo "TODO: ${FUNCNAME[0]}"
}

function test_windows_pod_to_linux_pod {
  echo "TEST: ${FUNCNAME[0]}"
  local windows_command_pod="$(get_windows_command_pod_name)"
  local linux_webserver_pod_ip="$(get_linux_webserver_pod_ip)"

  $kubectl exec $windows_command_pod -- powershell.exe \
    "curl -UseBasicParsing http://$linux_webserver_pod_ip" > $output_file
  if [[ $? -ne 0 ]]; then
    cleanup_deployments
    echo "Failing output:\n$(cat $output_file)"
    echo "FAILED: ${FUNCNAME[0]}"
    exit $?
  fi
}

function test_windows_pod_to_windows_pod {
  echo "TEST: ${FUNCNAME[0]}"
  local windows_command_pod="$(get_windows_command_pod_name)"
  local windows_webserver_pod_ip="$(get_windows_webserver_pod_ip)"

  $kubectl exec $windows_command_pod -- powershell.exe \
    "curl -UseBasicParsing http://$windows_webserver_pod_ip:8080/read" \
    > $output_file
  if [[ $? -ne 0 ]]; then
    cleanup_deployments
    echo "Failing output:\n$(cat $output_file)"
    echo "FAILED: ${FUNCNAME[0]}"
    exit $?
  fi
}

function test_windows_pod_to_internet {
  echo "TEST: ${FUNCNAME[0]}"
  local windows_command_pod="$(get_windows_command_pod_name)"
  local internet_ip="8.8.8.8"

  # This snippet tests Internet connectivity without depending on DNS by
  # attempting to curl Google's well-known DNS IP, 8.8.8.8. On success we expect
  # to get back a 404 status code; on failure the response object will have a
  # status code of 0 or some other HTTP code.
  $kubectl exec $windows_command_pod -- powershell.exe \
    "\$response = try { \`
       (curl -UseBasicParsing http://$internet_ip \`
          -ErrorAction Stop).BaseResponse \`
     } catch [System.Net.WebException] { \`
       \$_.Exception.Response \`
     }; \`
     \$statusCodeInt = [int]\$response.StatusCode; \`
     if (\$statusCodeInt -eq 404) { \`
       exit 0 \`
     } else { \`
       Write-Host \"curl $internet_ip got unexpected status code \$statusCodeInt\"
       exit 1 \`
     }" > $output_file
  if [[ $? -ne 0 ]]; then
    cleanup_deployments
    echo "Failing output:\n$(cat $output_file)"
    echo "FAILED: ${FUNCNAME[0]}"
    exit $?
  fi
}

function test_windows_pod_to_k8s_service {
  echo "TEST: ${FUNCNAME[0]}"
  local windows_command_pod="$(get_windows_command_pod_name)"
  local service="heapster"
  local service_ip=$($kubectl get service --namespace kube-system $service \
    -o jsonpath='{.spec.clusterIP}')
  local service_port=$($kubectl get service --namespace kube-system $service \
    -o jsonpath='{.spec.ports[?(@.protocol=="TCP")].port}')
  local service_address="$service_ip:$service_port"

  echo "curl-ing $service address from Windows pod: $service_address"
  # Performing a web request to the heapster service results in an expected 404
  # response; this code snippet filters out the expected 404 from other status
  # codes that indicate failure.
  $kubectl exec $windows_command_pod -- powershell.exe \
    "\$response = try { \`
       (curl -UseBasicParsing http://$service_address \`
          -ErrorAction Stop).BaseResponse \`
     } catch [System.Net.WebException] { \`
       \$_.Exception.Response \`
     }; \`
     \$statusCodeInt = [int]\$response.StatusCode; \`
     if (\$statusCodeInt -eq 404) { \`
       exit 0 \`
     } else { \`
       Write-Host \"curl $service_address got unexpected status code \$statusCodeInt\"
       exit 1 \`
     }" > $output_file
  if [[ $? -ne 0 ]]; then
    cleanup_deployments
    echo "Failing output:\n$(cat $output_file)"
    echo "FAILED: ${FUNCNAME[0]}"
    exit $?
  fi
}

function test_kube_dns_in_windows_pod {
  echo "TEST: ${FUNCNAME[0]}"
  local windows_command_pod="$(get_windows_command_pod_name)"
  local service="kube-dns"
  local service_ip=$($kubectl get service --namespace kube-system $service \
    -o jsonpath='{.spec.clusterIP}')

  $kubectl exec $windows_command_pod -- powershell.exe \
    "Resolve-DnsName www.bing.com -server $service_ip" > $output_file
  if [[ $? -ne 0 ]]; then
    cleanup_deployments
    echo "Failing output:\n$(cat $output_file)"
    echo "FAILED: ${FUNCNAME[0]}"
    exit $?
  fi
}

function test_dns_just_works_in_windows_pod {
  echo "TEST: ${FUNCNAME[0]}"
  local windows_command_pod="$(get_windows_command_pod_name)"

  $kubectl exec $windows_command_pod -- powershell.exe \
    "curl -UseBasicParsing http://www.bing.com" > $output_file
  if [[ $? -ne 0 ]]; then
    cleanup_deployments
    echo "Failing output:\n$(cat $output_file)"
    echo "FAILED: ${FUNCNAME[0]}"
    exit $?
  fi
}

function cleanup_deployments {
  undeploy_linux_webserver_pod
  undeploy_linux_command_pod
  undeploy_windows_webserver_pod
  undeploy_windows_command_pod
}

check_windows_nodes_are_ready
check_no_system_pods_on_windows_nodes
#run_iis_deployment

deploy_linux_webserver_pod
deploy_linux_command_pod
deploy_windows_webserver_pod
deploy_windows_command_pod
prepare_linux_command_pod
echo ""

test_linux_node_to_linux_pod
test_linux_node_to_windows_pod
test_linux_pod_to_linux_pod
test_linux_pod_to_windows_pod
test_linux_pod_to_k8s_service

# Note: test_windows_node_to_k8s_service is not supported at this time.
# https://docs.microsoft.com/en-us/virtualization/windowscontainers/kubernetes/common-problems#my-windows-node-cannot-access-my-services-using-the-service-ip
test_windows_node_to_linux_pod
test_windows_node_to_windows_pod
test_windows_pod_to_linux_pod
test_windows_pod_to_windows_pod
test_windows_pod_to_internet
test_windows_pod_to_k8s_service
test_kube_dns_in_windows_pod
test_dns_just_works_in_windows_pod
echo ""

cleanup_deployments
echo "All tests passed!"
exit 0
