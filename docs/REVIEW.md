# Guía de review en vivo

Ejecutar `watch kubectl get pods -A` en una terminal y mantener abiertas las UIs antes de iniciar.

## 1. Clúster, CNI y MetalLB

```bash
kubectl get nodes -o wide
kubectl get pods -n kube-system
kubectl get ipaddresspool,l2advertisement -n metallb-system
kubectl get svc -A | grep LoadBalancer
```

Evidencia: tres nodos `Ready`, tres miembros etcd, CoreDNS/metrics-server operativos e IP `192.168.1.240` asignada.

## 2. Gateway API y TLS

```bash
kubectl get gatewayclass istio -o yaml
kubectl get gateway platform-gateway -n istio-system
kubectl get httproute -A
curl -I http://todo.local
curl -I https://todo.local
```

Mostrar `Accepted=True`, `Programmed=True`, redirect 301 y certificado firmado por `LinkTIC Local Root CA`.

## 3. ArgoCD y ciclo GitOps

```bash
kubectl get applications -n argocd
```

Todas deben estar `Synced` y `Healthy`. Para la demostración, cambiar `spec.replicas` del frontend de 2 a 3, hacer commit y push, y observar:

```bash
watch kubectl get deployment todo-frontend -n todo
```

Restaurar luego el valor a 2 mediante otro commit.

## 4. CRUD y persistencia

Crear, completar y eliminar tareas desde `https://todo.local`.

```bash
kubectl rollout restart deployment/todo-api -n todo
kubectl rollout status deployment/todo-api -n todo
```

Recargar el navegador: las tareas permanecen en PostgreSQL.

## 5. Failover CloudNativePG

```bash
kubectl get cluster,pods,pvc -n todo
PRIMARY=$(kubectl get pods -n todo -l cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}')
date; kubectl delete pod -n todo "$PRIMARY"
watch kubectl get pods -n todo -L cnpg.io/instanceRole
```

Una réplica debe asumir `primary` automáticamente. Crear otra tarea mientras se recupera la instancia eliminada.

## 6. Jaeger y Kiali

Generar tráfico:

```bash
for i in $(seq 1 30); do curl -sk https://todo.local/api/tasks >/dev/null; done
```

- En Jaeger seleccionar `todo-api` y mostrar spans HTTP y PostgreSQL para `GET /tasks` y `POST /tasks`.
- En Kiali seleccionar namespace `todo`, activar tráfico y mostrar Gateway, frontend y API con latencia.
- Explicar el `VirtualService todo-api-resilience`: timeout de 3 s y dos reintentos ante fallos transitorios.

## 7. Grafana

Mostrar:

- Istio Mesh Dashboard: RPS, errores y p95.
- ToDo API and CloudNativePG: RPS, p95 y conexiones PostgreSQL.
- Kubernetes / Compute Resources / Cluster: CPU y memoria por nodo/pod.

## 8. Longhorn

```bash
kubectl get pvc -A
kubectl get volumes.longhorn.io -n longhorn-system
```

En la UI mostrar los tres volúmenes CNPG `Healthy` con dos réplicas en nodos distintos.

## 9. URL pública

```bash
kubectl logs -n public-tunnel deployment/cloudflared --tail=100 | grep -Eo 'https://[-a-z0-9]+\.trycloudflare\.com' | tail -1
```

Abrir la URL desde una red externa y crear una tarea. La URL cambia al reiniciar el pod porque es un Quick Tunnel gratuito.
