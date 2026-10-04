# Kubernetes + Gateway API + Monitoring + Logging

Репродуцируемое развёртывание одновузлового Kubernetes-кластера в Ubuntu 24.04 / WSL2.

Проект демонстрирует:

* Kubernetes;
* Cilium CNI;
* Gateway API;
* MetalLB;
* nginx;
* Prometheus;
* Filebeat;
* автоматизированное развёртывание через `setup.sh`;
* автоматическую проверку через `verify.sh`.

---

## 1. Архитектура

```text
                         Windows / WSL2
                              │
                              │
                    ┌─────────▼─────────┐
                    │   Ubuntu 24.04    │
                    │       WSL2        │
                    └─────────┬─────────┘
                              │
                    ┌─────────▼─────────┐
                    │ Kubernetes 1.37   │
                    │ single-node       │
                    └─────────┬─────────┘
                              │
             ┌────────────────┼─────────────────┐
             │                │                 │
      ┌──────▼──────┐  ┌──────▼──────┐  ┌──────▼──────┐
      │    Cilium   │  │   MetalLB   │  │  Filebeat   │
      │     CNI     │  │ LoadBalancer│  │  DaemonSet  │
      └──────┬──────┘  └──────┬──────┘  └──────┬──────┘
             │                │                 │
             │          192.168.0.200            │
             │                │                 │
             │        ┌───────▼────────┐        │
             │        │ Gateway API    │        │
             │        │ Cilium Gateway │        │
             │        └───────┬────────┘        │
             │                │                 │
             │        ┌───────▼────────┐        │
             └───────►│ nginx Service  │◄──────┘
                      └───────┬────────┘
                              │
                         ┌────▼────┐
                         │ nginx ×2│
                         └─────────┘

              Prometheus
                   │
                   ├── Cilium metrics
                   ├── kubelet/cAdvisor
                   └── infrastructure metrics
```

---

## 2. Требования

### Операционная система

* Ubuntu 24.04 LTS
* WSL2
* systemd должен быть включён
* доступ к `sudo`
* интернет-доступ

Проверка:

```bash
lsb_release -a
ps -p 1 -o comm=
```

Ожидается:

```text
Ubuntu 24.04
systemd
```

### WSL2 networking

Проект рассчитан на WSL2 с:

```ini
[wsl2]
networkingMode=mirrored
```

Это позволяет Kubernetes Gateway быть доступным из Windows/LAN через IP MetalLB.

---

## 3. Что устанавливает setup.sh

Скрипт `scripts/setup.sh` выполняет полный bootstrap:

1. устанавливает системные зависимости;
2. отключает swap;
3. загружает необходимые kernel modules;
4. настраивает Kubernetes sysctl;
5. устанавливает/configures containerd;
6. включает `SystemdCgroup`;
7. устанавливает:

   * kubeadm;
   * kubelet;
   * kubectl;
8. устанавливает Helm;
9. автоматически определяет текущий IP WSL;
10. создаёт Kubernetes cluster через kubeadm;
11. устанавливает Gateway API CRDs;
12. устанавливает Cilium;
13. включает Cilium kube-proxy replacement;
14. включает Cilium Gateway API;
15. устанавливает MetalLB;
16. создаёт nginx Deployment и Service;
17. создаёт Gateway и HTTPRoute;
18. устанавливает Prometheus/Grafana;
19. устанавливает Filebeat;
20. ждёт готовности компонентов.

Скрипт рассчитан на повторный запуск: если Kubernetes-кластер уже существует, `kubeadm init` повторно не выполняется.

---

## 4. Быстрый запуск

Клонировать репозиторий:

```bash
git clone <REPOSITORY_URL>
cd hackathon-k8s
```

Сделать скрипты исполняемыми:

```bash
chmod +x scripts/setup.sh scripts/verify.sh
```

Проверить синтаксис:

```bash
bash -n scripts/setup.sh
bash -n scripts/verify.sh
```

Запустить автоматическую установку:

```bash
./scripts/setup.sh
```

После завершения:

```bash
./scripts/verify.sh
```

---

## 5. Переменные конфигурации

По умолчанию используются:

```text
K8S_VERSION=1.37
CILIUM_VERSION=1.20.2
GATEWAY_API_VERSION=v1.6.1
METALLB_RANGE=192.168.0.200-192.168.0.202
FILEBEAT_IMAGE=docker.elastic.co/beats/filebeat:9.5.4
```

Их можно изменить через environment variables.

Например:

```bash
METALLB_RANGE=192.168.0.200-192.168.0.205 ./scripts/setup.sh
```

---

## 6. Kubernetes

Используется одновузловой кластер.

Kubernetes API автоматически привязывается к текущему IP WSL:

```bash
ip route get 8.8.8.8
```

IP не зашит в скрипт, потому что WSL IP может измениться после перезапуска WSL/Windows.

Создание кластера:

```bash
kubeadm init \
  --apiserver-advertise-address=<WSL_IP> \
  --pod-network-cidr=10.244.0.0/16 \
  --skip-phases=addon/kube-proxy
```

Cilium используется вместо kube-proxy.

После установки control-plane taint удаляется, чтобы workloads могли запускаться на единственной Kubernetes-нoded.

---

## 7. Cilium

Cilium используется как CNI.

Основные параметры:

```text
kubeProxyReplacement=true
gatewayAPI.enabled=true
prometheus.enabled=true
operator.prometheus.enabled=true
```

Cilium также предоставляет GatewayClass:

```text
cilium
```

GatewayClass создаётся и управляется Helm-релизом Cilium.

Поэтому `gatewayclass.yaml` из репозитория намеренно не применяется вручную.

---

## 8. Gateway API

Используется Gateway API v1.6.1.

Архитектура:

```text
Client
  │
  │ HTTP :80
  ▼
MetalLB
  │
  │ 192.168.0.200
  ▼
Cilium Gateway
  │
  ▼
HTTPRoute
  │
  ▼
nginx Service :80
  │
  ├── nginx pod
  └── nginx pod
```

Проверка:

```bash
kubectl get gateway
kubectl get httproute
```

Ожидается:

```text
Gateway       Accepted=True
HTTPRoute     Accepted=True
              ResolvedRefs=True
```

---

## 9. MetalLB

MetalLB предоставляет внешний IP для Gateway.

Используемый диапазон:

```text
192.168.0.200-192.168.0.202
```

Проверка:

```bash
kubectl get ipaddresspool -n metallb-system
kubectl get l2advertisement -n metallb-system
```

Gateway должен получить:

```text
192.168.0.200
```

Проверка:

```bash
kubectl get gateway web-gateway
```

---

## 10. nginx

Приложение состоит из:

```text
Deployment/nginx
Service/nginx
```

Количество replicas:

```text
2
```

Проверка:

```bash
kubectl get deployment nginx
kubectl get pods -l app=nginx
kubectl get svc nginx
```

Локальная проверка внутри Kubernetes:

```bash
kubectl run curl-test \
  --rm -it \
  --restart=Never \
  --image=curlimages/curl \
  -- curl -sS http://nginx/
```

---

## 11. Проверка Gateway

Получить IP:

```bash
kubectl get gateway web-gateway \
  -o jsonpath='{.status.addresses[0].value}'
```

Проверить HTTP:

```bash
curl --noproxy '*' http://192.168.0.200/
```

Ожидается:

```text
HTTP/1.1 200 OK
```

В WSL с установленным HTTP proxy параметр `--noproxy '*'` важен для обращения к локальному MetalLB IP.

---

## 12. Prometheus

Prometheus устанавливается в namespace:

```text
cilium-monitoring
```

Проверка:

```bash
kubectl get pods -n cilium-monitoring
```

Prometheus:

```text
prometheus
```

Grafana:

```text
grafana
```

Для локального доступа:

```bash
kubectl -n cilium-monitoring port-forward svc/prometheus 9090:9090
```

После этого:

```text
http://localhost:9090
```

Проверка API:

```bash
curl http://localhost:9090/-/ready
```

---

## 13. Filebeat

Filebeat работает как DaemonSet:

```text
kube-system/filebeat
```

Он читает container logs с node filesystem и добавляет Kubernetes metadata.

Проверка:

```bash
kubectl -n kube-system get daemonset filebeat
```

Проверка логов nginx:

```bash
kubectl logs -l app=nginx --tail=20
```

Проверка Filebeat:

```bash
kubectl -n kube-system logs -l app=filebeat --tail=300
```

### Проверка реального сбора

Сгенерировать запрос:

```bash
curl --noproxy '*' \
  -A 'hackathon-filebeat-test' \
  http://192.168.0.200/
```

Затем:

```bash
kubectl -n kube-system logs \
  -l app=filebeat \
  --since=2m \
  | grep 'hackathon-filebeat-test'
```

В результате должен присутствовать nginx access log с User-Agent:

```text
hackathon-filebeat-test
```

---

## 14. Proxy / NO_PROXY

Если в WSL настроен HTTP proxy, Kubernetes/MetalLB локальные адреса не должны проходить через него.

После `setup.sh` создаётся:

```text
~/.hackathon-k8s-env
```

В новом WSL shell:

```bash
source ~/.hackathon-k8s-env
```

После этого локальные Kubernetes/MetalLB адреса будут добавлены в `NO_PROXY`.

Для ручной проверки можно использовать:

```bash
curl --noproxy '*' http://192.168.0.200/
```

---

## 15. Автоматическая проверка

Основная проверка:

```bash
./scripts/verify.sh
```

Проверяются:

* Kubernetes node;
* Cilium;
* Gateway API;
* GatewayClass;
* Gateway;
* HTTPRoute;
* MetalLB;
* nginx;
* Prometheus;
* Filebeat;
* реальный HTTP-запрос;
* сбор nginx logs через Filebeat.

---

## 16. Полный reset для проверки воспроизводимости

Для проверки установки с чистого Kubernetes-кластера:

```bash
sudo kubeadm reset -f
```

Удалить kubeconfig:

```bash
rm -rf ~/.kube
```

Удалить CNI state:

```bash
sudo rm -rf /etc/cni/net.d
sudo rm -rf /var/lib/cni
```

Перезапустить containerd:

```bash
sudo systemctl restart containerd
```

После этого снова:

```bash
cd ~/hackathon-k8s
./scripts/setup.sh
```

И:

```bash
./scripts/verify.sh
```

Это позволяет проверить, что кластер действительно собирается автоматически, а не зависит от ручных действий, выполненных во время разработки.

---

## 17. Структура проекта

```text
hackathon-k8s/
├── manifests/
│   ├── app/
│   │   ├── deployment.yaml
│   │   └── service.yaml
│   │
│   ├── gateway/
│   │   ├── gateway.yaml
│   │   ├── gatewayclass.yaml
│   │   └── httproute.yaml
│   │
│   ├── metallb/
│   │   └── ip-pool.yaml
│   │
│   └── logging/
│       └── filebeat.yaml
│
├── scripts/
│   ├── setup.sh
│   └── verify.sh
│
└── README.md
```

`gatewayclass.yaml` сохранён в репозитории для документации, но не применяется `setup.sh`, поскольку GatewayClass `cilium` управляется Helm-релизом Cilium.

---

## 18. Результат

После успешного развёртывания:

```text
Kubernetes                  ✓
Cilium                      ✓
Gateway API                 ✓
MetalLB                     ✓
nginx                       ✓
Prometheus                  ✓
Filebeat                    ✓
Automation                  ✓
Verification                ✓
```

Основная точка входа приложения:

```text
http://192.168.0.200/
```

Проверка всей системы:

```bash
./scripts/verify.sh
```

---

## 19. Воспроизводимость

Проект рассчитан на чистую Ubuntu 24.04 / WSL2.

Все основные этапы установки автоматизированы:

```text
Ubuntu
  ↓
containerd
  ↓
kubeadm / kubelet / kubectl
  ↓
Kubernetes
  ↓
Cilium
  ↓
Gateway API
  ↓
MetalLB
  ↓
nginx
  ↓
Prometheus
  ↓
Filebeat
```

Для повторного развёртывания достаточно выполнить:

```bash
./scripts/setup.sh
./scripts/verify.sh
```
