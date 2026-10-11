#!/usr/bin/env bash
# cloudflared — the connector of Kubeletto's Cloudflare Tunnel, in the K3s
# cluster on the server node `k3s`. Idempotent. Run by OpenTofu
# (network/cloudflare/tunnel.tf) inside VM 300 through the guest agent, with
# the token line prepended on stdin (never argv, never echoed):
#   TUNNEL_TOKEN=<tunnel token>
#
# Remote-managed tunnel: the connector carries no config, only the token;
# the ingress rules live in tunnel.tf.
set -euo pipefail

[ -n "${TUNNEL_TOKEN:-}" ] || { echo "cloudflared: TUNNEL_TOKEN missing on stdin" >&2; exit 1; }
kubectl() { /usr/local/bin/k3s kubectl "$@"; }

# cloudflared 2026.10.0, the multi-arch index digest from Docker Hub.
IMAGE=docker.io/cloudflare/cloudflared:2026.10.0@sha256:9b49eed8f62806d5d45ddf59ecefb5710429598ea6d3fcccd2af938f621b2b07
# Rolls the pods when the token changes (they read it from the env at start).
TOKEN_SHA=$(printf '%s' "$TUNNEL_TOKEN" | sha256sum | cut -c1-16)

kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: cloudflared
  labels:
    pod-security.kubernetes.io/enforce: restricted
    app.kubernetes.io/managed-by: homeserver-repo
EOF

# The Secret through stdin: the token never appears in a process's argv.
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: tunnel-token
  namespace: cloudflared
type: Opaque
stringData:
  token: "${TUNNEL_TOKEN}"
EOF

kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cloudflared
  namespace: cloudflared
  labels:
    app.kubernetes.io/name: cloudflared
spec:
  # Two replicas (ADR 0004): one restarts while the other carries traffic.
  # Both on the server node: the token can serve every tunnelled hostname,
  # so it stays off the worker, where tenant code runs.
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: cloudflared
  strategy:
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  template:
    metadata:
      labels:
        app.kubernetes.io/name: cloudflared
      annotations:
        homeserver/token-sha: "${TOKEN_SHA}"
    spec:
      nodeSelector:
        node-role.kubernetes.io/control-plane: "true"
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: cloudflared
          image: ${IMAGE}
          args:
            - tunnel
            - --no-autoupdate
            - --metrics
            - 0.0.0.0:2000
            - run
          env:
            - name: TUNNEL_TOKEN
              valueFrom:
                secretKeyRef:
                  name: tunnel-token
                  key: token
          ports:
            - name: metrics
              containerPort: 2000
          readinessProbe:
            httpGet:
              path: /ready
              port: metrics
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /ready
              port: metrics
            initialDelaySeconds: 30
            periodSeconds: 10
            failureThreshold: 6
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              memory: 256Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: [ALL]
EOF

kubectl -n cloudflared rollout status deploy/cloudflared --timeout=240s
echo "cloudflared: $(kubectl -n cloudflared get pods -o wide --no-headers | awk '{print $1, $2, $3, $7}' | tr '\n' ';')"
