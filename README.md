# Piston connector

The connector lets jobs on Piston runners reach services inside your network:
a database to migrate, an internal API to call, a service behind your VPN.
You run one small container in that network. It connects to Piston, and it
holds each job to the routing rules you write in the Piston console: a job
reaches what they grant and nothing else.

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
   need. The console's Docker line is this one with the id, the key and the
   newest version filled in:

   ```sh
   docker run -d --name piston-connector --restart unless-stopped \
     --read-only --cap-drop ALL --security-opt no-new-privileges \
     -e PISTON_CONNECTOR_ID=<connector id> \
     -e PISTON_PRIVATE_KEY=<private key> \
     'ghcr.io/getpiston/piston-connector:<version>'
   ```

   Each release is one image, tagged with its version, such as `1.0.0`. The
   flags give the container a read-only filesystem and no Linux privileges,
   and it needs none. Keep `--restart unless-stopped`: the connector exits to
   take a change of its tunnel addresses, and Docker starts it again.

3. **See it connect.** The connector's page in the console lists the
   container under **Instances** once it connects. If it does not appear,
   `docker logs piston-connector` says why (see
   [Troubleshooting](#troubleshooting)).

4. **Write a routing rule.** On the connector's **Routing rules** tab, add a
   rule: its **Name**, unique on the connector, its **Job conditions**, which
   jobs may connect, and its **Resources**, what they reach. For example, a
   rule `api-db` lets jobs of `acme-inc/api` reach the hostname `db.internal`. A connector with no routing rule admits no job. See
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
   grant it, by name or by address; the step prints each rule that admitted
   the job, by its name, with the networks, hostnames and DNS domains it
   grants.

## Kubernetes with Helm

The console's Kubernetes line installs the newest chart in its own namespace,
with the chart's version filled in:

```sh
helm install piston-connector oci://ghcr.io/getpiston/charts/piston-connector \
  --version <chart version> \
  --namespace piston-connector --create-namespace \
  --set connectorConfigs.connectorId=<connector id> \
  --set connectorConfigs.privateKey=<private key>
```

The chart writes the private key into a Secret and runs two replicas, spread
across nodes; the console lists each one under **Instances**. The chart's
`appVersion` is the version of the connector image it installs.

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
place of `--reuse-values`. With Docker, remove the container
(`docker rm -f piston-connector`) and run its line again with the new
version. A replica that is replaced cuts its jobs' open connections, and
Piston moves their tunnels to a replica still running within two minutes, so
a job in the middle of a transfer may see one fail.

The console's **Instances** list marks an instance running an older release
than the newest with **Update Required** and the newest version.

## Settings

| Helm value | Environment variable | Default | What it is |
|---|---|---|---|
| `connectorConfigs.connectorId` | `PISTON_CONNECTOR_ID` | | Required. The connector's id, as the console's install lines carry it |
| `connectorConfigs.privateKey` | `PISTON_PRIVATE_KEY` | | Required. The connector's private key; with Helm, this or `connectorConfigs.existingSecret` |
| `connectorConfigs.existingSecret` | | | The name of a Secret of yours, in the release's namespace, holding the private key under the key `privateKey` |
| `connectorConfigs.dns.nameservers` | `PISTON_DNS_NAMESERVERS` | the container's own | The DNS servers the connector asks for the names jobs look up, as `address` or `address:port`: a list in Helm, comma separated in the environment |
| `connectorConfigs.logLevel` | `PISTON_LOG_LEVEL` | `info` | `debug`, `info`, `warn` or `error`; see [Logs](#logs) |
| `connectorConfigs.apiUrl` | `PISTON_API_URL` | Piston's production | The Piston address the connector connects to; set it only when Piston asks you to |
| | `PISTON_METRICS_LISTEN` | `:9090` | Where the [metrics](#metrics) are served |
| `networkPolicy.enabled`, `networkPolicy.egress` | | off; `0.0.0.0/0` with no except | An optional NetworkPolicy on the connector's pods; see [A network policy below the rules](#a-network-policy-below-the-rules) |
| `replicaCount`, `image.*`, `imagePullSecrets`, `serviceAccount.*`, `podAnnotations`, `podLabels`, `podSecurityContext`, `securityContext`, `resources`, `livenessProbe`, `readinessProbe`, `volumes`, `volumeMounts`, `nodeSelector`, `tolerations`, `affinity` | | as `values.yaml` sets them: 2 replicas; the image `ghcr.io/getpiston/piston-connector` at the chart's `appVersion`; 100m CPU and 64 MiB requested, a 1 GiB memory limit | The usual Kubernetes settings, under the names `helm create` gives them |

The connector reads its settings once, at start, and reports every mistake in
them at once.

The private addresses the tunnel uses inside jobs, `100.127.0.0/16` unless you
change them, are set in the Piston console: **Tunnel addresses**, in the
network connector's **Settings**. Change them only if they overlap a network a
job must reach. The console takes a change only while the connector has no
open tunnel, and every replica then restarts on the new addresses.

## How it works

1. **The connector connects to Piston.** Each container, an *instance*,
   keeps one HTTPS connection to Piston open and proves on each connect that
   it holds the connector's private key; Piston keeps only the public half.
   The console lists it under **Instances**, **Online** while it is connected
   and heard from within the last minute. Over this connection it receives
   its tunnel addresses and the tunnels it serves.
2. **A job asks for a tunnel.** The `getpiston/tunnel-action` step names the
   connector. Piston checks the job's GitHub identity, its repository,
   environment and branch, against the connector's routing rules, and hands
   the tunnel to an online instance. The job gets the resources of every rule
   that matched, as the rules stand at that moment.
3. **The job and the connector get connected.** An encrypted tunnel joins
   them, and the step ends once it is up.
4. **The job's traffic to your resources goes through the connector.** In the
   job, the matched rules' **Networks**, **Route by hostname** names and **DNS
   domains** go through the tunnel; the rest of the job's traffic leaves the
   runner as usual. The connector checks every connection and lookup against
   the job's resources, makes the connection from your network, and logs it.
   A name under **Route by hostname** resolves, in the job, to one of the
   connector's tunnel addresses, `100.127.x.y` by default; the connector
   looks the name up with its own DNS servers and connects to the real host.
5. **The tunnel ends with the run.** Piston closes it when the job's workflow
   run completes, or after 6 hours. When its instance stops, Piston moves it
   to another online instance within two minutes: connections open at that
   moment fail, and new ones work again once it has moved.

## What the connector needs from your network

- **HTTPS and UDP**: HTTPS (TCP 443) to `api.runners.eu.prod.piston.sh`, a
  connection that stays open, and UDP to and from any address and port,
  which carries the encrypted tunnels. The UDP cannot pass through an HTTP
  proxy. It needs no volume and no extra Linux capability. The
  chart runs it as a non-root user with every capability dropped, no
  privilege escalation, a read-only root filesystem and the `RuntimeDefault`
  seccomp profile, which meets Kubernetes' restricted Pod Security Standard.
- **A path to what your routing rules grant.** A job can reach at most what
  the connector's container can reach, and your own firewall or the chart's
  [network policy](#a-network-policy-below-the-rules) can narrow that further.
- **Two or more replicas.** A job's tunnel stays on one replica. When that
  replica stops, its tunnels' open connections are cut, and Piston moves them to
  a replica still running within two minutes. Two or more, the chart's default,
  mean a restart never leaves the connector without one. Each replica holds at
  most 100 jobs' tunnels at once; when every replica holds 100, Piston refuses
  a new job's tunnel, so add replicas for more.
- **No CPU limit.** The connector moves data in bursts, and a CPU limit
  throttles them, slowing every job's transfers. Keep the chart's small request
  and no limit, and add replicas for more throughput.

### A network policy below the rules

Routing rules decide what each job reaches. To be sure the connector never
reaches some ranges whatever a rule says, a mistaken rule included, turn on
the chart's NetworkPolicy and list them under `except`:

```yaml
networkPolicy:
  enabled: true
  egress:
    - cidr: 0.0.0.0/0
      except:
        - 169.254.169.254/32  # the cloud metadata service
        - 10.20.64.0/18       # a subnet no job may reach
```

Each entry allows the connector's pods to reach its `cidr`, minus its `except`
ranges, and nothing else; DNS to the cluster's `kube-dns` is always allowed. A
job that tries a refused address sees its connection fail, as when no rule
grants it. Keep Piston and its runners, on the internet, inside an allowed
range, and the DNS servers of `connectorConfigs.dns.nameservers` too when you
set them. The policy works only where the cluster's network plugin enforces
NetworkPolicy, as Calico, Cilium and the Amazon VPC CNI with network policy
turned on do; elsewhere Kubernetes accepts it and nothing applies it. The
ranges cover destinations outside the cluster: Cilium and GKE Dataplane V2
never match a pod, a node or a Service to a range, so there a connector whose
rules grant in-cluster names cannot reach them with the policy on.

## Routing rules

What a job reaches is written in the Piston console, not here. A network
connector's routing rules are on its **Routing rules** tab. Each has a name,
unique on the connector, and says two things: **Job conditions**, which jobs
the rule admits, and **Resources**, what those jobs reach. Every condition you fill in must match the job, and a list
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

TCP and UDP work through the tunnel; `ping` does not. A job reaches its
runner's own addresses, Docker's `172.17.0.0/16` among them, on the runner,
never through the tunnel, whatever its Networks hold.

A tunnel keeps the resources it opened with: an edit of the routing rules
applies to the tunnels opened after it, so re-run a job to try an edit.

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
| `connector_started`, `connector_stopped` | the connector starts, or stops on a signal or an error | `instance_id`, as the console's Instances list shows it; `error` |
| `control_connected`, `control_closed` | its connection to Piston comes up or drops; it reconnects on its own | `error`, `retry_in` |
| `connector_configured` | the connector takes its tunnel addresses from Piston, at its first connection | `tunnel_range` |
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
tunnel), or one of the connector's own: `handshake_timeout` (the job and the
connector could not get connected), `silent` (the job stopped answering), `address_reused` (a
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
| `piston_connector_tunnels_established` | of those, the ones the job's side has answered |
| `piston_connector_flows_total{protocol, verdict}` | connections from jobs, by verdict |
| `piston_connector_dns_answers_total{kind}` | lookups, by answer |

## Troubleshooting

A failure shows in one of three places: the job's tunnel step, the console's
**Instances** list, or the connector's log. The
[tunnel step's guide](https://github.com/getpiston/tunnel-action#when-the-step-fails)
lists every message the step fails with. A job's log lines carry its
`repository` and its `gh_run_id`, the number in the run's GitHub URL:

```sh
docker logs piston-connector
kubectl -n piston-connector logs -l app.kubernetes.io/name=piston-connector --prefix --tail=500
```

### The connector does not start

`helm install` refuses a missing setting with
`connectorConfigs.connectorId is the connector's id from the console's install line`,
`connectorConfigs.privateKey or connectorConfigs.existingSecret is required`
or `set connectorConfigs.privateKey or connectorConfigs.existingSecret, not both`.
A pod stuck in `CreateContainerConfigError` names a Secret that is not in the
release's namespace, or one with no `privateKey` key in it;
`kubectl -n piston-connector describe pod` says which.

Past those, the connector checks its settings at start. On a mistake it
writes one `connector_stopped` line whose `error` lists every mistake after
`configuration:`, and exits; Docker or Kubernetes starts it again until they
are fixed.

| `error` holds | Fix |
|---|---|
| `PISTON_CONNECTOR_ID is required`, or `… is not a UUID` | The id the console's install line carries |
| `PISTON_PRIVATE_KEY is required`, `… is not base64`, or `… the key is N bytes, want 32` | The whole private key, 44 characters ending in `=`, as the console showed it or `wg genkey` printed it |
| `PISTON_DNS_NAMESERVERS: "…" is not an address or address:port` | IP addresses, such as `10.20.0.2` or `10.20.0.2:5353`, not hostnames |
| `PISTON_DNS_NAMESERVERS is empty and /etc/resolv.conf names no nameserver` | Set `connectorConfigs.dns.nameservers` |
| `PISTON_LOG_LEVEL "…" is none of debug, info, warn and error` | One of those |
| `PISTON_API_URL: "…" is not an http or https URL` | Leave it unset unless Piston gave you another |

A `connector_stopped` line saying `the tunnel range changed from … to …; the
connector restarts to take it` follows a change of **Tunnel addresses** and is
no fault: Docker's `--restart unless-stopped`, or Kubernetes, starts the
connector again on the new addresses.

### No instance is online

| The log shows | Cause | Fix |
|---|---|---|
| `control_closed` again and again, its `error` starting `dial wss://…` with a DNS, TLS, timeout or refused-connection error | The container cannot reach Piston | Allow outbound HTTPS (TCP 443) to `api.runners.eu.prod.piston.sh`, and a DNS server in the container that resolves it |
| `control_unauthorized`, its `error` holding `the proof does not verify` | Piston does not take this id and key together: the key is not the private half of the connector's public key, the id is another connector's, or the connector was deleted | The id and the key from the same creation. A lost key cannot be recovered: see [Rotating the key](#rotating-the-key) |
| `control_connected`, yet the connector's page lists no instance | The instance runs with another connector's id and key, and shows on that connector's page | This connector's id and key |

The connector retries on its own, waiting longer each time up to 30 s, so a
fix to the network takes effect without a restart.

### The tunnel step fails

| The step says | Cause | Fix |
|---|---|---|
| `no connector of that name admits the job` | No connector of exactly that name, case included, in the organization that owns the job's repository, or no routing rule whose job conditions match the job. Piston does not say which, so a job cannot probe for names | The name as the console shows it. Then the rules: jobs for tags and pull requests match no rule that sets Branches, and a job with no environment no rule that sets Environments |
| `the tunnel to <name> did not come up within <N> s` | No instance online, or the job and the instance could not get connected | If no instance is online, [see above](#no-instance-is-online). If the log has a `tunnel_opened` for the job and then a `tunnel_closed` with the `reason` `handshake_timeout` 15 s later, with no `tunnel_established` between, the tunnel's UDP is blocked: allow UDP to and from any address and port. If it has no `tunnel_opened`, no instance took the tunnel in time, as just after a restart: a longer `timeout` on the step waits for one |
| `every instance of the connector holds 100 tunnels; more replicas take more` | Every instance is full | More replicas |
| `every tunnel address of the connector is in use` | The tunnel addresses are too few for the jobs running at once | Wider **Tunnel addresses** |

### The job cannot reach a service

The step printed the rules that matched, yet a connection from the job fails.
Look at the job's lines in the log:

| The log shows | Cause | Fix |
|---|---|---|
| `connection_denied`, `verdict` `deny` | No rule the job matched grants that `destination` | Add it to a rule's Networks or Route by hostname, then re-run the job: an edit reaches only tunnels opened after it |
| `lookup_denied` | The job looked up a name that reached the connector, but no rule it matched grants | Add the name under Route by hostname |
| `connection_failed`, `verdict` `unresolved` | The connector's DNS servers do not know the name | Set `connectorConfigs.dns.nameservers` to DNS servers that resolve your internal names |
| `lookup_failed` | The connector's DNS servers did not answer | Check the connector reaches them |
| `connection_failed`, `verdict` `dial_failed` | The connector could not connect to the destination | The service is down, or a firewall, a security group or the chart's network policy stops the connector. Try the same connection from where the connector runs |
| Nothing for that destination | The connection never took the tunnel | Its address is outside the matched rules' Networks, and its name outside their Route by hostname and DNS domains, so it left the runner as usual. A name under DNS domains alone resolves to its real address, which a Network must hold. Docker's `172.17.0.0/16`, IPv6 and `ping` never take the tunnel |

### Jobs lose connections mid-run, or run slowly

| The log or the cluster shows | Cause | Fix |
|---|---|---|
| `tunnel_closed` with the `reason` `shutdown` on one instance, then `tunnel_opened` for the same `runner_public_key` on another | The instance stopped: an upgrade, a node drain, a restart | Expected: connections open at that moment fail. Run two or more replicas, and let jobs retry a failed connection |
| `tunnel_closed` with the `reason` `silent` | The job's side stopped answering for 3 minutes | Usual for a job that ended while the rest of its run goes on |
| `control_unauthorized` while jobs run | The connector was deleted in the console | Every tunnel on it ends |
| A pod `OOMKilled` | Too many live connections for the memory limit; each UDP flow holds about 138 KiB | Raise `resources.limits.memory`, or add replicas |
| Transfers slower than the network | A CPU limit throttles the connector | No CPU limit, and more replicas for more throughput |

## Rotating the key

A network connector's key is fixed when it is created, so a new key is a new
connector: create one in the console, which makes its key, write its routing
rules, deploy it with its id and private key, and point your workflows'
`connector_name` at it. Once nothing uses the old one, uninstall it, then
delete it in the console. A lost private key is replaced the same way.

## Help

Open an issue in this repository.
