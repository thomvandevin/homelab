# Homelab apps

Contains a collection of all apps in my homelab.

## Secret notes

1. Install [kubeseal](https://sealed-secrets.netlify.app/docs/overview/#installation) CLI tool

2. Deploy the sealed-secrets controller to your cluster

```sh
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.18.0/controller.yaml
```

3. Create a regular Kubernetes secret (temporarily)

```sh
kubectl create secret generic my-secret --from-literal=password=mysecretpassword --dry-run=client -o yaml > secret.yaml
```

4. Seal the secret using kubeseal

```sh
kubeseal -f secret.yaml -w sealed-secret.yaml
```

5. Delete the temporary secret file and apply the sealed secret

```sh
rm secret.yaml
kubectl apply -f sealed-secret.yaml
```

6. The sealed-secrets controller will automatically decrypt the sealed secret and create the actual Kubernetes secret in the cluster.