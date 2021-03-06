# Setup Cluster with EKS

> WARNING: This is a work in progress.

## Requirements

* Install the [AWS CLI](https://aws.amazon.com/cli/).
* Have your AWS account (IAM Credentials) configured on your system (`~/.aws/credentials`).
* Install the [eksctl](https://eksctl.io/) binary.

## DNS Configuration

Create DNS sub-domain on [Route 53](https://console.aws.amazon.com/route53/home), register it as an `NS` entry on your registrar matching the name servers from the sub-domain, and make sure it works prior start the cluster; for example:

```bash
dig ns aws.agalue.net
```

The output should look like this:

```text
; <<>> DiG 9.10.6 <<>> ns aws.agalue.net
;; global options: +cmd
;; Got answer:
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 46163
;; flags: qr rd ra; QUERY: 1, ANSWER: 4, AUTHORITY: 0, ADDITIONAL: 1

;; OPT PSEUDOSECTION:
; EDNS: version: 0, flags:; udp: 4096
;; QUESTION SECTION:
;aws.agalue.net.      IN  NS

;; ANSWER SECTION:
aws.agalue.net.   172800  IN  NS  ns-1821.awsdns-35.co.uk.
aws.agalue.net.   172800  IN  NS  ns-718.awsdns-25.net.
aws.agalue.net.   172800  IN  NS  ns-1512.awsdns-61.org.
aws.agalue.net.   172800  IN  NS  ns-144.awsdns-18.com.

;; Query time: 85 msec
;; SERVER: 172.20.1.9#53(172.20.1.9)
;; WHEN: Mon Apr 29 14:16:37 EDT 2019
;; MSG SIZE  rcvd: 180
```

> **WARNING**: Please use your own Domain, meaning that every time the domain `aws.agalue.net` is mentioned or used, replace it with your own.

## Cluster Creation

Create the Kubernetes cluster using `eksctl`. The following example creates a cluster with 1 master node and 6 worker nodes:

```bash
eksctl create cluster \
  --name opennms \
  --version 1.14 \
  --region us-east-2 \
  --nodegroup-name onms-fleet \
  --node-type t2.2xlarge \
  --nodes 6 \
  --tags Environment=Test,Department=Support \
  --ssh-access \
  --external-dns-access \
  --alb-ingress-access \
  --managed
```

This process could take in average between 15 to 20 minutes to complete. The above command will finish when the cluster is ready.

To check if the cluster is active:

```bash
eksctl get cluster opennms
```

The output should be something like this:

```text
NAME	VERSION	STATUS	CREATED			VPC			SUBNETS										SECURITYGROUPS
opennms	1.14	ACTIVE	2019-11-19T18:31:45Z	vpc-0ba92160c1b9c36bd	subnet-02b614a06818c80a3,subnet-03484aa51fe7d7045,subnet-07e1b1be81687054c,subnet-08663ab52ff8ee348,subnet-08c5c04a3487ed4db,subnet-0e4e3304642c52875	sg-0d2a3cac05d2b6e78
```

Then,

```bash
kubectl cluster-info
```

The output should be something like this:

```text
Kubernetes master is running at https://7B58353198925AA605F877A99F3E85A2.sk1.us-east-2.eks.amazonaws.com
CoreDNS is running at https://7B58353198925AA605F877A99F3E85A2.sk1.us-east-2.eks.amazonaws.com/api/v1/namespaces/kube-system/services/kube-dns:dns/proxy

To further debug and diagnose cluster problems, use 'kubectl cluster-info dump'.
```

## Install the Ingress Controller

This add-on is required in order to avoid having a LoadBalancer per external service.

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/nginx-0.30.0/deploy/static/mandatory.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/nginx-0.30.0/deploy/static/provider/aws/service-l4.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/nginx-0.30.0/deploy/static/provider/aws/patch-configmap-l4.yaml
```

For Route53 mapping:

 ```bash
export DOMAIN=aws.agalue.net
export OWNER=agalue

curl https://raw.githubusercontent.com/kubernetes-sigs/aws-alb-ingress-controller/v1.1.3/docs/examples/external-dns.yaml 2>/dev/null | sed "s/--domain-filter=.*/--domain-filter=$DOMAIN/" | sed "s/--txt-owner-id=.*/--txt-owner-id=$OWNER/" | kubectl apply -f -
```

> **WARNING**: Please use your own domain.

## Install the CertManager

```bash
kubectl create namespace cert-manager
kubectl apply --validate=false -f https://github.com/jetstack/cert-manager/releases/download/v0.13.1/cert-manager.yaml
```

## Install Jaeger CRDs

```bash
kubectl apply -f https://raw.githubusercontent.com/jaegertracing/jaeger-operator/master/deploy/crds/jaegertracing.io_jaegers_crd.yaml
```

## Security Groups

When configuring Kafka, the `hostPort` is used in order to configure the `advertised.listeners` using the EC2 public FQDN. For this reason the external port (i.e. `9094`) should be opened on the security group called `eksctl-opennms-cluster/ClusterSharedNodeSecurityGroup`. Certainly, this can be done manually, but a `Terraform` recipe has been used for this purpose (check `update-security-groups.tf` for more details).

When using `kops`, the NGinx Ingress controller will be auto-magically associatd with Route53. Unfortunately, for `eks` we need an wildcard entry to make sure every host on the chosen sub-domain will hit the ALB.

Make sure `terraform` it installed on your system, and then execute the following:

```bash
export AWS_REGION="us-east-2"

pushd eks
terraform init
terraform apply -var "region=$AWS_REGION" -auto-approve
popd
```

## Manifets

To apply all the manifests:

```bash
kubectl apply -k manifests
```

If you're not running `kubectl` version 1.14, the following is an alternative:

```bash
kustomize build manifests | kubectl apply -f
```

## Install Jaeger Tracing

```bash
kubectl apply -n opennms -f https://raw.githubusercontent.com/jaegertracing/jaeger-operator/master/deploy/service_account.yaml
kubectl apply -n opennms -f https://raw.githubusercontent.com/jaegertracing/jaeger-operator/master/deploy/role.yaml
kubectl apply -n opennms -f https://raw.githubusercontent.com/jaegertracing/jaeger-operator/master/deploy/role_binding.yaml
kubectl apply -n opennms -f https://raw.githubusercontent.com/jaegertracing/jaeger-operator/master/deploy/operator.yaml
```

## Cleanup

To remove the Kubernetes cluster, do the following:

```bash
kubectl delete ingress ingress-rules --namespace opennms
kubectl delete service ext-kafka --namespace opennms
sleep 10
eksctl delete cluster --name opennms --region us-east-2 --wait
```

The first 2 commands will trigger the removal of the Route 53 entries associated with the ingresses and the Kafka ELB. The last will take care of the rest (including the PVCs).

This process could take in average between 15 to 20 minutes to complete. If wait is not feasible, remove `--wait` from the command.
