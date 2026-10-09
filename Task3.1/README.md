# Задание 3.1. Трейсинг с OpenTelemetry и Jaeger

## Описание

Два сервиса на Python + FastAPI, разворачиваемые в Kubernetes:

- **service-a** — сервис расчёта (`GET /`): при вызове обращается к service-b;
- **service-b** — сервис заказов (`GET /`): возвращает статус.

Оба сервиса инструментированы OpenTelemetry SDK и отправляют spans по OTLP
в Jaeger. Вызов `service-a → service-b` целиком попадает в **один трейс**:
W3C Trace Context (`traceparent`) автоматически пробрасывается в HTTP-заголовке
исходящего запроса.

## Структура проекта

- `services/service-a/` — исходный код service-a (FastAPI + OpenTelemetry, Dockerfile)
- `services/service-b/` — исходный код service-b (FastAPI + OpenTelemetry, Dockerfile)
- `k8s/jaeger-instance.yaml` — конфигурация Jaeger (strategy `allInOne`, in-memory storage)
- `k8s/services.yaml` — Kubernetes-конфигурация сервисов (Deployment + Service, порт 8080)
- `deploy.sh` — автоматическое развёртывание и проверка единого trace в Minikube

Конфигурации скопированы из репозитория
[Yandex-Practicum/architecture-alexandrite-k8s-trace](https://github.com/Yandex-Practicum/architecture-alexandrite-k8s-trace/tree/main).

## Требования

- Minikube
- kubectl
- Docker

## Автоматический запуск

Из каталога `Task3.1` выполните:

```bash
chmod +x deploy.sh
./deploy.sh
```

Скрипт проверит необходимые инструменты, запустит Minikube, установит
cert-manager и Jaeger Operator, соберёт образы, развернёт оба сервиса и
проверит совпадение `trace_id` в ответах `service-a` и `service-b`.

Дополнительные варианты запуска:

```bash
./deploy.sh --ui       # после проверки открыть Jaeger UI через port-forward
./deploy.sh --no-build # не пересобирать уже существующие образы
./deploy.sh --help     # показать справку
```

## Ручной запуск

### 1. Запуск Minikube

```bash
minikube start --addons=ingress
```

### 2. Установка cert-manager

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.3/cert-manager.yaml
```

### 3. Развертывание Jaeger

```bash
kubectl create namespace observability
kubectl create -f https://github.com/jaegertracing/jaeger-operator/releases/download/v1.51.0/jaeger-operator.yaml -n observability
kubectl apply -f k8s/jaeger-instance.yaml
```

> **Namespace.** Команда `kubectl apply -f k8s/jaeger-instance.yaml`
> выполняется без `-n`, поэтому Jaeger CR `simplest`, сервисы
> `simplest-query` и `simplest-collector`, а также приложения находятся в
> `default`. На это рассчитаны команды ниже и эндпоинт
> `http://simplest-collector:4317` в `k8s/services.yaml`.
> Если CR применён с `-n observability`, используйте
> `kubectl port-forward svc/simplest-query -n observability 16686:16686`
> и в `k8s/services.yaml` замените эндпоинт на
> `http://simplest-collector.observability:4317`.

### 4. Сборка и деплой сервисов

```bash
minikube image build -t service-a:latest services/service-a/
minikube image build -t service-b:latest services/service-b/
kubectl apply -f k8s/services.yaml
```

## Проверка работы

### Доступ к Jaeger UI

```bash
kubectl port-forward svc/simplest-query 16686:16686
```

Откройте в браузере: http://localhost:16686.

### Тестирование сервисов

```bash
kubectl exec -it $(kubectl get pods -l app=service-a -o jsonpath='{.items[0].metadata.name}') -- wget -qO- http://service-a:8080
```

В ответе `trace_id` сервисов должны совпадать:

```json
{
  "service": "service-a",
  "trace_id": "…",
  "service_b_response": {
    "service": "service-b",
    "trace_id": "…",
    "message": "hello from service-b"
  }
}
```

Найдите трейс в Jaeger UI по сервису **service-a** и полученному Trace ID.

### Скриншот

На скриншоте видны спаны `service-a` и `service-b` в одном трейсе:

![Трейс service-a и service-b в Jaeger UI](Screenshot%202026-08-01%20at%2014-02-41%20Jaeger%20UI.png)

## Как устроена трассировка

1. При старте каждый сервис инициализирует `TracerProvider` с ресурсом
   `service.name` и OTLP gRPC-экспортёром (см. `app/tracing.py`).
2. Автоматическая инструментация: входящие запросы — `FastAPIInstrumentor`,
   исходящие HTTP-вызовы — `HTTPXClientInstrumentor`.
3. Эндпоинт экспорта задаётся переменной окружения
   `OTEL_EXPORTER_OTLP_ENDPOINT=http://simplest-collector:4317` —
   это сервис Jaeger Collector в том же namespace; порт 4317 принимает OTLP
   по gRPC.
4. service-a дополнительно создаёт явный дочерний span `call-service-b`
   (`opentelemetry.trace.Tracer.start_as_current_span`).

## Поиск неисправностей

### `unable to upgrade connection: container not found ("service-a")`

Под с меткой `app=service-a` найден, но контейнер в нём не запущен.

```bash
kubectl get pods -l app=service-a -o wide
kubectl describe pod -l app=service-a | tail -30
kubectl logs $(kubectl get pods -l app=service-a -o jsonpath='{.items[0].metadata.name}')
```

Типичные причины:

- **Образ не попал в minikube.** Обязательно собирайте через
  `minikube image build -t service-a:latest services/service-a/`
  (обычный `docker build` minikube не видит). После сборки пересоздайте поды:
  `kubectl rollout restart deploy/service-a deploy/service-b`.
- Поды созданы раньше, чем собран образ (`ErrImagePull`), или exec выполнен
  в момент `ContainerCreating` — подождите и повторите.
- Код падает при старте (`CrashLoopBackOff`) — смотрите логи пода.

### `services "simplest-query" not found`

```bash
kubectl get pods -n observability
kubectl get jaeger -A
kubectl get svc -A | grep simplest
```

Типичные причины:

- Оператор ещё ставится или не готов — подождите и проверьте:
  `kubectl wait --for=condition=available deploy/jaeger-operator -n observability --timeout=120s`.
- CR `k8s/jaeger-instance.yaml` не применён — выполните
  `kubectl apply -f k8s/jaeger-instance.yaml`.
- Оператор ещё не создал сервисы после применения CR — подождите ~30–60 с и
  повторите `kubectl get svc simplest-query`.
- CR применён в другой namespace (например, с `-n observability`) — тогда
  порт-форвард тоже нужен с `-n observability` (см. выше).
