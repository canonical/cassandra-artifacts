# Cassandra Snap

This snap packages the Apache Cassandra database, following the layout and conventions of the upstream binary tarballs. It ships no add-on tooling — every command it exposes comes from upstream's `bin/`.

This repository contains the packaging metadata for creating the Cassandra Snap. For more information on snaps, visit [snapcraft.io](https://snapcraft.io/).

## Building the snap

### Clone Repository

```bash
git clone git@github.com:canonical/cassandra-snap.git
cd cassandra-snap
```

### Setup Prerequisites

```bash
sudo snap install snapcraft --classic
sudo snap install lxd
sudo lxd init --auto
```

The repository's recipes — linting, the test suites, and the two host commands below — live in a `justfile`, and `just --list` shows them. Install [`just`](https://just.systems) with `sudo snap install just --classic`, or from the Ubuntu archive with `sudo apt install just`.

### Pack the snap

```bash
snapcraft pack
```

### Test the snap

`snapcraft test` packs the snap, launches a VM through LXD, installs the snap there, brings the node up and runs the tasks under `tests/spread/` against it — `tests/spread/smoke` today:

```bash
snapcraft test
```

A single task is named by its job: `snapcraft test craft:ubuntu-26.04:tests/spread/smoke`. Pass `--debug` to be dropped into a shell in the VM when a task fails, or `--shell` to get one before the tasks run. The command is still marked experimental by snapcraft, which prints a warning saying so.

The suites can also be run directly against a snap installed on this machine — see `just --list` — which is what the `tests/spread/` tasks do inside the VM.

## Using the snap

### Setup the snap

```bash
sudo snap install cassandra*.snap --dangerous
```

The daemon refuses to start until the `process-control`, `system-observe` and `mount-observe` interfaces are connected, rather than starting in a degraded state. Each has a job:

- `process-control` — lets Cassandra stop its own process when it runs out of memory, instead of carrying on in a broken state.
- `system-observe` — lets Cassandra check two kernel settings it cares about, the memory-mapping limit (`vm.max_map_count`) and the swap setting (`vm.swappiness`), and warn when they are lower than it recommends.
- `mount-observe` — lets Cassandra see how the machine's disks are laid out, so it can tell which data folders share a disk and spread the load across them.
- `hardware-observe` — lets Cassandra see how much CPU and memory the machine has, which it uses to pick a sensible heap size.

Those three and `hardware-observe` are connected by `just connect-interfaces`, or by hand:

```bash
sudo snap connect cassandra:process-control
sudo snap connect cassandra:system-observe
sudo snap connect cassandra:mount-observe
sudo snap connect cassandra:hardware-observe
```

To start Cassandra: `sudo snap start cassandra.server`

### Host tuning

A strictly confined snap cannot change host `sysctl` settings, so the two Cassandra asks for have to be set on the host. To set them for the running kernel:

```bash
sudo sysctl -w vm.max_map_count=1048575
sudo sysctl -w vm.swappiness=0
```

Cassandra mmaps every SSTable component, so a node with many SSTables exhausts the default limit of 65530 mappings and dies with an `OutOfMemoryError: Map failed`. To keep the settings across reboots:

```bash
printf 'vm.max_map_count=1048575\nvm.swappiness=0\n' \
  | sudo tee /etc/sysctl.d/99-cassandra.conf
sudo sysctl --system
```

### Available commands

| Command | Upstream script |
| --- | --- |
| `cqlsh` | `cqlsh` |
| `debug-cql` | `debug-cql` |
| `nodetool` | `nodetool` |
| `sstableloader` | `sstableloader` |
| `sstablescrub` | `sstablescrub` |
| `sstableupgrade` | `sstableupgrade` |
| `sstableutil` | `sstableutil` |
| `sstableverify` | `sstableverify` |

Each of these is a snap app with a matching alias, so once the aliases are auto-connected the command is available directly in `$PATH` (e.g. `cqlsh`, `nodetool status`). Aliases are granted by the Snap Store, so for a locally built snap you either invoke the app explicitly:

```bash
sudo snap run cassandra.nodetool status
```

or create the aliases yourself:

```bash
sudo snap alias cassandra.nodetool nodetool
sudo snap alias cassandra.cqlsh cqlsh
```

The JRE's `keytool` is also exposed, as `cassandra.keytool`, for managing TLS keystores and truststores.

### Configuration

Cassandra is configured through `/var/snap/cassandra/common/etc/cassandra/cassandra.yaml`. There are two ways to set it.

**1. Snap options.** Common keys are settable with `snap set`:

```bash
sudo snap set cassandra cluster-name="Prod Cluster" seeds="10.0.0.1:7000,10.0.0.2:7000"
sudo snap restart cassandra.server
```

An option is named after the `cassandra.yaml` key it writes, with `_` replaced by `-`:

| Snap option | `cassandra.yaml` key |
| --- | --- |
| `broadcast-address` | `broadcast_address` |
| `broadcast-rpc-address` | `broadcast_rpc_address` |
| `cluster-name` | `cluster_name` |
| `endpoint-snitch` | `endpoint_snitch` |
| `listen-address` | `listen_address` |
| `num-tokens` | `num_tokens` |
| `rpc-address` | `rpc_address` |
| `seeds` | `seed_provider[0].parameters[0].seeds` |

Unsetting an option restores the default that ships with Cassandra:

```bash
sudo snap unset cassandra cluster-name
```

Cassandra only reads `cassandra.yaml` at startup, so changes need `sudo snap restart cassandra.server` to take effect.

**2. Editing `cassandra.yaml` directly.** Any key can be set by editing the file, and a value edited by hand takes precedence — the snap will not overwrite it, and will not silently drop your `snap set` either:

```
$ sudo snap set cassandra cluster-name="Prod Cluster"
error: cannot perform the following tasks:
- Run configure hook of "cassandra" snap (run hook "configure": cannot apply the
  'cluster-name' option: cluster_name is set to 'Edited By Hand' in cassandra.yaml
  a value edited by hand takes precedence; to hand the key back to 'snap set',
  remove that edit from /var/snap/cassandra/common/etc/cassandra/cassandra.yaml)
```

### Configuration log

`snap set` is applied by the snap's `configure` hook, and snapd shows a hook's output only when the hook fails. Everything it did on a successful `snap set` — which keys it wrote, which it left to a hand edit, whether a restart is needed — is recorded here instead:

```bash
sudo cat /var/snap/cassandra/common/ops/snap/logs/hook-configure.log
```

```
2026-08-21 09:14:02 setting cluster_name to 'Prod Cluster'
2026-08-21 09:14:02 setting seed_provider[0].parameters[0].seeds to '10.0.0.1:7000'
2026-08-21 09:14:02 run 'snap restart cassandra.server' to apply the new configuration
```

The log accumulates across installs, refreshes and every `snap set`.

### RAM

Initially, a single Cassandra instance will use slightly more than a half of the RAM available to the system. To limit the RAM usage (for example, prior running several Cassandra instances simultaneously on single machine) you can set `MAX_HEAP_SIZE` and `HEAP_NEWSIZE` environment variables globally in `/etc/environment` file or specifically in the `/var/snap/cassandra/common/etc/cassandra/cassandra-env.sh` file. Note that `HEAP_NEWSIZE` should be the half of a size of the `MAX_HEAP_SIZE`. Official minimal values are `MAX_HEAP_SIZE="1024M"` and `HEAP_NEWSIZE="512M"`.

### Single Node Deployment Example

1. Start a Cassandra daemon: `sudo snap start cassandra.server`.
2. After a while, you will be able to retrieve a cluster status via `sudo snap run cassandra.nodetool status`.

  ```
  Datacenter: datacenter1
  =======================
  Status=Up/Down
  |/ State=Normal/Leaving/Joining/Moving
  --  Address    Load        Tokens  Owns (effective)  Host ID                               Rack 
  UN  127.0.0.1  114.74 KiB  16      100.0%            c6da97b2-39cf-40a6-b23a-312112f95701  rack1
  ```

3. You can verify cluster works with `snap run cassandra.cqlsh`:

  ```
  Connected to Test Cluster at 127.0.0.1:9042
  [cqlsh 6.2.2 | Cassandra 5.0.9 | CQL spec 3.4.7 | Native protocol v5]
  Use HELP for help.
  cqlsh> create keyspace test WITH replication = {'class': 'SimpleStrategy', 'replication_factor' : 1};
  cqlsh> use test;
  cqlsh:test> create table t1 (message text primary key);
  cqlsh:test> select * from t1;

  message
  ---------

  (0 rows)
  cqlsh:test> insert into t1 (message) values ('hello');
  cqlsh:test> select * from t1;

  message
  ---------
    hello

  (1 rows)
  ```

4. Cassandra is successfully deployed and accessible.

### Multi Node Deployment Example

In this example, the next 3 LXC containers will be used:

- c1: `10.44.178.5`
- c2: `10.44.178.247`
- c3: `10.44.178.81`

1. Setup the required parameters in `/var/snap/cassandra/common/etc/cassandra/cassandra.yaml` on first machine:

  ```yaml
  seed_provider:
    - class_name: org.apache.cassandra.locator.SimpleSeedProvider
      parameters:
        - seeds: "10.44.178.5:7000"
  listen_address: 10.44.178.5
  ```

  > [!NOTE]
  > You should bind Cassandra node to the public IP of the machine in order to make service accessible and also explicitly specify it as seed node.

2. Start and wait for Cassandra to initialize the cluster on first machine: `sudo snap start cassandra.server` & `sudo snap run cassandra.nodetool status`.

  ```
  Datacenter: datacenter1
  =======================
  Status=Up/Down
  |/ State=Normal/Leaving/Joining/Moving
  --  Address      Load        Tokens  Owns (effective)  Host ID                               Rack 
  UN  10.44.178.5  118.77 KiB  16      100.0%            c6da97b2-39cf-40a6-b23a-312112f95701  rack1
  ```

3. Configure the second machine in the same way, but set seed pointing to the first machine: `- seeds: "10.44.178.5:7000"`.

  ```
  Datacenter: datacenter1
  =======================
  Status=Up/Down
  |/ State=Normal/Leaving/Joining/Moving
  --  Address        Load        Tokens  Owns (effective)  Host ID                               Rack 
  UN  10.44.178.247  119.67 KiB  16      51.2%             bbfc37c2-3533-4a54-ac42-5cb16e898939  rack1
  UN  10.44.178.5    118.77 KiB  16      48.8%             c6da97b2-39cf-40a6-b23a-312112f95701  rack1
  ```

4. Configure the third machine in the same way, but set seed pointing to the first machine: `- seeds: "10.44.178.5:7000"`.

  ```
  Datacenter: datacenter1
  =======================
  Status=Up/Down
  |/ State=Normal/Leaving/Joining/Moving
  --  Address        Load        Tokens  Owns (effective)  Host ID                               Rack 
  UN  10.44.178.247  85.1 KiB    16      31.6%             bbfc37c2-3533-4a54-ac42-5cb16e898939  rack1
  UN  10.44.178.5    118.77 KiB  16      32.7%             c6da97b2-39cf-40a6-b23a-312112f95701  rack1
  UN  10.44.178.81   90.13 KiB   16      35.7%             f27b8e4a-f912-46a7-8807-42c93e70d90d  rack1
  ```

5. Verify test data is writeable on second machine with `snap run cassandra.cqlsh`:

  ```
  Connected to Test Cluster at 127.0.0.1:9042
  [cqlsh 6.2.2 | Cassandra 5.0.9 | CQL spec 3.4.7 | Native protocol v5]
  Use HELP for help.
  cqlsh> create keyspace multitest WITH replication = {'class': 'SimpleStrategy', 'replication_factor' : 3};
  cqlsh> use multitest;
  cqlsh:multitest> create table ttt (message text primary key);
  cqlsh:multitest> insert into ttt (message) values ('hello');
  cqlsh:multitest> select * from ttt;

  message
  ---------
    hello

  (1 rows)
  ```

6. Verify test data is readable and writeable on third machine with `snap run cassandra.cqlsh`:

  ```
  Connected to Test Cluster at 127.0.0.1:9042
  [cqlsh 6.2.2 | Cassandra 5.0.9 | CQL spec 3.4.7 | Native protocol v5]
  Use HELP for help.
  cqlsh> use multitest;
  cqlsh:multitest> select * from ttt;

  message
  ---------
    hello

  (1 rows)
  cqlsh:multitest> insert into ttt (message) values ('world');
  cqlsh:multitest> select * from ttt;

  message
  ---------
    hello
    world

  (2 rows)
  ```

7. Verify test data is readable on first machine with `snap run cassandra.cqlsh`:

  ```
  Connected to Test Cluster at 127.0.0.1:9042
  [cqlsh 6.2.2 | Cassandra 5.0.9 | CQL spec 3.4.7 | Native protocol v5]
  Use HELP for help.
  cqlsh> use multitest;
  cqlsh:multitest> select * from ttt;

  message
  ---------
    hello
    world

  (2 rows)
  ```

8. Cassandra cluster is successfully deployed and accessible.

### Exposing Client Interface

While the `listen_address` parameter corresponds to node-to-node Cassandra connections, `rpc_address` parameter corresponds to the client connections (e.g. cqlsh) and is limited to localhost by default. Cassandra documentation warns about exposing of this interface, but for testing purposes it can be done by setting `rpc_address` to the public ip or `0.0.0.0`.

## License

The Apache Cassandra Snap is free software, distributed under the Apache Software License, version 2.0. See [LICENSE](LICENSE) for more information.

## Trademark Notice

Apache Cassandra and the Apache Cassandra logo are trademarks of the Apache Software Foundation. All other trademarks are the property of their respective owners.
