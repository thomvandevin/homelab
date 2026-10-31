{{/*
Pod-spec fragments for node placement. homelab-0 is the control plane and the
only host with the Zigbee/Bluetooth hardware and the UniFi inform address; it runs
the home apps (placement.homelab0) and nothing else for longer than a worker outage.
Everything else prefers the workers (thomvandev.in/role=worker), and the descheduler
moves pods that fell back to homelab-0 back once a worker has room.
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
