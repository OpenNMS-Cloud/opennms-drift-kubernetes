#!/bin/sh

infra_up() {
  SUBNET=$(az network vnet subnet show --vnet-name vnet-flows --name default -g $RG -o tsv --query 'id')
  if [ -z "$SUBNET" ]; then
    echo "Creating vnet"
    SUBNET=$(az network vnet create --name vnet-flows --address-prefix 10.5.0.0/16 -g ${RG} --subnet-name default --subnet-prefix 10.5.0.0/24 -o tsv --query 'newVNet.subnets[0].id')
  fi
#  ES_SUBNET=$(az network vnet subnet create --address-prefixes 10.5.1.0/24 -g ${RG} -n elastic --vnet-name vnet-flows -o tsv --query 'id')

  echo "Creating Kubernetes cluster"
  az aks create -n k8s-flows -g ${RG} -p flows -s Standard_DS5_v2 --vnet-subnet-id=${SUBNET} -c 2

#  echo "Creating Kafka HD Insight cluster"
#  az storage account create -n kafkaflowshdistorage -g ${RG} --sku Standard_LRS
#  az hdinsight create -n kafka-flows -g ${RG} -t kafka --component-version kafka=2.1 --subnet ${SUBNET} --http-password "${KAFKA_PASSWORD}" --http-user "${KAFKA_USER}" --workernode-data-disks-per-node 2 --storage-account kafkaflowshdistorage

  # TODO: Deploy elasticsearch cluster into subnet 'elastic'
}

infra_down() {
  az aks delete -g ${RG} -n k8s-flows -y
#  az hdinsight delete -n kafka-flows -g ${RG} -y
  # TODO: delete elastic cluster
  az network vnet delete --name vnet-flows -g ${RG}
}

kube_up() {
    az aks get-credentials -g ${RG} -n k8s-flows

    if ! kubectl get ns cert-manager; then
      ./cert-mgr.sh up
    fi

    if ! kubectl get ns ingress-nginx; then
      ./ingress.sh up
    fi
  
    kubectl create ns ${NAMESPACE}

    create_settings
    create_secret

#    echo "Installing a DNS cache service"
#    kubectl create cm -n ${NAMESPACE} dnscache-conf --from-file unbound.conf
#    kubectl apply -n ${NAMESPACE} -f dnscache.yaml
#    DNSIP=""
#    while [ "$DNSIP" = "" ]; do
#        DNSIP=$(kubectl get svc dnscache -n ${NAMESPACE} | grep -Eo "ClusterIP\s+\S+\s+" | awk '{print $2}')
#    done
#    echo "Using DNS cache address: $DNSIP"
#    sed -i "s/^nameservers = .*$/nameservers = $DNSIP/" config/onms-minion-init.sh


    echo "Installing OpenNMS"
    kubectl create cm -n ${NAMESPACE} init-scripts --from-file=config
#    kubectl apply -f k8s -n ${NAMESPACE}
    kubectl apply -f k8s/postgresql.yaml -n $NAMESPACE
    kubectl apply -f k8s/opennms.core.yaml -n $NAMESPACE
    kubectl apply -f k8s/opennms.minion.yaml -n $NAMESPACE
    kubectl apply -f k8s/opennms.sentinel.yaml -n $NAMESPACE
    kubectl apply -f k8s/cmak.yaml -n $NAMESPACE

    echo "Installing Flink"
    kubectl apply -f flink -n ${NAMESPACE}

    echo "Configuring ingress"
    kubectl apply -f external-access.yaml -n ${NAMESPACE}

#    echo "Restarting traffic generators"
#    kubectl delete -f k8s/udpgen.yaml -n ${NAMESPACE}
#    sleep 4
#    kubectl apply -f k8s/udpgen.yaml -n ${NAMESPACE}

}

kube_down() {
    kubectl delete ns ${NAMESPACE}
}

up() {
  infra_up
  kube_up
}

down() {
  echo "Omae wa mou shindeiru..."
  kube_down
  infra_down
}

create_secret() {
    export ELASTIC_PASSWORD_B64=$(echo -n $ELASTIC_PASSWORD|base64)
    export POSTGRES_PASSWORD_B64=$(echo -n $POSTGRES_PASSWORD|base64)
    export OPENNMS_UI_ADMIN_PASSWORD_B64=$(echo -n admin|base64) # TODO: random strong password
    export HASURA_GRAPHQL_ACCESS_KEY_B64=$(echo -n 0p3nNMS|base64) # TODO: random strong password
    export GRAFANA_UI_ADMIN_PASSWORD_B64=${HASURA_GRAPHQL_ACCESS_KEY_B64}
    export GRAFANA_DB_PASSWORD_B64=$(echo -n grafana|base64) # TODO: strong random password

    echo "Kafka: ${KAFKA_USER} / ${KAFKA_PASSWORD}"
    echo "Elastic: ${ELASTIC_USER} / ${ELASTIC_PASSWORD}"

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
  HASURA_GRAPHQL_ACCESS_KEY: ${HASURA_GRAPHQL_ACCESS_KEY_B64}
  GRAFANA_UI_ADMIN_PASSWORD: ${GRAFANA_UI_ADMIN_PASSWORD_B64}
  GRAFANA_DB_PASSWORD: ${GRAFANA_DB_PASSWORD_B64}
EOT
}

create_settings() {
  export KAFKA_SERVER=$(curl -sS -u ${KAFKA_USER}:${KAFKA_PASSWORD} -G https://${HDI}/api/v1/clusters/kafka-flows/services/KAFKA/components/KAFKA_BROKER | jq -r '["\(.host_components[].HostRoles.host_name)"] | join(",")' | cut -d',' -f1)
  export ZK_SERVER=$(echo $KAFKA_SERVER|sed -e 's/^wn0/zk0/')
#  export ELASTIC_SERVER=$(az vm list-ip-addresses -n esdata-0 -g ${RG} --query '[0].virtualMachine.network.privateIpAddresses[0]')
  export ELASTIC_SERVER=10.5.1.4

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
  ZK_SERVER: ${ZK_SERVER}
  ELASTIC_SERVER: ${ELASTIC_SERVER}
  POSTGRES_SERVER: ${POSTGRES_SERVER}
  ELASTIC_SHARDS: '12'
  LISTEN_THREADS: '140'
EOT
}

### ENTRY POINT ###

export RG="cloud-dev-flows"

export DOMAIN="flows.cloud.opennms.com"
export EMAIL="saas@opennms.com"
export NAMESPACE="opennms"

export HDI=kafka-flows.azurehdinsight.net
export KAFKA_USER=admin
export KAFKA_PASSWORD=${KAFKA_PASSWORD:-$(pwgen -ycnB 20 1)}

export ELASTIC_USER=elastic
export ELASTIC_PASSWORD="${KAFKA_PASSWORD}"
export ELASTIC_INTERNAL_PASSWORD=${KAFKA_PASSWORD}

export POSTGRES_SERVER=postgresql.${NAMESPACE}.svc.cluster.local
export POSTGRES_USER=postgres
export POSTGRES_PASSWORD=postgres

export VM_IMAGE_URN='Canonical:UbuntuServer:18.04-LTS:latest'
export KAFKA_VM_SIZE='Standard_DS4_v2' # 8 CPU, 28 GB RAM

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
