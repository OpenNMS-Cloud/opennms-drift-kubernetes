#!/bin/sh

up() {
    YAML=cert-manager.yaml
    if [ ! -f "$YAML" ]; then
        echo "Downloading the manifest"
        curl -sL -o "$YAML" https://github.com/jetstack/cert-manager/releases/download/v0.13.1/cert-manager.yaml
    fi
    echo "Install cert-manager"
    kubectl create ns cert-manager
    kubectl apply --validate=false -f "$YAML"

    echo "Waiting for pods"
    READY=0
    while [ $READY -lt 3 ]; do
        READY=$(kubectl get -n cert-manager pods|grep -c "1/1")
    done

    kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1alpha2
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
  namespace: cert-manager
spec:
  acme:
    email: saas@opennms.com
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-staging-key
    solvers:
    - http01:
        ingress:
          class: nginx

---
apiVersion: cert-manager.io/v1alpha2
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
  namespace: cert-manager
spec:
  acme:
    email: saas@opennms.com
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
    - http01:
        ingress:
          class: nginx
EOF
}

down() {
    kubectl delete ns cert-manager
}

status() {
    echo Cert-Manager
    kubectl get svc,pods -n cert-manager
    echo ""
    echo "Issuers"
    kubectl get clusterissuer
}

case "$1" in
    up) up ;;
    down) down ;;
    status) status ;;
    *) echo $(basename $0) '(up|down|status)' ;;
esac
