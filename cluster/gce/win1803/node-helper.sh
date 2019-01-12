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

#echo "PJH: TODO: is cluster/gce/gci/helper.sh needed for Windows?"
source "${KUBE_ROOT}/cluster/gce/gci/helper.sh"

function get-windows-version {
  if [[ "${WINDOWS_NODE_OS_DISTRIBUTION}" == "win1709" ]]; then
    echo "1709"
  else
    echo "1803"
  fi
}

function get-windows-node-instance-metadata-from-file {
  local win_version="$(get-windows-version)"
  local metadata=""
  #metadata+="cluster-location=${KUBE_TEMP}/cluster-location.txt,"
  #metadata+="configure-sh=${KUBE_ROOT}/cluster/gce/gci/configure.sh,"
  metadata+="cluster-name=${KUBE_TEMP}/cluster-name.txt,"
  metadata+="kube-env=${KUBE_TEMP}/windows-node-kube-env.yaml,"
  metadata+="kubelet-config=${KUBE_TEMP}/windows-node-kubelet-config.yaml,"
  # https://cloud.google.com/compute/docs/startupscript#startupscriptlocalfile
  # https://cloud.google.com/compute/docs/startupscript#providing_a_startup_script_for_windows_instances
  # To get startup script output run "gcloud compute instances
  # get-serial-port-output <instance>" from the location where you're running
  # kube-up.
  metadata+="windows-startup-script-ps1=${KUBE_ROOT}/cluster/gce/win${win_version}/configure.ps1,"
  metadata+="common-psm1=${KUBE_ROOT}/cluster/gce/win${win_version}/common.psm1,"
  metadata+="install-ssh-psm1=${KUBE_ROOT}/cluster/gce/win${win_version}/install-ssh.psm1,"
  metadata+="install-logging-agent-psm1=${KUBE_ROOT}/cluster/gce/win${win_version}/install-logging-agent.psm1,"
  metadata+="prepull-images-psm1=${KUBE_ROOT}/cluster/gce/win${win_version}/prepull-images.psm1,"
  metadata+="k8s-node-setup-psm1=${KUBE_ROOT}/cluster/gce/win${win_version}/k8s-node-setup.psm1,"
  metadata+="${NODE_EXTRA_METADATA}"
  echo "${metadata}"
}

function get-windows-node-instance-metadata {
  local win_version="$(get-windows-version)"
  local metadata=""
  metadata+="serial-port-enable=1,"
  metadata+="win-version=${win_version},"
  # TODO(pjh): check how KUBE_VERSION is set - does it make sense to use for
  # downloading the kubernetes binaries on the node?
  #metadata+="k8s-version=v1.12.0"
  metadata+="k8s-version=${KUBE_VERSION:-v1.13.2},"
  #metadata+="pod-cidr=${TODO_POD_CIDR},"
  metadata+="github-repo=${GITHUB_REPO},"
  metadata+="github-branch=${GITHUB_BRANCH}"
  echo "${metadata}"
}

# $1: template name (required).
function create-windows-node-instance-template {
  local template_name="$1"
  echo "PJH: TODO: what is ensure-gci-metadata-files? Fork it or remove it for windows."
  ensure-gci-metadata-files
  create-node-template "${template_name}" "${scope_flags[*]}" "$(get-windows-node-instance-metadata-from-file)" "$(get-windows-node-instance-metadata)" "windows"
}
