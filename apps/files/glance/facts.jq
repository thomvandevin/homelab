# Derives everything the dashboard shows from raw API objects.
# Inputs arrive as --slurpfile variables, one document each.

# Kubernetes quantity ("3500m", "32751080Ki", "1081342432n") to a plain number.
def q:
  if . == null then 0
  else (tostring | [capture("^(?<n>[0-9.]+)(?<u>[A-Za-z]*)$")] | .[0] // {n: "0", u: ""}) as $m
    | ($m.n | tonumber)
      * ({"": 1, "n": 1e-9, "u": 1e-6, "m": 1e-3, "k": 1e3, "M": 1e6, "G": 1e9, "T": 1e12,
          "Ki": 1024, "Mi": 1048576, "Gi": 1073741824, "Ti": 1099511627776}[$m.u] // 1)
  end;
def gi: . / 1073741824;
def r1: (. * 10 | round) / 10;
def sum: (add // 0);
def age: if . == null then "" else
  ((now - fromdateiso8601) as $s
   | if $s >= 86400 then "\($s / 86400 | floor)d"
     elif $s >= 3600 then "\($s / 3600 | floor)h"
     else "\($s / 60 | floor)m" end) end;

# "glance/icon" annotations use the same prefixes as Glance's own icon fields.
def icon_url:
  if . == null then null
  elif startswith("di:") then "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/\(.[3:]).svg"
  elif startswith("sh:") then "https://cdn.jsdelivr.net/gh/selfhst/icons/svg/\(.[3:]).svg"
  elif startswith("si:") then "https://cdn.jsdelivr.net/npm/simple-icons@latest/icons/\(.[3:]).svg"
  elif startswith("mdi:") then "https://cdn.jsdelivr.net/npm/@mdi/svg@latest/svg/\(.[4:]).svg"
  else . end;
def icon_invert: . != null and (startswith("si:") or startswith("mdi:"));
# namespaces nothing in the repo declares
def fallback_icons: {"kube-system": "di:kubernetes", "default": "di:github"};

def system_namespaces: ["kube-system", "longhorn-system", "metallb-system", "cert-manager",
  "tailscale", "cloudflare-tunnel", "argocd", "glance", "nginx-system",
  "actions-runner-controller", "gitlab-runner", "gitlab-runner-swiss-rounds", "default", "echo"];

($nodes[0].items) as $nodeItems
| ($pods[0].items) as $podItems
| ($workloads[0].items) as $wlItems
| ($argo[0].items | map({
    name: .metadata.name,
    namespace: .spec.destination.namespace,
    sync: .status.sync.status,
    health: .status.health.status,
    revision: (.status.sync.revision // "" | .[0:7]),
    source: (.spec.source.chart // (.spec.source.repoURL | sub("^.*/"; "")))
  })) as $argoApps
| ($argo[0].items | map({key: .spec.destination.namespace, value: .metadata.annotations["glance/icon"]}) | map(select(.value != null)) | from_entries) as $argoIcons
| ($namespaces[0].items | map({key: .metadata.name, value: .metadata.annotations["glance/icon"]}) | map(select(.value != null)) | from_entries) as $nsIcons
# own apps have no Application of their own; their state is the state of their
# resources inside the app-of-apps
| ($argo[0].items | map(select(.metadata.name == "apps")) | .[0].status.resources // []) as $argoResources
| def argo_for($ns):
    ($argoApps | map(select(.namespace == $ns and .name != "apps")) | .[0]) as $direct
    | ($argoResources | map(select(.namespace == $ns))) as $res
    | if $direct != null then $direct
      elif ($res | length) == 0 then null
      else {
        name: "apps",
        namespace: $ns,
        sync: (if ($res | all(.status == "Synced" or .status == null)) then "Synced" else "OutOfSync" end),
        health: ([$res[].health.status] | if index("Degraded") then "Degraded" elif index("Missing") then "Missing"
                 elif index("Progressing") then "Progressing" elif index("Suspended") then "Suspended" else "Healthy" end)
      } end;
# cloudflared routes: hostname -> the namespace of the service it targets
  ($tunnel[0].data["config.yaml"]
   | [match("hostname: *(?<h>\\S+)\\s+service: *(?<s>\\S+)"; "g")
      | {host: .captures[0].string, service: .captures[1].string}
      | select(.host | contains("*") | not)
      | .namespace = (.service | [capture("\\.(?<ns>[a-z0-9-]+)\\.svc")] | .[0].ns // null)]) as $routes
| ($ingress[0].items | map({
    namespace: .metadata.namespace,
    name: .metadata.name,
    class: .spec.ingressClassName,
    host: (.status.loadBalancer.ingress[0].hostname // .spec.rules[0].host // .spec.tls[0].hosts[0]),
  }) | map(.url = (if .class == "tailscale" then "https://\(.host)" else "http://\(.host)" end))) as $ingresses
| ($svc[0].items | map(select(.spec.type == "LoadBalancer" and .status.loadBalancer.ingress[0].ip != null) | {
    namespace: .metadata.namespace,
    name: .metadata.name,
    ip: .status.loadBalancer.ingress[0].ip,
    port: .spec.ports[0].port
  }) | map(.url = (if (.port == 443 or .port == 8443) then "https://\(.ip):\(.port)" else "http://\(.ip):\(.port)" end))) as $lbs
| ($wlItems | map(
    .metadata.namespace as $ns | .metadata.name as $name | .kind as $kind
    | ($podItems | map(select(.metadata.namespace == $ns
        and ((.metadata.ownerReferences[0].name // "") as $o
             | if $kind == "Deployment" then ($o | sub("-[a-z0-9]+$"; "")) == $name else $o == $name end)))) as $own
    | {
      namespace: $ns, kind: $kind, name: $name,
      image: (.spec.template.spec.containers[0].image | sub("@sha256:.*$"; "")),
      tag: (.spec.template.spec.containers[0].image | sub("@sha256:.*$"; "") | if contains(":") then sub("^.*:"; "") else "latest" end),
      ready: (.status.readyReplicas // .status.numberReady // 0),
      desired: (if $kind == "DaemonSet" then .status.desiredNumberScheduled else .spec.replicas end // 0),
      restarts: ([$own[].status.containerStatuses[]?.restartCount] | sum),
      nodes: ([$own[].spec.nodeName] | unique | map(select(. != null)) | map(sub("^homelab-"; "")) | join(",")),
      age: (.metadata.creationTimestamp | age),
      url: (.metadata.annotations["thomvandev.in/url"] // null),
      icon: (.metadata.annotations["glance/icon"] // null)
    })) as $workloadRows
| ($workloadRows | map(.namespace) | unique) as $namespaces
| ($namespaces | map(
    . as $ns
    | ($workloadRows | map(select(.namespace == $ns))) as $wl
    | ($podItems | map(select(.metadata.namespace == $ns and .metadata.ownerReferences[0].kind != "Job"))) as $np
    | ($nsIcons[$ns] // ($wl | map(.icon) | map(select(. != null)) | .[0]) // $argoIcons[$ns] // fallback_icons[$ns]) as $icon
    | {
      name: $ns,
      icon: ($icon | icon_url),
      iconInvert: ($icon | icon_invert),
      system: (system_namespaces | index($ns) != null),
      own: ($wl | any(.image | startswith("registry.gitlab.com/"))),
      ready: ($wl | map(.ready) | sum),
      desired: ($wl | map(.desired) | sum),
      restarts: ($wl | map(.restarts) | sum),
      podsRunning: ($np | map(select(.status.phase == "Running")) | length),
      podsTotal: ($np | length),
      argocd: argo_for($ns),
      links: (
        [($routes | map(select(.namespace == $ns)) | .[] | {kind: "public", url: "https://\(.host)", label: .host})]
        + [($ingresses | map(select(.namespace == $ns)) | .[] | {kind: "tailnet", url: .url, label: .host})]
        + [($lbs | map(select(.namespace == $ns)) | .[] | {kind: "lan", url: .url, label: "\(.ip):\(.port)"})]
        + [($wl | map(select(.url != null)) | .[] | {kind: "lan", url: .url, label: (.url | sub("^https?://"; ""))})]
      ),
      healthy: (($wl | all(.ready >= .desired)) and ($np | all(.status.phase == "Running" or .status.phase == "Succeeded")))
    })) as $apps
| {
  generatedAt: (now | todate),
  nodes: ($nodeItems | map(
    .metadata.name as $n
    | ($podItems | map(select(.spec.nodeName == $n and .status.phase == "Running"))) as $np
    | ($nodemetrics[0].items | map(select(.metadata.name == $n)) | .[0].usage) as $u
    | ($lhnodes[0].items | map(select(.metadata.name == $n)) | .[0]) as $lh
    | {
      name: $n,
      role: (if .metadata.labels["node-role.kubernetes.io/control-plane"] then "control plane" else "worker" end),
      ready: ((.status.conditions | map(select(.type == "Ready")) | .[0].status) == "True"),
      schedulable: (.spec.unschedulable != true),
      kernel: .status.nodeInfo.kernelVersion,
      os: .status.nodeInfo.osImage,
      k3s: .status.nodeInfo.kubeletVersion,
      pods: ($np | length),
      cpu: {
        capacity: (.status.capacity.cpu | q),
        allocatable: (.status.allocatable.cpu | q),
        used: ($u.cpu | q | r1),
        requested: ([$np[].spec.containers[].resources.requests.cpu // "0" | q] | sum | r1)
      },
      mem: {
        allocatable: (.status.allocatable.memory | q | gi | r1),
        used: ($u.memory | q | gi | r1),
        requested: ([$np[].spec.containers[].resources.requests.memory // "0" | q] | sum | gi | r1)
      },
      disk: ($lh.status.diskStatus // {} | [.[]] | {
        max: (map(.storageMaximum) | sum | gi | r1),
        available: (map(.storageAvailable) | sum | gi | r1),
        scheduled: (map(.storageScheduled) | sum | gi | r1)
      }),
      longhornReady: (($lh.status.conditions // []) | map(select(.type == "Ready")) | .[0].status == "True")
    }) | sort_by(.name)),
  apps: ($apps | map(select(.system | not)) | sort_by((.own | not), .name)),
  platform: ($apps | map(select(.system)) | sort_by(.name)),
  workloads: ($workloadRows | sort_by(-.restarts, .namespace, .name)),
  cronjobs: ($cronjobs[0].items | map({
    namespace: .metadata.namespace, name: .metadata.name, schedule: .spec.schedule,
    suspended: (.spec.suspend == true),
    lastSchedule: (.status.lastScheduleTime | age),
    lastSuccess: (.status.lastSuccessfulTime | age),
    ok: (.status.lastSuccessfulTime != null and (.status.lastScheduleTime == null or .status.lastSuccessfulTime >= .status.lastScheduleTime))
  }) | sort_by(.namespace, .name)),
  storage: {
    volumes: ($lhvolumes[0].items | map(
      .metadata.name as $v
      | {
        pvc: (.status.kubernetesStatus.pvcName // $v),
        namespace: (.status.kubernetesStatus.namespace // ""),
        sizeGi: (.spec.size | tonumber | gi | r1),
        replicas: .spec.numberOfReplicas,
        replicaNodes: ($lhreplicas[0].items | map(select(.spec.volumeName == $v and .spec.nodeID != null) | .spec.nodeID | sub("^homelab-"; "")) | sort | join(",")),
        state: .status.state,
        robustness: .status.robustness,
        attachedTo: (.status.currentNodeID // "" | sub("^homelab-"; "")),
        engine: (.status.currentImage // "" | sub("^.*:v?"; ""))
      }) | sort_by(.namespace, .pvc))
  },
  argocd: ($argoApps | sort_by(.name)),
  ingresses: ($ingresses | sort_by(.namespace)),
  loadBalancers: ($lbs | sort_by(.ip)),
  ci: {
    managers: ($podItems | map(select((.metadata.namespace | startswith("gitlab-runner")) and (.metadata.name | startswith("runner-") | not))
      | {namespace: .metadata.namespace, phase: .status.phase, node: (.spec.nodeName // "" | sub("^homelab-"; ""))})),
    jobs: ($podItems | map(select((.metadata.namespace | startswith("gitlab-runner")) and (.metadata.name | startswith("runner-")))
      | {namespace: .metadata.namespace, name: .metadata.name, phase: .status.phase, node: (.spec.nodeName // "" | sub("^homelab-"; "")), age: (.metadata.creationTimestamp | age)})
      | sort_by(.phase)),
    arc: ($podItems | map(select(.metadata.namespace == "default" and .metadata.labels["runner-deployment-name"] != null))
      | map({name: .metadata.labels["runner-deployment-name"], phase: .status.phase, node: (.spec.nodeName // "" | sub("^homelab-"; "")), age: (.metadata.creationTimestamp | age)}))
  },
  # The workspace StatefulSet is OnDelete, which never advances currentRevision;
  # a pod on an older revision than updateRevision has a change waiting for the
  # next idle-guarded deploy
  workspace: (
    ($podItems | map(select(.metadata.namespace == "workspace" and .metadata.name == "workspace-0")) | .[0]) as $p
    | ($wlItems | map(select(.kind == "StatefulSet" and .metadata.namespace == "workspace" and .metadata.name == "workspace")) | .[0]) as $ss
    | if $p == null then {present: false} else {
        present: true,
        ready: ($p.status.containerStatuses[0].ready // false),
        node: ($p.spec.nodeName // ""),
        age: ($p.metadata.creationTimestamp | age),
        restarts: ([$p.status.containerStatuses[]?.restartCount] | sum),
        digest: ($p.status.containerStatuses[0].imageID // "" | sub("^.*@"; "")),
        memGi: ($wsmetrics[0].items | map(select(.metadata.name == "workspace-0")) | .[0].containers // [] | map(.usage.memory | q) | sum | gi | r1),
        memLimitGi: ($p.spec.containers[0].resources.limits.memory | q | gi | r1),
        pendingRestart: ($ss != null and $p.metadata.labels["controller-revision-hash"] != $ss.status.updateRevision)
      } end)
}
