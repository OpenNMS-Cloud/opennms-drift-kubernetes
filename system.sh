#!/bin/sh

infra_up() {
  SUBNET=$(az network vnet create --name vnet-flows --address-prefix 10.5.0.0/16 -g ${RG} --subnet-name default --subnet-prefix 10.5.0.0/24 -o json --query 'newVNet.subnets[0].id')

  az aks create -n k8s-flows -g ${RG} -p flows -s Standard_DS3_v2 -z 1 --vnet-subnet-id=${SUBNET}

  az hdinsight create -n kafka-flows -g ${RG} -t kafka --component-version kafka=2.1 --subnet ${SUBNET} --http-password "${KAFKA_PASSWORD}" --http-user "${KAFKA_USER}" --workernode-data-disks-per-node 1

  #az postgres server create -n ${POSTGRES_SERVER} -g ${RG} --version 11 --sku-name GP_Gen5_4 -p "${POSTGRES_PASSWORD}" -u "${POSTGRES_USER}"

  # TODO: Add another subnet 10.5.1.0/24 as 'elastic'
  # TODO: Deploy elasticsearch cluster into subnet 'elastic'
}

infra_down() {
  az aks delete -g ${RG} -n k8s-flows -y
  az hdinsight delete -n kafka-flows -g ${RG} -y
  # TODO: delete elastic cluster
  az network vnet delete --name vnet-flows -g ${RG}
}

kube_up() {
    az aks get-credentials -g ${RG} -n k8s-flows
    kubectl create ns ${NAMESPACE}

    create_settings
    create_secret

    echo "Installing a DNS cache service"
    kubectl create cm -n ${NAMESPACE} dnscache-conf --from-file unbound.conf
    kubectl apply -n ${NAMESPACE} -f dnscache.yaml
    DNSIP=""
    while [ "$DNSIP" = "" ]; do
        DNSIP=$(kubectl get svc dnscache -n ${NAMESPACE} | grep -Eo "ClusterIP\s+\S+\s+" | awk '{print $2}')
    done
    echo "Using DNS cache address: $DNSIP"
    sed -i "s/^nameservers = .*$/nameservers = $DNSIP/" config/onms-minion-init.sh

    ./ingress.sh up

    echo "Installing Jaeger CRDs"
    kubectl apply -n ${NAMESPACE} -f https://raw.githubusercontent.com/jaegertracing/jaeger-operator/master/deploy/crds/jaegertracing.io_jaegers_crd.yaml

    echo "Installing OpenNMS"
    kubectl create cm -n ${NAMESPACE} init-scripts --from-file=config

    kubectl apply -f k8s -n ${NAMESPACE}
    kubectl apply -f manifests/external-access.yaml -n ${NAMESPACE}

    kubectl apply -f flink -n ${NAMESPACE}
    kubectl apply -f udpgen.yaml -n ${NAMESPACE}
}

kube_down() {
    ./ingress.sh down
    kubectl delete ns ${NAMESPACE}
}

up() {
  infra_up
  kube_up
}

down() {
  kube_down
  infra_down
}

create_secret() {
    export ELASTIC_PASSWORD_B64=$(echo -n $ELASTIC_PASSWORD|base64)
    export POSTGRES_PASSWORD_B64=$(echo -n $POSTGRES_PASSWORD|base64)
    export OPENNMS_UI_ADMIN_PASSWORD_B64=$(echo -n admin|base64) # TODO: random strong password

    kubectl -n $NAMESPACE apply -f -<<EOT
apiVersion: v1
kind: Secret
type: Opaque
metadata:
  name: onms-passwords
data:
  ELASTIC_PASSWORD: ${ELASTIC_PASSWORD_B64}
  POSTGRES_PASSWORD: ${POSTGRES_PASSWORD_B64}
  OPENNMS_UI_ADMIN_PASSWORD: ${OPENNMS_UI_ADMIN_PASSWORD_B64}
EOT
}

create_settings() {
  export KAFKA_SERVER=$(curl -sS -u ${KAFKA_USER}:${KAFKA_PASSWORD} -G https://${HDI}/api/v1/clusters/kafka-flows/services/KAFKA/components/KAFKA_BROKER | jq -r '["\(.host_components[].HostRoles.host_name)"] | join(",")' | cut -d',' -f1)
  
  export ELASTIC_SERVER=$(az vm list-ip-addresses -n flowsdata-0 -g ${RG} --query '[0].virtualMachine.network.privateIpAddresses[0]')

  kubectl -n $NAMESPACE apply -f -<<EOT
apiVersion: v1
kind: ConfigMap
metadata:
  name: common-settings
data:
  TIMEZONE: 'America/New_York'
  OPENNMS_INSTANCE_ID: K8S
  MINION_LOCATION: Kubernetes
  KAFKA_SERVER: ${KAFKA_SERVER}
  ELASTIC_SERVER: ${ELASTIC_SERVER}
  POSTGRES_SERVER: ${POSTGRES_SERVER}
EOT
}

### ENTRY POINT ###

export RG="cloud-dev"

export DOMAIN="flows.cloud.opennms.com"
export EMAIL="saas@opennms.com"
export NAMESPACE="opennms"

export HDI=kafka-flows.azurehdinsight.net
export KAFKA_USER=admin
export KAFKA_PASSWORD=${KAFKA_PASSWORD:-$(pwgen -ycnB 20 1)}

export ELASTIC_USER=opennms
export ELASTIC_PASSWORD="${KAFKA_PASSWORD}"
export ELASTIC_INTERNAL_PASSWORD=${ELASTIC_INTERNAL_PASSWORD:-$(pwgen -yncB 20 1)}

export POSTGRES_SERVER=postgresql.${NAMESPACE}.svc.cluster.local
export POSTGRES_USER=postgres
export POSTGRES_PASSWORD=postgres

echo "Kafka: ${KAFKA_USER} / ${KAFKA_PASSWORD}"
echo "Elastic: ${ELASTIC_USER} / ${ELASTIC_PASSWORD}"
echo "Postgres: ${POSTGRES_USER} / ${POSTGRES_PASSWORD}"

case "$1" in
    settings) create_settings; create_secret ;;
    up) up ;;
    infraup) infra_up ;;
    kubeup) kube_up ;;
    down) down ;;
    infradown) infra_down ;;
    kubedown) kube_down ;;
    *) echo $(basename $0) '(up|down)' ;;
esac
