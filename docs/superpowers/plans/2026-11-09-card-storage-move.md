# Card Storage Move Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Card images move to a RustFS in the `pokemon-api` namespace and backups to one in `db-system`; the `ptcgl` namespace is removed once the user approves.

**Architecture:** Two new RustFS stores are added next to the old one, filled by one-off rclone Jobs and checked by object count and size, then one commit points pokemon-api, the `/images/` proxy (moved to `pokemon-api/card-images`) and db-backup at them. The old store stays as the fallback until a night has passed and the user approves its removal.

**Tech Stack:** Helm chart `apps/` synced by Argo CD (app `apps`), RustFS 1.0.4, Longhorn, nginx 1.31, rclone, aws-cli, kubectl, Cloudflare tunnel.

**Spec:** `docs/superpowers/specs/2026-11-09-card-storage-move-design.md`

## Global Constraints

- Homelab changes are pushed straight to `main`; Argo CD applies them.
- Nothing in the `ptcgl` namespace is deleted, and the `ptcgl` database and `ptcgl_reader` role are not dropped, before the user approves the removal (Task 5).
- Public image URLs stay `https://pokemon-api.thomvandev.in/images/<path>`.
- No new secrets: new Secret objects reuse `.Values.ptcgl.s3_access_key` and `.Values.ptcgl.s3_secret_key`. Ruling: the spec's line "the `ptcgl.*` SOPS keys can be removed by the user" no longer holds, because the new secrets still read those values; renaming the SOPS keys is a later, optional user task.
- The card copy and the switch commit happen outside 01:40–07:00 UTC (rainier-sync 02:40 Amsterdam, baked-assets 03:10, db-backup 03:00).
- Render check before every push: `helm template apps apps -f apps/values.yaml -f apps/secrets.yaml > /dev/null` exits 0 (the encrypted secrets file renders as placeholder strings).
- No emdashes, no AI attribution in commits.

## Review Focus

- A bucket without the public-read policy on `decoded/*`: the `/images/` proxy then gets 403 and serves 404 for every image. Task 2 applies the policy in the copy Job and Task 3's check fetches real images.
- Objects written to the old bucket after the first copy (a re-decode, a new set): the final `rclone sync` right before the switch (Task 3 step 1) and the count check catch them.
- The backup Job at 03:00 running between Task 3's push and Argo's sync: the switch is pushed outside 01:40–07:00 UTC.
- Longhorn not scheduling the new 35 GB volume (pod stuck Pending): Task 1 step 4 checks the PVC is Bound and the pod Ready before any copy.
- A partial rclone copy that exits 0: Task 2 compares `rclone size` on both sides, not only the exit code.

---

### Task 1: New stores

**Files:**
- Create: `apps/templates/pokemon-api-storage.yaml`
- Create: `apps/templates/db-backup-storage.yaml`
- Modify: `apps/templates/app-pokemon-api.yaml:53-55` (secret keys)

**Interfaces:**
- Produces: Services `rustfs.pokemon-api.svc.cluster.local:9000` (bucket `cards`) and `rustfs-backups.db-system.svc.cluster.local:9000` (bucket `backups`); `api-secret` keys `s3-access-key`, `s3-secret-key` (the `ptcgl-s3-*` keys stay until Task 3).

- [ ] **Step 1: Write `apps/templates/pokemon-api-storage.yaml`**

```yaml
# Card images, set art, icons and the raw PTCGL bundles they are decoded from (bucket `cards`). The /images/ proxy
# (card-images) serves `decoded/` publicly; everything else is only reachable in the cluster.
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: rustfs-data
  namespace: pokemon-api
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: longhorn
  resources:
    requests:
      storage: 35Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rustfs
  namespace: pokemon-api
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: rustfs
  template:
    metadata:
      labels:
        app: rustfs
    spec:
      {{- include "placement.preferWorkers" . | nindent 6 }}
      securityContext:
        fsGroup: 10001
      containers:
        - name: rustfs
          image: rustfs/rustfs:1.0.4@sha256:ed9210d6411d77ffceb70d94b964a3cb7d225983368bc25bebe01e995293dcc2
          ports:
            - containerPort: 9000
            - containerPort: 9001
          env:
            - name: RUSTFS_VOLUMES
              value: /data
            - name: RUSTFS_CONSOLE_ENABLE
              value: "true"
            - name: RUSTFS_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: api-secret
                  key: s3-access-key
            - name: RUSTFS_SECRET_KEY
              valueFrom:
                secretKeyRef:
                  name: api-secret
                  key: s3-secret-key
          volumeMounts:
            - name: data
              mountPath: /data
          readinessProbe:
            tcpSocket:
              port: 9000
            periodSeconds: 10
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              memory: 2Gi
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: rustfs-data
---
apiVersion: v1
kind: Service
metadata:
  name: rustfs
  namespace: pokemon-api
spec:
  selector:
    app: rustfs
  ports:
    - name: api
      port: 9000
      targetPort: 9000
    - name: console
      port: 9001
      targetPort: 9001
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: pokemon-api-storage
  namespace: pokemon-api
spec:
  ingressClassName: tailscale
  rules:
    - http:
        paths:
          - backend:
              service:
                name: rustfs
                port:
                  number: 9001
            path: "/"
            pathType: Prefix
  tls:
    - hosts:
        - pokemon-api-storage
```

- [ ] **Step 2: Write `apps/templates/db-backup-storage.yaml`**

```yaml
# The nightly database dumps (bucket `backups`), kept next to Postgres and the db-backup job. Restores use the aws cli;
# see db-backup.yaml.
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: rustfs-backups-data
  namespace: db-system
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: longhorn
  resources:
    requests:
      storage: 5Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rustfs-backups
  namespace: db-system
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: rustfs-backups
  template:
    metadata:
      labels:
        app: rustfs-backups
    spec:
      {{- include "placement.preferWorkers" . | nindent 6 }}
      securityContext:
        fsGroup: 10001
      containers:
        - name: rustfs
          image: rustfs/rustfs:1.0.4@sha256:ed9210d6411d77ffceb70d94b964a3cb7d225983368bc25bebe01e995293dcc2
          ports:
            - containerPort: 9000
          env:
            - name: RUSTFS_VOLUMES
              value: /data
            - name: RUSTFS_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: db-backup-s3
                  key: access-key
            - name: RUSTFS_SECRET_KEY
              valueFrom:
                secretKeyRef:
                  name: db-backup-s3
                  key: secret-key
          volumeMounts:
            - name: data
              mountPath: /data
          readinessProbe:
            tcpSocket:
              port: 9000
            periodSeconds: 10
          resources:
            requests:
              cpu: 20m
              memory: 64Mi
            limits:
              memory: 512Mi
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: rustfs-backups-data
---
apiVersion: v1
kind: Service
metadata:
  name: rustfs-backups
  namespace: db-system
spec:
  selector:
    app: rustfs-backups
  ports:
    - name: api
      port: 9000
      targetPort: 9000
```

- [ ] **Step 3: Add the new keys to `api-secret`** in `apps/templates/app-pokemon-api.yaml`, under the existing `ptcgl-s3-*` lines:

```yaml
  # pokemon-api's own RustFS (pokemon-api-storage.yaml); the values are the keys the old ptcgl store used.
  s3-access-key: {{ .Values.ptcgl.s3_access_key | b64enc | quote }}
  s3-secret-key: {{ .Values.ptcgl.s3_secret_key | b64enc | quote }}
```

- [ ] **Step 4: Render, push, and check the stores run**

Run: `helm template apps apps -f apps/values.yaml -f apps/secrets.yaml > /dev/null && echo ok`
Expected: `ok`

```bash
git add apps/templates/pokemon-api-storage.yaml apps/templates/db-backup-storage.yaml apps/templates/app-pokemon-api.yaml
git commit -m "feat(storage): RustFS stores for card images in pokemon-api and for backups in db-system"
git push origin HEAD:main
```

Then wait for Argo (`kubectl -n argocd get application apps` shows Synced) and run:
`kubectl -n pokemon-api get pvc rustfs-data; kubectl -n pokemon-api rollout status deploy/rustfs --timeout=300s; kubectl -n db-system get pvc rustfs-backups-data; kubectl -n db-system rollout status deploy/rustfs-backups --timeout=300s`
Expected: both PVCs `Bound`, both deployments "successfully rolled out".

### Task 2: Copy and check

**Files:**
- Create (scratchpad, not committed): `copy-cards.yaml`, `copy-backups.yaml`

**Interfaces:**
- Consumes: Task 1's services and secrets.
- Produces: bucket `cards` with the same objects as `ptcgl`, public-read on `cards/decoded/*`; bucket `backups` in db-system with the same objects as the old `backups`.

- [ ] **Step 1: Write the card copy Job** (`copy-cards.yaml` in the session scratchpad)

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: copy-cards
  namespace: pokemon-api
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 14400
  template:
    spec:
      restartPolicy: Never
      initContainers:
        - name: bucket
          image: amazon/aws-cli:2.39.6@sha256:eccdb3ec77e159d43ca6a750a70738c546883138be7f094498294a1477ec7e42
          command: ["sh", "-c"]
          args:
            - |
              E=http://rustfs.pokemon-api.svc.cluster.local:9000
              aws --endpoint-url $E s3api head-bucket --bucket cards 2>/dev/null || aws --endpoint-url $E s3api create-bucket --bucket cards
              aws --endpoint-url $E s3api put-bucket-policy --bucket cards --policy '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"AWS":["*"]},"Action":["s3:GetObject"],"Resource":["arn:aws:s3:::cards/decoded/*"]}]}'
          env:
            - { name: AWS_ACCESS_KEY_ID, valueFrom: { secretKeyRef: { name: api-secret, key: s3-access-key } } }
            - { name: AWS_SECRET_ACCESS_KEY, valueFrom: { secretKeyRef: { name: api-secret, key: s3-secret-key } } }
            - { name: AWS_DEFAULT_REGION, value: us-east-1 }
      containers:
        - name: copy
          image: rclone/rclone:1.68.2
          command: ["sh", "-c"]
          args:
            - |
              set -e
              rclone sync old:ptcgl new:cards --transfers 16 --checkers 32 --stats 60s --stats-one-line
              echo "old: $(rclone size old:ptcgl --json)"
              echo "new: $(rclone size new:cards --json)"
          env:
            - { name: RCLONE_CONFIG_OLD_TYPE, value: s3 }
            - { name: RCLONE_CONFIG_OLD_PROVIDER, value: Other }
            - { name: RCLONE_CONFIG_OLD_ENDPOINT, value: "http://rustfs.ptcgl.svc.cluster.local:9000" }
            - { name: RCLONE_CONFIG_OLD_ACCESS_KEY_ID, valueFrom: { secretKeyRef: { name: api-secret, key: s3-access-key } } }
            - { name: RCLONE_CONFIG_OLD_SECRET_ACCESS_KEY, valueFrom: { secretKeyRef: { name: api-secret, key: s3-secret-key } } }
            - { name: RCLONE_CONFIG_NEW_TYPE, value: s3 }
            - { name: RCLONE_CONFIG_NEW_PROVIDER, value: Other }
            - { name: RCLONE_CONFIG_NEW_ENDPOINT, value: "http://rustfs.pokemon-api.svc.cluster.local:9000" }
            - { name: RCLONE_CONFIG_NEW_ACCESS_KEY_ID, valueFrom: { secretKeyRef: { name: api-secret, key: s3-access-key } } }
            - { name: RCLONE_CONFIG_NEW_SECRET_ACCESS_KEY, valueFrom: { secretKeyRef: { name: api-secret, key: s3-secret-key } } }
```

- [ ] **Step 2: Run it** (outside 01:40–07:00 UTC)

Run: `kubectl apply -f copy-cards.yaml && kubectl -n pokemon-api wait --for=condition=complete job/copy-cards --timeout=4h; kubectl -n pokemon-api logs job/copy-cards | tail -3`
Expected: the `old:` and `new:` lines show the same `count` and `bytes`.

- [ ] **Step 3: Write and run the backups copy Job** (`copy-backups.yaml`): the same Job in namespace `db-system` named `copy-backups`, secret `db-backup-s3` keys `access-key`/`secret-key` for both remotes, new endpoint `http://rustfs-backups.db-system.svc.cluster.local:9000`, bucket `backups` on both sides, an init step that creates bucket `backups` (no policy), and `activeDeadlineSeconds: 1800`.

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: copy-backups
  namespace: db-system
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 1800
  template:
    spec:
      restartPolicy: Never
      initContainers:
        - name: bucket
          image: amazon/aws-cli:2.39.6@sha256:eccdb3ec77e159d43ca6a750a70738c546883138be7f094498294a1477ec7e42
          command: ["sh", "-c"]
          args:
            - |
              E=http://rustfs-backups.db-system.svc.cluster.local:9000
              aws --endpoint-url $E s3api head-bucket --bucket backups 2>/dev/null || aws --endpoint-url $E s3api create-bucket --bucket backups
          env:
            - { name: AWS_ACCESS_KEY_ID, valueFrom: { secretKeyRef: { name: db-backup-s3, key: access-key } } }
            - { name: AWS_SECRET_ACCESS_KEY, valueFrom: { secretKeyRef: { name: db-backup-s3, key: secret-key } } }
            - { name: AWS_DEFAULT_REGION, value: us-east-1 }
      containers:
        - name: copy
          image: rclone/rclone:1.68.2
          command: ["sh", "-c"]
          args:
            - |
              set -e
              rclone sync old:backups new:backups --stats-one-line
              echo "old: $(rclone size old:backups --json)"
              echo "new: $(rclone size new:backups --json)"
          env:
            - { name: RCLONE_CONFIG_OLD_TYPE, value: s3 }
            - { name: RCLONE_CONFIG_OLD_PROVIDER, value: Other }
            - { name: RCLONE_CONFIG_OLD_ENDPOINT, value: "http://rustfs.ptcgl.svc.cluster.local:9000" }
            - { name: RCLONE_CONFIG_OLD_ACCESS_KEY_ID, valueFrom: { secretKeyRef: { name: db-backup-s3, key: access-key } } }
            - { name: RCLONE_CONFIG_OLD_SECRET_ACCESS_KEY, valueFrom: { secretKeyRef: { name: db-backup-s3, key: secret-key } } }
            - { name: RCLONE_CONFIG_NEW_TYPE, value: s3 }
            - { name: RCLONE_CONFIG_NEW_PROVIDER, value: Other }
            - { name: RCLONE_CONFIG_NEW_ENDPOINT, value: "http://rustfs-backups.db-system.svc.cluster.local:9000" }
            - { name: RCLONE_CONFIG_NEW_ACCESS_KEY_ID, valueFrom: { secretKeyRef: { name: db-backup-s3, key: access-key } } }
            - { name: RCLONE_CONFIG_NEW_SECRET_ACCESS_KEY, valueFrom: { secretKeyRef: { name: db-backup-s3, key: secret-key } } }
```

Run: `kubectl apply -f copy-backups.yaml && kubectl -n db-system wait --for=condition=complete job/copy-backups --timeout=30m; kubectl -n db-system logs job/copy-backups | tail -2`
Expected: same `count` and `bytes` on both lines.

- [ ] **Step 4: Check a public image reads from the new bucket without credentials**

Run (a throwaway curl pod in pokemon-api): `kubectl -n pokemon-api run curl-check --rm -i --restart=Never --image=curlimages/curl:8.11.1 -- curl -s -o /dev/null -w "%{http_code}\n" http://rustfs.pokemon-api.svc.cluster.local:9000/cards/decoded/10101_0000/sv10_en_233/sv10_en_233_etched.png`
Expected: `200`

### Task 3: Switch

**Files:**
- Modify: `apps/templates/app-pokemon-api.yaml` (bucket init container, rainier-sync and baked-assets env, create-db init container, remove `ptcgl-s3-*` secret keys)
- Modify: `apps/templates/pokemon-api-storage.yaml` (add the card-images proxy)
- Modify: `apps/templates/cloudflare-tunnel.yaml:86-88`
- Modify: `apps/templates/db-backup.yaml` (endpoint, header comment, secret comment)
- Modify: `docs/superpowers/specs/2026-11-09-card-storage-move-design.md` (the SOPS line, per the Global Constraints ruling)

**Interfaces:**
- Consumes: Task 2's filled buckets.

- [ ] **Step 1: Final sync** (outside 01:40–07:00 UTC): `kubectl -n pokemon-api delete job copy-cards && kubectl apply -f copy-cards.yaml && kubectl -n pokemon-api wait --for=condition=complete job/copy-cards --timeout=1h && kubectl -n pokemon-api logs job/copy-cards | tail -2`. Expected: equal counts and bytes.

- [ ] **Step 2: Point pokemon-api at the new store.** In `app-pokemon-api.yaml`:
  - In the rainier-sync `bucket` init container replace the three lines with:
    ```
                  E=http://rustfs.pokemon-api.svc.cluster.local:9000
                  aws --endpoint-url $E s3api head-bucket --bucket cards 2>/dev/null || aws --endpoint-url $E s3api create-bucket --bucket cards
                  aws --endpoint-url $E s3api put-bucket-policy --bucket cards --policy '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"AWS":["*"]},"Action":["s3:GetObject"],"Resource":["arn:aws:s3:::cards/decoded/*"]}]}'
    ```
  - Every `value: http://rustfs.ptcgl.svc.cluster.local:9000` becomes `value: http://rustfs.pokemon-api.svc.cluster.local:9000`; every `RAINIER_S3_BUCKET` `value: ptcgl` becomes `value: cards`; every `key: ptcgl-s3-access-key` / `key: ptcgl-s3-secret-key` becomes `key: s3-access-key` / `key: s3-secret-key`.
  - Delete the `ptcgl-s3-*` keys and their comment from `api-secret`.
  - In the create-db init container delete the three comment lines starting "pokemon-api only reads the PTCGL mirror" and the line `$PG -tc "SELECT 1 FROM pg_database WHERE datname = 'ptcgl'" | grep -q 1 || $PG -c "CREATE DATABASE ptcgl"`; keep `export PGPASSWORD=$DB_PASSWORD` and the `PG=` line, which the block after them uses.

  Check: `grep -n "ptcgl" apps/templates/app-pokemon-api.yaml` prints nothing.

- [ ] **Step 3: Move the `/images/` proxy.** Append to `apps/templates/pokemon-api-storage.yaml`:

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: card-images-nginx
  namespace: pokemon-api
data:
  default.conf: |
    map $uri $asset_type {
      ~*\.png$  image/png;
      ~*\.json$ application/json;
      default    application/octet-stream;
    }
    server {
      listen 80;
      server_tokens off;
      location /images/ {
        limit_except GET { deny all; }
        proxy_pass http://rustfs.pokemon-api.svc.cluster.local:9000/cards/;
        proxy_set_header Host rustfs.pokemon-api.svc.cluster.local:9000;
        proxy_hide_header Set-Cookie;
        proxy_hide_header Content-Type;
        proxy_hide_header Server;
        proxy_hide_header x-amz-request-id;
        proxy_hide_header x-amz-id-2;
        proxy_hide_header x-request-id;
        proxy_intercept_errors on;
        error_page 403 404 = @missing;
        error_page 500 502 503 504 = @unavailable;
        add_header Content-Type $asset_type;
        add_header Cache-Control "public, max-age=604800";
      }
      location @missing { return 404; }
      location @unavailable { return 502; }
      location / { return 404; }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: card-images
  namespace: pokemon-api
spec:
  replicas: 1
  selector:
    matchLabels:
      app: card-images
  template:
    metadata:
      labels:
        app: card-images
    spec:
      {{- include "placement.preferWorkers" . | nindent 6 }}
      containers:
        - name: nginx
          image: nginx:1.31-alpine@sha256:713fc2ebfd92e8217db451477182ee91944b123d2b1ee9fd5a8c6e91ca6c3a11
          ports:
            - containerPort: 80
          volumeMounts:
            - name: conf
              mountPath: /etc/nginx/conf.d
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
            limits:
              memory: 64Mi
      volumes:
        - name: conf
          configMap:
            name: card-images-nginx
---
apiVersion: v1
kind: Service
metadata:
  name: card-images
  namespace: pokemon-api
spec:
  selector:
    app: card-images
  ports:
    - port: 80
      targetPort: 80
```

  In `cloudflare-tunnel.yaml` change the `^/images/` route's service to `http://card-images.pokemon-api.svc.cluster.local:80`.

- [ ] **Step 4: Point db-backup at its store.** In `db-backup.yaml`: `E=http://rustfs-backups.db-system.svc.cluster.local:9000`; the restore recipe's endpoint likewise; replace the comment "RustFS lives in the ptcgl namespace; the dump job needs its keys here." with "The keys of the backups store (db-backup-storage.yaml)."; and in the header add one line "Since 2026-11-10 the dumps live in rustfs-backups in db-system; older days were copied over."

- [ ] **Step 5: Fix the spec's SOPS line** to: "The `ptcgl.*` SOPS keys stay: the new secrets still read them. Renaming them is optional and the user's."

- [ ] **Step 6: Render, then push** (outside 01:40–07:00 UTC)

Run: `helm template apps apps -f apps/values.yaml -f apps/secrets.yaml > /dev/null && echo ok; grep -rn "rustfs.ptcgl\|ptcgl-assets" apps/templates | grep -v app-ptcgl.yaml`
Expected: `ok`, and no grep output.

```bash
git add apps/templates docs/superpowers/specs/2026-11-09-card-storage-move-design.md
git commit -m "feat(storage): pokemon-api, the /images/ proxy and db-backup use the new stores"
git push origin HEAD:main
```

- [ ] **Step 7: Check the switch**

After Argo syncs: `kubectl -n pokemon-api rollout status deploy/card-images --timeout=300s` and `kubectl -n cloudflare-tunnel get pods` (the tunnel pod picks up the new route; if it still serves the old one after five minutes, `kubectl -n cloudflare-tunnel rollout restart deploy`).
Run: `for p in decoded/10101_0000/sv10_en_233/sv10_en_233_etched.png decoded/baked/energy/grass.png; do curl -s -o /dev/null -w "$p %{http_code}\n" "https://pokemon-api.thomvandev.in/images/$p?check=$(date +%s)"; done`
Expected: both `200` (the query string bypasses the Cloudflare cache, so the new proxy answers).
Then run a card-data build (`card-data-run.sh` from the session scratchpad); expected outcome `applied`.

### Task 4: The night after

- [ ] **Step 1: Check the nightly jobs** (after 07:00 UTC)

Run: `kubectl -n pokemon-api get jobs --sort-by=.metadata.creationTimestamp | tail -3; kubectl -n db-system get jobs --sort-by=.metadata.creationTimestamp | tail -2`
Expected: the newest rainier-sync, baked-assets and db-backup Jobs `Complete`.

Run: `kubectl -n db-system exec deploy/rustfs-backups -- ls /data/backups | tail -2; kubectl -n pokemon-api exec deploy/rustfs -- ls /data/cards/decoded | head -3`
Expected: today's date folder in the backups store; `decoded/` lists its folders in the cards store (RustFS keeps buckets and key prefixes as directories, as the old store did).

- [ ] **Step 2: Restore check.** Copy today's dump out of the new store and restore it into a scratch database:

```bash
day=$(date -u +%F)
kubectl -n db-system run restore-copy --rm -i --restart=Never --image=amazon/aws-cli:2.39.6 --env AWS_DEFAULT_REGION=us-east-1 \
    --overrides='{"spec":{"containers":[{"name":"restore-copy","image":"amazon/aws-cli:2.39.6","command":["sh","-c","aws --endpoint-url http://rustfs-backups.db-system.svc.cluster.local:9000 s3 cp s3://backups/'$day'/pokemon_api.dump - "],"env":[{"name":"AWS_ACCESS_KEY_ID","valueFrom":{"secretKeyRef":{"name":"db-backup-s3","key":"access-key"}}},{"name":"AWS_SECRET_ACCESS_KEY","valueFrom":{"secretKeyRef":{"name":"db-backup-s3","key":"secret-key"}}},{"name":"AWS_DEFAULT_REGION","value":"us-east-1"}]}]}}' > /tmp/claude-scratch-pokemon_api.dump
kubectl -n db-system exec -i statefulset/postgresql -- sh -c 'cat > /tmp/r.dump && PGPASSWORD=$POSTGRES_PASSWORD createdb -U postgres pokemon_api_restore_check && PGPASSWORD=$POSTGRES_PASSWORD pg_restore -U postgres -d pokemon_api_restore_check --no-owner /tmp/r.dump; rm /tmp/r.dump' < /tmp/claude-scratch-pokemon_api.dump
pgq -d pokemon_api_restore_check -At -c "SELECT count(*) FROM cards"; pgq -d pokemon_api -At -c "SELECT count(*) FROM cards"
pgq -d postgres -c "DROP DATABASE pokemon_api_restore_check"; rm /tmp/claude-scratch-pokemon_api.dump
```
Expected: the two counts are equal (the live one may be higher only if a build ran after 03:00). If the Postgres pod or its password variable is named differently, the executor rules on the equivalent and ledgers it.

### Task 5: Remove the old store (after the user approves)

**Files:**
- Delete: `apps/templates/app-ptcgl.yaml`
- Modify: `apps/templates/db-backup.yaml` (the `ptcgl` database left the dump list by itself once dropped; nothing to change unless a name list mentions it)

- [ ] **Step 1: Ask the user.** Show Task 4's results and ask to approve deleting the `ptcgl` namespace (RustFS, its 35 GB volume, the old proxy, the console, `ptcgl-secret`) and dropping the empty `ptcgl` database and `ptcgl_reader` role. Stop here until the user says yes.

- [ ] **Step 2: Delete and push**

```bash
git rm apps/templates/app-ptcgl.yaml
helm template apps apps -f apps/values.yaml -f apps/secrets.yaml > /dev/null && echo ok
git commit -m "chore(storage): remove the ptcgl namespace; card images and backups have moved"
git push origin HEAD:main
```
Expected: `ok`; after Argo syncs, `kubectl get ns ptcgl` reports NotFound (Argo prunes the namespace and its objects; if the namespace stays, `kubectl delete namespace ptcgl`).

- [ ] **Step 3: Drop the database and role**

Run with the session's `pgq` helper: `pgq -d postgres -c "DROP DATABASE ptcgl"` and, if `SELECT 1 FROM pg_roles WHERE rolname='ptcgl_reader'` returns a row, `pgq -d postgres -c "DROP ROLE ptcgl_reader"`.
Expected: `DROP DATABASE`; the role query returns nothing or `DROP ROLE`.

- [ ] **Step 4: Memory.** Update `own-dataset.md` and `repos-and-infra.md`: card images in `pokemon-api/rustfs` bucket `cards`, console `pokemon-api-storage`, proxy `pokemon-api/card-images`; backups in `db-system/rustfs-backups` bucket `backups`; the `ptcgl` namespace and database are gone.

## Revision (2026-11-09)

Tasks 1 to 3 for the card store are replaced by the procedure in the spec's Revision section; the backups parts of Tasks 1 to 3 and Tasks 4 and 5 stand, with the bucket name `ptcgl` instead of `cards`.
