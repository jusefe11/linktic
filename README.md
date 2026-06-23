# Prueba técnica Cloud Native

## Estado actual: fase 1 completada

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

No se han instalado todavía Istio, Gateway API, ArgoCD, Longhorn ni observabilidad.

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

# 4. MetalLB L2 saludable y una IP externa asignada
sudo k3s kubectl get pods -n metallb-system -o wide
sudo k3s kubectl get ipaddresspool,l2advertisement -n metallb-system
sudo k3s kubectl get service metallb-smoke -n kube-system -o wide

# 5. Prueba real del LoadBalancer
curl -sk -o /dev/null -w 'HTTP=%{http_code} CONNECT=%{time_connect}s\n' \
  https://192.168.1.240/
```

Resultados esperados:

- `etcd ok`, `etcd-readiness ok` y `readyz check passed`.
- `master`, `worker1` y `worker2` en `Ready`.
- Tres pods `calico-node` en `1/1 Running`, sin reinicios.
- Un controlador y tres speakers MetalLB en `Running`.
- El servicio `metallb-smoke` con `EXTERNAL-IP 192.168.1.240`.
- Respuesta HTTP `403` desde metrics-server. El código es esperado por falta de credenciales y demuestra que ARP, MetalLB, kube-proxy, Calico y el endpoint funcionan extremo a extremo.
