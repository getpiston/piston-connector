# Piston connector

The connector lets a job on a Piston runner reach services inside your
network: a database to migrate, an internal API to call, a service behind
your VPN. You run it in your cluster with its id and private key and
nothing else. A job adds the `getpiston/tunnel-action` step and reaches what the
connector's routing rules grant it, by name or by address. The job is authorized
by the identity GitHub gives it for that run, so there is no VPN for you to
operate and no long-lived secret for the job to hold.

What a job reaches is written in the Piston console, not here: the network
connector's routing rules say which jobs may connect and what each of them may reach, and
the connector holds every job to that. Everything else a job sends through
the tunnel is refused.

## The key

The connector holds one key. Its public half is pinned in the console when
the network connector is created, with the id the connector names itself
by. Leave **Public key** empty on the console's New network connector page and the console makes
the key in your browser and shows the private key once, with install lines
that carry it. Or make the key yourself first and paste its public half:

```sh
kubectl create namespace piston-connector
umask 077
wg genkey > connector.key
wg pubkey < connector.key   # paste this into "Public key"
kubectl -n piston-connector create secret generic piston-connector --from-file=privateKey=connector.key
rm connector.key
```

Piston keeps only the public key.

## Install

### With Helm

```sh
helm install piston-connector oci://ghcr.io/getpiston/charts/piston-connector \
  --version <version> --namespace piston-connector \
  --set connectorId=<connector id> --set existingSecret=piston-connector
```

Or pass the key as `--set privateKey=…` and the chart writes the Secret
itself. Local settings go in a values file when yours differ:

```yaml
existingSecret: piston-connector
dns:
  nameservers: [10.20.0.2]  # the resolvers that know your internal names; default the pod's own
```

### With `docker run`

```sh
docker run -d --name piston-connector --restart unless-stopped \
  --read-only --cap-drop ALL --security-opt no-new-privileges \
  -e PISTON_CONNECTOR_ID='<connector id>' \
  -e PISTON_PRIVATE_KEY='<the connector private key>' \
  ghcr.io/getpiston/piston-connector:<version>
```

### Images

Use the plain `<version>` tag. Each release also publishes
`<version>-staging`, which exists for Piston's own verification.

## Settings

| Value | Environment | Default | What it is |
|---|---|---|---|
| `connectorId` | `PISTON_CONNECTOR_ID` | | The connector's id, as the console's install lines carry it. Required |
| `privateKey` | `PISTON_PRIVATE_KEY` | | The connector's private key. Set this or `existingSecret` |
| `existingSecret` | | | A Secret in the release's namespace holding the private key under the key `privateKey` |
| `dns.nameservers` | `PISTON_DNS_NAMESERVERS` | the pod's own | The resolvers the connector asks for the names jobs look up, `address` or `address:port`, comma separated in the environment |
| `replicas` | | `2` | Each replica serves the connector on its own; the console lists them under Instances. Run two or more, so a restart never leaves the connector without one |
| `tunnelRange` | `PISTON_TUNNEL_RANGE` | `100.127.0.0/16` | The address range the tunnel uses inside jobs; change it only if it overlaps a network a job must reach. IPv4, wider than a /20 |
| `logLevel` | `PISTON_LOG_LEVEL` | `info` | `debug`, `info`, `warn` or `error`; see [Logs](#logs) |
| `resources` | | 100m CPU and 64 MiB requested, 1 GiB limit | |
| `image.repository`, `image.tag`, `image.pullPolicy` | | `ghcr.io/getpiston/piston-connector`, the chart's version | |
| `nodeSelector`, `tolerations`, `affinity`, `podAnnotations` | | empty | The ordinary pod knobs |
| | `PISTON_METRICS_LISTEN` | `:9090` | Where Prometheus metrics are served |

The connector reads its settings once, at start, and reports every mistake
in them at once.

## What the connector needs from your network

- Outbound HTTPS to Piston, and outbound UDP to Piston's runners. No inbound
  port, no volume, no capability.
- Reachability to what your routing rules grant. What the connector's pod
  can reach is the outer bound of what any job can reach, and your own
  egress policy may narrow it.
- A job's connection stays with the replica that holds it. A replica that
  stops ends those jobs' connections; new jobs go to the replicas still
  running.

## Which jobs may connect, and what they reach

A network connector's routing rules are written on its page in the console, each as
**Job conditions**, which jobs the rule admits, above **Resources**, what
those jobs get. A job is admitted when any rule's job conditions match it,
and it reaches the resources of every rule that matches it, together. Rules
only add: there is no deny, and a connector with no rules admits no job.

| Job condition | Matches | What it protects |
|---|---|---|
| Repositories | the repository, as `owner/repo`; `*` is every repository | trusts everyone who can run a workflow there |
| Environments | the job's environment | a job without one matches only a rule that sets no environments; inherits the environment's required reviewers |
| Branches | the branch the job runs for | tags and pull-request merge refs never match a rule that sets branches; as strong as the branch's protection |

| Resource | What a matched job gets |
|---|---|
| Networks | IPv4 networks in CIDR form, reached by address |
| Route by hostname | names the job reaches by name, an exact name or `*.x` for `x` and every name under it, resolved by the connector in your network |
| DNS domains | names resolved through the connector as your resolvers answer them, with every name under them; reachable only inside the job's networks; `.` is every lookup |

A pod network in a rule exposes every pod in it. `0.0.0.0/0` exposes
everything the connector's pod can reach: the internet through your egress,
the cloud metadata service and with it the node's cloud credentials unless
your cluster blocks it, the Kubernetes API, and the nodes. Grant the
narrowest resources a job needs. TCP and UDP work through the tunnel;
`ping` does not.

## Logs

The connector writes one JSON object per line to standard output, for
whatever collects your cluster's logs. The lines at `info`, the default, are
an audit log of what every job did through the tunnel. Each carries `event`,
one token of a fixed vocabulary, and the job's `repository`, `environment`,
`gh_run_id`, `gh_run_attempt`, `actor_login` and `branch`:

| `event` | Written when | Its own fields |
|---|---|---|
| `connector_started`, `connector_stopped` | the connector starts, or exits on an error | `instance_id`, as the console's Instances list shows it; `error` |
| `control_connected`, `control_closed` | its connection to Piston comes up or drops; it redials on its own | `error`, `retry_in` |
| `control_unauthorized` | Piston no longer accepts this connector: it was deleted in the console, or recreated with another key; every job's tunnel on it ends | `error`, `retry_in` |
| `tunnels_replayed` | after a reconnect, Piston has resent the tunnels this connector serves | `tunnels` |
| `tunnel_opened`, `tunnel_established`, `tunnel_closed` | a job is assigned to this connector, its connection comes up, and it ends | `runner_public_key`, `runner_endpoint`, `reach`; `reason` and `connections` on the close |
| `tunnel_reach_changed` | a routing-rule edit reaches a running job | `reach` |
| `connection_opened`, `connection_closed` | a connection from the job to a destination, and its end | `connection_id`, `protocol`, `source`, `destination`, `verdict`, `dialed`; `duration_ms`, `bytes_to_destination` and `bytes_to_runner` on the close |
| `connection_denied`, `connection_failed` | a connection the rules do not grant, or one the destination did not answer | the same, `verdict`; `error` |
| `lookup_allowed`, `lookup_forwarded`, `lookup_denied`, `lookup_failed` | a name the job looked up: granted by a rule, passed to your resolvers unchanged, refused, or unanswered | `name`, `type`, `answer` |

A connection's `destination` is what the job asked for, a hostname or an
address with its port; `dialed` is the address the connector reached;
`connection_id` joins a connection's lines. Its `verdict` is `allow_hostname`
or `allow_ip` for what a rule granted, `deny`, `unresolved` when the hostname
did not resolve, or `dial_failed`. A `tunnel_closed` line's `reason` is
`run_completed`, `cap` or `connector_deleted` from Piston, or the connector's
own: `handshake_timeout`, `silent`, `not_replayed`, `address_reused` or
`unauthorized`.

At `debug` the connector adds detail for troubleshooting with Piston support.

## Metrics

Served on port 9090 at `/metrics`; the pod carries the `prometheus.io/*`
annotations.

| Metric | What it counts |
|---|---|
| `piston_connector_control_connected` | 1 while the connection to Piston is established |
| `piston_connector_tunnels_open` | tunnels this replica holds, one a job |
| `piston_connector_tunnels_up` | of those, the ones that are up |
| `piston_connector_flows_total{protocol, verdict}` | connections from jobs, by verdict |
| `piston_connector_dns_answers_total{kind}` | lookups, by answer |

## Rotating the key

Rotation is a new key and a redeploy. A network connector's key is pinned
when it is created, so a new key comes with a new connector in the console:
make the key, create the connector with it, deploy it with its id and the new
private key, and once nothing uses the old one, uninstall it and then delete
it in the console. A lost private key is replaced the same way.

## Help

Open an issue at `getpiston/tunnel-action`.
