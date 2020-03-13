#!/bin/sh

up() {
    ./cert-mgr.sh up
    ./ingress.sh up

    echo "Installing Jaeger CRDs"
    kubectl apply -f https://raw.githubusercontent.com/jaegertracing/jaeger-operator/master/deploy/crds/jaegertracing.io_jaegers_crd.yaml

    echo "Installing Drift"
    kubectl apply -k aks
    kubectl apply -f manifests/external-access.yaml -n opennms

    echo "Waiting for external Kafka address"
    LBADDR=""
    while [ "$LBADDR" = "" ]; do
      LBADDR=$(kubectl get svc ext-kafka -n opennms | grep -Eo "LoadBalancer\s+\S+\s+[0-9.]+\s+" | awk '{print $3}')
    done
    echo LoadBalancer "$LBADDR"

    echo "Publishing A records"
    az network dns record-set a add-record -z cloud.opennms.com --ttl 600 -g opennms-global -n 'kafka.flows' -a "$LBADDR"

    kubectl apply -f udpgen.yaml -n opennms
}

down() {
    kubectl delete -f udpgen.yaml -n opennms

    echo "Deleting A records"
    az network dns record-set a delete -z cloud.opennms.com -g opennms-global -n 'kafka.flows' -y

    kubectl delete -k aks
    ./ingress.sh down
    ./cert-mgr.sh down
}

status() {
    ./cert-mgr.sh status
    ./ingress.sh status
    kubectl get pod -n opennms

    ADMINUSER=$(kubectl -n opennms get secret kafka-jaas -o jsonpath='{.data.KAFKA_ADMIN_USER}' | base64 -d)
    PASSWORD=$(kubectl -n opennms get secret kafka-jaas -o jsonpath='{.data.KAFKA_ADMIN_PASSWORD}' | base64 -d)
    echo "Kafka admin user: $ADMINUSER Password: $PASSWORD"

    CLIENTUSER=$(kubectl -n opennms get secret kafka-jaas -o jsonpath='{.data.KAFKA_CLIENT_USER}' | base64 -d)
    PASSWORD=$(kubectl -n opennms get secret kafka-jaas -o jsonpath='{.data.KAFKA_CLIENT_PASSWORD}' | base64 -d)
    echo "Kafka client user: $CLIENTUSER Password: $PASSWORD"

    PASSWORD=$(kubectl -n opennms get secret onms-passwords -o jsonpath='{.data.ELASTICSEARCH_PASSWORD}' | base64 -d)
    echo "Elasticsearch password: $PASSWORD"

    PASSWORD=$(kubectl -n opennms get secret onms-passwords -o jsonpath='{.data.GRAFANA_UI_ADMIN_PASSWORD}' | base64 -d)
    echo "Grafana admin password: $PASSWORD"

    PASSWORD=$(kubectl -n opennms get secret onms-passwords -o jsonpath='{.data.OPENNMS_UI_ADMIN_PASSWORD}' | base64 -d)
    echo "OpenNMS admin password: $PASSWORD"
}

create() {
    az group create --name "$GROUP" --location "$LOCATION"
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
    az aks get-credentials --name opennms -g "$GROUP" --context "$GROUP"

    sed -i -e "s/__EMAIL__/$EMAIL/" -e "s/__DOMAIN__/$DOMAIN/g" manifests/external-access.yaml
    sed -i "s/__DOMAIN__/$DOMAIN/g" aks/patches/external-access.yaml aks/patches/common-settings.yaml
}

destroy() {
    az aks delete --yes --name opennms -g "$GROUP"
    az group delete --yes --name "$GROUP"
}

export GROUP=flowslab
export LOCATION=centralus
export DOMAIN="flows.cloud.opennms.com"
export EMAIL="saas@opennms.com"

case "$1" in
    create) create ;;
    destroy) destroy ;;
    up) up ;;
    down) down ;;
    status) status ;;
    *) echo $(basename $0) '(up|down|status)' ;;
esac
