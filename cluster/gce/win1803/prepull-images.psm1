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

<#
.SYNOPSIS
  Library for pre-pulling E2E test container images on Windows nodes.
#>

# Pulls the container images used for the Windows end-to-end tests.
function Prepull-E2EImages {
  $images = @(
    "e2eteam/busybox:1.29"
    "e2eteam/dnsutils:1.1"
    "e2eteam/entrypoint-tester:1.0"
    "e2eteam/gb-frontend:v6"
    "e2eteam/gb-redisslave:v3"
    "e2eteam/hostexec:1.1"
    "e2eteam/jessie-dnsutils:1.0"
    "e2eteam/mounttest:1.0"
    "e2eteam/netexec:1.1"
    "e2eteam/nettest:1.0"
    "e2eteam/nginx:1.14-alpine"
    "e2eteam/pause:3.1"
    "e2eteam/porter:1.0"
    "e2eteam/redis:1.0"
    "e2eteam/serve-hostname:1.1"
    "e2eteam/test-webserver:1.0"
  )
  ForEach ($img in $images) {
    docker pull $img
  }
}

# Export all public functions:
Export-ModuleMember -Function *-*
