#!/bin/sh

up() {
    YAML1=ingress-nginx.yaml
    YAML2=cloud-generic.yaml
    if [ ! -f "$YAML1" ] || [ ! -f "$YAML2" ]; then
        echo "Downloading the manifest"
        curl -sL -o "$YAML1" https://raw.githubusercontent.com/kubernetes/ingress-nginx/nginx-0.26.1/deploy/static/mandatory.yaml
        curl -sL -o "$YAML2" https://raw.githubusercontent.com/kubernetes/ingress-nginx/nginx-0.26.1/deploy/static/provider/cloud-generic.yaml
    fi
    echo "Install Ingress"
    kubectl apply -f "$YAML1"
    kubectl apply -f "$YAML2"

    echo "Waiting for pods"
    READY=""
    while [ "$READY" != "1/1" ]; do
        READY=$(kubectl get pods --all-namespaces -l app.kubernetes.io/name=ingress-nginx|grep -o "1/1")
    done

    echo "Waiting for external address"
    LBADDR=""
    while [ "$LBADDR" = "" ]; do
      LBADDR=$(kubectl get svc -A -l app.kubernetes.io/name=ingress-nginx | grep -Eo "LoadBalancer\s+\S+\s+[0-9.]+\s+80:" | awk '{print $3}')
    done
    echo LoadBalancer "$LBADDR"

    echo "Publishing A records"
    az network dns record-set a add-record -z cloud.opennms.com --ttl 600 -g opennms-global -n '*.flows' -a "$LBADDR"
}

down() {
    kubectl delete ns ingress-nginx
    echo "Deleting A records"
    az network dns record-set a delete -z cloud.opennms.com -g opennms-global -n '*.flows' -y
}

status() {
    echo Ingress NGINX
    kubectl get svc,pods --all-namespaces -l app.kubernetes.io/name=ingress-nginx
}

case "$1" in
    up) up ;;
    down) down ;;
    status) status ;;
    *) echo $(basename $0) '(up|down|status)' ;;
esac
