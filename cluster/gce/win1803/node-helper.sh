#!/usr/bin/env bash

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

# A library of helper functions and constants for Windows nodes.

function get-windows-node-instance-metadata-from-file {
  local metadata=""
  metadata+="cluster-name=${KUBE_TEMP}/cluster-name.txt,"
  metadata+="kube-env=${KUBE_TEMP}/windows-node-kube-env.yaml,"
  metadata+="kubelet-config=${KUBE_TEMP}/windows-node-kubelet-config.yaml,"
  # https://cloud.google.com/compute/docs/startupscript#startupscriptlocalfile
  # https://cloud.google.com/compute/docs/startupscript#providing_a_startup_script_for_windows_instances
  # To get startup script output run "gcloud compute instances
  # get-serial-port-output <instance>" from the location where you're running
  # kube-up.
  metadata+="windows-startup-script-ps1=${KUBE_ROOT}/cluster/gce/${WINDOWS_NODE_OS_DISTRIBUTION}/configure.ps1,"
  metadata+="common-psm1=${KUBE_ROOT}/cluster/gce/${WINDOWS_NODE_OS_DISTRIBUTION}/common.psm1,"
  metadata+="install-ssh-psm1=${KUBE_ROOT}/cluster/gce/${WINDOWS_NODE_OS_DISTRIBUTION}/install-ssh.psm1,"
  metadata+="install-logging-agent-psm1=${KUBE_ROOT}/cluster/gce/${WINDOWS_NODE_OS_DISTRIBUTION}/install-logging-agent.psm1,"
  metadata+="prepull-images-psm1=${KUBE_ROOT}/cluster/gce/${WINDOWS_NODE_OS_DISTRIBUTION}/prepull-images.psm1,"
  metadata+="k8s-node-setup-psm1=${KUBE_ROOT}/cluster/gce/${WINDOWS_NODE_OS_DISTRIBUTION}/k8s-node-setup.psm1,"
  metadata+="${NODE_EXTRA_METADATA}"
  echo "${metadata}"
}

function get-windows-node-instance-metadata {
  local metadata=""
  metadata+="serial-port-enable=1,"
  metadata+="win-version=${WINDOWS_NODE_OS_DISTRIBUTION},"
  metadata+="k8s-version=${KUBE_VERSION:-v1.13.2},"
  metadata+="github-repo=${GITHUB_REPO},"
  metadata+="github-branch=${GITHUB_BRANCH}"
  echo "${metadata}"
}

# $1: template name (required).
function create-windows-node-instance-template {
  local template_name="$1"
  create-node-template "${template_name}" "${scope_flags[*]}" "$(get-windows-node-instance-metadata-from-file)" "$(get-windows-node-instance-metadata)" "windows"
}
