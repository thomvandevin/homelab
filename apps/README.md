# Homelab Applications

This directory contains Kubernetes applications for the homelab infrastructure, managed through ArgoCD with GitOps principles.

## Architecture Overview

- **Application Management**: ArgoCD applications defined in `templates/` directory
- **Secret Management**: Sealed Secrets for secure secret storage in Git
- **Helm Charts**: Used for complex application deployments
- **Namespaces**: Applications organized by function and security boundaries

## Initial Setup Guide

Follow these steps if you're setting up the homelab from scratch:

### 1. Prerequisites

Ensure you have the following tools installed:

```bash
# Kubernetes CLI
brew install kubectl

# Sealed Secrets CLI
brew install kubeseal

# YAML processor (for automation scripts)
brew install yq

# Helm (for some applications)
brew install helm
```

### 2. Kubernetes Cluster Setup

Make sure your Kubernetes cluster is running and `kubectl` is configured to access it:

```bash
kubectl cluster-info
kubectl get nodes
```

### 3. Install ArgoCD

Deploy ArgoCD to manage applications:

```bash
# Create namespace
kubectl create namespace argocd

# Install ArgoCD
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for ArgoCD to be ready
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd
```

Access ArgoCD UI:
```bash
# Port forward to access UI
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Get initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

### 4. Install Sealed Secrets Controller

Deploy the sealed secrets controller to handle encrypted secrets:

```bash
# Install the controller
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.0/controller.yaml

# Verify installation
kubectl get pods -n kube-system | grep sealed-secrets
```

### 5. Prepare Secrets

If you have a `secrets.yaml.dec` file with decrypted secrets:

#### Option A: Automated Script (Recommended)

Use the automation script to generate all sealed secrets:

```bash
# Make sure your secrets.yaml.dec exists
ls apps/secrets.yaml.dec

# Run the automation script
./scripts/create-sealed-secrets.sh
```

#### Option B: Manual Secret Creation

For each secret you need to create:

```bash
# Example: Create a sealed secret manually
kubectl create secret generic my-secret \
    --namespace=default \
    --from-literal=key="value" \
    --dry-run=client -o yaml | \
kubeseal --format=yaml --namespace=default > apps/templates/sealed-my-secret.yaml
```

### 6. Deploy Core Infrastructure

Apply the core applications in order:

```bash
# Apply all applications
kubectl apply -f apps/Chart.yaml
kubectl apply -f apps/templates/

# Or apply specific critical apps first
kubectl apply -f apps/templates/helm-sealed-secrets.yaml
kubectl apply -f apps/templates/helm-cert-manager.yaml
kubectl apply -f apps/templates/helm-nginx.yaml
```

### 7. Verify Deployments

Check that applications are deploying correctly:

```bash
# Check ArgoCD applications
kubectl get applications -n argocd

# Check sealed secrets are being decrypted
kubectl get sealedsecrets --all-namespaces

# Check regular secrets were created
kubectl get secrets --all-namespaces
```

## Managing Secrets

### Current Sealed Secrets

The following sealed secrets are configured:

| Secret Name | Namespace | Purpose | Contains |
|-------------|-----------|---------|----------|
| `cloudflare-secret` | `default` | Cloudflare tunnel credentials | `secret` |
| `tailscale-secret` | `tailscale` | Tailscale OAuth credentials | `clientId`, `clientSecret` |
| `db-secret` | `db-system` | Database credentials | `password` |
| `github-secret` | `actions-runner-controller` | GitHub token for ARC | `token` |
| `scraper-secret` | `default` | Pushover notifications | `user`, `token` |
| `gcr-scraper-secret` | `scraper` | GCR pull secret for scraper | `.dockerconfigjson` |
| `gcr-swiss-rounds-secret` | `swiss-rounds` | GCR pull secret for swiss-rounds | `.dockerconfigjson` |
| `gcr-limitless-tournament-decks-secret` | `limitless-tournament-decks` | GCR pull secret for limitless-tournament-decks | `.dockerconfigjson` |

### Adding New Secrets

To add a new sealed secret:

1. Create the regular Kubernetes secret (dry-run):
```bash
kubectl create secret generic new-secret \
    --namespace=target-namespace \
    --from-literal=key="value" \
    --dry-run=client -o yaml > temp-secret.yaml
```

2. Seal the secret:
```bash
kubeseal -f temp-secret.yaml -w apps/templates/sealed-new-secret.yaml
```

3. Clean up and commit:
```bash
rm temp-secret.yaml
git add apps/templates/sealed-new-secret.yaml
git commit -m "Add new sealed secret"
```

### Updating Existing Secrets

To update an existing sealed secret:

1. Delete the existing sealed secret:
```bash
kubectl delete sealedsecret secret-name -n namespace
```

2. Create new sealed secret with updated values:
```bash
kubectl create secret generic secret-name \
    --namespace=namespace \
    --from-literal=key="new-value" \
    --dry-run=client -o yaml | \
kubeseal --format=yaml --namespace=namespace > apps/templates/sealed-secret-name.yaml
```

3. Apply the updated secret:
```bash
kubectl apply -f apps/templates/sealed-secret-name.yaml
```

### Creating GCR/Artifact Registry Secrets

For Google Container Registry (GCR) or Artifact Registry authentication, use the `encode-gcr-secret.py` script to convert service account keys to the proper dockerconfigjson format:

```bash
# Convert a Google service account JSON key to base64-encoded dockerconfigjson
./scripts/encode-gcr-secret.py path/to/service-account.json

# Verify the conversion
./scripts/encode-gcr-secret.py path/to/service-account.json --verify

# Use with a different registry (e.g., Artifact Registry)
./scripts/encode-gcr-secret.py path/to/service-account.json --registry us-docker.pkg.dev
```

The script outputs a base64-encoded string that can be added directly to `secrets.yaml.dec`:

```yaml
gcr:
  my_service: "eyJhdXRocyI6eyJnY3IuaW8iOnsidXNlcm5hbWUiOiJfanNvbl9rZXki..."
```

Then regenerate sealed secrets using the automation script:
```bash
./scripts/create-sealed-secrets.sh
```

## Application Structure

### Core Applications

- **cert-manager**: TLS certificate management
- **nginx**: Ingress controller
- **sealed-secrets**: Secret encryption/decryption
- **postgresql**: Database server
- **tailscale**: VPN connectivity

### Custom Applications

- **scraper**: Web scraping service
- **swiss-rounds**: Tournament management
- **cloudflare-tunnel**: Secure external access

## Troubleshooting

### Sealed Secrets Issues

If sealed secrets show `no key could decrypt secret`:

1. Check if the sealed secrets controller is running:
```bash
kubectl get pods -n kube-system | grep sealed-secrets
```

2. Fetch the current public key:
```bash
kubeseal --fetch-cert > public.pem
```

3. Re-create sealed secrets with the current key:
```bash
# Use the automation script
./scripts/create-sealed-secrets.sh
```

### ArgoCD Sync Issues

If applications aren't syncing:

1. Check ArgoCD application status:
```bash
kubectl get applications -n argocd
```

2. Force sync if needed:
```bash
kubectl patch application app-name -n argocd --type merge --patch '{"operation":{"sync":{"syncStrategy":{"hook":{"force":true}}}}}'
```

### Pod Issues

For application pod problems:

```bash
# Check pod status
kubectl get pods -n namespace

# Check pod logs
kubectl logs pod-name -n namespace

# Describe pod for events
kubectl describe pod pod-name -n namespace
```

## Security Notes

- **Never commit unencrypted secrets** to Git
- **Regularly rotate secrets** especially for external services
- **Use least privilege** for service accounts and RBAC
- **Monitor secret access** through audit logs
- **Backup sealed secrets private keys** for disaster recovery

## Automation Scripts

- `scripts/create-sealed-secrets.sh`: Automated sealed secret generation from `secrets.yaml.dec`
- `scripts/encode-gcr-secret.py`: Convert Google service account JSON keys to base64-encoded dockerconfigjson format for GCR/Artifact Registry authentication

## Directory Structure

```
apps/
├── Chart.yaml              # Helm chart metadata
├── templates/               # Kubernetes manifests and ArgoCD applications
│   ├── helm-*.yaml         # Helm-based applications
│   ├── sealed-*.yaml       # Sealed secrets
│   └── *.yaml              # Direct Kubernetes resources
├── scripts/                # Automation scripts
└── README.md               # This file
```