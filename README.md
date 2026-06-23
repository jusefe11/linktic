# Prueba técnica Cloud Native

## Estado actual: fases 1 y 2 completadas

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

No se han instalado todavía ArgoCD, Longhorn, CloudNativePG ni observabilidad.

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
