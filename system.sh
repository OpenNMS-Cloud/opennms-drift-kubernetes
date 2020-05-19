#!/bin/sh

infra_up() {
  SUBNET=$(az network vnet subnet show --vnet-name vnet-flows --name default -g $RG -o tsv --query 'id')
  if [ -z "$SUBNET" ]; then
    echo "Creating vnet"
    SUBNET=$(az network vnet create --name vnet-flows --address-prefix 10.5.0.0/16 -g ${RG} --subnet-name default --subnet-prefix 10.5.0.0/24 -o tsv --query 'newVNet.subnets[0].id')
  fi

  echo "Creating Elasticsearch cluster"
  # must be done first so it can get certain IPs
  TMPFILE=$(mktemp)
  cat >$TMPFILE <<EOF
  {
    "adminPassword": {
        "value": "${ELASTIC_PASSWORD}"
    },
    "sshPublicKey": {
        "value": "$(cat ~/.ssh/id_rsa.pub)"
    },
    "securityBootstrapPassword": {
        "value": "${ELASTIC_PASSWORD}"
    },
    "securityAdminPassword": {
        "value": "${ELASTIC_PASSWORD}"
    },
    "securityKibanaPassword": {
        "value": "${ELASTIC_PASSWORD}"
    },
    "securityLogstashPassword": {
        "value": "${ELASTIC_PASSWORD}"
    },
    "securityBeatsPassword": {
        "value": "${ELASTIC_PASSWORD}"
    },
    "securityApmPassword": {
        "value": "${ELASTIC_PASSWORD}"
    },
    "securityRemoteMonitoringPassword": {
        "value": "${ELASTIC_PASSWORD}"
    }
  }
EOF
  az deployment group create -g $RG --name esflows --template-file es-template.json \
    --parameters @es-parameters.json --parameters @$TMPFILE
  rm -f $TMPFILE

  echo "Resizing client VMs for ingestion"
  az vm resize -g $RG --name esclient-0 --size Standard_D8s_v3
  az vm resize -g $RG --name esclient-1 --size Standard_DS4_v2

  echo "Creating Kubernetes cluster"
  az aks create -n k8s-flows -g ${RG} -p flows -s Standard_DS5_v2 --vnet-subnet-id ${SUBNET} -c 2
  echo "MOAR COARS"
  az aks nodepool add --cluster-name k8s-flows --name nodepool2 -g ${RG} \
    --node-vm-size Standard_DS3_v2 --vnet-subnet-id ${SUBNET} --node-count 3

  TMPFILE=$(mktemp)
  cat >$TMPFILE <<EOF
  {
    "clusterLoginPassword": {
      "value": "${KAFKA_PASSWORD}"
    },
    "sshPassword": {
      "value": "${KAFKA_PASSWORD}"
    }
 }
EOF

  echo "Creating Kafka HD Insight cluster"
  az deployment group create -g $RG --name kafka-flows --template-file hdi-template.json \
    --parameters @hdi-parameters.json --parameters @$TMPFILE
  rm -f $TMPFILE
}

infra_postup() {
  DATANODES=$(seq -f 'esdata-%.0f' 0 11)
  CLIENTNODES=$(seq -f 'esclient-%.0f' 0 1)
  rm nodes
  for x in $DATANODES $CLIENTNODES; do
    IP=$(az vm show -n $x -g cloud-dev-flows -d --query 'privateIps' -o tsv)
    echo $IP $x >> nodes
  done

  cat >runme <<EOF
ssh-keygen -N "" -f .ssh/new -t rsa
cat .ssh/new.pub >> .ssh/authorized_keys
sudo bash -c 'cat nodes >> /etc/hosts'
awk '{print \$2}' nodes|sed -e 's/ //g' > names
for x in \$(cat names); do
  scp -oStrictHostKeyChecking=no .ssh/authorized_keys \$x:.ssh/authorized_keys
done
for x in \$(cat names); do
  ssh \$x sudo cp -v .ssh/authorized_keys /root/.ssh/authorized_keys
done
mv -f .ssh/new .ssh/id_rsa
mv -f .ssh/new.pub .ssh/id_rsa.pub
EOF

  KIBANA=$(az vm show -n eskibana -g $RG -d --query 'fqdns' -o tsv)
  scp ~/.ssh/id_rsa ~/.ssh/id_rsa.pub $ELASTIC_USER@$KIBANA:.ssh
  scp nodes runme $ELASTIC_USER@$KIBANA:
  ssh -A $ELASTIC_USER@$KIBANA sh ./runme
  ssh $ELASTIC_USER@$KIBANA ssh esdata-0 echo ok

  echo "Installing netflow aggregate template from nephron"
  scp ../nephron/main/src/main/resources/netflow_agg-template.json $ELASTIC_USER@$KIBANA:
  ssh $ELASTIC_USER@$KIBANA curl -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
    -XPUT -H \'Content-Type: application/json\' \
    http://esdata-0:9200/_template/netflow_agg -d@./netflow_agg-template.json
}

infra_down() {
  echo "お前 は もう　しんでいる..."
  az resource delete --ids $(az resource list -g ${RG} -o tsv --query '[*].id')
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

#   echo "Installing a DNS cache service"
#   kubectl create cm -n ${NAMESPACE} dnscache-conf --from-file unbound.conf
#   kubectl apply -n ${NAMESPACE} -f dnscache.yaml
#   DNSIP=""
#   while [ "$DNSIP" = "" ]; do
#       DNSIP=$(kubectl get svc dnscache -n ${NAMESPACE} | grep -Eo "ClusterIP\s+\S+\s+" | awk '{print $2}')
#   done
#   echo "Using DNS cache address: $DNSIP"
#   sed -i "s/^nameservers = .*$/nameservers = $DNSIP/" config/onms-minion-init.sh


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

neph_up() {
  if [ -d ../nephron ] && [ ! -f nephron-flink-bundled*.jar ]; then
    cd ../nephron
    mvn clean package
    cd -
    cp -fv ../nephron/assemblies/flink/target/nephron-flink-bundled*.jar .
  fi

  JOBPOD=$(kubectl -n opennms get pod | grep jobmanager | awk '{print $1}')
  KAFKA_SERVER=$(curl -sS -u ${KAFKA_USER}:${KAFKA_PASSWORD} -G https://${HDI}/api/v1/clusters/kafka-flows/services/KAFKA/components/KAFKA_BROKER | jq -r '["\(.host_components[].HostRoles.host_name)"] | join(",")' | cut -d',' -f1)

  echo "Copying nephron jar to $JOBPOD"
  kubectl -n $NAMESPACE cp nephron-flink-bundled*.jar ${JOBPOD}:nephron.jar
  kubectl -n $NAMESPACE exec -it ${JOBPOD} -- ./bin/flink run -d --parallelism 6 \
  --class org.opennms.nephron.Nephron nephron.jar --fixedWindowSizeMs=1000 \
  --runner=FlinkRunner --jobName=nephron --checkpointingInterval=60000 \
  --autoCommit=false --topK=10 --disableMetrics=true \
  --bootstrapServers=${KAFKA_SERVER}:9092 --elasticIndexStrategy=MONTHLY \
  --elasticUser=${ELASTIC_USER} --elasticPassword=${ELASTIC_PASSWORD} \
  --elasticUrl=http://10.5.0.4:9200
}

up() {
  infra_up
  infra_postup
  kube_up
  neph_up
}

down() {
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
  export ELASTIC_SERVER=10.5.0.4

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

case "$1" in
    settings) create_settings; create_secret ;;
    up) up ;;
    down) down ;;
    *) $1_$2 ;;
esac
