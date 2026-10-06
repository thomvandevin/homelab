{{/*
Pod-spec fragments for node placement. homelab-0 is the control plane and the
only host with the Zigbee/Bluetooth hardware, the UniFi inform address and the
registry hostPath; workers carry thomvandev.in/role=worker.
*/}}

{{- define "placement.homelab0" -}}
nodeSelector:
  kubernetes.io/hostname: homelab-0
{{- end -}}

{{- define "placement.workersOnly" -}}
nodeSelector:
  thomvandev.in/role: worker
{{- end -}}

{{- define "placement.preferWorkers" -}}
affinity:
  nodeAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        preference:
          matchExpressions:
            - key: thomvandev.in/role
              operator: In
              values: ["worker"]
{{- end -}}
