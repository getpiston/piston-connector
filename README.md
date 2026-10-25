# Piston connector

The connector lets jobs on Piston runners reach services inside your network:
a database to migrate, an internal API to call, a service behind your VPN.
You run one small container in that network. It connects out to Piston and
opens no inbound port, and it holds each job to the routing rules you write in
the Piston console: a job reaches what they grant and nothing else.

## Quick start with Docker

The shortest path, for a quick trial or a single host. For a cluster, the
next section, [Kubernetes with Helm](#kubernetes-with-helm), is the way.

1. **Create the network connector.** In the Piston console, open **Runners →
   Network connectors** and choose **New network connector**. Give it a name:
   your workflows open the tunnel by that name. Leave **Public key** empty and
   the console makes the connector's key in your browser, then shows once the
   private key and ready-made install lines that carry the connector's id and
   key. Copy them now: Piston keeps only the public half of the key. To make
   the key yourself instead, see [Your own key](#your-own-key).

2. **Run the container** on a machine that can reach the services your jobs
   need. The console's Docker line is this one with the id and key filled in:

   ```sh
   docker run -d --name piston-connector --restart unless-stopped \
     --read-only --cap-drop ALL --security-opt no-new-privileges \
     -e PISTON_CONNECTOR_ID=<connector id> \
     -e PISTON_PRIVATE_KEY=<private key> \
     'ghcr.io/getpiston/piston-connector:<version>'
   ```

   Put in the version you want, such as `0.1.0`: each release is one image,
   tagged with its version. The flags give the container a read-only
   filesystem and no Linux privileges, and it needs none.

3. **See it connect.** The connector's page in the console lists the
   container under **Instances** once it connects. If it does not appear,
   `docker logs piston-connector` says why (see [Logs](#logs)).

4. **Write a routing rule.** On the connector's **Routing rules** tab, add a
   rule: its **Job conditions** say which jobs may connect, its **Resources**
   what they reach. For example, jobs of `acme-inc/api` reach the hostname
   `db.internal`. A connector with no routing rule admits no job. See
   [Routing rules](#routing-rules).

5. **Open the tunnel from a job.** Add the `getpiston/tunnel-action` step,
   with the connector's name, before the steps that need your network:

   ```yaml
   jobs:
     migrate:
       runs-on: piston-4cpu-ubuntu-2402
       permissions:
         contents: read
         id-token: write
       steps:
         - uses: getpiston/tunnel-action@v1
           with:
             connector_name: <the network connector's name>
         - run: psql "postgres://app@db.internal:5432/app" -c 'select 1'
   ```

   The job proves which repository, branch and environment it runs for with
   the identity GitHub gives it for that run, which is what `id-token: write`
   allows. So there is no VPN for you to operate and no long-lived secret for
   the job to hold. After the step, the job reaches what the routing rules
   grant it, by name or by address.

## Kubernetes with Helm

The console's Kubernetes line installs the newest chart in its own namespace:

```sh
helm install piston-connector oci://ghcr.io/getpiston/charts/piston-connector \
  --namespace piston-connector --create-namespace \
  --set connectorConfigs.connectorId=<connector id> \
  --set connectorConfigs.privateKey=<private key>
```

The chart writes the private key into a Secret and runs two replicas, spread
across nodes; the console lists each one under **Instances**. The chart's
`appVersion` is the version of the connector image it installs, and
`--version <chart version>` pins a chart release.

### Your own key

To keep the private key out of your shell history and Helm's stored values,
put it in a Secret of your own and give the chart the Secret's name. Save the
private key the console showed in `connector.key`, or make the key yourself
before you create the connector: run this where the connector will run, with
the `wg` tool from WireGuard's tools, and paste the line it prints into the
console's **Public key** field.

```sh
(umask 077 && wg genkey | tee connector.key | wg pubkey)
```

Then create the Secret, holding the key under `privateKey`, in the release's
namespace, and install with it:

```sh
kubectl create namespace piston-connector
kubectl -n piston-connector create secret generic piston-connector \
  --from-file=privateKey=connector.key
rm connector.key
helm install piston-connector oci://ghcr.io/getpiston/charts/piston-connector \
  --namespace piston-connector \
  --set connectorConfigs.connectorId=<connector id> \
  --set connectorConfigs.existingSecret=piston-connector
```

Set `connectorConfigs.privateKey` or `connectorConfigs.existingSecret`, never
both. With Docker, the same file goes in as
`-e PISTON_PRIVATE_KEY="$(cat connector.key)"`.

### A values file

Settings that differ from the defaults go in a values file:

```yaml
replicaCount: 3
connectorConfigs:
  connectorId: <connector id>
  existingSecret: piston-connector
  dns:
    nameservers: [10.20.0.2]  # the DNS servers that know your internal names
```

```sh
helm install piston-connector oci://ghcr.io/getpiston/charts/piston-connector \
  --namespace piston-connector -f values.yaml
```

### Upgrading

```sh
helm upgrade piston-connector oci://ghcr.io/getpiston/charts/piston-connector \
  --namespace piston-connector --reuse-values
```

This moves to the newest chart, and so to its connector image, and keeps the
settings you installed with; with a values file, pass `-f values.yaml` in
place of `--reuse-values`. A replica that is replaced hands its jobs'
tunnels to a replica still running within about a minute; the connections open
at that moment are cut, so a job in the middle of a transfer may see one fail.

## Settings

| Helm value | Environment variable | Default | What it is |
|---|---|---|---|
| `connectorConfigs.connectorId` | `PISTON_CONNECTOR_ID` | | Required. The connector's id, as the console's install lines carry it |
| `connectorConfigs.privateKey` | `PISTON_PRIVATE_KEY` | | Required. The connector's private key; with Helm, this or `connectorConfigs.existingSecret` |
| `connectorConfigs.existingSecret` | | | The name of a Secret of yours, in the release's namespace, holding the private key under the key `privateKey` |
| `connectorConfigs.dns.nameservers` | `PISTON_DNS_NAMESERVERS` | the container's own | The DNS servers the connector asks for the names jobs look up, as `address` or `address:port`: a list in Helm, comma separated in the environment |
| `connectorConfigs.tunnelRange` | `PISTON_TUNNEL_RANGE` | `100.127.0.0/16` | The private addresses the tunnel uses inside jobs. Change it only if it overlaps a network a job must reach. IPv4, a `/19` or wider |
| `connectorConfigs.logLevel` | `PISTON_LOG_LEVEL` | `info` | `debug`, `info`, `warn` or `error`; see [Logs](#logs) |
| `connectorConfigs.apiUrl` | `PISTON_API_URL` | Piston's production | The Piston address the connector connects to; set it only when Piston asks you to |
| | `PISTON_METRICS_LISTEN` | `:9090` | Where the [metrics](#metrics) are served |
| `replicaCount`, `image.*`, `imagePullSecrets`, `serviceAccount.*`, `podAnnotations`, `podLabels`, `podSecurityContext`, `securityContext`, `resources`, `livenessProbe`, `readinessProbe`, `volumes`, `volumeMounts`, `nodeSelector`, `tolerations`, `affinity` | | as `values.yaml` sets them: 2 replicas; the image `ghcr.io/getpiston/piston-connector` at the chart's `appVersion`; 100m CPU and 64 MiB requested, a 1 GiB memory limit | The usual Kubernetes settings, under the names `helm create` gives them |

The connector reads its settings once, at start, and reports every mistake in
them at once.

## What the connector needs from your network

- **Outbound connections only**: HTTPS to Piston, and UDP to Piston's runners,
  which carries the encrypted tunnels. It needs no inbound port, no volume and
  no extra Linux capability.
- **A path to what your routing rules grant.** A job can reach at most what
  the connector's container can reach, and your own firewall or Kubernetes
  network policy can narrow that further.
- **Two or more replicas.** A job's tunnel stays on one replica. When that
  replica stops, its tunnels move to one still running within about a minute,
  and their open connections are cut. Two or more, the chart's default, mean a
  restart never leaves the connector without one.
- **No CPU limit.** The connector moves data in bursts, and a CPU limit
  throttles them, slowing every job's transfers. Keep the chart's small request
  and no limit, and add replicas for more throughput.

## Routing rules

What a job reaches is written in the Piston console, not here. A network
connector's routing rules are on its **Routing rules** tab, and each says two
things: **Job conditions**, which jobs the rule admits, and **Resources**, what
those jobs reach. Every condition you fill in must match the job, and a list
left empty matches any; `*` matches any text, and case does not matter.

A job may connect when any rule's job conditions match it, and it reaches the
resources of every rule that matches it, together. Rules only add: there is no
deny rule, and a connector with no rules admits no job. Everything else a job
sends through the tunnel is refused.

| Job condition | Example | Matches | Keep in mind |
|---|---|---|---|
| Repositories | `acme-inc/api`, `acme-inc/*` | the job's repository, as `owner/repo`; `*` alone is every repository | everyone who can run a workflow there can open the tunnel |
| Environments | `production` | the job's GitHub environment | a job without one matches only a rule that sets no environments; a job in one waits for that environment's required reviewers |
| Branches | `main`, `release/*` | the branch the job runs for | jobs for tags and pull requests never match a rule that sets branches; a rule is only as safe as the protection on its branches |

| Resource | Example | What a matching job gets |
|---|---|---|
| Networks | `10.20.0.0/16`, the addresses of your VPC | every address in the range, reached by address. A range is its first address and a size: `/16` is the 65,536 addresses from `10.20.0.0` to `10.20.255.255`, `/32` one address. IPv4 only |
| Route by hostname | `postgres.data.svc.cluster.local`, your Postgres Service; `*.kafka.internal` | those hosts, by name: an exact name, or `*.x` for `x` and every name under it. The connector looks the name up in your network, so the job needs no matching network |
| DNS domains | `corp.example.com` | the names under the domain, looked up through the connector as your DNS servers answer them. The job reaches their addresses only where they fall inside its Networks. `.` is every lookup |

**Grant the narrowest resources a job needs.** A new rule starts empty.
`0.0.0.0/0` opens everything the connector's container can reach: the
internet through your network, the cloud metadata service and with it the
node's cloud credentials unless your cluster blocks it, the Kubernetes API, and
the nodes. A range that holds your pods' addresses opens every pod in it.

TCP and UDP work through the tunnel; `ping` does not.

## Logs

The connector writes one JSON object per line to standard output, so
`docker logs piston-connector`, or
`kubectl -n piston-connector logs -l app.kubernetes.io/name=piston-connector`,
and whatever collects your logs, show them. At `info`, the default, the lines
are an audit log of what every job did through the tunnel. Each has an
`event`, one of the names below, and a job's lines carry the job's
`repository`, `environment`, `gh_run_id`, `gh_run_attempt`, `actor_login` and
`branch`:

| `event` | Written when | Its own fields |
|---|---|---|
| `connector_started`, `connector_stopped` | the connector starts, or stops; with `error` when it stopped on one | `instance_id`, as the console's Instances list shows it; `error` |
| `control_connected`, `control_closed` | its connection to Piston comes up or drops; it reconnects on its own | `error`, `retry_in` |
| `control_unauthorized` | Piston no longer accepts this connector: it was deleted in the console, or recreated with another key; every job's tunnel on it ends | `error`, `retry_in` |
| `tunnel_opened`, `tunnel_established`, `tunnel_closed` | a job is assigned to this connector, its tunnel comes up, and it ends | `runner_public_key`, `runner_endpoint`, `reach`; `reason` and `connections` on the close |
| `tunnel_reach_changed` | Piston sent a job's tunnel again under different routing rules | `reach` |
| `connection_opened`, `connection_closed` | a connection from the job to a destination, and its end | `connection_id`, `protocol`, `source`, `destination`, `verdict`, `dialed`; `duration_ms`, `bytes_to_destination` and `bytes_to_runner` on the close |
| `connection_denied`, `connection_failed` | a connection the rules do not grant, or one the destination did not answer | the same, `verdict`; `error` |
| `lookup_allowed`, `lookup_forwarded`, `lookup_denied`, `lookup_failed` | a name the job looked up: granted by a rule, passed to your DNS servers unchanged, refused, or unanswered | `name`, `type`, `answer` |

A connection's `destination` is what the job asked for, a hostname or an
address with its port; `dialed` is the address the connector reached;
`connection_id` joins a connection's lines. Its `verdict` is `allow_hostname`
or `allow_ip` for what a rule granted, `deny`, `unresolved` when the hostname
did not resolve, or `dial_failed`. A `tunnel_closed` line's `reason` is one of
Piston's, `run_completed` (the run finished), `cap` (the tunnel reached its
6-hour limit), `connector_deleted` or `closed` (Piston no longer lists the
tunnel), or one of the connector's own: `handshake_timeout` (it could not
reach the job), `silent` (the job stopped answering), `address_reused` (a
newer tunnel took its address), `shutdown` (the connector was stopped) or
`unauthorized`.

At `debug` the connector adds detail for troubleshooting with Piston support.

## Metrics

Prometheus metrics are served on port 9090 at `/metrics`. The chart's pods
carry the `prometheus.io/*` annotations, so a Prometheus that finds pods by
annotation scrapes them.

| Metric | What it counts |
|---|---|
| `piston_connector_control_connected` | 1 while the connection to Piston is up |
| `piston_connector_tunnels_open` | tunnels this replica holds, one a job |
| `piston_connector_tunnels_up` | of those, the ones that are up |
| `piston_connector_flows_total{protocol, verdict}` | connections from jobs, by verdict |
| `piston_connector_dns_answers_total{kind}` | lookups, by answer |

## Rotating the key

A network connector's key is fixed when it is created, so a new key is a new
connector: create one in the console, which makes its key, write its routing
rules, deploy it with its id and private key, and point your workflows'
`connector_name` at it. Once nothing uses the old one, uninstall it, then
delete it in the console. A lost private key is replaced the same way.

## Help

Open an issue in this repository.
