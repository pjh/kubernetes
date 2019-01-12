# Copyright 2019 The Kubernetes Authors.
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

<#
.SYNOPSIS
  Library for installing and starting the Stackdriver logging agent.

.NOTES
  This module depends on common.psm1.
#>

$STACKDRIVER_ROOT = 'C:\Program Files (x86)\Stackdriver'

Import-Module -Force C:\common.psm1

# Install and start the Stackdriver logging agent according to
#   https://cloud.google.com/logging/docs/agent/installation
# TODO: Update to a newer Stackdriver agent once it is released to support
# kubernetes metadata properly. The current version does not recognizes the
# local resource key "logging.googleapis.com/local_resource_id", and fails to
# label namespace, pod and container names on the logs.
function InstallAndStart-LoggingAgent {
  # Remove the existing storage.json file if it exists. This is a workaround
  # for the bug where the logging agent cannot start up if the file is
  # corrupted.
  Remove-Item `
      -Force `
      -ErrorAction Ignore `
      ("$STACKDRIVER_ROOT\LoggingAgent\Main\pos\winevtlog.pos\worker0\" +
       "storage.json")

  if (Test-Path $STACKDRIVER_ROOT) {
    # Note: we should reinstall the Stackdriver agent if $REDO_STEPS is true
    # here, but we don't know how to run the installer without it prompting
    # when Stackdriver is already installed. I dumped the strings in the
    # installer binary and searched for flags to do this but found nothing. Oh
    # well.
    Log-Output ("Skip: $STACKDRIVER_ROOT is already present, assuming that " +
                "Stackdriver logging agent is already installed")
    # Restart-Service restarts a running service or starts a not-running
    # service.
    Restart-Service StackdriverLogging
    return
  }

  # TODO: Need to either skip or ensure the installation will not stall when
  # the machine restarts.
  Log-Output 'Install Stackdriver...'
  # Create a temporary directory for download.
  New-Item 'C:\stackdriver_tmp' -ItemType 'directory' -Force

  # Download the agent.
  $url = ("https://dl.google.com/cloudagents/windows/StackdriverLogging-v1-8.exe")
  $ProgressPreference = 'SilentlyContinue'
  Invoke-Webrequest $url -OutFile C:\stackdriver_tmp\StackdriverLogging-v1-8.exe

  # Start the installer silently. This automatically starts the
  # "StackdriverLogging" service.
  Start-Process 'C:\stackdriver_tmp\StackdriverLogging-v1-8.exe' `
      -ArgumentList "/S" `
      -Wait

  # Install additional plugins required to parse container logs.
  Start-Process "$STACKDRIVER_ROOT\LoggingAgent\Main\bin\fluent-gem" `
      -ArgumentList "install","fluent-plugin-record-reformer" `
      -Wait

  # Create a configuration file for kubernetes containers.
  # The config.d directory should have already been created automatically, but
  # try creating again just in case.
  New-Item "$STACKDRIVER_ROOT\LoggingAgent\config.d" `
      -ItemType 'directory' `
      -Force
  $FLUENTD_CONFIG | Out-File `
      -FilePath "$STACKDRIVER_ROOT\LoggingAgent\config.d\k8s_containers.conf" `
      -Encoding ASCII

  # Restart the service to pick up the new configurations.
  Restart-Service StackdriverLogging

  # Remove the temporary directory.
  Remove-Item -Force -Recurse 'C:\stackdriver_tmp'
}

# TODO:
#   - Collect kubelet/kube-proxy logs.
#   - Add tag for kubernetes node name.
$FLUENTD_CONFIG = @'
# This configuration file for Fluentd is used
# to watch changes to kubernetes container logs in the 
# directory /var/lib/docker/containers/ and submit the log records to Google
# Cloud Logging using the cloud-logging plugin.
#
# Example
# =======
# A line in the Docker log file might look like this JSON:
#
# {"log":"2014/09/25 21:15:03 Got request with path wombat\\n",
#  "stream":"stderr",
#   "time":"2014-09-25T21:15:03.499185026Z"}
#
# The original tag is derived from the log file's location.
# For example a Docker container's logs might be in the directory:
#  /var/lib/docker/containers/997599971ee6366d4a5920d25b79286ad45ff37a74494f262e3bc98d909d0a7b
# and in the file:
#  997599971ee6366d4a5920d25b79286ad45ff37a74494f262e3bc98d909d0a7b-json.log
# where 997599971ee6... is the Docker ID of the running container.
# The Kubernetes kubelet makes a symbolic link to this file on the host
# machine in the /var/log/containers directory which includes the pod name,
# the namespace name and the Kubernetes container name:
#    synthetic-logger-0.25lps-pod_default_synth-lgr-997599971ee6366d4a5920d25b79286ad45ff37a74494f262e3bc98d909d0a7b.log
#    ->
#    /var/lib/docker/containers/997599971ee6366d4a5920d25b79286ad45ff37a74494f262e3bc98d909d0a7b/997599971ee6366d4a5920d25b79286ad45ff37a74494f262e3bc98d909d0a7b-json.log
# The /var/log directory on the host is mapped to the /var/log directory in the container
# running this instance of Fluentd and we end up collecting the file:
#   /var/log/containers/synthetic-logger-0.25lps-pod_default_synth-lgr-997599971ee6366d4a5920d25b79286ad45ff37a74494f262e3bc98d909d0a7b.log
# This results in the tag:
#  var.log.containers.synthetic-logger-0.25lps-pod_default_synth-lgr-997599971ee6366d4a5920d25b79286ad45ff37a74494f262e3bc98d909d0a7b.log
# where 'synthetic-logger-0.25lps-pod' is the pod name, 'default' is the
# namespace name, 'synth-lgr' is the container name and '997599971ee6..' is
# the container ID.
# The record reformer is used to extract pod_name, namespace_name and
# container_name from the tag and set them in a local_resource_id in the
# format of:
# 'k8s_container.<NAMESPACE_NAME>.<POD_NAME>.<CONTAINER_NAME>'.
# The reformer also changes the tags to 'stderr' or 'stdout' based on the
# value of 'stream'.
# local_resource_id is later used by google_cloud plugin to determine the
# monitored resource to ingest logs against.

# Json Log Example:
# {"log":"[info:2016-02-16T16:04:05.930-08:00] Some log text here\n","stream":"stdout","time":"2016-02-17T00:04:05.931087621Z"}
# TODO: Support CRI log format, which requires the multi_format plugin.
<source>
  @type tail
  path /var/log/containers/*.log
  pos_file /var/log/gcp-containers.log.pos
  # Tags at this point are in the format of:
  # reform.var.log.containers.<POD_NAME>_<NAMESPACE_NAME>_<CONTAINER_NAME>-<CONTAINER_ID>.log
  tag reform.*
  format json
  time_key time
  time_format %Y-%m-%dT%H:%M:%S.%NZ
  read_from_head true
</source>

<match reform.**>
  @type record_reformer
  enable_ruby true
  <record>
    # Extract local_resource_id from tag for 'k8s_container' monitored
    # resource. The format is:
    # 'k8s_container.<namespace_name>.<pod_name>.<container_name>'.
    "logging.googleapis.com/local_resource_id" ${"k8s_container.#{tag_suffix[4].rpartition('.')[0].split('_')[1]}.#{tag_suffix[4].rpartition('.')[0].split('_')[0]}.#{tag_suffix[4].rpartition('.')[0].split('_')[2].rpartition('-')[0]}"}
    # Rename the field 'log' to a more generic field 'message'. This way the
    # fluent-plugin-google-cloud knows to flatten the field as textPayload
    # instead of jsonPayload after extracting 'time', 'severity' and
    # 'stream' from the record.
    message ${record['log']}
    # If 'severity' is not set, assume stderr is ERROR and stdout is INFO.
    severity ${record['severity'] || if record['stream'] == 'stderr' then 'ERROR' else 'INFO' end}
  </record>
  tag ${if record['stream'] == 'stderr' then 'raw.stderr' else 'raw.stdout' end}
  remove_keys stream,log
</match>
'@

Export-ModuleMember -Function *-*
