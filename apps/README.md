# Homelab Applications

This directory contains Kubernetes applications for the homelab infrastructure, managed through ArgoCD with GitOps principles.

## Architecture Overview

- **Application Management**: ArgoCD applications defined in `templates/` directory
- **Secret Management**: SOPS + AGE encryption with helm-secrets plugin
- **Helm Charts**: Used for complex application deployments
- **Namespaces**: Applications organized by function and security boundaries

## Secret Management

Secrets are managed using [SOPS](https://github.com/getsops/sops) with [AGE](https://github.com/FiloSottile/age) encryption and the [helm-secrets](https://github.com/jkroepke/helm-secrets) plugin for ArgoCD integration.

### How it works

1. **Local editing**: You maintain a decrypted `secrets.yaml.dec` file locally (gitignored)
2. **Encryption**: When you make changes, encrypt it to `secrets.yaml` using SOPS
3. **Git storage**: The encrypted `secrets.yaml` is committed to Git (safe for public repos)
4. **ArgoCD decryption**: ArgoCD uses helm-secrets to decrypt at deploy time
5. **Helm templating**: Secrets are injected as Helm values into Kubernetes Secret templates

### Prerequisites

Install the required tools:

```bash
# Install SOPS and AGE
brew install sops age

# Install helm-secrets plugin (for local testing)
helm plugin install https://github.com/jkroepke/helm-secrets --version v4.6.10
```

### Initial Setup

1. **Generate an AGE key pair** (if not already done):
   ```bash
   age-keygen -o key.txt
   ```
   The public key will be displayed. Keep `key.txt` safe - it's gitignored.

2. **Update `.sops.yaml`** with your public key:
   ```yaml
   creation_rules:
     - age: >-
         age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
   ```

3. **Create the AGE key secret in the cluster** (for ArgoCD):
   ```bash
   kubectl -n argocd create secret generic helm-secrets-age-key --from-file=key.txt=key.txt
   ```

### Managing Secrets

#### Editing Secrets

1. Edit the decrypted secrets file:
   ```bash
   # Edit apps/secrets.yaml.dec with your favorite editor
   vim apps/secrets.yaml.dec
   ```

2. Encrypt and save:
   ```bash
   cd apps
   SOPS_AGE_KEY_FILE=../key.txt sops --encrypt --input-type yaml --output-type yaml secrets.yaml.dec > secrets.yaml
   ```

3. Commit the encrypted file:
   ```bash
   git add secrets.yaml
   git commit -m "Update secrets"
   git push
   ```

#### Decrypting Secrets (for viewing/editing)

```bash
cd apps
SOPS_AGE_KEY_FILE=../key.txt sops --decrypt secrets.yaml > secrets.yaml.dec
```

#### Adding New Secrets

1. Add the new secret value to `secrets.yaml.dec`:
   ```yaml
   myapp:
     apiKey: "my-secret-api-key"
   ```

2. Create a new secret template in `templates/`:
   ```yaml
   # templates/myapp-secret.yaml
   apiVersion: v1
   kind: Secret
   type: Opaque
   metadata:
     name: myapp-secret
     namespace: myapp
   data:
     apiKey: {{ .Values.myapp.apiKey | b64enc | quote }}
   ```

3. Encrypt and commit:
   ```bash
   cd apps
   SOPS_AGE_KEY_FILE=../key.txt sops --encrypt --input-type yaml --output-type yaml secrets.yaml.dec > secrets.yaml
   git add secrets.yaml templates/myapp-secret.yaml
   git commit -m "Add myapp secret"
   ```

### Current Secrets

| Secret Name | Namespace | Purpose |
|-------------|-----------|---------|
| `tailscale-secret` | `tailscale` | Tailscale OAuth credentials |
| `db-secret` | `db-system` | Database password |
| `db-secret` | `scraper` | Database password (scraper namespace) |
| `db-secret` | `limitless-tournament-decks` | Database password |
| `github-secret` | `actions-runner-controller` | GitHub token for ARC |
| `tunnel-credentials` | `cloudflare-tunnel` | Cloudflare tunnel credentials |
| `scraper-secret` | `scraper` | Pushover notifications |
| `gcr-scraper-secret` | `scraper` | GCR pull secret |
| `gcr-swiss-rounds-secret` | `swiss-rounds` | GCR pull secret |
| `gcr-limitless-tournament-decks-secret` | `limitless-tournament-decks` | GCR pull secret |
| `gcr-end-of-year-secret` | `end-of-year` | GCR pull secret |

### Secrets File Structure

```yaml
# secrets.yaml.dec (decrypted, gitignored)
tailscale:
  clientId: "your-client-id"
  clientSecret: "your-client-secret"
db:
  password: "your-db-password"
gh:
  token: "github_pat_xxx"
cloudflare:
  secret: '{"AccountTag":"...","TunnelSecret":"...","TunnelID":"..."}'
pushover:
  scraper:
    user: "user-key"
    token: "app-token"
gcr:
  scraper: "base64-encoded-dockerconfigjson"
  swiss_rounds: "base64-encoded-dockerconfigjson"
  limitless_tournament_decks: "base64-encoded-dockerconfigjson"
  end_of_year: "base64-encoded-dockerconfigjson"
```

## Initial Cluster Setup

### 1. Prerequisites

```bash
brew install kubectl helm age sops
helm plugin install https://github.com/jkroepke/helm-secrets --version v4.6.10
```

### 2. Install ArgoCD

```bash
# Create namespace
kubectl create namespace argocd

# Install ArgoCD
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for ArgoCD to be ready
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd
```

### 3. Create AGE Key Secret

```bash
# Create the secret for helm-secrets decryption
kubectl -n argocd create secret generic helm-secrets-age-key --from-file=key.txt=key.txt
```

### 4. Deploy Applications

```bash
# Apply the root application
kubectl apply -f app.yaml
```

ArgoCD will automatically sync and deploy all applications.

## Application Structure

### Core Applications

- **argocd**: GitOps continuous delivery
- **cert-manager**: TLS certificate management
- **nginx**: Ingress controller
- **postgresql**: Database server
- **tailscale**: VPN connectivity
- **prometheus**: Monitoring

### Custom Applications

- **scraper**: Web scraping service
- **swiss-rounds**: Tournament management
- **limitless-tournament-decks**: Deck management
- **cloudflare-tunnel**: Secure external access

## Troubleshooting

### ArgoCD Can't Decrypt Secrets

1. Verify the AGE key secret exists:
   ```bash
   kubectl get secret helm-secrets-age-key -n argocd
   ```

2. Check ArgoCD repo-server logs:
   ```bash
   kubectl logs -n argocd -l app.kubernetes.io/component=repo-server
   ```

3. Recreate the secret if needed:
   ```bash
   kubectl -n argocd delete secret helm-secrets-age-key
   kubectl -n argocd create secret generic helm-secrets-age-key --from-file=key.txt=key.txt
   ```

### Secrets Not Updating

1. Force ArgoCD to refresh:
   ```bash
   kubectl patch application apps -n argocd --type merge --patch '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
   ```

2. Check if the encrypted file was updated:
   ```bash
   git log -1 apps/secrets.yaml
   ```

### Local Testing

Test Helm template rendering locally:

```bash
cd apps
helm secrets template . -f secrets://secrets.yaml
```

## Directory Structure

```
apps/
├── .sops.yaml              # SOPS configuration with AGE public key
├── Chart.yaml              # Helm chart metadata
├── secrets.yaml            # Encrypted secrets (committed to Git)
├── secrets.yaml.dec        # Decrypted secrets (gitignored)
├── templates/              # Kubernetes manifests and ArgoCD applications
│   ├── helm-*.yaml         # Helm-based applications
│   ├── *-secret.yaml       # Secret templates using Helm values
│   └── *.yaml              # Direct Kubernetes resources
└── README.md               # This file
```

## Security Notes

- **Never commit `secrets.yaml.dec`** - it's gitignored for a reason
- **Backup your `key.txt`** - losing it means you can't decrypt secrets
- **Rotate secrets regularly** especially for external services
- **The encrypted `secrets.yaml` is safe** for public repositories
