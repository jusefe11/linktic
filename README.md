# Plataforma Kubernetes Cloud Native - GitOps con ArgoCD

## Objetivo

Implementar una plataforma Kubernetes cloud-native basada en GitOps utilizando ArgoCD, Gateway API, Istio, PostgreSQL, Observabilidad y exposición pública mediante Ngrok.

---

# Prerrequisitos

## Hardware

* 1 nodo Master
* 2 nodos Worker
* Ubuntu Server 24.04 LTS
* 4 vCPU por nodo
* 8 GB RAM por nodo
* 50 GB disco por nodo

## Software

* Git
* Docker
* kubectl
* Helm
* ArgoCD CLI
* Istioctl
* Ngrok
* K3s

---

# Justificación de K3s

Se seleccionó K3s en lugar de kubeadm debido a:

* Menor consumo de recursos.
* Instalación simplificada.
* Integración nativa con Local Path Provisioner.
* Menor complejidad operativa para entornos de laboratorio.
* Compatibilidad total con Kubernetes estándar.

---

# Hostnames

Agregar en /etc/hosts:

192.168.1.50 argocd.local
192.168.1.50 grafana.local
192.168.1.50 jaeger.local
192.168.1.50 kiali.local
192.168.1.50 registry.local
192.168.1.50 todo.local
192.168.1.50 api.todo.local
192.168.1.50 longhorn.local

---

# Estructura del Repositorio

apps/
infra/
observability/
root/

---

# Despliegue desde Cero

## 1. Cluster

Instalar K3s en Master y Workers.

## 2. Infraestructura

Instalar:

* Gateway API CRDs
* Cert Manager
* MetalLB
* Longhorn (evaluado)
* CloudNativePG

## 3. Service Mesh

Instalar Istio utilizando perfil demo.

## 4. GitOps

Instalar ArgoCD.

Registrar repositorio:

argocd repo add https://github.com/jusefe11/linktic.git

Aplicar:

kubectl apply -f root/root-app.yaml

## 5. Observabilidad

Instalar:

* Prometheus
* Grafana
* Jaeger
* Kiali
* Loki

## 6. Exposición Pública

kubectl port-forward svc/todo-frontend 8080:80 -n todo

ngrok http 8080

---

# Decisiones de Diseño

## GitOps

Patrón App of Apps con ArgoCD.

## Gateway API

Implementación mediante Istio GatewayClass.

## Service Mesh

Istio para observabilidad, métricas y trazabilidad.

## Persistencia

Evaluación de Longhorn.

Persistencia final mediante Local Path Provisioner.

## Observabilidad

Prometheus
Grafana
Jaeger
Kiali
Loki

---

# Aplicación ToDo

## Todo API

Tecnologías:

* Node.js
* Express
* PostgreSQL

Endpoints:

GET /healthz
GET /readyz
GET /metrics
GET /tasks
GET /tasks/{id}
POST /tasks
PUT /tasks/{id}
DELETE /tasks/{id}

## Todo Frontend

Aplicación HTTP publicada mediante Gateway API e Istio.

---

# Base de Datos

## PostgreSQL

Persistencia mediante PVC.

Configuración mediante:

* ConfigMap
* Secret

---

# Observabilidad

## Grafana

Host:

grafana.local

## Jaeger

Host:

jaeger.local

## Kiali

Host:

kiali.local

## Loki

Centralización de logs.

---

# Exposición Pública

Se utilizó Ngrok para compartir la aplicación mediante HTTPS.

Consideraciones:

* Plan gratuito.
* 1 túnel simultáneo.
* URL temporal.
* No requiere cambios de red.

---

# Estado Actual

| Componente      | Estado    |
| --------------- | --------- |
| Kubernetes K3s  | Operativo |
| ArgoCD          | Operativo |
| Gateway API     | Operativo |
| Cert Manager    | Operativo |
| Istio           | Operativo |
| Docker Registry | Operativo |
| PostgreSQL      | Operativo |
| Todo Frontend   | Operativo |
| Prometheus      | Operativo |
| Grafana         | Operativo |
| Jaeger          | Operativo |
| Kiali           | Operativo |
| Loki            | Operativo |
| Ngrok           | Operativo |
| CloudNativePG   | Parcial   |
| Longhorn        | Evaluado  |

---

# Bootstrap

El repositorio incluye bootstrap.sh con los siguientes bloques:

./bootstrap.sh cluster
./bootstrap.sh infra
./bootstrap.sh gateway
./bootstrap.sh argocd
./bootstrap.sh observability
./bootstrap.sh expose
