#!/usr/bin/env bash
# Lint and render assertions for the piston-connector chart.
set -uo pipefail

CHART="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0

# A fixed test key, never a live connector's.
PRIVATE_KEY="ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pn8="
CONNECTOR_ID="6f1c1e43-7a39-4c43-9d7e-5f2b8a4a7d10"
BASE=(
  --set-string "privateKey=$PRIVATE_KEY"
  --set-string "connectorId=$CONNECTOR_ID"
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
hasnt "one replica has no spread"                 "topologySpreadConstraints" --set replicas=1

# The private key: rendered from `privateKey`, or read from the customer's own Secret.
has  "the private key goes in a Secret"           "privateKey: \"$PRIVATE_KEY\""
has  "the key reaches the pod by reference"       "key: privateKey"
has  "the key is PISTON_PRIVATE_KEY"              "name: PISTON_PRIVATE_KEY"
has  "the connector id reaches the pod"           "value: \"$CONNECTOR_ID\""
fails "no connectorId fails"                       --set-string "privateKey=$PRIVATE_KEY"
hasnt "the key is never a plain env value"        "value: \"$PRIVATE_KEY\""
t "existingSecret renders no Secret and is referenced"
out="$(helm template piston-connector "$CHART" -n piston --set-string existingSecret=customer-owned --set-string "connectorId=$CONNECTOR_ID" 2>/dev/null)"
if ! grep -q '^kind: Secret' <<<"$out" && grep -qF 'name: customer-owned' <<<"$out"; then ok; else no; fi
fails "neither privateKey nor existingSecret fails"
fails "both privateKey and existingSecret fail"   --set-string "privateKey=$PRIVATE_KEY" --set-string existingSecret=customer-owned
has  "a key change rolls the pods"                "checksum/secret:"

# The configuration's keys, comma separated as docker run takes them.
has  "nameservers are joined"                     'value: "10.20.0.2,10.20.0.3"' --set "dns.nameservers={10.20.0.2,10.20.0.3}"
has  "the tunnel range defaults"                  'value: "100.127.0.0/16"'
has  "the tunnel range is overridable"            'value: "100.64.0.0/16"' --set-string tunnelRange=100.64.0.0/16
hasnt "the api URL is the image's"                "PISTON_API_URL"

# Hardening: assert what the chart sets, so the posture cannot regress unseen.
has  "runs as non-root"                           "runAsNonRoot: true"
has  "seccomp is RuntimeDefault"                  "type: RuntimeDefault"
has  "no privilege escalation"                    "allowPrivilegeEscalation: false"
has  "read-only root filesystem"                  "readOnlyRootFilesystem: true"
has  "every capability dropped"                   'drop: ["ALL"]'
hasnt "no capability added back"                  "add:"
has  "no service account token mounted"           "automountServiceAccountToken: false"
hasnt "no volume"                                 "volumes:"

# Scraped by annotation; no ServiceMonitor, no Service.
has  "prometheus scrapes it"                      'prometheus.io/scrape: "true"'
has  "prometheus scrapes port 9090"               'prometheus.io/port: "9090"'
hasnt "no ServiceMonitor"                         "kind: ServiceMonitor"
hasnt "no Service"                                "kind: Service"

# The ordinary pod knobs pass through.
has  "podAnnotations pass through"                "example.com/team: data" --set "podAnnotations.example\.com/team=data"
has  "nodeSelector passes through"                "kubernetes.io/arch: arm64" --set "nodeSelector.kubernetes\.io/arch=arm64"
has  "tolerations pass through"                   "key: dedicated" --set "tolerations[0].key=dedicated" --set "tolerations[0].operator=Exists"
has  "affinity passes through"                    "podAntiAffinity:" \
     --set "affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution[0].topologyKey=kubernetes.io/hostname"
has  "resources default"                          "memory: 1Gi"
has  "log level default"                          'value: "info"'
has  "log level passes through"                   'value: "debug"' --set "logLevel=debug"

exit "$rc"
