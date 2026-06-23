# Prueba técnica Cloud Native

## Estado actual: fases 1, 2 y 3 completadas

Cluster Kubernetes sobre tres máquinas virtuales VirtualBox, sin nodos basados en Docker:

| Nodo | IP | Rol |
|---|---:|---|
| `master` | `192.168.1.50` | K3s server, control-plane y etcd |
| `worker1` | `192.168.1.51` | K3s agent |
| `worker2` | `192.168.1.53` | K3s agent |

Componentes instalados en esta fase:

- K3s `v1.36.1+k3s1` con etcd embebido.
- Calico `v3.32.0` como CNI, con VXLAN y soporte completo de `NetworkPolicy`.
- MetalLB `v0.16.1` en modo Layer 2.
- Pool MetalLB: `192.168.1.240-192.168.1.250`.
- Gateway API Standard Channel `v1.4.1`.
- cert-manager `v1.20.2` con CA raíz local.
- Istio `1.30.1` como controlador de Gateway API.
- Gateway principal HTTP/HTTPS en `192.168.1.240`.
- ArgoCD `v3.4.4` mediante App of Apps y sincronización automática.

Longhorn, CloudNativePG y el stack de observabilidad permanecen declarados en el repositorio y se activan en sus fases correspondientes para mantener cada entrega verificable.

## Elección de bootstrap: K3s

Se eligió K3s porque el laboratorio se ejecuta en VMs con recursos compartidos y K3s reduce memoria, procesos y tiempo de bootstrap sin abandonar conformidad Kubernetes. Usa APIs estándar, containerd y permite reemplazar sus componentes integrados.

Frente a kubeadm, esta opción deja más tiempo de la prueba para demostrar Gateway API, GitOps, almacenamiento y observabilidad. Para mantener fidelidad a producción se usó `--cluster-init`, por lo que el datastore es etcd y no SQLite. El miembro único de etcd es suficiente para este laboratorio; en producción se usarían tres nodos server para mantener quorum.

Se deshabilitaron Flannel, ServiceLB, Traefik y Local Path:

- Calico reemplaza Flannel y ofrece `NetworkPolicy` completa para la aplicación e Istio.
- MetalLB reemplaza ServiceLB y entrega IPs reales de la LAN mediante ARP/NDP.
- Istio será el proveedor posterior de Gateway API.
- Longhorn será la StorageClass posterior.

Calico usa VXLAN, evitando depender de sesiones BGP en la red VirtualBox. La configuración CNI habilita `allow_ip_forwarding`, requerido para el tráfico redirigido por sidecars de Istio.

## Bootstrap reproducible

En el master:

```bash
curl -sfL https://get.k3s.io -o /tmp/install-k3s.sh
sudo env INSTALL_K3S_VERSION='v1.36.1+k3s1' sh /tmp/install-k3s.sh server \
  --cluster-init \
  --write-kubeconfig-mode=644 \
  --flannel-backend=none \
  --disable-network-policy \
  --disable=servicelb \
  --disable=traefik \
  --disable=local-storage \
  --node-taint='node-role.kubernetes.io/control-plane=true:NoSchedule' \
  --secrets-encryption
```

El manifiesto oficial de Calico se fija en `v3.32.0`. Antes de aplicarlo se configura el CIDR `10.42.0.0/16`, `allow_ip_forwarding`, backend VXLAN y sondas exclusivas de Felix.

Los workers se unen con el token de `/var/lib/rancher/k3s/server/node-token`. En Kubernetes 1.36 las etiquetas reservadas de rol se aplican después desde la API:

```bash
kubectl label node worker1 node-role.kubernetes.io/worker=true
kubectl label node worker2 node-role.kubernetes.io/worker=true
```

MetalLB se instala desde su manifiesto nativo oficial y la configuración L2 versionada se encuentra en [infra/metallb/l2-config.yaml](infra/metallb/l2-config.yaml).

## Gateway API con Istio

La instalación respeta el orden exigido por la prueba:

1. CRDs del Gateway API Standard Channel `v1.4.1`.
2. cert-manager `v1.20.2`.
3. Istio `1.30.1` con perfil `minimal`.
4. CA local, certificado TLS, Gateway y HTTPRoute de redirección.

Se usa la `GatewayClass istio`, registrada por Istio con el controlador `istio.io/gateway-controller`. El recurso [infra/platform/gateway.yaml](infra/platform/gateway.yaml) define:

- listener HTTP en el puerto 80;
- listener HTTPS en el puerto 443;
- terminación TLS con el Secret `wildcard-local-tls`;
- redirección HTTP a HTTPS mediante `RequestRedirect` con código 301;
- IP solicitada `192.168.1.240` a MetalLB.

La cadena de confianza local está declarada en [infra/platform/certificates.yaml](infra/platform/certificates.yaml): un `ClusterIssuer` autofirmado crea la CA `LinkTIC Local Root CA`; después el issuer `local-ca` firma el certificado `*.local` usado por el Gateway.

## Evidencia para sustentación

Ejecutar desde el master:

```bash
# 1. etcd y API saludables
sudo k3s kubectl get --raw='/readyz?verbose' | grep -E 'etcd|readyz check passed'

# 2. Los tres nodos Ready
sudo k3s kubectl get nodes -o wide

# 3. CNI Calico saludable en los tres nodos
sudo k3s kubectl get pods -n kube-system -l k8s-app=calico-node -o wide
sudo k3s kubectl get deployment calico-kube-controllers -n kube-system
sudo k3s kubectl get ippool default-ipv4-ippool \
  -o custom-columns=NAME:.metadata.name,CIDR:.spec.cidr,IPIP:.spec.ipipMode,VXLAN:.spec.vxlanMode

# 4. MetalLB L2 saludable
sudo k3s kubectl get pods -n metallb-system -o wide
sudo k3s kubectl get ipaddresspool,l2advertisement -n metallb-system

# 5. GatewayClass y Gateway aceptados/programados
sudo k3s kubectl get gatewayclass istio
sudo k3s kubectl get gateway platform-gateway -n istio-system
sudo k3s kubectl get service platform-gateway-istio -n istio-system

# 6. Certificado y HTTPRoute
sudo k3s kubectl get certificate wildcard-local -n istio-system
sudo k3s kubectl get httproute redirect-http-to-https -n istio-system

# 7. Prueba real de redirect y HTTPS
curl -I -H 'Host: todo.local' http://192.168.1.240/
curl -kI --resolve todo.local:443:192.168.1.240 https://todo.local/
```

Resultados esperados:

- `etcd ok`, `etcd-readiness ok` y `readyz check passed`.
- `master`, `worker1` y `worker2` en `Ready`.
- Tres pods `calico-node` en `1/1 Running`, sin reinicios.
- Un controlador y tres speakers MetalLB en `Running`.
- `GatewayClass istio` con `Accepted=True`.
- `platform-gateway` con `Accepted=True` y `Programmed=True`.
- Service `platform-gateway-istio` con `EXTERNAL-IP 192.168.1.240`.
- Certificado `wildcard-local` en `Ready=True`, emitido por `LinkTIC Local Root CA`.
- HTTP responde `301` con `Location: https://todo.local/`.
- HTTPS termina en `istio-envoy`; hasta desplegar la aplicación responde `404`, lo cual confirma que listener, TLS y LoadBalancer funcionan.

## GitOps con ArgoCD

ArgoCD `v3.4.4` está instalado en el namespace `argocd`. No se usa `port-forward`: la UI se publica mediante el `HTTPRoute` versionado en [infra/gitops-platform/argocd-route.yaml](infra/gitops-platform/argocd-route.yaml), con hostname `argocd.local` y TLS terminado por el Gateway de Istio.

Agregar en el archivo `hosts` del equipo desde el que se realizará la demostración:

```text
192.168.1.240 argocd.local
```

Después se accede directamente a `https://argocd.local`. El certificado está firmado por la CA local de cert-manager; para evitar la advertencia del navegador se debe importar `LinkTIC Local Root CA` en el almacén de confianza del equipo.

La contraseña inicial del usuario `admin` se obtiene sin exponerla en el repositorio:

```bash
sudo k3s kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

### Fuente de verdad y App of Apps

El repositorio público se puede consumir directamente. Para registrarlo explícitamente desde la CLI:

```bash
argocd repo add https://github.com/jusefe11/linktic.git
```

Si el repositorio cambia a privado, el mismo comando debe incluir un token mediante `--username` y `--password`, almacenado fuera de Git.

La Application raíz es [root/root-app.yaml](root/root-app.yaml). El bootstrap inicial se limita a instalar ArgoCD y aplicar este recurso:

```bash
sudo k3s kubectl apply -f root/root-app.yaml
```

La estructura declarativa es:

- `root/`: Application raíz y Applications agrupadoras.
- `apps/`: Applications de `todo-api` y `todo-frontend`.
- `infra/`: Gateway API, cert-manager, MetalLB, Longhorn y CloudNativePG.
- `observability/`: Istio, kube-prometheus-stack, Loki y Gateways de plataforma.

Las fases futuras están versionadas pero se habilitan al abordar su punto de la prueba, evitando instalar bases de datos, almacenamiento y observabilidad antes de validarlos. Ningún Gateway ni HTTPRoute se crea manualmente: los recursos activos salen de `infra/gitops-platform/` y son propiedad de `platform-gateway-config`.

### Orden mediante Sync Waves

| Wave | Application | Propósito |
|---:|---|---|
| `-5` | `gateway-api-crds` | CRDs Standard Channel v1.4.1 |
| `-4` | `cert-manager` | CRDs, controladores y CA local |
| `-3` | `metallb` | LoadBalancer Layer 2 |
| `-2` | `istio-base` | CRDs de Istio |
| `-1` | `istiod` | Controlador Gateway API |
| `0` | `platform-gateway-config` | namespaces, certificados, Gateway y HTTPRoutes |

### Evidencia de sustentación del punto 3

```bash
# Todas las Applications deben estar Synced + Healthy
sudo k3s kubectl -n argocd get applications.argoproj.io \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status \
  --sort-by=.metadata.name

# HTTPRoute aceptada y Gateway programado
sudo k3s kubectl -n argocd get httproute argocd
sudo k3s kubectl -n istio-system get gateway platform-gateway

# Acceso real, sin port-forward
curl -kI --resolve argocd.local:443:192.168.1.240 https://argocd.local/
curl -I --resolve argocd.local:80:192.168.1.240 http://argocd.local/

# Evidencia del ciclo GitOps: el valor vivo debe ser v2
sudo k3s kubectl -n argocd get configmap gitops-cycle-demo \
  -o jsonpath='{.data.version}'; echo
```

El ciclo completo se demostró con el commit `06f468d`: se cambió `infra/gitops-platform/gitops-cycle.yaml` de `v1` a `v2`, se hizo push a `main`, ArgoCD detectó el commit y `platform-gateway-config` volvió automáticamente a `Synced + Healthy`. El ConfigMap vivo mostró `v2` sin ejecutar `kubectl apply` sobre ese manifiesto.

Resultados verificados:

- nueve Applications en `Synced + Healthy`;
- `GatewayClass istio` con `Accepted=True`;
- `platform-gateway` con `Programmed=True` e IP `192.168.1.240`;
- `https://argocd.local/` devuelve HTTP `200`;
- `http://argocd.local/` devuelve HTTP `301` hacia HTTPS;
- los tres nodos permanecen `Ready`.
