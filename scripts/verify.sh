#!/usr/bin/env bash
set -u

REPO_DIR="${REPO_DIR:-$HOME/hackathon-k8s}"
FAIL=0

ok()   { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
bad()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*"; FAIL=1; }

echo "=== Kubernetes ==="
if kubectl get nodes >/dev/null 2>&1; then
  NODE_READY="$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}' | grep -c '^Ready$' || true)"
  [[ "$NODE_READY" -ge 1 ]] && ok "At least one Ready node" || bad "No Ready node"
else
  bad "kubectl cannot access the cluster"
fi

echo
echo "=== Cilium ==="
if kubectl -n kube-system get ds/cilium >/dev/null 2>&1; then
  kubectl -n kube-system get pods -l k8s-app=cilium --no-headers
  kubectl -n kube-system get pods -l name=cilium-operator --no-headers
  ok "Cilium resources exist"
else
  bad "Cilium DaemonSet missing"
fi

echo
echo "=== Application ==="
kubectl get deployment/nginx service/nginx endpoints/nginx 2>/dev/null || bad "nginx resources missing"
NGINX_READY="$(kubectl get deployment/nginx -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
[[ "${NGINX_READY:-0}" == "2" ]] && ok "2/2 nginx replicas Ready" || warn "nginx ready replicas: ${NGINX_READY:-0}"

echo
echo "=== Gateway API ==="
GATEWAY_CLASS="$(kubectl get gatewayclass cilium -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)"
[[ "$GATEWAY_CLASS" == "True" ]] && ok "Cilium GatewayClass Accepted" || bad "Cilium GatewayClass is not Accepted"

GATEWAY_IP="$(kubectl get gateway web-gateway -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
[[ -n "$GATEWAY_IP" ]] && ok "Gateway address: $GATEWAY_IP" || bad "Gateway has no address"

ROUTE_ACCEPTED="$(kubectl get httproute nginx-route -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)"
ROUTE_REFS="$(kubectl get httproute nginx-route -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}' 2>/dev/null || true)"
[[ "$ROUTE_ACCEPTED" == "True" ]] && ok "HTTPRoute Accepted" || bad "HTTPRoute not Accepted"
[[ "$ROUTE_REFS" == "True" ]] && ok "HTTPRoute references resolved" || bad "HTTPRoute references unresolved"

if [[ -n "$GATEWAY_IP" ]]; then
  BODY="$(curl --noproxy '*' -fsS --max-time 10 "http://${GATEWAY_IP}/" 2>/dev/null || true)"
  [[ "$BODY" == *"Welcome to nginx!"* ]] && ok "Gateway -> nginx HTTP 200" || bad "Gateway HTTP request failed"
fi

echo
echo "=== MetalLB ==="

POOL_COUNT="$(kubectl -n metallb-system get ipaddresspools --no-headers 2>/dev/null | wc -l)"
L2_COUNT="$(kubectl -n metallb-system get l2advertisements --no-headers 2>/dev/null | wc -l)"

if [[ "$POOL_COUNT" -ge 1 ]]; then
  ok "MetalLB IPAddressPool exists"
else
  bad "No MetalLB IPAddressPool found"
fi

if [[ "$L2_COUNT" -ge 1 ]]; then
  ok "MetalLB L2Advertisement exists"
else
  bad "No MetalLB L2Advertisement found"
fi

echo
echo "=== Prometheus ==="
kubectl -n cilium-monitoring get deployment/prometheus >/dev/null 2>&1 \
  && ok "Prometheus deployment exists" \
  || bad "Prometheus deployment missing"

if kubectl -n cilium-monitoring get pods -l k8s-app=prometheus -o name 2>/dev/null | grep -q .; then
  ok "Prometheus pod exists"
fi

echo
echo "=== Filebeat ==="
FB_READY="$(kubectl -n kube-system get ds/filebeat -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)"
[[ "${FB_READY:-0}" -ge 1 ]] && ok "Filebeat DaemonSet Ready" || bad "Filebeat is not Ready"

echo
echo "=== Real log collection test ==="
TEST_AGENT="hackathon-filebeat-$(date +%s)"
if [[ -n "$GATEWAY_IP" ]]; then
  curl --noproxy '*' -fsS -A "$TEST_AGENT" "http://${GATEWAY_IP}/" >/dev/null 2>&1 || true
  sleep 2
  if kubectl -n kube-system logs -l app=filebeat --tail=3000 2>/dev/null | grep -q "$TEST_AGENT"; then
    ok "Filebeat collected a fresh nginx access log"
  else
    warn "Fresh Filebeat event not found yet; retry manually with:"
    echo "  kubectl -n kube-system logs -l app=filebeat --tail=3000 | grep '$TEST_AGENT'"
  fi
else
  warn "Skipping fresh Filebeat event test because Gateway IP is unavailable"
fi

echo
echo "=== Summary ==="
if [[ "$FAIL" -eq 0 ]]; then
  printf '\033[1;32mALL REQUIRED CHECKS PASSED\033[0m\n'
  exit 0
else
  printf '\033[1;31mSOME REQUIRED CHECKS FAILED\033[0m\n'
  exit 1
fi
