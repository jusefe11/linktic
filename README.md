# Plataforma Kubernetes Cloud Native - GitOps con ArgoCD

## Repositorio GitOps

El repositorio sigue el patrón App of Apps donde una Application raíz (`root-app`) gestiona el resto de Applications declarativas.

Estructura:

```text
apps/
infra/
observability/
root/
```

## Registrar repositorio en ArgoCD

Obtener acceso al servidor ArgoCD y registrar el repositorio:

```bash
argocd repo add https://github.com/jusefe11/linktic.git
```

Verificar repositorios registrados:

```bash
argocd repo list
```

---

## Aplicar la Application raíz

Desplegar la Application principal:

```bash
kubectl apply -f root/root-app.yaml
```

Verificar:

```bash
kubectl get applications -n argocd
```

Resultado esperado:

```text
applications-app    Synced   Healthy
infra-app           Synced   Healthy
observability-app   Synced   Healthy
root-app            Synced   Healthy
```

---

## Verificación de sincronización

Consultar estado de las Applications:

```bash
kubectl get applications -n argocd
```

Consultar detalle:

```bash
kubectl describe application root-app -n argocd
```

---

## Flujo GitOps

1. Modificar un manifiesto dentro del repositorio Git.
2. Realizar commit.
3. Realizar push al repositorio remoto.
4. ArgoCD detecta automáticamente el cambio.
5. ArgoCD sincroniza el clúster.
6. Kubernetes aplica la nueva configuración.

Ejemplo:

Modificar:

```yaml
replicas: 1
```

por:

```yaml
replicas: 2
```

Luego:

```bash
git add .
git commit -m "Increase replicas"
git push
```

Verificar:

```bash
kubectl get deployments -A
kubectl get applications -n argocd
```

---

## Sync Waves

Orden de despliegue configurado:

1. Gateway API CRDs
2. cert-manager
3. Istio
4. CloudNativePG
5. Aplicaciones
6. Gateways y HTTPRoutes

Esto garantiza que las dependencias se desplieguen en el orden correcto.

---

## Validación

Todas las Applications deben permanecer en estado:

```text
Synced
Healthy
```

Los recursos Gateway y HTTPRoute son gestionados por ArgoCD y se encuentran versionados en el repositorio Git.



# Registry Local (ECR Simulado)

## Implementación

Se desplegó un Docker Registry v2 dentro del clúster Kubernetes en el namespace `registry`.

La elección de Docker Registry v2 se realizó por su simplicidad de operación, bajo consumo de recursos y compatibilidad con el estándar OCI, cumpliendo los requisitos de la prueba para simular un registry privado similar a AWS ECR.

## Arquitectura

* Namespace: `registry`
* Deployment: `docker-registry`
* Service: `docker-registry`
* Puerto: `5000`
* Exposición mediante Gateway API e Istio.
* Certificados TLS gestionados por cert-manager.

## Flujo de uso

1. Construcción local de la imagen Docker.
2. Etiquetado de la imagen apuntando al registry interno.
3. Push de la imagen al registry del clúster.
4. Uso de la imagen desde los Deployments de Kubernetes.

Ejemplo:

```bash
docker build -t todo-api:v1 .
docker tag todo-api:v1 registry.local/todo-api:v1
docker push registry.local/todo-api:v1
```

Posteriormente los Deployments consumen la imagen desde:

```text
registry.local/todo-api:v1
```


# Aplicación TODO

## Arquitectura

La solución implementa una aplicación de gestión de tareas compuesta por dos microservicios desplegados en el namespace `todo`.

### Todo API

Tecnología:

* Node.js 20
* Express
* PostgreSQL

Puerto:

* 8080

Endpoints implementados:

* GET /healthz
* GET /readyz
* GET /metrics
* GET /tasks
* GET /tasks/{id}
* POST /tasks
* PUT /tasks/{id}
* DELETE /tasks/{id}

La API almacena las tareas en PostgreSQL y expone métricas compatibles con Prometheus mediante la librería prom-client.

### Todo Frontend

Tecnología:

* Frontend HTTP expuesto mediante Service y HTTPRoute
* Integrado con Istio Gateway

Namespace:

```text
todo
```

---

# Recursos Kubernetes Implementados

## Deployment

Se utilizaron Deployments para ambos microservicios.

Características:

* RollingUpdate
* Gestión declarativa mediante GitOps
* Integración con ArgoCD

## HTTPRoute

Se implementaron rutas utilizando Gateway API.

Rutas desplegadas:

* todo.local
* api.todo.local

Las rutas se encuentran asociadas al Gateway principal gestionado por Istio.

## Horizontal Pod Autoscaler

Configuración:

* CPU Target: 60%
* Mínimo: 2 réplicas
* Máximo: 5 réplicas

Objetivo:

Escalado automático de la API ante incremento de carga.

## Liveness y Readiness Probes

Todo API:

* /healthz
* /readyz

Permiten a Kubernetes validar la salud y disponibilidad de la aplicación.

## Resources Requests y Limits

Configurados para evitar consumo descontrolado de recursos.

Ejemplo:

* CPU Request: 100m
* CPU Limit: 500m
* Memory Request: 128Mi
* Memory Limit: 512Mi

## ConfigMap

Variables externalizadas:

* DB_HOST
* DB_NAME

## Secret

Credenciales protegidas:

* DB_USER
* DB_PASSWORD

## Service Accounts

Se implementó una cuenta de servicio independiente por microservicio:

* todo-api-sa
* todo-frontend-sa

Aplicando el principio de mínimo privilegio.

## Network Policies

Se implementaron políticas de red para restringir la comunicación interna.

Objetivos:

* Frontend → API
* API → PostgreSQL

---

# Observabilidad

## Prometheus

Prometheus realiza el scraping de métricas expuestas por la aplicación mediante:

```text
/metrics
```

## Grafana

Grafana permite visualizar métricas de infraestructura y aplicaciones.

## Jaeger

Jaeger proporciona trazabilidad distribuida para las solicitudes procesadas por Istio.

## Kiali

Kiali permite visualizar:

* Frontend → API
* API → PostgreSQL

Mostrando el flujo de tráfico dentro de la malla de servicios.

---


# Base de Datos

## PostgreSQL

La aplicación utiliza PostgreSQL como motor de persistencia para el almacenamiento de tareas.

Características implementadas:

* Persistencia mediante PersistentVolumeClaim.
* Configuración mediante ConfigMap y Secret.
* Acceso restringido desde la aplicación todo-api.
* Integración con Kubernetes mediante Deployment y Service.

## CloudNativePG

Se realizó la instalación del operador CloudNativePG para implementar PostgreSQL cloud-native sobre Kubernetes.

Se definieron recursos GitOps para:

* Secret de credenciales.
* Definición del clúster PostgreSQL.
* Integración con Prometheus para monitoreo.

Durante las pruebas en el entorno K3s sobre VirtualBox se presentaron inconvenientes relacionados con el webhook del operador, impidiendo completar el despliegue del recurso Cluster.

Los manifiestos quedaron versionados en Git para futuras iteraciones de la plataforma.

---

# Almacenamiento Persistente

## Evaluación de Longhorn

Se evaluó Longhorn como solución de almacenamiento distribuido para Kubernetes.

Longhorn fue desplegado inicialmente sobre el clúster, validando los requisitos de instalación de open-iscsi en los nodos.

Durante las pruebas se identificaron problemas de estabilidad relacionados con los componentes del controlador y la interfaz de administración.

## Solución Utilizada

La persistencia de la plataforma se mantuvo mediante Local Path Provisioner (LocalPV) incluido en K3s.

Esta solución permitió:

* Persistencia de PostgreSQL.
* Recuperación de datos tras reinicio de Pods.
* Recuperación de datos tras recreación de Deployments.

---

# Estado Actual de la Plataforma

| Componente         | Estado    |
| ------------------ | --------- |
| Kubernetes K3s     | Operativo |
| ArgoCD             | Operativo |
| Gateway API        | Operativo |
| Istio Service Mesh | Operativo |
| Cert Manager       | Operativo |
| Docker Registry    | Operativo |
| Todo Frontend      | Operativo |
| Todo API           | Operativo |
| PostgreSQL         | Operativo |
| Prometheus         | Operativo |
| Grafana            | Operativo |
| Jaeger             | Operativo |
| Kiali              | Operativo |
| CloudNativePG      | Parcial   |
| Longhorn           | Evaluado  |

---

# Evidencias

Para la revisión técnica se incluyen evidencias de:

* ArgoCD Applications.
* Gateway API.
* HTTPRoutes.
* Deployments.
* Pods.
* PostgreSQL.
* Docker Registry.
* Prometheus.
* Grafana.
* Jaeger.
* Kiali.
1~# Base de Datos

## PostgreSQL

La aplicación utiliza PostgreSQL como motor de persistencia para el almacenamiento de tareas.

Características implementadas:

* Persistencia mediante PersistentVolumeClaim.
* Configuración mediante ConfigMap y Secret.
* Acceso restringido desde la aplicación todo-api.
* Integración con Kubernetes mediante Deployment y Service.

## CloudNativePG

Se realizó la instalación del operador CloudNativePG para implementar PostgreSQL cloud-native sobre Kubernetes.

Se definieron recursos GitOps para:

* Secret de credenciales.
* Definición del clúster PostgreSQL.
* Integración con Prometheus para monitoreo.

Durante las pruebas en el entorno K3s sobre VirtualBox se presentaron inconvenientes relacionados con el webhook del operador, impidiendo completar el despliegue del recurso Cluster.

Los manifiestos quedaron versionados en Git para futuras iteraciones de la plataforma.

---

# Almacenamiento Persistente

## Evaluación de Longhorn

Se evaluó Longhorn como solución de almacenamiento distribuido para Kubernetes.

Longhorn fue desplegado inicialmente sobre el clúster, validando los requisitos de instalación de open-iscsi en los nodos.

Durante las pruebas se identificaron problemas de estabilidad relacionados con los componentes del controlador y la interfaz de administración.

## Solución Utilizada

La persistencia de la plataforma se mantuvo mediante Local Path Provisioner (LocalPV) incluido en K3s.

Esta solución permitió:

* Persistencia de PostgreSQL.
* Recuperación de datos tras reinicio de Pods.
* Recuperación de datos tras recreación de Deployments.

---

# Estado Actual de la Plataforma

| Componente         | Estado    |
| ------------------ | --------- |
| Kubernetes K3s     | Operativo |
| ArgoCD             | Operativo |
| Gateway API        | Operativo |
| Istio Service Mesh | Operativo |
| Cert Manager       | Operativo |
| Docker Registry    | Operativo |
| Todo Frontend      | Operativo |
| Todo API           | Operativo |
| PostgreSQL         | Operativo |
| Prometheus         | Operativo |
| Grafana            | Operativo |
| Jaeger             | Operativo |
| Kiali              | Operativo |
| CloudNativePG      | Parcial   |
| Longhorn           | Evaluado  |

---


# Observabilidad — Istio y Stack de Monitoreo

## Istio Service Mesh

Se desplegó Istio como service mesh principal de la plataforma utilizando Gateway API como mecanismo de exposición de servicios.

Funcionalidades habilitadas:

* Inyección automática de sidecars Envoy.
* Observabilidad L7.
* Métricas de tráfico entre servicios.
* Integración con Prometheus, Grafana, Jaeger y Kiali.
* Exposición de aplicaciones mediante Gateway API.

Namespace con inyección habilitada:

```bash
kubectl label namespace todo istio-injection=enabled
```

Validación:

```bash
kubectl get ns --show-labels
```

Resultado:

```text
todo   istio-injection=enabled
```

## Jaeger

Jaeger fue desplegado para visualización de trazas distribuidas generadas por Istio.

Servicio:

```text
Namespace: monitoring
Service: jaeger
Puerto: 16686
```

HTTPRoute configurado:

```text
jaeger.local
```

Objetivo:

* Visualizar trazas distribuidas.
* Analizar flujo de peticiones entre servicios.
* Correlacionar solicitudes dentro de la malla de servicios.

## Grafana

Grafana fue desplegado mediante kube-prometheus-stack.

Servicio:

```text
Namespace: monitoring
Service: kube-prometheus-stack-grafana
Puerto: 80
```

HTTPRoute configurado:

```text
grafana.local
```

Dashboards disponibles:

* Kubernetes Cluster
* Istio Mesh
* Prometheus Metrics

## Kiali

Kiali fue desplegado para visualizar la topología de la malla de servicios.

Servicio:

```text
Namespace: istio-system
Service: kiali
Puerto: 20001
```

HTTPRoute configurado:

```text
kiali.local
```

Funcionalidades:

* Grafo de dependencias.
* Visualización de tráfico.
* Estado de workloads.
* Métricas de latencia y errores.

## HTTPRoutes de Observabilidad

Recursos configurados:

```text
grafana.local
jaeger.local
kiali.local
```

Implementados mediante Gateway API utilizando el Gateway:

```text
platform-gateway-istio
```

## Estado Actual

| Componente            | Estado    |
| --------------------- | --------- |
| Istio                 | Operativo |
| Gateway API           | Operativo |
| Prometheus            | Operativo |
| Grafana               | Operativo |
| Jaeger                | Operativo |
| Kiali                 | Operativo |
| Sidecar Injection     | Operativo |
| Tracing distribuido   | Parcial   |
| CloudNativePG Metrics | Pendiente |
| Longhorn Metrics      | Pendiente |

# Observabilidad

## Istio Service Mesh

Se instaló Istio utilizando el perfil demo para habilitar observabilidad, trazabilidad distribuida y control de tráfico mediante Envoy Sidecars.

Se habilitó la inyección automática de sidecars en el namespace `todo`:

```bash
kubectl label namespace todo istio-injection=enabled --overwrite
```

Los pods del namespace `todo` fueron reiniciados para recibir el sidecar Envoy.

## Jaeger

Jaeger fue desplegado para visualizar trazas distribuidas de las solicitudes HTTP procesadas por la aplicación.

Acceso:

* Host: `jaeger.local`
* Expuesto mediante HTTPRoute gestionado por Istio Gateway.

## Kiali

Kiali permite visualizar el grafo de dependencias y el flujo de tráfico del Service Mesh.

Acceso:

* Host: `kiali.local`
* Expuesto mediante HTTPRoute gestionado por Istio Gateway.

## Grafana

Grafana fue desplegado mediante kube-prometheus-stack para visualización de métricas de infraestructura y aplicaciones.

Acceso:

* Host: `grafana.local`
* Expuesto mediante HTTPRoute gestionado por Istio Gateway.

## Loki

Loki fue desplegado para centralización de logs del clúster Kubernetes.

La integración con Grafana permite consultar logs de aplicaciones y componentes de plataforma desde una única interfaz.

## Métricas

Prometheus realiza el scraping de:

* Kubernetes
* Istio
* PostgreSQL
* Aplicación ToDo
* Componentes del clúster

Endpoint de métricas de la aplicación:

```text
/metrics
```
# Exposición Pública con Ngrok

Para facilitar la demostración remota de la plataforma se utilizó Ngrok.

Configuración:

```bash
kubectl port-forward svc/todo-frontend 8080:80 -n todo

ngrok http 8080
```

URL pública generada durante la validación:

```text
https://dash-syrup-frequency.ngrok-free.dev
```

Consideraciones:

* Plan gratuito de Ngrok.
* Un único túnel simultáneo.
* La URL cambia en cada sesión.
* No requiere modificaciones en la red local.
* Permite acceso HTTPS público para demostraciones y revisiones remotas.

