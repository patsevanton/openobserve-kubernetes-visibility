# OpenObserve: open-source альтернатива Datadog — разворачиваем наблюдаемый Kubernetes в Yandex Managed K8s

## Введение

У каждой команды рано или поздно наступает момент, когда `kubectl logs` перестаёт хватать: логи размазаны по нодам и исчезают вместе с подами, метрики живут в Prometheus без истории, трейсы вообще никто не настроил, а дашборды для Grafana надо собирать из трёх разных источников. Классический путь — Elasticsearch + Kibana + Prometheus + Tempo + Grafana — превращается в зоопарк из полудюжины систем, каждая со своим языком запросов, хранилищем и режимом отказов. Коммерческая альтернатива (Datadog, Splunk, New Relic) решает проблему комплексно, но ценой проприетарного vendor lock-in и счёта, растущего быстрее, чем инфраструктура.

[OpenObserve](https://github.com/openobserve/openobserve) — open-source платформа наблюдаемости, написанная на Rust: логи, метрики, трейсы, RUM, дашборды, алерты, инциденты, пайплайны и AI-обсервабельность в едином бинарнике. Данные хранятся в колоночном формате Parquet поверх S3-совместимого объектного хранилища — по заявлениям авторов это до **140x** дешевле Elasticsearch по storage-затратам. OpenTelemetry-native: OTLP-инжест из коробки, никакого собственного языка запросов — только SQL и PromQL. Крупнейшее известное развёртывание — 2+ PB/день инжеста.

В этой статье мы развернём OpenObserve в HA-конфигурации в Yandex Managed Kubernetes через Helm — с Postgres (CloudNativePG), NATS, хранилищем в Yandex Object Storage, ingress-nginx и доменом из публичного IP — а затем подключим `openobserve-collector`, чтобы кластер начал наблюдать сам за собой: логи, метрики, события и state всех Kubernetes-объектов.

## OpenObserve vs Elasticsearch vs Loki+Grafana vs Datadog

| Метрика | OpenObserve | Elasticsearch | Loki + Grafana | Datadog |
|---------|-------------|---------------|----------------|---------|
| Тип | Единый бинарник (Rust) | Кластер JVM-нод | Компоненты Grafana-стека | SaaS |
| Хранилище | Parquet + S3 (до 140x дешевле ES) | Hot/warm/cold tiers, дорого | Объектное хранилище | Проприетарное облако |
| Логи | ✅ SQL + full-text + инвертированный индекс | ✅ | ✅ (только лейблы, LogQL) | ✅ |
| Метрики | ✅ SQL + PromQL, remote write | ⚠️ | ✅ (нужен Prometheus) | ✅ |
| Трейсы | ✅ OTLP, waterfall, service graph | ❌ | ❌ (нужен Tempo) | ✅ |
| RUM + session replay | ✅ | ❌ | ❌ | ✅ |
| Дашборды | ✅ встроенные, 19+ типов графиков | Kibana | ✅ Grafana | ✅ |
| Алерты и инциденты | ✅ | Watcher (платно) | ✅ Alertmanager | ✅ |
| Пайплайны обработки при инжесте | ✅ визуальный редактор + VRL | ⚠️ ingest pipelines | ❌ | ⚠️ |
| AI/LLM-обсервабельность | ✅ | ❌ | ❌ | ✅ (LLM Observability) |
| Язык запросов | SQL + PromQL | Lucene/DSL/KQL | LogQL + PromQL | Проприетарный |
| Высокая кардинальность в логах | ✅ | ⚠️ (memory pressure) | ❌ (страдает) | ✅ |
| Self-hosted | ✅ | ✅ | ✅ | ❌ |
| Лицензия | AGPL-3.0 | Elastic License 2.0 / AGPL | Apache 2.0 / AGPL | Проприетарная |

OpenObserve не заменит специализированные системы на экстремальных нагрузках (миллиарды событий в секунду), а встроенные дашборды проще, чем зрелые Grafana-дашборды с экосистемой плагинов. Но для команды, которой нужно «все сигналы в одном месте за разумные деньги» — это самый короткий путь.

Отличительные особенности OpenObserve:

- **Единый бинарник** — single-node режим стартует за 2 минуты без внешних зависимостей
- **Parquet + S3-native** — данные в дешёвом объектном хранилище, ноды stateless
- **SQL для всего** — логи, трейсы и даже метрики можно запросить через SQL (или PromQL)
- **Native multi-tenancy** — организации и потоки как первоклассные концепты

> Предполагается, что у вас уже есть работающий кластер Yandex Managed Kubernetes с установленным ingress-nginx. Как его поставить через Terraform — см. репозиторий проекта (`.tf`-файлы): `terraform apply` поднимает VPC с NAT-шлюзом, кластер и ingress-nginx и генерирует `values.yaml` / `collector-values.yaml`. Нужен [yc CLI](https://yandex.cloud/ru/docs/cli/quickstart) с настроенным профилем и переменные: `folder_id`, `openobserve_root_user_email`, `openobserve_root_user_password`, `openobserve_s3_bucket_name`.

## Часть 1. Локальный запуск за 2 минуты

Прежде чем разворачивать HA-кластер, полезно пощупать OpenObserve локально. Один Docker-контейнер — и у вас полноценная платформа с UI:

```bash
docker run -d \
  --name openobserve \
  -v $PWD/data:/data \
  -p 5080:5080 \
  -e ZO_ROOT_USER_EMAIL="root@example.com" \
  -e ZO_ROOT_USER_PASSWORD="Complexpass#123" \
  public.ecr.aws/zinclabs/openobserve:latest
```

Открываем [http://localhost:5080](http://localhost:5080), входим с указанными credentials — и оказываемся в UI: домашний дашборд, логи, метрики, трейсы, пайплайны. В этом режиме данные пишутся на локальный диск (`ZO_LOCAL_MODE_STORAGE=disk`), метаданные — в SQLite. Ничего настраивать не нужно.

Сразу проверим инжест — отправим пару JSON-логов через HTTP API:

```bash
curl -s http://localhost:5080/api/default/my_stream/_json \
  -u "root@example.com:Complexpass#123" \
  -H "Content-Type: application/json" \
  -d '[{"level":"info","message":"hello from curl","service":"demo"}]'
```

Открываем в UI **Logs** → стрим `my_stream` — записи уже там. Это весь процесс: любой JSON, POST на `/{org}/{stream}/_json` — и данные наблюдаемы.

Кроме Docker есть готовые бинарники под linux/darwin/windows (amd64/arm64):

```bash
# OSS-сборка (укажите версию, например v0.92.2; latest см. на странице релизов GitHub)
curl -fLo o2.tar.gz \
  "https://downloads.openobserve.ai/releases/openobserve/v0.92.2/openobserve-v0.92.2-linux-amd64.tar.gz"
tar -xzf o2.tar.gz && ./openobserve

# Enterprise-сборка
curl -fsSL https://raw.githubusercontent.com/openobserve/openobserve/main/downloadO2.sh | bash
```

Для продакшена такой режим не подходит: нет HA, данные на одном диске. Перейдём к кластерному деплою.

## Часть 2. HA-деплой в Yandex Managed K8s

Кластерный режим OpenObserve разделяет монолит на роли, каждая — отдельный deployment/statefulset:

- **Router** — единая точка входа: разруливает запросы инжеста и UI между компонентами
- **Ingester** — принимает данные, буферизует в WAL, пишет Parquet в S3
- **Querier** — исполняет SQL/PromQL-запросы по данным в S3 (с дисковым кэшем)
- **Compactor** — мерджит мелкие Parquet-файлы, применяет retention
- **Scheduler** — оркестрирует распределённые задачи (запросы, компакция)

Плюс инфраструктура: **Postgres** (метаданные: пользователи, схемы стримов, дашборды), **NATS** (координация кластера и очередь запросов) и S3-совместимое хранилище (сами данные).

Архитектура получается такая:

```
                        ┌────────────► NATS (координация, очередь)
                        │
Браузер ──HTTPS──► ingress-nginx ──► Router ──► Ingester ──Parquet──► Yandex Object Storage
OTLP-агенты ──OTLP──►     Router ──► Querier ◄────S3────────────────────────┘
                        │              │
                        │         Postgres (CloudNativePG: метаданные)
                        └────────────► Compactor (мердж + retention)
```

Ноды stateless (кроме WAL/кэша на PVC), поэтому масштабирование горизонтальное, а отказоустойчивость данных гарантирует S3 с его 11 девятками durability.

### Шаг 0. Домен из публичного IP — sslip.io

Если DNS-зона в Yandex Cloud не настроена, удобнее всего сервис sslip.io: домен формируется прямо из публичного IP балансировщика ingress-контроллера. Terraform уже сделал это за вас — FQDN вида `openobserve.<публичный-IP>.sslip.io` доступен в output'е `openobserve_fqdn` и подставлен в сгенерированный `values.yaml`:

```bash
terraform output openobserve_fqdn
```

Или вручную:

```bash
# Публичный IP ingress-контроллера
kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

### Шаг 1. Бакет в Yandex Object Storage

Бакет (например, `my-openobserve-bucket`) и static access key создаются Terraform'ом (`openobserve.tf`): сервисный аккаунт с ролью `storage.editor` и static access key, креды подставляются в сгенерированный `values.yaml`. Хранить данные Observability в объектном хранилище — и есть главный источник экономии: холодные Parquet-файлы не занимают ни PV, ни RAM.

### Шаг 2. CloudNativePG Operator

Кластерный чарт использует Postgres как метаданные-стор и сам создаёт кластер CloudNativePG (1 primary + 1 replica). Сначала нужен оператор:

```bash
kubectl apply --server-side -f \
  https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.30/releases/cnpg-1.30.0.yaml
```

### Шаг 3. Добавляем Helm-репозиторий

```bash
helm repo add openobserve https://charts.openobserve.ai
helm repo update
```

В этой статье используется чарт версии **0.92.2** (совпадает с версией приложения). Посмотреть все доступные версии:

```bash
helm search repo openobserve --versions
```

### Шаг 4. values-файл

Файл `values.yaml` генерируется Terraform'ом из шаблона `values.yaml.tftpl` (домен, креды root-пользователя и static access key S3 подставляются автоматически):

```yaml
auth:
  ZO_ROOT_USER_EMAIL: "root@example.com"
  ZO_ROOT_USER_PASSWORD: "Complexpass#123"
  # Static access key Yandex Object Storage
  ZO_S3_ACCESS_KEY: "YCAJExxxxxxxxxxxxxxxxxxxx"
  ZO_S3_SECRET_KEY: "YCPxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

config:
  ZO_S3_PROVIDER: "s3"
  ZO_S3_SERVER_URL: "https://storage.yandexcloud.net"
  ZO_S3_REGION_NAME: "ru-central1"
  ZO_S3_BUCKET_NAME: "my-openobserve-bucket"
  ZO_COMPACT_DATA_RETENTION_DAYS: "30"
  ZO_TELEMETRY: "false"

# OSS-образ вместо enterprise (enterprise-фичи не используются)
enterprise:
  enabled: false

# Генерация отчётов в PDF — не нужна в базовом сценарии
reportserver:
  enabled: false

# Уменьшенные PVC для демо; в проде оставьте 100Gi по умолчанию
ingester:
  persistence:
    enabled: true
    size: 20Gi

querier:
  persistence:
    enabled: true
    size: 20Gi

scheduler:
  persistence:
    enabled: true
    size: 10Gi

ingress:
  enabled: true
  className: nginx
  hosts:
    - host: ваш-fqdn-url
      paths:
        - path: /
          pathType: Prefix
```

Из нестандартного здесь:

- `ZO_S3_*` — S3-эндпоинт и креды Yandex Object Storage. Провайдер `s3` — стандартный AWS-совместимый путь: Yandex Object Storage говорит по S3 API, отдельного `minio`-режима не требуется
- `enterprise.enabled: false` — чарт по умолчанию ставит enterprise-образ; OSS-режим полностью production-ready, а лишний агрессивный default нас не интересует
- `ZO_COMPACT_DATA_RETENTION_DAYS: "30"` — retention 30 дней вместо 3650. По умолчанию OpenObserve **никогда ничего не удаляет** — всё иммутабельно, что отлично для compliance, но бакет будет расти бесконечно
- `ZO_TELEMETRY: "false"` — отключает отправку анонимной статистики использования
- `ingress` — домен из sslip.io формируется Terraform'ом из публичного IP балансировщика ingress-nginx; чарт сам закрывает публичный доступ к `/metrics` через nginx-сайдкар `blocked-metrics` (403 на `/metrics` и `/api/metrics`)

Чему соответствуют `ingester/querier/scheduler.persistence` — это WAL и дисковый кэш на PVC, **не** данные. Сами данные — в S3. В продакшене чем больше кэш querier'а, тем меньше повторных чтений из S3 — дефолтные 100Gi разумны.

### Шаг 5. Устанавливаем

```bash
kubectl create namespace openobserve
helm upgrade --install openobserve openobserve/openobserve --version 0.92.2 \
  -n openobserve -f values.yaml
```

Чарт подтянет NATS как subchart (кластер из 3 реплик с JetStream на PVC) и развернёт все роли OpenObserve.

### Шаг 6. Проверяем

```bash
# Ждём готовности всех подов
kubectl get pods -n openobserve -w

# Открываем UI
open http://<ваш-fqdn-url>
```

Должно получиться примерно так:

```
NAME                                          READY   STATUS    RESTARTS   AGE
openobserve-compactor-5f8c9b7d4-x2k9p      1/1     Running   0          5m
openobserve-ingester-0                     1/1     Running   0          5m
openobserve-postgres-rw-0                  1/1     Running   0          5m
openobserve-postgres-ro-1                  1/1     Running   0          4m
openobserve-querier-0                      1/1     Running   0          5m
openobserve-router-7d4f6c8b5-j3m2n         1/1     Running   0          5m
openobserve-scheduler-0                    1/1     Running   0          5m
openobserve-nats-0                                     1/1     Running   0          5m
openobserve-nats-1                                     1/1     Running   0          5m
openobserve-nats-2                                     1/1     Running   0          5m
```

Входим с credentials из `auth.*` — и видим пустой (пока) домашний дашборд. Платформа готова принимать данные.

## Часть 3. Коллектор: кластер наблюдает сам за собой

Сервер есть — теперь подключим источник данных. Чарт `openobserve-collector` разворачивает OpenTelemetry Collector (contrib) в двух режимах сразу плюс kube-state-metrics:

- **agent** (DaemonSet) — с каждой ноды: логи из `/var/log/pods`, kubeletstats, hostmetrics
- **gateway** (StatefulSet, 1 реплика) — события и state всех K8s-объектов (watch), cAdvisor, kube-state-metrics, CoreDNS, автоскрейп аннотированных подов, приём OTLP от приложений
- **kube-state-metrics** — метрики состояния объектов K8s

Всё это по OTLP уходит в OpenObserve. Плюс чарт умеет автоинструментацию приложений (Java, Python, Node.js, .NET, Go) через аннотации — в этой статье выключим её для простоты.

### Требования

- OpenTelemetry Operator:

```bash
kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml
```

### values-файл коллектора

Файл `collector-values.yaml` генерируется Terraform'ом из шаблона `collector-values.yaml.tftpl` — Authorization-заголовок (Basic из credentials OpenObserve: `printf '%s:%s' "$EMAIL" "$PASS" | base64`) подставляется автоматически. Ручной вариант:

```yaml
exporters:
  otlphttp/openobserve:
    endpoint: http://openobserve-router.openobserve.svc.cluster.local:5080/api/default/
    headers:
      Authorization: Basic cm9vdEBleGFtcGxlLmNvbTpDb21wbGV4cGFzcyMxMjM=
  otlphttp/openobserve_k8s_events:
    endpoint: http://openobserve-router.openobserve.svc.cluster.local:5080/api/default/
    headers:
      Authorization: Basic cm9vdEBleGFtcGxlLmNvbTpDb21wbGV4cGFzcyMxMjM=
      stream-name: k8s_events

k8sCluster: "openobserve"

autoinstrumentation:
  enabled: false

kube-state-metrics:
  enabled: true
```

Важно: в **Yandex Managed K8s control-plane недоступен для скрейпинга** — мастер управляемый и находится вне кластера. Поэтому из дефолтных scrape-jobs коллектора нужно убрать `kube-scheduler` и `kube-controller-manager` (иначе скрейпы по кругу падают с connection refused, а логи забиваются ошибками). k8s_events, напротив, работает: события читаются через API-сервер, который доступен.

Расширенный вариант `collector-values.yaml` с переписанным списком scrape-jobs (убраны scheduler/controller-manager, оставлены cadvisor, kube-state-metrics, CoreDNS и автодискавери):

```yaml
exporters:
  otlphttp/openobserve:
    endpoint: http://openobserve-router.openobserve.svc.cluster.local:5080/api/default/
    headers:
      Authorization: Basic cm9vdEBleGFtcGxlLmNvbTpDb21wbGV4cGFzcyMxMjM=
  otlphttp/openobserve_k8s_events:
    endpoint: http://openobserve-router.openobserve.svc.cluster.local:5080/api/default/
    headers:
      Authorization: Basic cm9vdEBleGFtcGxlLmNvbTpDb21wbGV4cGFzcyMxMjM=
      stream-name: k8s_events

k8sCluster: "openobserve"

autoinstrumentation:
  enabled: false

kube-state-metrics:
  enabled: true

gateway:
  replicas: 1
  receivers:
    prometheus:
      config:
        scrape_configs:
          - job_name: cadvisor
            scheme: https
            sample_limit: 10000
            scrape_interval: 30s
            scrape_timeout: 10s
            metrics_path: /metrics/cadvisor
            tls_config:
              ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
              insecure_skip_verify: true
            authorization:
              credentials_file: "/var/run/secrets/kubernetes.io/serviceaccount/token"
              type: Bearer
            kubernetes_sd_configs:
              - role: node
            metric_relabel_configs:
              - action: drop
                regex: ".+;"
                separator: ";"
                source_labels:
                  - id
                  - pod
            relabel_configs:
              - action: replace
                replacement: "kubelet"
                target_label: job
              - action: replace
                source_labels:
                  - __meta_kubernetes_node_name
                target_label: node
          - job_name: kube-state-metrics
            scrape_interval: 30s
            scrape_timeout: 10s
            static_configs:
              - targets: ["kube-state-metrics.kube-system.svc.cluster.local:8080"]
          - job_name: coredns
            scrape_interval: 30s
            scrape_timeout: 10s
            kubernetes_sd_configs:
              - role: endpoints
                namespaces:
                  names: [kube-system]
            relabel_configs:
              - source_labels: [__meta_kubernetes_service_name]
                action: keep
                regex: kube-dns
              - source_labels: [__meta_kubernetes_endpoint_port_name]
                action: keep
                regex: metrics
          - job_name: prometheus-autodiscovery
            scrape_interval: 30s
            kubernetes_sd_configs:
              - role: pod
            relabel_configs:
              - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
                action: keep
                regex: "true"
              - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
                action: replace
                target_label: __metrics_path__
                regex: (.+)
              - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
                action: replace
                regex: "([^:]+)(?::\\d+)?;(\\d+)"
                replacement: "$1:$2"
                target_label: __address__
              - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scheme]
                action: replace
                regex: (https?)
                target_label: __scheme__
              - source_labels: [__meta_kubernetes_namespace]
                target_label: namespace
              - source_labels: [__meta_kubernetes_pod_name]
                target_label: pod
              - source_labels: [__meta_kubernetes_pod_label_app_kubernetes_io_name]
                target_label: service
            sample_limit: 10000
```

### Устанавливаем

```bash
kubectl create namespace openobserve-collector
helm upgrade --install openobserve-collector openobserve/openobserve-collector \
  -n openobserve-collector -f collector-values.yaml
```

### Проверяем

```bash
kubectl get pods -n openobserve-collector -o wide
```

Agent-коллекторы появятся на каждой ноде (DaemonSet), gateway — один. Через пару минут в UI OpenObserve:

- **Logs** → стримы `default` — логи всех подов кластера, с лейблами `k8s.pod.name`, `k8s.namespace.name` и т.д.
- **Logs** → стрим `k8s_events` — события K8s (watch почти 30 типов объектов: pods, deployments, RBAC, CRD...) в отдельном потоке
- **Metrics** — метрики контейнеров (cAdvisor), kube-state-metrics, CoreDNS, hostmetrics

Теперь кластер наблюдает сам за собой. Клик по любому поду в дашборде → его логи, окружение, события — всё в одном месте.

## Обзор экранов OpenObserve

### Logs

Поиск по всем логам с full-text, инвертированным индексом, гистограммой по времени и field explorer'ом. Запросы на SQL с полным агрегационным арсеналом; quick-фильтры собираются мышкой. Из найденного — сразу в дашборд или алерт.

### Traces

OTLP-трейсы с waterfall-представлением, flame graph, Gantt. Клик по спану — drill в связанные логи. Service Graph строит карту зависимостей сервисов с health-цветовой индикацией.

### Metrics

Браузер тысяч метрик с фасетными фильтрами, запросы на SQL или PromQL, формулы из нескольких запросов, 19+ типов визуализаций. Prometheus remote_write поддерживается — существующие экспортеры переезжают без изменений.

### Dashboards

Драг-н-дроп построитель из любого сигнала: логи, метрики, трейсы в одном дашборде. Template-переменные, geo-карты, 200+ вариаций визуализаций.

### Pipelines

Визуальный редактор stream-processing прямо в UI: source → transform (VRL-функции, условия) → destination. Обогащение, редакция чувствительных данных, logs-to-metrics — без внешних инструментов.

### Alerts и Incidents

Пороговые, scheduled и real-time-алерты по любому сигналу; каналы уведомлений, история срабатываний, anomaly detection. Связанные алерты группируются в инциденты с lifecycle-трекингом.

### RUM и Session Replay

Real User Monitoring: Core Web Vitals, ошибки фронтенда, полные записи сессий пользователей с таймлайном событий.

### AI Observability

Трекинг LLM-приложений: стоимость, токены, латентность, error rate по моделям, agent-графы, session-трейсы, оценка качества ответов.

## Секреты: как не зашить креды в values

Креды в values.yaml — для демо. В продакшене используйте existing Secret (`externalSecret.*`) или `extraEnv` с `secretKeyRef`:

```yaml
externalSecret:
  enabled: true
  name: "openobserve-secrets"  # Secret с ZO_ROOT_USER_*, ZO_S3_ACCESS_KEY, ZO_S3_SECRET_KEY
```

Или через extraEnv:

```yaml
extraEnv:
  - name: ZO_S3_SECRET_KEY
    valueFrom:
      secretKeyRef:
        name: openobserve-s3-credentials
        key: secret_key
```

## Масштабирование и обновление

### Реплики по ролям

Каждая роль масштабируется независимо (`replicaCount.*`). Router и querier — простым увеличением реплик. Ingester — тоже, но данные шардятся consistent hashing'ом, поэтому рост числа реплик ingester'а запускает ребалансировку WAL. HPA из коробки:

```yaml
autoscaling:
  router:
    enabled: true
    minReplicas: 2
    maxReplicas: 10
    targetCPUUtilizationPercentage: 80
```

### Обновление

```bash
helm repo update openobserve
helm upgrade openobserve openobserve/openobserve -n openobserve -f values.yaml
helm upgrade openobserve-collector openobserve/openobserve-collector \
  -n openobserve-collector -f collector-values.yaml
```

Мажорные версии чарта и приложения — сначала [UPGRADING.md](https://github.com/openobserve/openobserve-helm-chart/blob/main/UPGRADING.md) и release notes приложения.

### Удаление

```bash
helm uninstall openobserve-collector -n openobserve-collector
helm uninstall openobserve -n openobserve
kubectl delete namespace openobserve-collector openobserve
# Данные в Object Storage останутся — удалите бакет отдельно, если нужно
```

## Troubleshooting

### 1. Под ingester'а не стартует / CrashLoopBackOff

```bash
kubectl logs -n openobserve openobserve-ingester-0 --previous
kubectl describe pod -n openobserve openobserve-ingester-0
```

Частая причина — недоступность S3: проверьте креды, имя бакета и эндпоинт `https://storage.yandexcloud.net`.

### 2. UI открывается, но данных нет

- Коллектор живёт? `kubectl get pods -n openobserve-collector`
- Куда шлёт? `kubectl logs -n openobserve-collector <gateway-pod> | grep -i error`
- Авторизация: заголовок `Authorization` в exporter'ах — валидный Basic из credentials OpenObserve

### 3. Collector-шробы падают с connection refused

Если оставили дефолтные scrape-jobs на managed-кластере — это kube-scheduler и kube-controller-manager. Control-plane Yandex Managed K8s вне кластера и не скрейпится: уберите эти job'ы (см. values выше).

### 4. Постоянно растёт расход S3

Retention. По умолчанию данные не удаляются никогда — задайте `ZO_COMPACT_DATA_RETENTION_DAYS`. Также проверьте, что компактор жив: он же и занимается удалением.

## Безопасность

- **Данные не покидают ваш периметр** — self-hosted, S3 ваш, телеметрию можно отключить (`ZO_TELEMETRY: "false"`)
- **S3-эндпоинт по HTTPS**; TLS на ingress при необходимости добавляется cert-manager'ом (в этой конфигурации не используется)
- **/metrics закрыты от публики** — чарт ставит nginx-сайдкар blocked-metrics, отдающий 403 на `/metrics` и `/api/metrics`
- **Секреты** — у чарта режим existing Secret вместо plaintext-credentials в values
- **OSS vs Enterprise** — SSO (OIDC/SAML/LDAP), гранулярный RBAC и audit trail доступны в Enterprise-редакции; OSS-аутентификация — пользователи OpenObserve с ролями
- **Лицензия** — AGPL-3.0: бесплатна для коммерческого использования, но модификации OpenObserve обязаны оставаться открытыми

## Заключение

OpenObserve — это то, чем должен был быть «ELK для всех»: единая платформа для логов, метрик, трейсов, RUM и дашбордов на SQL + PromQL, с хранением в дешёвом объектном S3 и без лицензионных счётчиков.

Ключевые преимущества:

- **Простота** — один Helm-чарт, SQL и PromQL вместо трёх DSL, единый UI
- **Экономия** — Parquet в S3 до 140x дешевле Elasticsearch-стека
- **OTel-native** — collector'ы и автоинструментация по стандарту, без lock-in
- **Stateless-масштабирование** — Postgres + NATS + S3, реплики добавляются по роли
- **Единое окно** — от лога пода до трейса запроса и записи сессии пользователя

Что учесть: встроенные дашборды проще Grafana (экспорт в Grafana всегда возможен), а при очень высоких нагрузках (миллиарды событий/сек) специализированные системы имеют право на жизнь.

Полезные ссылки:

- GitHub: [github.com/openobserve/openobserve](https://github.com/openobserve/openobserve)
- Документация: [openobserve.ai/docs](https://openobserve.ai/docs/)
- Helm-чарты: [github.com/openobserve/openobserve-helm-chart](https://github.com/openobserve/openobserve-helm-chart)
- Slack-сообщество: [short.openobserve.ai/community](https://short.openobserve.ai/community)
