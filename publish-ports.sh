#!/bin/bash

set -e

# =====================================================================
# CONFIGURATION
# =====================================================================

NAMESPACE=circleci

[ -z "$HOSTNAME" ] && HOSTNAME=$(hostname)
[ -z "$DOMAIN" ] && DOMAIN="remistag.site"
[ -z "$WS_DOMAIN" ] && WS_DOMAIN="ws-remistag.site"

[ -z "$HTTP_PORTS" ] && HTTP_PORTS=""
[ -z "$WS_PORTS" ] && WS_PORTS=""
[ -z "$NODE_PORTS" ] && NODE_PORTS=""

# =====================================================================
# FUNCTIONS
# =====================================================================

# Thêm label cho pod
add_pod_label() {
  echo "🔖 Adding label pod-name=$HOSTNAME to pod $HOSTNAME"
  kubectl label pod "$HOSTNAME" pod-name="$HOSTNAME" -n $NAMESPACE --overwrite
}

# Tạo internal service cho HTTP và WS ports
create_internal_service() {
  local service_name="svc-$HOSTNAME"

  echo "⚙️  Creating Service $service_name"
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: $service_name
  namespace: $NAMESPACE
  labels:
    app: $HOSTNAME
    owner: $HOSTNAME
spec:
  selector:
    pod-name: $HOSTNAME
  ports:
$(for port in $HTTP_PORTS; do cat <<EOP
    - name: http-$port
      port: $port
      targetPort: $port
EOP
done)
$(for port in $WS_PORTS; do cat <<EOP
    - name: ws-$port
      port: $port
      targetPort: $port
EOP
done)
EOF
}

# Tạo HTTP Ingress
create_http_ingress() {
  local ingress_name="ing-http-$HOSTNAME"
  local service_name="svc-$HOSTNAME"

  echo "⚙️  Creating Ingress $ingress_name"
  cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: $ingress_name
  namespace: $NAMESPACE
  labels:
    app: $HOSTNAME
    owner: $HOSTNAME
  annotations:
    kubernetes.io/ingress.class: nginx
spec:
  ingressClassName: nginx
  rules:
$(for port in $HTTP_PORTS; do cat <<EOP
    - host: $HOSTNAME-$port.$DOMAIN
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: $service_name
                port:
                  number: $port
EOP
done)
EOF
}

# Tạo WebSocket Ingress
create_ws_ingress() {
  local ingress_name="ing-ws-$HOSTNAME"
  local service_name="svc-$HOSTNAME"

  echo "⚙️  Creating Ingress $ingress_name"
  cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: $ingress_name
  namespace: $NAMESPACE
  labels:
    app: $HOSTNAME
    owner: $HOSTNAME
  annotations:
    kubernetes.io/ingress.class: haproxy
    haproxy.org/websocket: "true"
spec:
  ingressClassName: haproxy
  rules:
$(for port in $WS_PORTS; do cat <<EOP
    - host: $HOSTNAME-$port.$WS_DOMAIN
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: $service_name
                port:
                  number: $port
EOP
done)
EOF
}

# Tạo NodePort Service
create_nodeport_service() {
  local service_name="svc-node-port-$HOSTNAME"

  # Lấy node name và IP
  local node_name=$(kubectl get pod "$HOSTNAME" -n $NAMESPACE -o jsonpath='{.spec.nodeName}')
  local node_ip=$(kubectl get node "$node_name" -o jsonpath='{.status.addresses[?(@.type=="ExternalIP")].address}')

  # Fallback nếu node không có external IP
  if [ -z "$node_ip" ]; then
    node_ip=$(kubectl get node "$node_name" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
  fi

  echo "⚙️  Creating NodePort Service $service_name"
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: $service_name
  namespace: $NAMESPACE
  labels:
    app: $HOSTNAME
    owner: $HOSTNAME
spec:
  type: NodePort
  externalTrafficPolicy: Local
  selector:
    pod-name: $HOSTNAME
  ports:
$(for port in $NODE_PORTS; do cat <<EOP
    - name: nodeport-$port
      port: $port
      targetPort: $port
EOP
done)
EOF

  echo ""
  echo "📡 Assigned NodePorts:"
  for port in $NODE_PORTS; do
    local nodeport=$(kubectl get svc $service_name -n $NAMESPACE -o jsonpath="{.spec.ports[?(@.port==$port)].nodePort}")
    echo "→ $port -> ${node_ip}:${nodeport}"
    echo "export NODE_PORT_${port}='${node_ip}:${nodeport}'" >> $BASH_ENV
  done
}

# In ra các URLs đã tạo
print_urls() {
  for port in $HTTP_PORTS; do
    echo "🌍 HTTP: http://$HOSTNAME-$port.$DOMAIN"
  done

  for port in $WS_PORTS; do
    echo "🔌 WS: ws://$HOSTNAME-$port.$WS_DOMAIN"
  done
}

# =====================================================================
# MAIN EXECUTION
# =====================================================================

# Step 1: Thêm label cho pod
add_pod_label

# Step 2: Tạo internal service nếu có HTTP hoặc WS ports
if [ -n "$HTTP_PORTS" ] || [ -n "$WS_PORTS" ]; then
  create_internal_service
fi

# Step 3A: Tạo HTTP Ingress nếu có HTTP ports
if [ -n "$HTTP_PORTS" ]; then
  create_http_ingress
fi

# Step 3B: Tạo WS Ingress nếu có WS ports
if [ -n "$WS_PORTS" ]; then
  create_ws_ingress
fi

# Step 4: Tạo NodePort Service nếu có NodePort ports
if [ -n "$NODE_PORTS" ]; then
  create_nodeport_service
fi

# In ra các URLs
print_urls
