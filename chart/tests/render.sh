#!/usr/bin/env bash
# Lint and render assertions for the piston-connector chart.
set -uo pipefail

CHART="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0

# A fixed test key, never a live connector's.
PRIVATE_KEY="ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pn8="
CONNECTOR_ID="6f1c1e43-7a39-4c43-9d7e-5f2b8a4a7d10"
BASE=(
  --set-string "connectorConfigs.privateKey=$PRIVATE_KEY"
  --set-string "connectorConfigs.connectorId=$CONNECTOR_ID"
  -n "piston"
)

t()  { printf '  %-62s' "$1"; }
ok() { printf 'ok\n'; }
no() { printf 'FAIL\n'; rc=1; }

render() { helm template piston-connector "$CHART" "${BASE[@]}" "$@" 2>/dev/null; }
has() {
  local d="$1" n="$2"; shift 2; t "$d"
  if render "$@" | grep -qF -- "$n"; then ok; else no; fi
}
hasnt() {
  local d="$1" n="$2"; shift 2; t "$d"
  if render "$@" | grep -qF -- "$n"; then no; else ok; fi
}
nokind() {
  local d="$1" k="$2"; t "$d"
  if render | grep -qx -- "kind: $k"; then no; else ok; fi
}
fails() {
  local d="$1"; shift; t "$d"
  if helm template piston-connector "$CHART" -n piston "$@" >/dev/null 2>&1; then no; else ok; fi
}

echo "connector chart"
t "helm lint passes"
if helm lint "$CHART" "${BASE[@]}" >/dev/null 2>&1; then ok; else no; fi

has  "image defaults to the chart's appVersion"   "image: \"ghcr.io/getpiston/piston-connector:$(awk '/^appVersion:/ {gsub(/"/,"",$2); print $2}' "$CHART/Chart.yaml")\""
has  "image tag is overridable"                   'image: "ghcr.io/getpiston/piston-connector:9.9.9"' --set-string image.tag=9.9.9
has  "two replicas by default"                    "replicas: 2"
has  "replicas spread across nodes"               "topologyKey: kubernetes.io/hostname"
hasnt "one replica has no spread"                 "topologySpreadConstraints" --set replicaCount=1

# The private key: rendered from `privateKey`, or read from the customer's own Secret.
has  "the private key goes in a Secret"           "privateKey: \"$PRIVATE_KEY\""
has  "the key reaches the pod by reference"       "key: privateKey"
has  "the key is PISTON_PRIVATE_KEY"              "name: PISTON_PRIVATE_KEY"
has  "the connector id reaches the pod"           "value: \"$CONNECTOR_ID\""
fails "no connectorId fails"                       --set-string "connectorConfigs.privateKey=$PRIVATE_KEY"
hasnt "the key is never a plain env value"        "value: \"$PRIVATE_KEY\""
t "existingSecret renders no Secret and is referenced"
out="$(helm template piston-connector "$CHART" -n piston --set-string connectorConfigs.existingSecret=customer-owned --set-string "connectorConfigs.connectorId=$CONNECTOR_ID" 2>/dev/null)"
if ! grep -q '^kind: Secret' <<<"$out" && grep -qF 'name: customer-owned' <<<"$out"; then ok; else no; fi
fails "neither privateKey nor existingSecret fails"
fails "both privateKey and existingSecret fail"   --set-string "connectorConfigs.privateKey=$PRIVATE_KEY" --set-string connectorConfigs.existingSecret=customer-owned
has  "a key change rolls the pods"                "checksum/secret:"

# The configuration's keys.
hasnt "the api URL is the image's by default"     "PISTON_API_URL"
t "the api URL reaches the pod when set"
out="$(render --set-string connectorConfigs.apiUrl=https://api.example.com)"
if grep -qF 'name: PISTON_API_URL' <<<"$out" && grep -qF 'value: "https://api.example.com"' <<<"$out"; then ok; else no; fi

# Hardening: assert what the chart sets, so the posture cannot regress unseen.
has  "runs as non-root"                           "runAsNonRoot: true"
has  "seccomp is RuntimeDefault"                  "type: RuntimeDefault"
has  "no privilege escalation"                    "allowPrivilegeEscalation: false"
has  "read-only root filesystem"                  "readOnlyRootFilesystem: true"
has  "every capability dropped"                   "- ALL"
hasnt "no capability added back"                  "add:"
has  "no service account token mounted"           "automountServiceAccountToken: false" -s templates/deployment.yaml
hasnt "no volume"                                 "volumes:"

# Its own ServiceAccount, which holds no token either.
has  "a ServiceAccount is rendered"               "kind: ServiceAccount" -s templates/serviceaccount.yaml
has  "the ServiceAccount mounts no token"         "automountServiceAccountToken: false" -s templates/serviceaccount.yaml
has  "the pod names the ServiceAccount"           "serviceAccountName: piston-connector" -s templates/deployment.yaml

# Scraped by annotation; nothing fronts it.
has  "prometheus scrapes it"                      'prometheus.io/scrape: "true"'
has  "prometheus scrapes port 9090"               'prometheus.io/port: "9090"'
nokind "no ServiceMonitor"                        ServiceMonitor
nokind "no Service"                               Service
nokind "no Ingress"                               Ingress
nokind "no HorizontalPodAutoscaler"               HorizontalPodAutoscaler

# The optional NetworkPolicy: egress alone, kube-dns always, each range with its excepts.
hasnt "no NetworkPolicy by default"               "kind: NetworkPolicy"
has  "a NetworkPolicy when enabled"               "kind: NetworkPolicy" --set networkPolicy.enabled=true
has  "it governs egress alone"                    "- Egress" --set networkPolicy.enabled=true
has  "kube-dns stays reachable"                   "k8s-app: kube-dns" --set networkPolicy.enabled=true
has  "every address by default"                   "cidr: 0.0.0.0/0" --set networkPolicy.enabled=true
has  "an except is a range never reached"         "- 169.254.169.254/32" --set networkPolicy.enabled=true \
     --set "networkPolicy.egress[0].cidr=0.0.0.0/0" --set "networkPolicy.egress[0].except[0]=169.254.169.254/32"

# The ordinary pod knobs pass through.
has  "podAnnotations pass through"                "example.com/team: data" --set "podAnnotations.example\.com/team=data"
has  "nodeSelector passes through"                "kubernetes.io/arch: arm64" --set "nodeSelector.kubernetes\.io/arch=arm64"
has  "tolerations pass through"                   "key: dedicated" --set "tolerations[0].key=dedicated" --set "tolerations[0].operator=Exists"
has  "affinity passes through"                    "podAntiAffinity:" \
     --set "affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution[0].topologyKey=kubernetes.io/hostname"
has  "resources default"                          "memory: 1Gi"
has  "log level default"                          'value: "info"'
has  "log level passes through"                   'value: "debug"' --set "connectorConfigs.logLevel=debug"

exit "$rc"
