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
  Library for configuring Windows nodes and joining them to the cluster.

.DESCRIPTION
  Some portions copied / adapted from
  https://github.com/Microsoft/SDN/blob/master/Kubernetes/windows/start-kubelet.ps1.
.EXAMPLE
  Suggested usage for dev/test:
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest `
        https://github.com/pjh/kubernetes/raw/windows-up/cluster/gce/win1803/k8s-node-setup.psm1 `
        -OutFile C:\k8s-node-setup.psm1
    Invoke-WebRequest `
        https://github.com/pjh/kubernetes/raw/windows-up/cluster/gce/win1803/configure.ps1 `
        -OutFile C:\configure.ps1
    Import-Module -Force C:\k8s-node-setup.psm1  # -Force to override existing
    # Execute functions manually or run configure.ps1.
#>

# TODO: update scripts for these style guidelines:
#  - Remove {} around variable references unless actually needed for clarity.
#  - Always use single-quoted strings unless actually interpolating variables
#    or using escape characters.
#  - Use "approved verbs":
#    https://docs.microsoft.com/en-us/powershell/developer/cmdlet/approved-verbs-for-windows-powershell-commands
#  - Document functions using proper syntax:
#    https://technet.microsoft.com/en-us/library/hh847834(v=wps.620).aspx

# Set to $true to redo steps that were determined to have already been completed
# once (e.g. to overwrite already-existing config files).
# TODO: when this is set to $false there's something about the network setup on
# the Windows node that does not get configured properly - the smoke tests for
# connectivity between Linux and Windows pods fail. Investigate what's going on
# so that setting this to $false works. If re-doing some step is required but
# shouldn't be, report it to sig-windows.
# TODO: move this variable and other basic function (e.g. Log-Output) to a
# common.psm1 module that all other modules depend on.
$REDO_STEPS = $true

$K8S_DIR = "C:\etc\kubernetes"
$INFRA_CONTAINER = "kubeletwin/pause"
$GCE_METADATA_SERVER = "169.254.169.254"
# The "management" interface is used by the kubelet and by Windows pods to talk
# to the rest of the Kubernetes cluster *without NAT*. This interface does not
# exist until an initial HNS network has been created on the Windows node - see
# Add-InitialHnsNetwork().
$MGMT_ADAPTER_NAME = "vEthernet (Ethernet*"

function Log-Output {
  param (
    [parameter(Mandatory=$true)] [string]$Message,
    [switch]$Fatal
  )
  # TODO(pjh): what's correct, Write-Output or Write-Host??
  Write-Host "${Message}"
  if (${Fatal}) {
    Exit 1
  }
}

# Checks if a file should be written or overwritten by testing if it already
# exists and checking the value of the global $REDO_STEPS variable. Emits an
# informative message if the file already exists.
#
# Returns $true if the file does not exist, or if it does but the global
# $REDO_STEPS variable is set to $true. Returns $false if the file exists and
# the caller should not overwrite it.
function ShouldWrite_File {
  param (
    [parameter(Mandatory=$true)] [string]$Filename
  )
  if (Test-Path $Filename) {
    if ($REDO_STEPS) {
      Log-Output "Warning: $Filename already exists, will overwrite it"
      return $true
    }
    Log-Output "Skip: $Filename already exists, not overwriting it"
    return $false
  }
  return $true
}

function Todo {
  param (
    [parameter(Mandatory=$true)] [string]$Message
  )
  Log-Output "TODO: ${Message}"
}

function Log_NotImplemented {
  param (
    [parameter(Mandatory=$true)] [string]$Message
  )
  Log-Output "Not implemented yet: ${Message}" -Fatal
}

# Fails and exits if the route to the GCE metadata server is not present,
# otherwise does nothing and emits nothing.
function Verify_GceMetadataServerRouteIsPresent {
  Try {
    Get-NetRoute `
        -ErrorAction "Stop" `
        -AddressFamily IPv4 `
        -DestinationPrefix ${GCE_METADATA_SERVER}/32 | Out-Null
  } Catch [Microsoft.PowerShell.Cmdletization.Cim.CimJobException] {
    # TODO(pjh): add $true arg to make this fatal.
    Log-Output ("GCE metadata server route is not present as expected.`n" +
                "$(Get-NetRoute -AddressFamily IPv4 | Out-String)")
  }
}

function WaitFor_GceMetadataServerRouteToBeRemoved {
  $elapsed = 0
  $timeout = 60
  Log-Output ("Waiting up to ${timeout} seconds for GCE metadata server " +
              "route to be removed")
  while (${elapsed} -lt ${timeout}) {
    Try {
      Get-NetRoute `
          -ErrorAction "Stop" `
          -AddressFamily IPv4 `
          -DestinationPrefix ${GCE_METADATA_SERVER}/32 | Out-Null
    } Catch [Microsoft.PowerShell.Cmdletization.Cim.CimJobException] {
      break
    }
    $sleeptime = 2
    Start-Sleep ${sleeptime}
    ${elapsed} += ${sleeptime}
  }
}

function Add_GceMetadataServerRoute {
  # Before setting up HNS the 1803 VM has a "vEthernet (nat)" interface and a
  # "Ethernet" interface, and the route to the metadata server exists on the
  # Ethernet interface. After adding the HNS network a "vEthernet (Ethernet)"
  # interface is added, and it seems to subsume the routes of the "Ethernet"
  # interface (trying to add routes on the Ethernet interface at this point just
  # results in "New-NetRoute : Element not found" errors). I don't know what's
  # up with that, but since it's hard to know what's the right thing to do here
  # we just try to add the route on all of the network adapters.
  Get-NetAdapter | ForEach-Object {
    $adapter_index = $_.InterfaceIndex
    New-NetRoute `
        -ErrorAction Ignore `
        -DestinationPrefix "${GCE_METADATA_SERVER}/32" `
        -InterfaceIndex ${adapter_index} | Out-Null
  }
}

function Get-InstanceMetadataValue {
  param (
    [parameter(Mandatory=$true)] [string]$Key,
    [parameter(Mandatory=$false)] [string]$Default
  )

  $url = ("http://metadata.google.internal/computeMetadata/v1/instance/" +
          "attributes/$Key")
  try {
    $client = New-Object Net.WebClient
    $client.Headers.Add('Metadata-Flavor', 'Google')
    return ($client.DownloadString($url)).Trim()
  }
  catch [System.Net.WebException] {
    if ($Default) {
      return $Default
    }
    else {
      Log-Output "Failed to retrieve value for $Key."
      return $null
    }
  }
}

# Fetches the kube-env from the instance metadata.
#
# Returns: a PowerShell Hashtable object containing the key-value pairs from
#   kube-env.
function Fetch-KubeEnv {
  # Testing / debugging:
  # First:
  #   ${kube_env} = Get-InstanceMetadataValue 'kube-env'
  # or:
  #   ${kube_env} = [IO.File]::ReadAllText(".\kubeEnv.txt")
  # ${kube_env_table} = ConvertFrom-Yaml ${kube_env}
  # ${kube_env_table}
  # ${kube_env_table}.GetType()

  # The type of kube_env is a powershell String.
  $kube_env = Get-InstanceMetadataValue 'kube-env'
  $kube_env_table = ConvertFrom-Yaml ${kube_env}
  return ${kube_env_table}
}

function Set-MachineEnvironmentVar {
  param (
    [parameter(Mandatory=$true)] [string]$Key,
    [parameter(Mandatory=$true)] [string]$Value
  )
  [Environment]::SetEnvironmentVariable($Key, $Value, "Machine")
}

function Set-CurrentShellEnvironmentVar {
  param (
    [parameter(Mandatory=$true)] [string]$Key,
    [parameter(Mandatory=$true)] [string]$Value
  )
  $expression = '$env:' + $Key + ' = "' + $Value + '"'
  Invoke-Expression ${expression}
}

function Set-EnvironmentVars {
  $env_vars = @{
    "K8S_DIR" = "${K8S_DIR}"
    "NODE_DIR" = "${K8S_DIR}\node\bin"
    "Path" = ${env:Path} + ";${K8S_DIR}\node\bin"
    "LOGS_DIR" = "${K8S_DIR}\logs"
    "CNI_DIR" = "${K8S_DIR}\cni"
    "CNI_CONFIG_DIR" = "${K8S_DIR}\cni\config"
    "MANIFESTS_DIR" = "${K8S_DIR}\manifests"
    "KUBELET_CONFIG" = "${K8S_DIR}\kubelet-config.yaml"
    "KUBECONFIG" = "${K8S_DIR}\kubelet.kubeconfig"
    "BOOTSTRAP_KUBECONFIG" = "${K8S_DIR}\kubelet.bootstrap-kubeconfig"
    "KUBEPROXY_KUBECONFIG" = "${K8S_DIR}\kubeproxy.kubeconfig"
    "KUBE_NETWORK" = "l2bridge".ToLower()
    "PKI_DIR" = "${K8S_DIR}\pki"
    "CA_CERT_BUNDLE_PATH" = "${K8S_DIR}\pki\ca-certificates.crt"
    "KUBELET_CERT_PATH" = "${K8S_DIR}\pki\kubelet.crt"
    "KUBELET_KEY_PATH" = "${K8S_DIR}\pki\kubelet.key"
  }

  # Set the environment variables in two ways: permanently on the machine (only
  # takes effect after a reboot), and in the current shell.
  $env_vars.GetEnumerator() | ForEach-Object{
    $message = "Setting environment variable: " + $_.key + " = " + $_.value
    Log-Output ${message}
    Set-MachineEnvironmentVar $_.key $_.value
    Set-CurrentShellEnvironmentVar $_.key $_.value
  }
}

function Set-PrerequisiteOptions {
  Log-Output "Disabling Windows Firewall and Windows Update service"
  Set-NetFirewallProfile -Profile Domain, Public, Private -Enabled False
  sc.exe config wuauserv start=disabled
  sc.exe stop wuauserv

  # Use TLS 1.2: needed for Invoke-WebRequest downloads from github.com.
  [Net.ServicePointManager]::SecurityProtocol = `
      [Net.SecurityProtocolType]::Tls12

  # https://github.com/cloudbase/powershell-yaml
  Log-Output "Installing powershell-yaml module from external repo"
  Install-Module -Name powershell-yaml -Force
}

function Create-Directories {
  Log-Output "Creating ${env:K8S_DIR} and its subdirectories."
  ForEach ($dir in ("${env:K8S_DIR}", "${env:NODE_DIR}", "${env:LOGS_DIR}",
    "${env:CNI_DIR}", "${env:CNI_CONFIG_DIR}", "${env:MANIFESTS_DIR}",
    "${env:PKI_DIR}")) {
    mkdir -Force $dir
  }
}

function Download-HelperScripts {
  if (-not (ShouldWrite_File ${env:K8S_DIR}\hns.psm1)) {
    return
  }
  Invoke-WebRequest `
      https://github.com/Microsoft/SDN/raw/master/Kubernetes/windows/hns.psm1 `
      -OutFile ${env:K8S_DIR}\hns.psm1
}

function Create-PauseImage {
  $win_version = Get-InstanceMetadataValue 'win-version'

  $pause_dir = "${env:K8S_DIR}\pauseimage"
  $dockerfile = "$pause_dir\Dockerfile"
  mkdir -Force $pause_dir
  if (ShouldWrite_File $dockerfile) {
    New-Item -Force -ItemType file $dockerfile
    Set-Content `
        $dockerfile `
        ("FROM microsoft/nanoserver:${win_version}`n`n" +
         "CMD cmd /c ping -t localhost")
  }

  if (($(docker images -a) -like "*${INFRA_CONTAINER}*") -and
      (-not $REDO_STEPS)) {
    Log-Output "Skip: ${INFRA_CONTAINER} already built"
    return
  }
  docker build -t ${INFRA_CONTAINER} $pause_dir
}

function Download_FileIfNotAlreadyPresent {
  param (
    [parameter(Mandatory=$true)] [string]$Url,
    [parameter(Mandatory=$true)] [string]$OutFile
  )
  if (-not (ShouldWrite_File $OutFile)) {
    return
  }
  # Disable progress bar to dramatically increase download speed.
  $ProgressPreference = 'SilentlyContinue'
  Invoke-WebRequest $Url -OutFile $OutFile
}

function DownloadAndInstall-KubernetesBinaries {
  $tmp_dir = 'C:\k8s_tmp'
  New-Item $tmp_dir -ItemType 'directory' -Force

  $uri = ${kube_env}['NODE_BINARY_TAR_URL']
  $filename = Split-Path -leaf $uri

  # Disable progress bar to increase download speed.
  $ProgressPreference = 'SilentlyContinue'
  Invoke-WebRequest $uri -OutFile ${tmp_dir}\${filename}

  # TODO: Verify hash of the tarball.

  # Change the directory to the parent directory of ${env:K8S_DIR} and untar.
  # This (over-)writes $Pdest_dir}/kubernetes/node/bin/*.exe files.
  $dest_dir = (get-item ${env:K8S_DIR}).Parent.Fullname
  tar xzf ${tmp_dir}\${filename} -C ${dest_dir}

  # Clean up the temporary directory
  Remove-Item -Force -Recurse $tmp_dir
}

# TODO(pjh): this is copied from
# https://github.com/Microsoft/SDN/blob/master/Kubernetes/windows/start-kubelet.ps1#L98.
# See if there's a way to fetch or construct the "management subnet" so that
# this is not needed.
function ConvertTo_DecimalIP
{
  param(
    [parameter(Mandatory = $true, Position = 0)]
    [Net.IPAddress] $IPAddress
  )

  $i = 3; $decimal_ip = 0;
  $IPAddress.GetAddressBytes() | % {
    $decimal_ip += $_ * [Math]::Pow(256, $i); $i--
  }
  return [UInt32]$decimal_ip
}

# TODO(pjh): this is copied from
# https://github.com/Microsoft/SDN/blob/master/Kubernetes/windows/start-kubelet.ps1#L98.
# See if there's a way to fetch or construct the "management subnet" so that
# this is not needed.
function ConvertTo_DottedDecimalIP
{
  param(
    [parameter(Mandatory = $true, Position = 0)]
    [Uint32] $IPAddress
  )

  $dotted_ip = $(for ($i = 3; $i -gt -1; $i--) {
    $remainder = $IPAddress % [Math]::Pow(256, $i)
    ($IPAddress - $remainder) / [Math]::Pow(256, $i)
    $IPAddress = $remainder
  })
  return [String]::Join(".", $dotted_ip)
}

# TODO(pjh): this is copied from
# https://github.com/Microsoft/SDN/blob/master/Kubernetes/windows/start-kubelet.ps1#L98.
# See if there's a way to fetch or construct the "management subnet" so that
# this is not needed.
function ConvertTo_MaskLength
{
  param(
    [parameter(Mandatory = $True, Position = 0)]
    [Net.IPAddress] $SubnetMask
  )

  $bits = "$($SubnetMask.GetAddressBytes() | % {
    [Convert]::ToString($_, 2)
  } )" -replace "[\s0]"
  return $bits.Length
}

# This function will fail if Add-InitialHnsNetwork() has not been called first.
function Get_MgmtSubnet {
  $net_adapter = Get_MgmtNetAdapter

  $addr = (Get-NetIPAddress `
      -InterfaceAlias ${net_adapter}.ifAlias `
      -AddressFamily IPv4).IPAddress
  $mask = (Get-WmiObject Win32_NetworkAdapterConfiguration |
      Where-Object InterfaceIndex -eq $(${net_adapter}.ifIndex)).IPSubnet[0]
  $mgmt_subnet = `
    (ConvertTo_DecimalIP ${addr}) -band (ConvertTo_DecimalIP ${mask})
  $mgmt_subnet = ConvertTo_DottedDecimalIP ${mgmt_subnet}
  return "${mgmt_subnet}/$(ConvertTo_MaskLength $mask)"
}

# This function will fail if Add-InitialHnsNetwork() has not been called first.
function Get_MgmtNetAdapter {
  $net_adapter = Get-NetAdapter | Where-Object Name -Like ${MGMT_ADAPTER_NAME}
  if (-not ${net_adapter}) {
    throw ("Failed to find a suitable network adapter, check your network " +
           "settings.")
  }

  return $net_adapter
}

# Decodes the base64 $Data string and writes it as binary to $File. Does
# nothing if $File already exists and $REDO_STEPS is not set.
function Write_PkiData {
  param (
    [parameter(Mandatory=$true)] [string] $Data,
    [parameter(Mandatory=$true)] [string] $File
  )

  if (-not (ShouldWrite_File $File)) {
    return
  }

  # This command writes out a PEM certificate file, analogous to "base64
  # --decode" on Linux. See https://stackoverflow.com/a/51914136/1230197.
  [IO.File]::WriteAllBytes($File, [Convert]::FromBase64String($Data))
  Todo ("need to set permissions correctly on ${File}; not sure what the " +
        "Windows equivalent of 'umask 077' is")
  # Linux: owned by root, rw by user only.
  #   -rw------- 1 root root 1.2K Oct 12 00:56 ca-certificates.crt
  #   -rw------- 1 root root 1.3K Oct 12 00:56 kubelet.crt
  #   -rw------- 1 root root 1.7K Oct 12 00:56 kubelet.key
  # Windows:
  #   https://docs.microsoft.com/en-us/dotnet/api/system.io.fileattributes
  #   https://docs.microsoft.com/en-us/dotnet/api/system.io.fileattributes
}

# This function is analogous to create-node-pki() in gci/configure-helper.sh for
# Linux nodes.
# Required ${kube_env} keys:
#   CA_CERT
#   KUBELET_CERT
#   KUBELET_KEY
function Create-NodePki {
  Log-Output "Creating node pki files"

  # Note: create-node-pki() tests if CA_CERT_BUNDLE / KUBELET_CERT /
  # KUBELET_KEY are already set, we don't.
  $CA_CERT_BUNDLE = ${kube_env}['CA_CERT']
  $KUBELET_CERT = ${kube_env}['KUBELET_CERT']
  $KUBELET_KEY = ${kube_env}['KUBELET_KEY']

  # Wrap data arg in quotes in case it contains spaces? (does this even make
  # sense?)
  Write_PkiData "${CA_CERT_BUNDLE}" ${env:CA_CERT_BUNDLE_PATH}
  Write_PkiData "${KUBELET_CERT}" ${env:KUBELET_CERT_PATH}
  Write_PkiData "${KUBELET_KEY}" ${env:KUBELET_KEY_PATH}
  Get-ChildItem ${env:PKI_DIR}
}

# This is analogous to create-kubelet-kubeconfig() in gci/configure-helper.sh
# for Linux nodes.
# Create-NodePki() must be called first.
# Required ${kube_env} keys:
#   KUBERNETES_MASTER_NAME: the apiserver IP address.
function Create-KubeletKubeconfig {
  # The API server IP address comes from KUBERNETES_MASTER_NAME in kube-env, I
  # think. cluster/gce/gci/configure-helper.sh?l=2801
  $apiserverAddress = ${kube_env}['KUBERNETES_MASTER_NAME']

  # TODO(pjh): set these using kube-env values.
  $createBootstrapConfig = $true
  $fetchBootstrapConfig = $false

  if (${createBootstrapConfig}) {
    if (-not (ShouldWrite_File ${env:BOOTSTRAP_KUBECONFIG})) {
      return
    }
    New-Item -Force -ItemType file ${env:BOOTSTRAP_KUBECONFIG}
    # TODO(pjh): is user "kubelet" correct? In my guide it's
    #   "system:node:$(hostname)"
    # The kubelet user config uses client-certificate and client-key here; in
    # my guide it's client-certificate-data and client-key-data. Does it matter?
    Set-Content ${env:BOOTSTRAP_KUBECONFIG} `
'apiVersion: v1
kind: Config
users:
- name: kubelet
  user:
    client-certificate: KUBELET_CERT_PATH
    client-key: KUBELET_KEY_PATH
clusters:
- name: local
  cluster:
    server: https://APISERVER_ADDRESS
    certificate-authority: CA_CERT_BUNDLE_PATH
contexts:
- context:
    cluster: local
    user: kubelet
  name: service-account-context
current-context: service-account-context'.`
      replace('KUBELET_CERT_PATH', ${env:KUBELET_CERT_PATH}).`
      replace('KUBELET_KEY_PATH', ${env:KUBELET_KEY_PATH}).`
      replace('APISERVER_ADDRESS', ${apiserverAddress}).`
      replace('CA_CERT_BUNDLE_PATH', ${env:CA_CERT_BUNDLE_PATH})
    Log-Output ("kubelet bootstrap kubeconfig:`n" +
                "$(Get-Content -Raw ${env:BOOTSTRAP_KUBECONFIG})")
  }
  elseif (${fetchBootstrapConfig}) {
    Log_NotImplemented `
        "fetching kubelet bootstrap-kubeconfig file from metadata"
    # get-metadata-value "instance/attributes/bootstrap-kubeconfig" >
    #   /var/lib/kubelet/bootstrap-kubeconfig
    Log-Output ("kubelet bootstrap kubeconfig:`n" +
                "$(Get-Content -Raw ${env:BOOTSTRAP_KUBECONFIG})")
  }
  else {
    Log_NotImplemented "fetching kubelet kubeconfig file from metadata"
    # get-metadata-value "instance/attributes/kubeconfig" >
    #   /var/lib/kubelet/kubeconfig
    Get-Content -Raw ${env:KUBECONFIG}
    Log-Output "kubelet kubeconfig:`n$(Get-Content -Raw ${env:KUBECONFIG})"
  }
}

# This is analogous to create-kubeproxy-user-kubeconfig() in
# gci/configure-helper.sh for Linux nodes. Create-NodePki() must be called
# first.
# Required ${kube_env} keys:
#   CA_CERT
#   KUBE_PROXY_TOKEN
function Create-KubeproxyKubeconfig {
  if (-not (ShouldWrite_File ${env:KUBEPROXY_KUBECONFIG})) {
    return
  }

  # TODO: make this command and other New-Item commands silent.
  New-Item -Force -ItemType file ${env:KUBEPROXY_KUBECONFIG}

  # In configure-helper.sh kubelet kubeconfig uses certificate-authority while
  # kubeproxy kubeconfig uses certificate-authority-data, ugh. Does it matter?
  # Use just one or the other for consistency?
  Set-Content ${env:KUBEPROXY_KUBECONFIG} `
'apiVersion: v1
kind: Config
users:
- name: kube-proxy
  user:
    token: KUBEPROXY_TOKEN
clusters:
- name: local
  cluster:
    certificate-authority-data: CA_CERT
contexts:
- context:
    cluster: local
    user: kube-proxy
  name: service-account-context
current-context: service-account-context'.`
    replace('KUBEPROXY_TOKEN', ${kube_env}['KUBE_PROXY_TOKEN']).`
    #replace('CA_CERT_BUNDLE_PATH', ${env:CA_CERT_BUNDLE_PATH})
    replace('CA_CERT', ${kube_env}['CA_CERT'])

  Log-Output ("kubeproxy kubeconfig:`n" +
              "$(Get-Content -Raw ${env:KUBEPROXY_KUBECONFIG})")
}

function Get_IpAliasRange {
  $url = ("http://${GCE_METADATA_SERVER}/computeMetadata/v1/instance/" +
          "network-interfaces/0/ip-aliases/0")
  $client = New-Object Net.WebClient
  $client.Headers.Add('Metadata-Flavor', 'Google')
  return ($client.DownloadString($url)).Trim()
}

# The pod CIDR can be accessed at $env:POD_CIDR after this function returns.
function Set-PodCidr {
  while($true) {
    $pod_cidr = Get_IpAliasRange
    if (-not $?) {
      Log-Output ${pod_cIDR}
      Log-Output "Retrying Get_IpAliasRange..."
      Start-Sleep -sec 1
      continue
    }
    break
  }

  Log-Output "fetched pod CIDR (same as IP alias range): ${pod_cidr}"
  Set-MachineEnvironmentVar "POD_CIDR" ${pod_cidr}
  Set-CurrentShellEnvironmentVar "POD_CIDR" ${pod_cidr}
}

# This function adds an initial HNS network on the Windows node, which forces
# the creation of a virtual switch and the "management" interface that will be
# used to communicate with the rest of the Kubernetes cluster without NAT.
function Add-InitialHnsNetwork {
  Import-Module -Force ${env:K8S_DIR}\hns.psm1
  # This comes from
  # https://github.com/Microsoft/SDN/blob/master/Kubernetes/flannel/l2bridge/start.ps1#L74
  # (or
  # https://github.com/Microsoft/SDN/blob/master/Kubernetes/windows/start-kubelet.ps1#L206).
  #
  # daschott noted on Slack: "L2bridge networks require an external vSwitch.
  # The first network ("External") with hardcoded values in the script is just
  # a placeholder to create an external vSwitch. This is purely for convenience
  # to be able to remove/modify the actual HNS network ("cbr0") or rejoin the
  # nodes without a network blip. Creating a vSwitch takes time, causes network
  # blips, and it makes it more likely to hit the issue where flanneld is
  # stuck, so we want to do this as rarely as possible."
  if ($(Get-HnsNetwork) -like '*Name*External*') {
    Log-Output ('Skip: Initial "External" HNS network already exists, not ' +
                'recreating it')
    return
  }
  Log-Output ("Creating initial HNS network to force creation of " +
              "${MGMT_ADAPTER_NAME} interface")
  # Note: RDP connection will hiccup when running this command.
  New-HNSNetwork `
      -Type "L2Bridge" `
      -AddressPrefix "192.168.255.0/30" `
      -Gateway "192.168.255.1" `
      -Name "External" `
      -Verbose
}

# Prerequisites:
#   $env:POD_CIDR is set (by Set-PodCidr).
#   The "management" interface exists (Add-InitialHnsNetwork).
function Configure-HostNetworkingService {
  $endpoint_name = "cbr0"
  $vnic_name = "vEthernet (${endpoint_name})"

  Import-Module -Force ${env:K8S_DIR}\hns.psm1
  Verify_GceMetadataServerRouteIsPresent

  # For Windows nodes the pod gateway IP address is the .1 address in the pod
  # CIDR for the host, but from inside containers it's the .2 address.
  $pod_gateway = `
      ${env:POD_CIDR}.substring(0, ${env:POD_CIDR}.lastIndexOf('.')) + '.1'
  $pod_endpoint_gateway = `
      ${env:POD_CIDR}.substring(0, ${env:POD_CIDR}.lastIndexOf('.')) + '.2'
  Log-Output ("Setting up Windows node HNS networking: " +
              "podCidr = ${env:POD_CIDR}, podGateway = ${pod_gateway}, " +
              "podEndpointGateway = ${pod_endpoint_gateway}")

  if (Get-HnsNetwork | Where-Object Name -eq ${env:KUBE_NETWORK}) {
    if ($REDO_STEPS) {
      Log-Output ("${env:KUBE_NETWORK} HNS network already exists, removing " +
                  "it and recreating it")
      Get-HnsNetwork | Where-Object Name -eq ${env:KUBE_NETWORK} |
          Remove-HnsNetwork
    }
    else {
      Log-Output "Skip: ${env:KUBE_NETWORK} HNS network already exists"
      return
    }
  }

  # Note: RDP connection will hiccup when running this command.
  $hns_network = New-HNSNetwork `
      -Type "L2Bridge" `
      -AddressPrefix ${env:POD_CIDR} `
      -Gateway ${pod_gateway} `
      -Name ${env:KUBE_NETWORK} `
      -Verbose
  $hns_endpoint = New-HnsEndpoint `
      -NetworkId ${hns_network}.Id `
      -Name ${endpoint_name} `
      -IPAddress ${pod_endpoint_gateway} `
      -Gateway "0.0.0.0" `
      -Verbose
  Attach-HnsHostEndpoint `
      -EndpointID ${hns_endpoint}.Id `
      -CompartmentID 1 `
      -Verbose
  netsh interface ipv4 set interface "${vnic_name}" forwarding=enabled
  Get-HNSPolicyList | Remove-HnsPolicyList

  # Add a route from the management NIC to the pod CIDR.
  #
  # When a packet from a Kubernetes service backend arrives on the destination
  # Windows node, the reverse SNAT will be applied and the source address of
  # the packet gets replaced from the pod IP to the service VIP. The packet
  # will then leave the VM and return back through hairpinning.
  #
  # When IP alias is enabled, IP forwarding is disabled for anti-spoofing;
  # the packet with the service VIP will get blocked and be lost. With this
  # route, the packet will be routed to the pod subnetwork, and not leave the
  # VM.
  $mgmt_net_adapter = Get_MgmtNetAdapter
  New-NetRoute `
      -ErrorAction Ignore `
      -InterfaceAlias ${mgmt_net_adapter}.ifAlias `
      -DestinationPrefix ${env:POD_CIDR} `
      -NextHop "0.0.0.0" `
      -Verbose

  # There is an HNS bug where the route to the GCE metadata server will be
  # removed when the HNS network is created:
  # https://github.com/Microsoft/hcsshim/issues/299#issuecomment-425491610.
  # The behavior here is very unpredictable: the route may only be removed
  # after some delay, or it may appear to be removed then you'll add it back but
  # then it will be removed once again. So, we first wait a long unfortunate
  # amount of time to ensure that things have quiesced, then we wait until we're
  # sure the route is really gone before re-adding it again.
  Log-Output "Waiting 45 seconds for host network state to quiesce"
  Start-Sleep 45
  WaitFor_GceMetadataServerRouteToBeRemoved
  Log-Output "Re-adding the GCE metadata server route"
  Add_GceMetadataServerRoute
  Verify_GceMetadataServerRouteIsPresent

  Log-Output "Host network setup complete"
}

# Prerequisites:
#   $env:POD_CIDR is set (by Set-PodCidr).
#   The "management" interface exists (Add-InitialHnsNetwork).
#   The "cbr0" HNS network for pod networking has been configured
#     (Configure-HostNetworkingService).
function Configure-CniNetworking {
  $github_repo = Get-InstanceMetadataValue 'github-repo'
  $github_branch = Get-InstanceMetadataValue 'github-branch'

  if ((ShouldWrite_File ${env:CNI_DIR}\win-bridge.exe) -or
      (ShouldWrite_File ${env:CNI_DIR}\host-local.exe)) {
    Invoke-WebRequest `
        https://github.com/${github_repo}/kubernetes/raw/${github_branch}/cluster/gce/windows-cni-plugins.zip `
        -OutFile ${env:CNI_DIR}\windows-cni-plugins.zip
    rm ${env:CNI_DIR}\*.exe
    Expand-Archive ${env:CNI_DIR}\windows-cni-plugins.zip ${env:CNI_DIR}
    mv ${env:CNI_DIR}\bin\*.exe ${env:CNI_DIR}\
    rmdir ${env:CNI_DIR}\bin
  }
  if (-not ((Test-Path ${env:CNI_DIR}\win-bridge.exe) -and `
            (Test-Path ${env:CNI_DIR}\host-local.exe))) {
    Log-Output `
        "win-bridge.exe and host-local.exe not found in ${env:CNI_DIR}" `
        -Fatal
  }

  $l2bridge_conf = "${env:CNI_CONFIG_DIR}\l2bridge.conf"
  if (-not (ShouldWrite_File ${l2bridge_conf})) {
    return
  }

  $veth_ip = (Get-NetAdapter | Where-Object Name -Like ${MGMT_ADAPTER_NAME} |
              Get-NetIPAddress -AddressFamily IPv4).IPAddress
  $mgmt_subnet = Get_MgmtSubnet
  Log-Output ("using mgmt IP ${veth_ip} and mgmt subnet ${mgmt_subnet} for " +
              "CNI config")

  # TODO(pjh): validate these values against CNI config on Linux node.
  #
  # Explanation of the CNI config values:
  #   POD_CIDR: ...
  #   DNS_SERVER_IP: ...
  #   DNS_DOMAIN: ...
  #   CLUSTER_CIDR: TODO: validate this against Linux kube-proxy-config.yaml.
  #   SERVICE_CIDR: SERVICE_CLUSTER_IP_RANGE from kube_env?
  #   MGMT_SUBNET: $mgmt_subnet.
  #   MGMT_IP: $vethIp.
  New-Item -Force -ItemType file ${l2bridge_conf}
  Set-Content ${l2bridge_conf} `
'{
  "cniVersion":  "0.2.0",
  "name":  "l2bridge",
  "type":  "win-bridge",
  "capabilities":  {
    "portMappings":  true
  },
  "ipam":  {
    "type": "host-local",
    "subnet": "POD_CIDR"
  },
  "dns":  {
    "Nameservers":  [
      "DNS_SERVER_IP"
    ],
    "Search": [
      "DNS_DOMAIN"
    ]
  },
  "Policies":  [
    {
      "Name":  "EndpointPolicy",
      "Value":  {
        "Type":  "OutBoundNAT",
        "ExceptionList":  [
          "CLUSTER_CIDR",
          "SERVICE_CIDR",
          "MGMT_SUBNET"
        ]
      }
    },
    {
      "Name":  "EndpointPolicy",
      "Value":  {
        "Type":  "ROUTE",
        "DestinationPrefix":  "SERVICE_CIDR",
        "NeedEncap":  true
      }
    },
    {
      "Name":  "EndpointPolicy",
      "Value":  {
        "Type":  "ROUTE",
        "DestinationPrefix":  "MGMT_IP/32",
        "NeedEncap":  true
      }
    }
  ]
}'.replace('POD_CIDR', ${env:POD_CIDR}).`
  replace('DNS_SERVER_IP', ${kube_env}['DNS_SERVER_IP']).`
  replace('DNS_DOMAIN', ${kube_env}['DNS_DOMAIN']).`
  replace('MGMT_IP', ${vethIp}).`
  replace('CLUSTER_CIDR', ${kube_env}['CLUSTER_IP_RANGE']).`
  replace('SERVICE_CIDR', ${kube_env}['SERVICE_CLUSTER_IP_RANGE']).`
  replace('MGMT_SUBNET', ${mgmt_subnet})

  Log-Output "CNI config:`n$(Get-Content -Raw ${l2bridge_conf})"
}

function Configure-Kubelet {
  # The Kubelet config is built by build-kubelet-config() in
  # cluster/gce/util.sh, and stored in the metadata server under the
  # 'kubelet-config' key.

  if (-not (ShouldWrite_File ${env:KUBELET_CONFIG})) {
    return
  }

  # Download and save Kubelet Config, and log the result
  $kubelet_config = Get-InstanceMetadataValue 'kubelet-config'
  Set-Content ${env:KUBELET_CONFIG} $kubelet_config
  Log-Output "Kubelet config:`n$(Get-Content -Raw ${env:KUBELET_CONFIG})"
}

function Start-WorkerServices {
  $kubelet_args_str = ${kube_env}['KUBELET_ARGS']
  $kubelet_args = $kubelet_args_str.Split(" ")
  Log-Output "kubelet_args from metadata: ${kubelet_args}"
    # --v=2
    # --allow-privileged=true
    # --cloud-provider=gce
    # --non-masquerade-cidr=0.0.0.0/0
    # --node-labels=beta.kubernetes.io/fluentd-ds-ready=true,cloud.google.com/gke-netd-ready=true

  # Reference:
  # https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/#options
  $additional_arg_list = @(`
      "--config=${env:KUBELET_CONFIG}",

      # Path to a kubeconfig file that will be used to get client certificate
      # for kubelet. If the file specified by --kubeconfig does not exist, the
      # bootstrap kubeconfig is used to request a client certificate from the
      # API server. On success, a kubeconfig file referencing the generated
      # client certificate and key is written to the path specified by
      # --kubeconfig. The client certificate and key file will be stored in the
      # directory pointed by --cert-dir.
      #
      # See also:
      # https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet-tls-bootstrapping/
      "--bootstrap-kubeconfig=${env:BOOTSTRAP_KUBECONFIG}",
      "--kubeconfig=${env:KUBECONFIG}",

      # The directory where the TLS certs are located. If --tls-cert-file and
      # --tls-private-key-file are provided, this flag will be ignored.
      "--cert-dir=${env:PKI_DIR}",

      # The following flags are adapted from
      # https://github.com/Microsoft/SDN/blob/master/Kubernetes/windows/start-kubelet.ps1#L117
      # (last checked on 2019-01-07):
      "--pod-infra-container-image=${INFRA_CONTAINER}",
      "--resolv-conf=`"`"",
      # The kubelet currently fails when this flag is omitted on Windows.
      "--cgroups-per-qos=false",
      # The kubelet currently fails when this flag is omitted on Windows.
      "--enforce-node-allocatable=`"`"",
      "--network-plugin=cni",
      "--cni-bin-dir=${env:CNI_DIR}",
      "--cni-conf-dir=${env:CNI_CONFIG_DIR}",
      "--pod-manifest-path=${env:MANIFESTS_DIR}",
      # Windows images are large and we don't have gcr mirrors yet. Allow
      # longer pull progress deadline.
      "--image-pull-progress-deadline=5m",
      "--enable-debugging-handlers=true",
      # Turn off kernel memory cgroup notification.
      "--experimental-kernel-memcg-notification=false"
      # These flags come from Microsoft/SDN, not sure what they do or if
      # they're needed.
      #   --log-dir=c:\k
      #   --logtostderr=false
      # We set these values via the kubelet config file rather than via flags:
      #   --cluster-dns=$KubeDnsServiceIp
      #   --cluster-domain=cluster.local
      #   --hairpin-mode=promiscuous-bridge
  )
  $kubelet_args = ${kubelet_args} + ${additional_arg_list}

  # These args are present in the Linux KUBELET_ARGS value of kube-env, but I
  # don't think we need them or they don't make sense on Windows.
  $arg_list_unused = @(`
      # [Experimental] Path of mounter binary. Leave empty to use the default
      # mount.
      "--experimental-mounter-path=/home/kubernetes/containerized_mounter/mounter",
      # [Experimental] if set true, the kubelet will check the underlying node
      # for required components (binaries, etc.) before performing the mount
      "--experimental-check-node-capabilities-before-mount=true",
      # The Kubelet will use this directory for checkpointing downloaded
      # configurations and tracking configuration health. The Kubelet will
      # create this directory if it does not already exist. The path may be
      # absolute or relative; relative paths start at the Kubelet's current
      # working directory. Providing this flag enables dynamic Kubelet
      # configuration.  Presently, you must also enable the
      # DynamicKubeletConfig feature gate to pass this flag.
      "--dynamic-config-dir=/var/lib/kubelet/dynamic-config",
      # The full path of the directory in which to search for additional third
      # party volume plugins (default
      # "/usr/libexec/kubernetes/kubelet-plugins/volume/exec/")
      "--volume-plugin-dir=/home/kubernetes/flexvolume",
      # The container runtime to use. Possible values: 'docker', 'rkt'.
      # (default "docker")
      "--container-runtime=docker"
  )

  # kubeproxy is started on Linux nodes using
  # kube-manifests/kubernetes/gci-trusty/kube-proxy.manifest, which is
  # generated by start-kube-proxy in configure-helper.sh and contains e.g.:
  #   kube-proxy --master=https://35.239.84.171
  #   --kubeconfig=/var/lib/kube-proxy/kubeconfig --cluster-cidr=10.64.0.0/14
  #   --resource-container="" --oom-score-adj=-998 --v=2
  #   --feature-gates=ExperimentalCriticalPodAnnotation=true
  #   --iptables-sync-period=1m --iptables-min-sync-period=10s
  #   --ipvs-sync-period=1m --ipvs-min-sync-period=10s
  # And also with various volumeMounts and "securityContext: privileged: true".
  $apiserver_address = ${kube_env}['KUBERNETES_MASTER_NAME']
  $kubeproxy_args = @(`
      "--v=4",
      "--master=https://${apiserver_address}",
      "--kubeconfig=${env:KUBEPROXY_KUBECONFIG}",
      "--proxy-mode=kernelspace",
      "--hostname-override=$(hostname)",
      "--resource-container=`"`"",
      "--cluster-cidr=$(${kube_env}['CLUSTER_IP_RANGE'])"
  )

  if (Get-Process | Where-Object Name -eq "kubelet") {
    Log-Output `
        "A kubelet process is already running, don't know what to do" `
        -Fatal
  }
  Log-Output "Starting kubelet"

  # Use Start-Process, not Start-Job; jobs are killed as soon as the shell /
  # script that invoked them terminates, whereas processes continue running.
  #
  # -PassThru causes a process object to be returned from the Start-Process
  # command.
  #
  # TODO(pjh): add -UseNewEnvironment flag and debug error "server.go:262]
  # failed to run Kubelet: could not init cloud provider "gce": Get
  # http://169.254.169.254/computeMetadata/v1/instance/zone: dial tcp
  # 169.254.169.254:80: socket: The requested service provider could not be
  # loaded or initialized."
  # -UseNewEnvironment ensures that there are no implicit dependencies
  # on the variables in this script - everything the kubelet needs should be
  # specified via flags or config files.
  $kubelet_process = Start-Process `
      -FilePath "${env:NODE_DIR}\kubelet.exe" `
      -ArgumentList ${kubelet_args} `
      -WindowStyle Hidden -PassThru `
      -RedirectStandardOutput ${env:LOGS_DIR}\kubelet.out `
      -RedirectStandardError ${env:LOGS_DIR}\kubelet.log
  Log-Output "$(${kubelet_process} | Out-String)"
  # TODO(pjh): set kubelet_process as a global variable so that
  # Stop-WorkerServices can access it.

  # TODO(pjh): kubelet is emitting these messages:
  # I1023 23:44:11.761915    2468 kubelet.go:274] Adding pod path:
  # C:\etc\kubernetes
  # I1023 23:44:11.775601    2468 file.go:68] Watching path
  # "C:\\etc\\kubernetes"
  # ...
  # E1023 23:44:31.794327    2468 file.go:182] Can't process manifest file
  # "C:\\etc\\kubernetes\\hns.psm1": C:\etc\kubernetes\hns.psm1: couldn't parse
  # as pod(yaml: line 10: did not find expected <document start>), please check
  # config file.
  #
  # Figure out how to change the directory that the kubelet monitors for new
  # pod manifests.

  Log-Output "Waiting 10 seconds for kubelet to stabilize"
  Start-Sleep 10

  if (Get-Process | Where-Object Name -eq "kube-proxy") {
    Log-Output `
        "A kube-proxy process is already running, don't know what to do" `
        -Fatal
  }

  # F1020 23:08:52.000083    9136 server.go:361] unable to load in-cluster
  # configuration, KUBERNETES_SERVICE_HOST and KUBERNETES_SERVICE_PORT must be
  # defined
  Log-Output "Starting kube-proxy"
  $kubeproxy_process = Start-Process `
      -FilePath "${env:NODE_DIR}\kube-proxy.exe" `
      -ArgumentList ${kubeproxy_args} `
      -WindowStyle Hidden -PassThru `
      -RedirectStandardOutput ${env:LOGS_DIR}\kube-proxy.out `
      -RedirectStandardError ${env:LOGS_DIR}\kube-proxy.log
  Log-Output "$(${kubeproxy_process} | Out-String)"

  # TODO(pjh): still getting errors like these in kube-proxy log:
  # E1023 04:03:58.143449    4840 reflector.go:205] k8s.io/kubernetes/pkg/client/informers/informers_generated/internalversion/factory.go:129: Failed to list *core.Endpoints: Get https://35.239.84.171/api/v1/endpoints?limit=500&resourceVersion=0: dial tcp 35.239.84.171:443: connectex: A connection attempt failed because the connected party did not properly respond after a period of time, or established connection failed because connected host has failed to respond.
  # E1023 04:03:58.150266    4840 reflector.go:205] k8s.io/kubernetes/pkg/client/informers/informers_generated/internalversion/factory.go:129: Failed to list *core.Service: Get https://35.239.84.171/api/v1/services?limit=500&resourceVersion=0: dial tcp 35.239.84.171:443: connectex: A connection attempt failed because the connected party did not properly respond after a period of time, or established connection failed because connected host has failed to respond.

  Todo ("verify that jobs are still running; print more details about the " +
        "background jobs.")
  Log-Output "$(Get-Process kube* | Out-String)"
  Verify_GceMetadataServerRouteIsPresent
  Log-Output "Kubernetes components started successfully"
}

function Stop-WorkerServices {
  # Stop-Job
  # Remove-Job
}

function Verify-WorkerServices {
  Log-Output ("kubectl get nodes:`n" +
              "$(& ${env:NODE_DIR}\kubectl.exe get nodes | Out-String)")
  Verify_GceMetadataServerRouteIsPresent
  Todo "run more verification commands."
}

# Export all public functions:
Export-ModuleMember -Function *-*
