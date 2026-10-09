# Homelab NixOS

## Nodes

- homelab-0 (192.168.178.151) control plane
- homelab-1 (192.168.178.152) worker
- homelab-2 (192.168.178.153) worker

homelab-0 holds no Longhorn replicas: its single SATA SSD also carries etcd,
and replica I/O there stalled the API server. Scheduling is disabled on its
Longhorn node object (`allowScheduling: false`, set with kubectl, not in this
repo), so every volume keeps its two replicas on homelab-1 and homelab-2.

## Tech stack

<table>
    <tr>
        <th>Logo</th>
        <th>Name</th>
        <th>Description</th>
    </tr>
    <tr>
        <td><img width="32" src="https://nixos.wiki/images/thumb/2/20/Home-nixos-logo.png/414px-Home-nixos-logo.png"></td>
        <td><a href="https://nixos.org">NixOS</a></td>
        <td>Base OS for Kubernetes nodes</td>
    </tr>
    <tr>
        <td><img width="32" src="https://github.com/jetstack/cert-manager/raw/master/logo/logo.png"></td>
        <td><a href="https://cert-manager.io">cert-manager</a></td>
        <td>Cloud native certificate management</td>
    </tr>
    <tr>
        <td><img width="32" src="https://avatars.githubusercontent.com/u/314135?s=200&v=4"></td>
        <td><a href="https://www.cloudflare.com">Cloudflare</a></td>
        <td>Reverse Proxy</td>
    </tr>
    <tr>
        <td><img width="32" src="https://github.com/kubernetes-sigs/external-dns/raw/master/docs/img/external-dns.png"></td>
        <td><a href="https://github.com/kubernetes-sigs/external-dns">ExternalDNS</a></td>
        <td>Synchronizes exposed Kubernetes Services and Ingresses with DNS providers</td>
    </tr>
    <tr>
        <td><img width="32" src="https://grafana.com/static/img/menu/grafana2.svg"></td>
        <td><a href="https://grafana.com">Grafana</a></td>
        <td>Observability platform</td>
    </tr>
    <tr>
        <td><img width="32" src="https://avatars.githubusercontent.com/u/3380462"></td>
        <td><a href="https://prometheus.io">Prometheus</a></td>
        <td>Systems monitoring and alerting toolkit</td>
    </tr>
    <tr>
        <td><img width="32" src="https://helm.sh/img/helm.svg"></td>
        <td><a href="https://helm.sh">Helm</a></td>
        <td>The package manager for Kubernetes</td>
    </tr>
    <tr>
        <td><img width="32" src="https://avatars.githubusercontent.com/u/49319725"></td>
        <td><a href="https://k3s.io">K3s</a></td>
        <td>Lightweight distribution of Kubernetes</td>
    </tr>
    <tr>
        <td><img width="32" src="https://avatars.githubusercontent.com/u/13629408"></td>
        <td><a href="https://kubernetes.io">Kubernetes</a></td>
        <td>Container-orchestration system, the backbone of this project</td>
    </tr>
    <tr>
        <td><img width="32" src="https://avatars.githubusercontent.com/u/1412239?s=200&v=4"></td>
        <td><a href="https://www.nginx.com">NGINX</a></td>
        <td>Kubernetes Ingress Controller</td>
    </tr>
    <tr>
        <td><img width="32" src="https://avatars.githubusercontent.com/u/48932923?s=200&v=4"></td>
        <td><a href="https://tailscale.com">Tailscale</a></td>
        <td>VPN without port forwarding</td>
    </tr>
    <tr>
    <td><img width="32" src="https://avatars.githubusercontent.com/u/1087378?s=48&v=4"></td>
        <td><a href="http://www.fail2ban.org/">fail2ban</a></td>
        <td>Ban hosts that cause multiple authentication errors</td>
    </tr>
     <td><img width="32" src="https://avatars0.githubusercontent.com/u/44036562?s=100&v=4"></td>
        <td><a href="https://github.com/actions/actions-runner-controller">Actions Runner Controller (ARC)</a></td>
        <td>Kubernetes operator that orchestrates and scales self-hosted runners for GitHub Actions.</td>
    </tr>
     <td><img width="32" src="https://avatars.githubusercontent.com/u/30269780?s=100&v=4"></td>
        <td><a href="https://github.com/argoproj/argo-cd">Argo CD</a></td>
        <td>Declarative GitOps CD for Kubernetes</td>
    </tr>
</table>

## PTCGL mirror (namespace `ptcgl`)

Marvin's ptcgl.dev sync mirrors Pokemon TCG Live card data and images nightly (02:40) into the `ptcgl`
database and the RustFS bucket `ptcgl`; pokemon-api serves the images under `/assets/`.

- New PTCS account or a dead token: put a fresh `ory_rt_*` refresh token in `pokemon_api.ptcs_refresh_token`
  (`sops apps/secrets.yaml`), push, wait for Argo, then run a sync:
  `kubectl -n ptcgl create job --from=cronjob/ptcgl-sync ptcgl-manual-$(date +%s)`. The `seed-auth` init
  container writes the new token once; the sync rotates it from then on. Do not log in to TCGL with the same
  token elsewhere: it is single use.
- Status: `SELECT * FROM ingest_run ORDER BY id DESC LIMIT 5;` in database `ptcgl`, and the job logs.
