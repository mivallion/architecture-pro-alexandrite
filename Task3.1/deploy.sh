#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CERT_MANAGER_VERSION="v1.13.3"
JAEGER_OPERATOR_VERSION="v1.51.0"
BUILD_IMAGES=1
START_UI=0

usage() {
  printf '%s\n' \
    'Автоматический деплой MVP из задания 3.1 в локальный minikube.' \
    '' \
    'Использование:' \
    '  ./deploy.sh            — развернуть Jaeger и оба сервиса, проверить trace_id' \
    '  ./deploy.sh --ui       — после проверки открыть port-forward Jaeger UI' \
    '  ./deploy.sh --no-build — использовать ранее собранные образы сервисов' \
    '  ./deploy.sh --help     — показать эту справку'
}

for arg in "$@"; do
  case "$arg" in
    --ui) START_UI=1 ;;
    --no-build) BUILD_IMAGES=0 ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Неизвестный аргумент: $arg (см. --help)" >&2
      exit 2
      ;;
  esac
done

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok() { printf '\033[1;32m==> %s\033[0m\n' "$*"; }

wait_for_resource() {
  local kind="$1" namespace="$2" name="$3" timeout_s="${4:-120}"
  local end=$((SECONDS + timeout_s))

  while [ "$SECONDS" -lt "$end" ]; do
    if kubectl get "$kind" "$name" -n "$namespace" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  echo "Ошибка: $kind/$name не найден в namespace $namespace за ${timeout_s}s." >&2
  return 1
}

wait_rollout() {
  local namespace="$1"
  shift
  local timeout_s="${ROLLOUT_TIMEOUT_S:-300}"

  if ! kubectl -n "$namespace" rollout status "$@" --timeout="${timeout_s}s"; then
    echo "Ошибка: deployment не стал готовым. Диагностика:" >&2
    kubectl -n "$namespace" get pods -o wide >&2 || true
    kubectl -n "$namespace" get events --sort-by=.lastTimestamp | tail -20 >&2 || true
    for deployment in "$@"; do
      kubectl -n "$namespace" logs "$deployment" --tail=50 >&2 || true
    done
    return 1
  fi
}

log "1/7 Проверка инструментов"
for tool in minikube kubectl docker; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Ошибка: не найден '$tool'. Установите его и повторите запуск." >&2
    exit 1
  fi
done

if ! minikube status >/dev/null 2>&1; then
  minikube start --addons=ingress
else
  echo "minikube уже запущен"
fi

kubectl config use-context minikube >/dev/null
CURRENT_CONTEXT="$(kubectl config current-context)"
if [ "$CURRENT_CONTEXT" != "minikube" ]; then
  echo "Ошибка: активный kubectl context '$CURRENT_CONTEXT', ожидался 'minikube'." >&2
  exit 1
fi
minikube addons enable ingress >/dev/null 2>&1 || true
ok "minikube готов"

log "2/7 Установка cert-manager ${CERT_MANAGER_VERSION}"
kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
wait_rollout cert-manager deployment/cert-manager deployment/cert-manager-webhook deployment/cert-manager-cainjector
ok "cert-manager готов"

log "3/7 Установка jaeger-operator ${JAEGER_OPERATOR_VERSION}"
if ! kubectl get namespace observability >/dev/null 2>&1; then
  kubectl create namespace observability
fi
kubectl apply -f "https://github.com/jaegertracing/jaeger-operator/releases/download/${JAEGER_OPERATOR_VERSION}/jaeger-operator.yaml" -n observability

if kubectl -n observability get deployment jaeger-operator -o jsonpath='{.spec.template.spec.containers[*].name}' | grep -q kube-rbac-proxy; then
  kubectl -n observability patch deployment jaeger-operator --type=strategic \
    -p '{"spec":{"template":{"spec":{"containers":[{"name":"kube-rbac-proxy","$patch":"delete"}]}}}}'
fi

wait_rollout observability deployment/jaeger-operator

kubectl apply -f k8s/jaeger-instance.yaml
JAEGER_NS="$(kubectl get jaeger simplest -o jsonpath='{.metadata.namespace}')"
wait_for_resource deployment "$JAEGER_NS" simplest 240
wait_rollout "$JAEGER_NS" deployment/simplest
wait_for_resource service "$JAEGER_NS" simplest-query 120
wait_for_resource service "$JAEGER_NS" simplest-collector 120
ok "Jaeger готов в namespace $JAEGER_NS"

if [ "$BUILD_IMAGES" = 1 ]; then
  log "4/7 Сборка образов"
  minikube image build -t service-a:latest services/service-a/
  minikube image build -t service-b:latest services/service-b/
else
  log "4/7 Сборка образов пропущена"
fi
ok "Образы готовы"

log "5/7 Деплой сервисов"
kubectl apply -f k8s/services.yaml
APP_NS="$(kubectl get deployment service-a -o jsonpath='{.metadata.namespace}')"
wait_rollout "$APP_NS" deployment/service-a deployment/service-b
ok "service-a и service-b готовы в namespace $APP_NS"

log "6/7 Проверка единого trace"
POD_A="$(kubectl get pods -l app=service-a -n "$APP_NS" -o jsonpath='{.items[0].metadata.name}')"
if ! RESPONSE="$(kubectl exec "$POD_A" -n "$APP_NS" -- wget -qO- --timeout=5 http://service-a:8080)"; then
  echo "Ошибка: вызов service-a не удался." >&2
  kubectl -n "$APP_NS" get endpoints service-a >&2 || true
  kubectl -n "$APP_NS" logs deployment/service-a --tail=30 >&2 || true
  exit 1
fi
echo "$RESPONSE"

TRACE_IDS="$(printf '%s' "$RESPONSE" | grep -oE '"trace_id": "[0-9a-f]{32}"' | grep -oE '[0-9a-f]{32}')"
TRACE_ID_A="$(printf '%s\n' "$TRACE_IDS" | head -1)"
TRACE_ID_B="$(printf '%s\n' "$TRACE_IDS" | tail -1)"
if [ -z "$TRACE_ID_A" ] || [ "$TRACE_ID_A" != "$TRACE_ID_B" ]; then
  echo "Ошибка: trace_id не совпали или не найдены (service-a='$TRACE_ID_A', service-b='$TRACE_ID_B')." >&2
  exit 1
fi
ok "Оба сервиса находятся в одном trace: $TRACE_ID_A"

log "7/7 Jaeger UI"
if [ "$START_UI" = 1 ]; then
  echo "Jaeger UI: http://localhost:16686 (для остановки нажмите Ctrl+C)"
  kubectl port-forward -n "$JAEGER_NS" svc/simplest-query 16686:16686
else
  echo "Для открытия Jaeger UI выполните:"
  echo "  kubectl port-forward -n $JAEGER_NS svc/simplest-query 16686:16686"
  echo "Затем откройте http://localhost:16686 и найдите trace $TRACE_ID_A"
fi
