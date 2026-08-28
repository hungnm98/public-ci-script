#!/bin/bash

set -e

# =====================================================================
# CONFIGURATION
# =====================================================================

NAMESPACE="${NAMESPACE:-${K8S_NAMESPACE:-circleci}}"

[ -z "$HOSTNAME" ] && HOSTNAME=$(hostname)
[ -z "$DOMAIN" ] && DOMAIN="remistag.site"
[ -z "$WS_DOMAIN" ] && WS_DOMAIN="ws-remistag.site"

[ -z "$HTTP_PORTS" ] && HTTP_PORTS=""
[ -z "$WS_PORTS" ] && WS_PORTS=""
[ -z "$NODE_PORTS" ] && NODE_PORTS=""

POD_HOSTNAME="$HOSTNAME"
RESOURCE_HOSTNAME="$POD_HOSTNAME"

hash_hostname() {
  if command -v md5sum >/dev/null 2>&1; then
    printf '%s' "$1" | md5sum | awk '{print $1}'
  elif command -v md5 >/dev/null 2>&1; then
    printf '%s' "$1" | md5
  else
    echo "Neither md5sum nor md5 is available" >&2
    exit 1
  fi
}

if [ "${#POD_HOSTNAME}" -ge 50 ]; then
  RESOURCE_HOSTNAME=$(hash_hostname "$POD_HOSTNAME")
fi

echo "🏷️  Original pod hostname: $POD_HOSTNAME"
echo "🔑 Resource hostname: $RESOURCE_HOSTNAME"

# =====================================================================
# FUNCTIONS
# =====================================================================

# Thêm label cho pod
add_pod_label() {
  echo "🔖 Adding label pod-name=$POD_HOSTNAME to pod $POD_HOSTNAME"
  kubectl label pod "$POD_HOSTNAME" pod-name="$POD_HOSTNAME" -n $NAMESPACE --overwrite
}

# Tạo internal service cho HTTP và WS ports
create_internal_service() {
  local service_name="svc-$RESOURCE_HOSTNAME"

  echo "⚙️  Creating Service $service_name"
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: $service_name
  namespace: $NAMESPACE
  labels:
    app: $POD_HOSTNAME
    owner: $POD_HOSTNAME
spec:
  selector:
    pod-name: $POD_HOSTNAME
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
  local ingress_name="ing-http-$RESOURCE_HOSTNAME"
  local service_name="svc-$RESOURCE_HOSTNAME"

  echo "⚙️  Creating Ingress $ingress_name"
  cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: $ingress_name
  namespace: $NAMESPACE
  labels:
    app: $POD_HOSTNAME
    owner: $POD_HOSTNAME
  annotations:
    kubernetes.io/ingress.class: nginx
spec:
  ingressClassName: nginx
  rules:
$(for port in $HTTP_PORTS; do cat <<EOP
    - host: $POD_HOSTNAME-$port.$DOMAIN
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
  local ingress_name="ing-ws-$RESOURCE_HOSTNAME"
  local service_name="svc-$RESOURCE_HOSTNAME"

  echo "⚙️  Creating Ingress $ingress_name"
  cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: $ingress_name
  namespace: $NAMESPACE
  labels:
    app: $POD_HOSTNAME
    owner: $POD_HOSTNAME
  annotations:
    kubernetes.io/ingress.class: haproxy
    haproxy.org/websocket: "true"
spec:
  ingressClassName: haproxy
  rules:
$(for port in $WS_PORTS; do cat <<EOP
    - host: $POD_HOSTNAME-$port.$WS_DOMAIN
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
  local service_name="svc-node-port-$RESOURCE_HOSTNAME"

  # Lấy node name và IP, ưu tiên label public_ip
  local node_name=$(kubectl get pod "$POD_HOSTNAME" -n $NAMESPACE -o jsonpath='{.spec.nodeName}')
  local node_ip=$(kubectl get node "$node_name" -o jsonpath='{.metadata.labels.public_ip}')

  if [ -z "$node_ip" ]; then
    node_ip=$(kubectl get node "$node_name" -o jsonpath='{.status.addresses[?(@.type=="ExternalIP")].address}')
  fi

  if [ -z "$node_ip" ]; then
    node_ip=$(kubectl get node "$node_name" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
  fi

  if [ -z "$node_ip" ]; then
    echo "Node $node_name does not have a public_ip label, ExternalIP, or InternalIP" >&2
    exit 1
  fi

  echo "⚙️  Creating NodePort Service $service_name"
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: $service_name
  namespace: $NAMESPACE
  labels:
    app: $POD_HOSTNAME
    owner: $POD_HOSTNAME
spec:
  type: NodePort
  externalTrafficPolicy: Local
  selector:
    pod-name: $POD_HOSTNAME
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
    echo "🌍 HTTP: http://$POD_HOSTNAME-$port.$DOMAIN"
  done

  for port in $WS_PORTS; do
    echo "🔌 WS: ws://$POD_HOSTNAME-$port.$WS_DOMAIN"
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
