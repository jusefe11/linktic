# Plataforma Kubernetes Cloud Native - Prueba Ingeniero Cloud Senior

Implementación reproducible de la prueba técnica: K3s con etcd, Gateway API, Istio, ArgoCD, cert-manager, MetalLB, Longhorn, CloudNativePG, una aplicación ToDo de dos microservicios y observabilidad completa.

## Arquitectura

| Nodo | IP | Rol |
|---|---:|---|
| master | 192.168.1.50 | control-plane + etcd |
| worker1 | 192.168.1.51 | worker (agente K3s) |
| worker2 | 192.168.1.53 | worker (agente K3s) |

Se utiliza K3s porque reduce el consumo del laboratorio sin abandonar APIs estándar. El maestro ejecuta el control-plane y etcd; los dos workers funcionan como agentes. Esta topología evita la contención de I/O de tres miembros etcd sobre discos VirtualBox y hace la demostración reproducible. La alta disponibilidad evaluada se implementa en la capa de datos con tres instancias CloudNativePG y volúmenes Longhorn replicados entre nodos. Traefik, ServiceLB y Local Path están deshabilitados: Istio implementa Gateway API, MetalLB anuncia las IP y Longhorn proporciona almacenamiento replicado.

El flujo de una operación es:

`Navegador -> Gateway Istio -> todo-frontend -> Gateway Istio -> todo-api -> CloudNativePG`

El frontend vuelve a entrar por el Gateway al llamar a la API. Las cabeceras B3 se propagan en Nginx y OpenTelemetry instrumenta Express y PostgreSQL para producir trazas correlacionadas.

## Versiones fijadas

- Kubernetes Gateway API 1.4.1
- K3s 1.35.5+k3s1
- Istio 1.30.1
- cert-manager 1.20.2
- MetalLB 0.16.1
- Longhorn 1.12.0
- CloudNativePG 1.29.1 (chart 0.28.3)
- kube-prometheus-stack 86.3.2
- Kiali 2.27.0

## Prerrequisitos de los nodos

- Ubuntu 24.04, swap deshabilitado y relojes sincronizados con Chrony.
- `open-iscsi`, `nfs-common`, `curl`, `jq` y módulos `overlay`/`br_netfilter`.
- Puertos internos de K3s, etcd, VXLAN e iSCSI permitidos entre las tres IP.
- Los nodos deben acceder a Internet para descargar charts e imágenes.

## Instalación

Los componentes se pueden desplegar por bloques:

```bash
./bootstrap.sh cluster
./bootstrap.sh infra
./bootstrap.sh gateway
./bootstrap.sh argocd
./bootstrap.sh observability
./bootstrap.sh expose
./bootstrap.sh status
```

La `Application` raíz inicia el patrón App of Apps:

```bash
kubectl apply -f root/root-app.yaml
kubectl get applications -n argocd -w
```

Las Sync Waves aplican primero CRDs, cert-manager e infraestructura; después Istio y observabilidad; finalmente configuración, base de datos y microservicios. Todas las aplicaciones usan auto-sync, prune y self-heal.

## Imágenes y registry local

El registry se publica como NodePort en `192.168.1.50:30500`. Cada nodo debe tener `/etc/rancher/k3s/registries.yaml`:

```yaml
mirrors:
  "192.168.1.50:30500":
    endpoint:
      - "http://192.168.1.50:30500"
```

Construcción desde el maestro:

```bash
docker build -t 192.168.1.50:30500/todo-api:v1 apps/todo-api
docker build -t 192.168.1.50:30500/todo-frontend:v1 apps/todo-frontend
docker push 192.168.1.50:30500/todo-api:v1
docker push 192.168.1.50:30500/todo-frontend:v1
```

## DNS local y HTTPS

MetalLB reserva `192.168.1.240` para el Gateway. Agregar al archivo `hosts`:

```text
192.168.1.240 todo.local api.todo.local argocd.local grafana.local kiali.local jaeger.local longhorn.local registry.local
```

cert-manager crea una CA raíz y un certificado para los hosts. Para confiar en ella:

```bash
kubectl get secret local-root-ca -n cert-manager -o jsonpath='{.data.tls\.crt}' | base64 -d > local-root-ca.crt
```

Importar `local-root-ca.crt` en el almacén de autoridades raíz del sistema o navegador.

## Accesos

| Servicio | URL |
|---|---|
| ToDo | https://todo.local |
| ArgoCD | https://argocd.local |
| Grafana | https://grafana.local |
| Kiali | https://kiali.local |
| Jaeger | https://jaeger.local |
| Longhorn | https://longhorn.local |
| Registry | https://registry.local/v2/ |

Credenciales de laboratorio:

- ArgoCD: usuario `admin`; obtener contraseña con `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`.
- Grafana: `admin` / `admin`.

## Decisiones principales

- Gateway API sustituye Ingress y separa infraestructura (`Gateway`) de rutas de aplicación (`HTTPRoute`). TLS termina en el Gateway para centralizar certificados y políticas.
- Longhorn mantiene dos réplicas por volumen. Cada instancia CNPG solicita un PVC independiente de 5 GiB.
- CloudNativePG ejecuta una primaria y dos réplicas, publica el Service `tododb-rw` y expone métricas mediante `PodMonitor`.
- mTLS estricto se aplica a los dos microservicios. PostgreSQL se excluye de la inyección de sidecar para no interferir con la gestión del operador.
- El túnel público usa Cloudflare Quick Tunnel, alternativa aceptada por el enunciado, sin almacenar tokens en Git.

## Sustentación

La secuencia y los comandos de evidencia se encuentran en [docs/REVIEW.md](docs/REVIEW.md).
