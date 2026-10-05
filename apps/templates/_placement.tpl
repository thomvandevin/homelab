{{/*
Pod-spec fragments for node placement. homelab-0 is the control plane and the
only host with the Zigbee/Bluetooth hardware, the UniFi inform address and the
registry hostPath; workers carry node-role.kubernetes.io/worker=true.
*/}}

{{- define "placement.homelab0" -}}
nodeSelector:
  kubernetes.io/hostname: homelab-0
{{- end -}}

{{- define "placement.workersOnly" -}}
nodeSelector:
  node-role.kubernetes.io/worker: "true"
{{- end -}}

{{- define "placement.preferWorkers" -}}
affinity:
  nodeAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        preference:
          matchExpressions:
            - key: node-role.kubernetes.io/worker
              operator: In
              values: ["true"]
{{- end -}}
