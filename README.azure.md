# Setup Cluster with Azure

> WARNING: This is a work in progress.

## Requirements

* Install the [Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli?view=azure-cli-latest).

## Configure the Azure CLI

Login into Azure:

```bash
az login
```

## Create common environment variables:

```bash
export GROUP="Kubernetes"
export LOCATION="East US"
export DOMAIN="azure.agalue.net"
```

## Create a Resource Group:

```bash
az group create --name "$GROUP" --location "$LOCATION"
```

## DNS Configuration

Create a DNS Zone:

```bash
az network dns zone create -g "$GROUP" -n "$DOMAIN"
```

> **WARNING**: Make sure to add a `NS` record on your registrar pointing to the Domain Servers returned from the above command.

## Cluster Creation

> **WARNING**: Make sure you have enough quota on your Azure to create all the resources. Be aware that trial accounts cannot request quota changes. A reduced version is available in order to test the deployment.

Create a service principal account:

```
az ad sp create-for-rbac --skip-assignment --name opennmsAKSClusterServicePrincipal
```

From the output, create an environment variable called `APP_ID` with the content of the `appId` field, and another one called `PASSWORD` for the `password` field. Those will be used on the following command.

```bash
az aks create --name opennms \
  --resource-group "$GROUP" \
  --service-principal "$APP_ID" \
  --client-secret "$PASSWORD" \
  --dns-name-prefix opennms \
  --kubernetes-version 1.15.7 \
  --location "$LOCATION" \
  --node-count 4 \
  --node-vm-size Standard_DS3_v2 \
  --nodepool-name onmspool \
  --network-plugin azure \
  --network-policy azure \
  --generate-ssh-keys \
  --tags Environment=Development
```

The following command can be used to verify which Kubernetes versions are available:

```bash
az aks get-versions --location "$LOCATION"
```

To validate the cluster:

```bash
az aks show --resource-group "$GROUP" --name opennms
```

To configure `kubectl`:

```bash
az aks get-credentials --resource-group "$GROUP" --name opennms
```

## Install the NGinx Ingress Controller

This add-on is required in order to avoid having a LoadBalancer per external service.

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/static/mandatory.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/static/provider/cloud-generic.yaml
```

## Install the CertManager

```bash
kubectl create namespace cert-manager
kubectl apply --validate=false -f https://github.com/jetstack/cert-manager/releases/download/v0.13.1/cert-manager.yaml
```

## Install Jaeger CRDs

```bash
kubectl apply -f https://raw.githubusercontent.com/jaegertracing/jaeger-operator/master/deploy/crds/jaegertracing.io_jaegers_crd.yaml
```

## Manifets

To apply all the manifests:

```bash
kubectl apply -k aks
```

> **NOTE**: The amount of resources has been reduced to avoid quota issues. The limits were designed to use a `Visual Studio Enterprise` Subscription. 

## Install Jaeger Tracing

```bash
kubectl apply -n opennms -f https://raw.githubusercontent.com/jaegertracing/jaeger-operator/master/deploy/service_account.yaml
kubectl apply -n opennms -f https://raw.githubusercontent.com/jaegertracing/jaeger-operator/master/deploy/role.yaml
kubectl apply -n opennms -f https://raw.githubusercontent.com/jaegertracing/jaeger-operator/master/deploy/role_binding.yaml
kubectl apply -n opennms -f https://raw.githubusercontent.com/jaegertracing/jaeger-operator/master/deploy/operator.yaml
```

## Security Groups

When configuring Kafka, the `hostPort` is used in order to configure the `advertised.listeners` using the workers public FQDN. For this reason, the external port (i.e. `9094`) should be opened. Fortunately, AKS does that auto-magically for you, so there is no need for changes.

However, by default, with AKS there is no public IP for the nodes; hence, nothing is reported via metadata. For this reason, external Kafka won't work. There is a [feature in preview](https://docs.microsoft.com/en-us/azure/aks/use-multiple-node-pools#assign-a-public-ip-per-node-in-a-node-pool) to let AKS assign a public IP per node in a node pool.

## Configure DNS Entry for the Ingress Controller and Kafka

With Kops and EKS, the External DNS controller takes care of the DNS entries. Here, we're going to use a different approach.

Find out the external IP of the Ingress Controller (wait for it, in case it is not there):

```bash
kubectl get svc ingress-nginx -n ingress-nginx
```

The output should be something like this:

```text
NAME            TYPE           CLUSTER-IP    EXTERNAL-IP      PORT(S)                      AGE
ingress-nginx   LoadBalancer   10.0.83.198   40.117.237.217   80:30664/TCP,443:30213/TCP   9m58s
```

Something similar can be done for Kafka:

```bash
kubectl get svc ext-kafka -n opennms
```

Create a wildcard DNS entry on your DNS Zone to point to the `EXTERNAL-IP`; and create an A record for `kafka`. For example:

```bash
export NGINX_EXTERNAL_IP=$(kubectl get svc ingress-nginx -n ingress-nginx -o json | jq -r '.status.loadBalancer.ingress[0].ip')
export KAFKA_EXTERNAL_IP=$(kubectl get svc ext-kafka -n opennms -o json | jq -r '.status.loadBalancer.ingress[0].ip')

az network dns record-set a add-record -g "$GROUP" -z "$DOMAIN" -n 'kafka' -a $KAFKA_EXTERNAL_IP
az network dns record-set a add-record -g "$GROUP" -z "$DOMAIN" -n '*' -a $NGINX_EXTERNAL_IP
```

## Cleanup

Remove the A Records from the DNS Zone:

```bash
az network dns record-set a remove-record -g "$GROUP" -z "$DOMAIN" -n 'kafka' -a $KAFKA_EXTERNAL_IP
az network dns record-set a remove-record -g "$GROUP" -z "$DOMAIN" -n '*' -a $NGINX_EXTERNAL_IP
```

Delete the cluster:

```bash
az aks delete --name opennms --resource-group "$GROUP"
```

> **WARNING**: Deleting the cluster may take several minutes to complete.
