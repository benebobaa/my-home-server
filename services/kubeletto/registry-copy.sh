#!/usr/bin/env bash
# Copy the registry's blobs from R2 (bucket kubeletto-registry) onto the K3s
# server's own disk, /mnt/registry/data (ADR 0021). One rclone Job in namespace
# registry, env from the registry's own R2 secret (no key goes through this Mac),
# on the control-plane node, writing the hostPath the registry will mount.
# The S3 layout (rootdirectory /) is the filesystem layout: digests are kept.
#
#   ./registry-copy.sh        sync R2 -> disk, repeatable (the second run copies
#                             only what changed; run it again in the cutover
#                             window with the registry read-only)
#   ./registry-copy.sh check  object count and size on both sides, no copy
set -euo pipefail
NODE=root@10.10.10.12
VMID=300
MODE=${1:-sync}
[[ $MODE =~ ^(sync|check)$ ]] || { sed -n 2,13p "$0" >&2; exit 2; }

vm() { ssh -o BatchMode=yes "$NODE" "qm guest exec $VMID --pass-stdin 1 --timeout 3000 -- $*" |
  python3 -c 'import json,sys; d=json.load(sys.stdin); sys.stdout.write(d.get("out-data","")); sys.stderr.write(d.get("err-data","")); sys.exit(d.get("exitcode",1))'; }
K="/usr/local/bin/k3s kubectl -n registry"

if [ "$MODE" = check ]; then ARGS='rclone size R2:kubeletto-registry; rclone size /data'; else
  ARGS='rclone sync R2:kubeletto-registry /data --transfers 16 --checkers 32 --fast-list --stats 30s --stats-one-line -v'; fi

JOB=registry-copy
vm "$K delete job $JOB --ignore-not-found" </dev/null >/dev/null
vm "$K apply -f -" <<YAML
apiVersion: batch/v1
kind: Job
metadata: {name: $JOB, namespace: registry}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 86400
  template:
    spec:
      restartPolicy: Never
      nodeSelector: {node-role.kubernetes.io/control-plane: "true"}
      tolerations:
        - {key: node-role.kubernetes.io/control-plane, operator: Exists, effect: NoSchedule}
      containers:
        - name: rclone
          image: docker.io/rclone/rclone:1.68.2
          command: [sh, -c, "$ARGS"]
          env:
            - {name: RCLONE_CONFIG_R2_TYPE, value: s3}
            - {name: RCLONE_CONFIG_R2_PROVIDER, value: Cloudflare}
            - {name: RCLONE_CONFIG_R2_REGION, value: auto}
            - {name: RCLONE_CONFIG_R2_NO_CHECK_BUCKET, value: "true"}
            - name: RCLONE_CONFIG_R2_ACCESS_KEY_ID
              valueFrom: {secretKeyRef: {name: registry-r2-credentials, key: access-key}}
            - name: RCLONE_CONFIG_R2_SECRET_ACCESS_KEY
              valueFrom: {secretKeyRef: {name: registry-r2-credentials, key: secret-key}}
            - name: RCLONE_CONFIG_R2_ENDPOINT
              valueFrom: {secretKeyRef: {name: registry-r2-credentials, key: endpoint}}
          volumeMounts: [{name: blobs, mountPath: /data}]
          resources: {requests: {cpu: 100m, memory: 128Mi}, limits: {cpu: "2", memory: 1Gi}}
      volumes:
        - {name: blobs, hostPath: {path: /mnt/registry/data, type: Directory}}
YAML
vm "$K wait --for=condition=complete job/$JOB --timeout=2900s" </dev/null || { vm "$K logs job/$JOB --tail=40" </dev/null; exit 1; }
vm "$K logs job/$JOB --tail=15" </dev/null
