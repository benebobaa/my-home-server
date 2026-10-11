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

# No inbound traffic at all: cloudflared only dials out, and its metrics port
# also serves /debug/pprof, which tenant pods on the worker could otherwise
# reach over the pod network. K3s's policy controller (kube-router) still
# admits traffic from the pod's own node, so the kubelet probes keep working.
kubectl apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-ingress
  namespace: cloudflared
spec:
  podSelector: {}
  policyTypes: [Ingress]
EOF

# Cloudflare Origin CA roots (public; developers.cloudflare.com/ssl/static/,
# RSA sha256 D3:C7:E8:5C..., ECC AA:63:69:7A..., both valid to 2029-08-15).
# Kubeletto's Traefik serves Origin CA certs; tunnel.tf points ca_pool here.
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: origin-ca
  namespace: cloudflared
data:
  origin-ca.pem: |
    -----BEGIN CERTIFICATE-----
    MIIEADCCAuigAwIBAgIID+rOSdTGfGcwDQYJKoZIhvcNAQELBQAwgYsxCzAJBgNV
    BAYTAlVTMRkwFwYDVQQKExBDbG91ZEZsYXJlLCBJbmMuMTQwMgYDVQQLEytDbG91
    ZEZsYXJlIE9yaWdpbiBTU0wgQ2VydGlmaWNhdGUgQXV0aG9yaXR5MRYwFAYDVQQH
    Ew1TYW4gRnJhbmNpc2NvMRMwEQYDVQQIEwpDYWxpZm9ybmlhMB4XDTE5MDgyMzIx
    MDgwMFoXDTI5MDgxNTE3MDAwMFowgYsxCzAJBgNVBAYTAlVTMRkwFwYDVQQKExBD
    bG91ZEZsYXJlLCBJbmMuMTQwMgYDVQQLEytDbG91ZEZsYXJlIE9yaWdpbiBTU0wg
    Q2VydGlmaWNhdGUgQXV0aG9yaXR5MRYwFAYDVQQHEw1TYW4gRnJhbmNpc2NvMRMw
    EQYDVQQIEwpDYWxpZm9ybmlhMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKC
    AQEAwEiVZ/UoQpHmFsHvk5isBxRehukP8DG9JhFev3WZtG76WoTthvLJFRKFCHXm
    V6Z5/66Z4S09mgsUuFwvJzMnE6Ej6yIsYNCb9r9QORa8BdhrkNn6kdTly3mdnykb
    OomnwbUfLlExVgNdlP0XoRoeMwbQ4598foiHblO2B/LKuNfJzAMfS7oZe34b+vLB
    yrP/1bgCSLdc1AxQc1AC0EsQQhgcyTJNgnG4va1c7ogPlwKyhbDyZ4e59N5lbYPJ
    SmXI/cAe3jXj1FBLJZkwnoDKe0v13xeF+nF32smSH0qB7aJX2tBMW4TWtFPmzs5I
    lwrFSySWAdwYdgxw180yKU0dvwIDAQABo2YwZDAOBgNVHQ8BAf8EBAMCAQYwEgYD
    VR0TAQH/BAgwBgEB/wIBAjAdBgNVHQ4EFgQUJOhTV118NECHqeuU27rhFnj8KaQw
    HwYDVR0jBBgwFoAUJOhTV118NECHqeuU27rhFnj8KaQwDQYJKoZIhvcNAQELBQAD
    ggEBAHwOf9Ur1l0Ar5vFE6PNrZWrDfQIMyEfdgSKofCdTckbqXNTiXdgbHs+TWoQ
    wAB0pfJDAHJDXOTCWRyTeXOseeOi5Btj5CnEuw3P0oXqdqevM1/+uWp0CM35zgZ8
    VD4aITxity0djzE6Qnx3Syzz+ZkoBgTnNum7d9A66/V636x4vTeqbZFBr9erJzgz
    hhurjcoacvRNhnjtDRM0dPeiCJ50CP3wEYuvUzDHUaowOsnLCjQIkWbR7Ni6KEIk
    MOz2U0OBSif3FTkhCgZWQKOOLo1P42jHC3ssUZAtVNXrCk3fw9/E15k8NPkBazZ6
    0iykLhH1trywrKRMVw67F44IE8Y=
    -----END CERTIFICATE-----
    -----BEGIN CERTIFICATE-----
    MIICiTCCAi6gAwIBAgIUXZP3MWb8MKwBE1Qbawsp1sfA/Y4wCgYIKoZIzj0EAwIw
    gY8xCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpDYWxpZm9ybmlhMRYwFAYDVQQHEw1T
    YW4gRnJhbmNpc2NvMRkwFwYDVQQKExBDbG91ZEZsYXJlLCBJbmMuMTgwNgYDVQQL
    Ey9DbG91ZEZsYXJlIE9yaWdpbiBTU0wgRUNDIENlcnRpZmljYXRlIEF1dGhvcml0
    eTAeFw0xOTA4MjMyMTA4MDBaFw0yOTA4MTUxNzAwMDBaMIGPMQswCQYDVQQGEwJV
    UzETMBEGA1UECBMKQ2FsaWZvcm5pYTEWMBQGA1UEBxMNU2FuIEZyYW5jaXNjbzEZ
    MBcGA1UEChMQQ2xvdWRGbGFyZSwgSW5jLjE4MDYGA1UECxMvQ2xvdWRGbGFyZSBP
    cmlnaW4gU1NMIEVDQyBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkwWTATBgcqhkjOPQIB
    BggqhkjOPQMBBwNCAASR+sGALuaGshnUbcxKry+0LEXZ4NY6JUAtSeA6g87K3jaA
    xpIg9G50PokpfWkhbarLfpcZu0UAoYy2su0EhN7wo2YwZDAOBgNVHQ8BAf8EBAMC
    AQYwEgYDVR0TAQH/BAgwBgEB/wIBAjAdBgNVHQ4EFgQUhTBdOypw1O3VkmcH/es5
    tBoOOKcwHwYDVR0jBBgwFoAUhTBdOypw1O3VkmcH/es5tBoOOKcwCgYIKoZIzj0E
    AwIDSQAwRgIhAKilfntP2ILGZjwajktkBtXE1pB4Y/fjAfLkIRUzrI15AiEA5UCL
    XYZZ9m2c3fKwIenMMojL1eqydsgqj/wK4p5kagQ=
    -----END CERTIFICATE-----
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
      volumes:
        - name: origin-ca
          configMap:
            name: origin-ca
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
          volumeMounts:
            - name: origin-ca
              mountPath: /etc/cloudflared/origin-ca
              readOnly: true
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
