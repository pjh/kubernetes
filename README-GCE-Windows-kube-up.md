# Starting a Windows Kubernetes cluster on GCE using kube-up

## Bring up the cluster

Prerequisites: a Google Cloud Platform project.

### 0. Clone the repository and check out the branch
On a Linux machine: clone this repository under your `$GOPATH/src` directory
then run:

```
# Checkout the Windows branch:
git checkout windows-up

# Remove files that interfere with get-kube / kube-up:
rm -rf ./kubernetes/; rm -f kubernetes.tar.gz; rm -f ~/.kube/config

# Set environment variables needed by kube-up scripts:
source cluster/gce/kube-up-gce-windows-netd.env

# Set the default gcloud project for this shell. This is optional but convenient
# if you're working with multiple projects and don't want to repeatedly switch
# between gcloud config configurations.
export CLOUDSDK_CORE_PROJECT=<your_project_name>
```

### 1. Build Kubernetes

When building Kubernetes, you can choose to build all node binaries for Windows
(`kubelet`, `kube-proxy`, and `kubectl`) from source, or simply download them
from a specific Kubernetes versioned release. If you are developing against
those components, please follow 1.a to build them locally. Otherwise, see 1.b.

#### 1.a Build everything from source

The most straightforward approach to build those binaries is to run `make
release`. However, that builds binaries for all supported platforms, and can be
slow. You can speed up the process by following the instructions below to only
build the necessary binaries.
```
# Apply the patch to build windows binaries
curl https://raw.githubusercontent.com/yujuhong/gce-k8s-windows-testing/master/0001-Build-windows-biniaries-when-running-make-quick-rele.patch \
 | git apply

# Build binaries for both Linux and Windows
make quick-release

# Ensure locally-built binaries are used
unset USE_RELEASE_NODE_BINARIES
```

#### 1.b Use prebuilt Windows binaries

Alternatively, you can download the released Windows binaries. Note that if you
have made changes to `kubelet`, `kube-proxy`, or `kubectl`, you will have to
build them locally following the instructions in 1.a.

```
make quick-release

# Set the variable so that everything except for the node binaries will be
# built locally.
export USE_RELEASE_NODE_BINARIES=true

# Optionally, you can set KUBE_VERSION to choose the version of node binaries
# to download. The default version is v1.13.2
# export KUBE_VERSION=v1.13.2
```

### 2 Create a Kubernetes cluster

You can create a regular Kubernetes cluster, or a end-to-end test cluster.
Please make sure you set the environement variables properly following the
instructions in the previous section.

#### 2.a Create a regular Kubernetes cluster

```
# Invoke kube-up.sh with these environment variables:
#   PROJECT: text name of your GCP project.
#   KUBERNETES_SKIP_CONFIRM: skips any kube-up prompts.
PROJECT=${CLOUDSDK_CORE_PROJECT} KUBERNETES_SKIP_CONFIRM=y ./cluster/kube-up.sh
```

To teardown the cluster run:

```
PROJECT=${CLOUDSDK_CORE_PROJECT} KUBERNETES_SKIP_CONFIRM=y ./cluster/kube-down.sh
```

#### 2.b Create a Kubernetes end-to-end (E2E) test cluster

```
PROJECT=${CLOUDSDK_CORE_PROJECT} go run ./hack/e2e.go  -- --up
```
This command, by default, tears down the existing E2E cluster and create a new
one.

No matter what type of cluster you chose to create, the result should be a
Kubernetes cluster with one Linux master node, two Linux worker nodes and two
Windows worker nodes. The number of nodes can be adjusted by setting the
`NUM_LINUX_NODES` and `NUM_WINDOWS_NODES` environment variables before running
the commands to bring up the cluster. The Linux nodes will use the `netd` CNI
plugin and the Windows nodes will use `win-bridge`.


## Validating the cluster

Invoke this script to run a smoke test that verifies that the cluster has been
brought up correctly:

```
cluster/gce/windows/smoke-test.sh
```

## Running tests against the cluster

These steps are based on the
[e2e-win-prow-deployment](https://github.com/e2e-win/e2e-win-prow-deployment)
steps.

*   Ensure that you're using the patched `cluster/local/util.sh` in this branch.

*   If necessary run `alias kubectl=client/bin/kubectl` .

*   Set the following environment variables (these values should make sense if
    you built your cluster using the kube-up steps above):

    ```
    export KUBE_HOME=$(pwd)
    export KUBECONFIG=~/.kube/config
    export KUBE_MASTER=local
    export KUBE_MASTER_NAME=kubernetes-master
    export KUBE_MASTER_IP=$(kubectl get node ${KUBE_MASTER_NAME} -o jsonpath='{.status.addresses[?(@.type=="ExternalIP")].address}')
    export KUBE_MASTER_URL=https://${KUBE_MASTER_IP}
    export KUBE_MASTER_PORT=443
    ```

*   Download the list of Windows e2e tests:

    ```
    curl https://raw.githubusercontent.com/e2e-win/e2e-win-prow-deployment/master/repo-list.txt -o ${KUBE_HOME}/repo-list.yaml
    export KUBE_TEST_REPO_LIST=${KUBE_HOME}/repo-list.yaml
    ```

*   Download and configure the list of tests to exclude:

    ```
    curl https://raw.githubusercontent.com/e2e-win/e2e-win-prow-deployment/master/exclude_conformance_test.txt -o ${KUBE_HOME}/exclude_conformance_test.txt
    export EXCLUDED_TESTS=$(cat exclude_conformance_test.txt |
      tr -d '\r' |                # remove Windows carriage returns
      tr -s '\n' '|' |            # coalesce newlines into |
      tr -s ' ' '.' |             # coalesce spaces into .
      sed -e 's/[]\[()]/\\&/g' |  # escape brackets and parentheses
      sed -e 's/.$//g')           # remove final | added by tr
    ```

*   Taint the Linux nodes so that test pods will not land on them:

    ```
    export LINUX_NODES=$(kubectl get nodes -l beta.kubernetes.io/os=linux,kubernetes.io/hostname!=${KUBE_MASTER_NAME} -o name)
    export LINUX_NODE_COUNT=$(echo ${LINUX_NODES} | wc -w)
    for node in $LINUX_NODES; do
      kubectl taint node $node node-under-test=false:NoSchedule
    done
    ```

*   Build necessary test binaries:

    ```
    make WHAT=test/e2e/e2e.test
    ```

*   Run the tests with flags that point at the "local" (already-running) cluster
    and that permit the `NoSchedule` Linux nodes:

    ```
    export KUBETEST_ARGS="--ginkgo.noColor=true "\
    "--report-dir=${KUBE_HOME}/e2e-reports "\
    "--allowed-not-ready-nodes=${LINUX_NODE_COUNT} "\
    "--ginkgo.dryRun=false "\
    "--ginkgo.focus=\[Conformance\] "\
    "--ginkgo.skip=${EXCLUDED_TESTS}"

    go run ${KUBE_HOME}/hack/e2e.go -- --verbose-commands \
      --ginkgo-parallel=4 \
      --check-version-skew=false --test --provider=local \
      --test_args="${KUBETEST_ARGS}" &> ${KUBE_HOME}/conformance.out
    ```

    TODO: copy log files from Windows nodes using some command like:

    ```
    scp -r -o PreferredAuthentications=keyboard-interactive,password \
      -o PubkeyAuthentication=no \
      user@kubernetes-minion-windows-group-mk0p:C:\\etc\\kubernetes\\logs \
      kubetest-logs/
    ```
