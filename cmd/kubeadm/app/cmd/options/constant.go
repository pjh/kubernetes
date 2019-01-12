/*
Copyright 2018 The Kubernetes Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package options

// APIServerAdvertiseAddress flag sets the IP address the API Server will advertise it's listening on. Specify '0.0.0.0' to use the address of the default network interface.
const APIServerAdvertiseAddress = "apiserver-advertise-address"

// APIServerBindPort flag sets the port for the API Server to bind to.
const APIServerBindPort = "apiserver-bind-port"

// APIServerCertSANs flag sets extra Subject Alternative Names (SANs) to use for the API Server serving certificate. Can be both IP addresses and DNS names.
const APIServerCertSANs = "apiserver-cert-extra-sans"

// APIServerExtraArgs flag sets a extra flags to pass to the API Server or override default ones in form of <flagname>=<value>.
const APIServerExtraArgs = "apiserver-extra-args"

// CertificatesDir flag sets the path where to save and read the certificates.
const CertificatesDir = "cert-dir"

// CfgPath flag sets the path to kubeadm config file.
const CfgPath = "config"

// ControllerManagerExtraArgs flag sets extra flags to pass to the Controller Manager or override default ones in form of <flagname>=<value>.
const ControllerManagerExtraArgs = "controller-manager-extra-args"

// DryRun flag instruct kubeadm to don't apply any changes; just output what would be done.
const DryRun = "dry-run"

// FeatureGatesString flag sets key=value pairs that describe feature gates for various features.
const FeatureGatesString = "feature-gates"

// IgnorePreflightErrors sets the path a list of checks whose errors will be shown as warnings. Example: 'IsPrivilegedUser,Swap'. Value 'all' ignores errors from all checks.
const IgnorePreflightErrors = "ignore-preflight-errors"

// ImageRepository sets the container registry to pull control plane images from.
const ImageRepository = "image-repository"

// KubeconfigDir flag sets the path where to save the kubeconfig file.
const KubeconfigDir = "kubeconfig-dir"

// KubeconfigPath flag sets the kubeconfig file to use when talking to the cluster. If the flag is not set, a set of standard locations are searched for an existing KubeConfig file.
const KubeconfigPath = "kubeconfig"

// KubernetesVersion flag sets the Kubernetes version for the control plane.
const KubernetesVersion = "kubernetes-version"

// NetworkingDNSDomain flag sets the domain for services, e.g. "myorg.internal".
const NetworkingDNSDomain = "service-dns-domain"

// NetworkingServiceSubnet flag sets the range of IP address for service VIPs.
const NetworkingServiceSubnet = "service-cidr"

// NetworkingPodSubnet flag sets the range of IP addresses for the pod network. If set, the control plane will automatically allocate CIDRs for every node.
const NetworkingPodSubnet = "pod-network-cidr"

// NodeCRISocket flag sets the CRI socket to connect to.
const NodeCRISocket = "cri-socket"

// NodeName flag sets the node name.
const NodeName = "node-name"

// SchedulerExtraArgs flag sets extra flags to pass to the Scheduler or override default ones in form of <flagname>=<value>".
const SchedulerExtraArgs = "scheduler-extra-args"

// SkipTokenPrint flag instruct kubeadm to skip printing of the default bootstrap token generated by 'kubeadm init'.
const SkipTokenPrint = "skip-token-print"

// CSROnly flag instructs kubeadm to create CSRs instead of automatically creating or renewing certs
const CSROnly = "csr-only"

// CSRDir flag sets the location for CSRs and flags to be output
const CSRDir = "csr-dir"

// TokenStr flag sets the token
const TokenStr = "token"

// TokenTTL flag sets the time to live for token
const TokenTTL = "token-ttl"

// TokenUsages flag sets the usages of the token
const TokenUsages = "usages"

// TokenGroups flag sets the authentication groups of the token
const TokenGroups = "groups"

// TokenDescription flag sets the description of the token
const TokenDescription = "description"
