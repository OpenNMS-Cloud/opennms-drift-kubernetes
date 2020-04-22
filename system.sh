#!/bin/sh

up() {
    kubectl create ns ${NAMESPACE}

    echo "Installing a DNS cache service"
    kubectl create cm -n ${NAMESPACE} dnscache-conf --from-file unbound.conf
    kubectl apply -n ${NAMESPACE} -f dnscache.yaml
    DNSIP=""
    while [ "$DNSIP" = "" ]; do
        DNSIP=$(kubectl get svc dnscache -n ${NAMESPACE} | grep -Eo "ClusterIP\s+\S+\s+" | awk '{print $2}')
    done
    echo "Using DNS cache address: $DNSIP"

    cp -f manifests/opennms.minion.yaml manifests/opennms.minion.yaml.bak
    cp -f manifests/config/onms-minion-init.sh manifests/config/onms-minion-init.sh.bak
    sed -i "s/__DNSIP__/$DNSIP/g" manifests/opennms.minion.yaml manifests/config/onms-minion-init.sh
    sed -i -e "s/__EMAIL__/$EMAIL/" -e "s/__DOMAIN__/$DOMAIN/g" manifests/external-access.yaml
    sed -i "s/__DOMAIN__/$DOMAIN/g" aks/patches/external-access.yaml aks/patches/common-settings.yaml
    kubectl apply -f debug.yaml -n ${NAMESPACE}
    ./ingress.sh up

    echo "Installing Jaeger CRDs"
    kubectl apply -n ${NAMESPACE} -f https://raw.githubusercontent.com/jaegertracing/jaeger-operator/master/deploy/crds/jaegertracing.io_jaegers_crd.yaml

    echo "Installing Drift"
    kubectl apply -k aks
    kubectl apply -f manifests/external-access.yaml -n ${NAMESPACE}

    echo "Waiting for external Kafka address"
    LBADDR=""
    while [ "$LBADDR" = "" ]; do
      LBADDR=$(kubectl get svc ext-kafka -n ${NAMESPACE} | grep -Eo "LoadBalancer\s+\S+\s+[0-9.]+\s+" | awk '{print $3}')
    done
    echo LoadBalancer "$LBADDR"

    echo "Publishing A records"
    az network dns record-set a add-record -z cloud.opennms.com --ttl 600 -g cloud-global -n 'kafka.flows' -a "$LBADDR"

    kubectl apply -f udpgen.yaml -n ${NAMESPACE}
}

down() {
    echo "Deleting A records"
    az network dns record-set a delete -z cloud.opennms.com -g cloud-global -n 'kafka.flows' -y
    ./ingress.sh down

    kubectl delete ns ${NAMESPACE}

    cp -f manifests/opennms.minion.yaml.bak manifests/opennms.minion.yaml
    cp -f manifests/config/onms-minion-init.sh.bak manifests/config/onms-minion-init.sh
}

status() {
    ./ingress.sh status
    kubectl get pod -n ${NAMESPACE}
    kubectl get svc dnscache -n ${NAMESPACE}

    ADMINUSER=$(kubectl -n ${NAMESPACE} get secret kafka-jaas -o jsonpath='{.data.KAFKA_ADMIN_USER}' | base64 -d)
    PASSWORD=$(kubectl -n ${NAMESPACE} get secret kafka-jaas -o jsonpath='{.data.KAFKA_ADMIN_PASSWORD}' | base64 -d)
    echo "Kafka admin user: $ADMINUSER Password: $PASSWORD"

    CLIENTUSER=$(kubectl -n ${NAMESPACE} get secret kafka-jaas -o jsonpath='{.data.KAFKA_CLIENT_USER}' | base64 -d)
    PASSWORD=$(kubectl -n ${NAMESPACE} get secret kafka-jaas -o jsonpath='{.data.KAFKA_CLIENT_PASSWORD}' | base64 -d)
    echo "Kafka client user: $CLIENTUSER Password: $PASSWORD"

    PASSWORD=$(kubectl -n ${NAMESPACE} get secret onms-passwords -o jsonpath='{.data.ELASTICSEARCH_PASSWORD}' | base64 -d)
    echo "Elasticsearch password: $PASSWORD"

    PASSWORD=$(kubectl -n ${NAMESPACE} get secret onms-passwords -o jsonpath='{.data.GRAFANA_UI_ADMIN_PASSWORD}' | base64 -d)
    echo "Grafana admin password: $PASSWORD"

    PASSWORD=$(kubectl -n ${NAMESPACE} get secret onms-passwords -o jsonpath='{.data.OPENNMS_UI_ADMIN_PASSWORD}' | base64 -d)
    echo "OpenNMS admin password: $PASSWORD"
}

### ENTRY POINT ###

export DOMAIN="flows.cloud.opennms.com"
export EMAIL="saas@opennms.com"
export NAMESPACE="opennms"

case "$1" in
    up) up ;;
    down) down ;;
    status) status ;;
    *) echo $(basename $0) '(up|down|status)' ;;
esac
