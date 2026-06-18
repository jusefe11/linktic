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
