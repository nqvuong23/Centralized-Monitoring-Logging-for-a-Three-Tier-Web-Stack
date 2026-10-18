# CLAUDE.md — Observation Project

## 1. What this project is

A small lab that practises **centralised monitoring and log collection** on
Linux. Six VMs run a normal web stack, a client injects load, and the whole
project is about observing that stack: watching metrics in Zabbix, reading
logs in Grafana Loki, finding root causes, and comparing every run with a
baseline.

The stack itself is on purpose simple. The value of this project is the
observation work, not the architecture.

## 2. Three core rules

1. **English everywhere.** All code, config files, comments, commit messages
   and Markdown documents are written in simple English (CEFR B1–B2). Short
   sentences, common words, no idioms. Chat with the user may be in
   Vietnamese, but nothing written into a file is.
2. **Comments: 1 to 3 lines, only where they help.** Comment every function if it is necessary,
   and any line whose *reason* is not obvious (a magic number, a tuning value,
   a workaround). Never comment what the code already says.
   Good: `# inter 2s, fall 3 -> a dead node is detected in about 6 seconds.`
   Bad: `# restart nginx` above `systemctl restart nginx`.
3. **Explicit over clever.** Write code and config that is easy to debug.
   Full flag names, named variables, one step per line. No dense one-liners,
   no chained shortcuts, no regex where a plain string works. If a reader has
   to stop and decode a line, rewrite the line.

## 3. Scope

**In scope**

- Zabbix: agents, templates, items, triggers, dashboards.
- Logging: rsyslog → Grafana Alloy → Loki → Grafana.
- Load scenarios with k6, and the analysis of each run.
- A minimal Nginx + PHP-FPM + MySQL application that gives something to watch.

**Out of scope — do not add these**

- ELK / OpenSearch, Kafka, Prometheus, any clustered or distributed setup.
- High availability, keepalived, MySQL replication, TLS, firewall design.
- Ansible or any configuration management. Services are configured by hand.
- A frontend, a web UI, user accounts, or real business logic.
- Container runtimes. Everything runs directly on the VMs.

If a task seems to need something from this list, stop and ask the user first.

## 4. Lab topology

Two interfaces per VM, and nothing more:

| NIC | Type | Address | Purpose |
|-----|------|---------|---------|
| NIC 1 | NAT, assigned by Vagrant | DHCP | internet for `apt`, and the `vagrant ssh` path |
| NIC 2 | host-only, lab network | `192.168.10.0/24`, static | all traffic between the lab hosts |

One flat lab network. No subnets, no routing, no firewall rules. Every service
binds to its `192.168.10.x` address, so the NAT interface only carries package
downloads and SSH from the host machine.

| Host | Role | vCPU | RAM | IP |
|------|------|------|-----|-----|
| `lb01` | HAProxy load balancer | 2 | 1 GB | 192.168.10.10 |
| `web01` | Nginx + PHP-FPM | 2 | 1 GB | 192.168.10.20 |
| `web02` | Nginx + PHP-FPM | 2 | 1 GB | 192.168.10.30 |
| `db01` | MySQL 8.0 | 2 | 1.5 GB | 192.168.10.40 |
| `mon01` | Zabbix server + frontend, Loki, Alloy, Grafana | 2 | 4 GB | 192.168.10.100 |
| `mgmt01` | k6 load generator, admin workstation | 2 | 1 GB | 192.168.10.111 |

**Monitored hosts:** `lb01`, `web01`, `web02`, `db01`, and `mon01`. Each of
the five runs a **Zabbix agent 2** and forwards its logs with **rsyslog**.
Only `mon01` runs **Grafana Alloy**, Loki and Grafana.

`lb01`, `web01`, `web02` and `db01` are the system under test. `mon01` is in
scope because it holds Loki and the Zabbix database: if its disk fills up, all
monitoring stops and no alert is sent. Keep its item set small: CPU, memory,
and disk space on `/` and `/var/lib/loki`.

`mgmt01` is **not** monitored and ships no logs. It only runs k6. Its health
is checked by hand during a run, with the `dropped_iterations` counter from
the k6 summary and a `vmstat` capture saved in the run folder.

## 5. Software

| Area | Choice |
|------|--------|
| Host platform | VMware Workstation, managed by Vagrant |
| Guest OS | Ubuntu Server 24.04 LTS on every VM |
| Load balancer | HAProxy 2.8 |
| Web | Nginx 1.24 + PHP-FPM 8.3 |
| Database | MySQL 8.0 |
| Metrics | Zabbix 7.0 LTS (server, frontend, agent 2) |
| Logs | rsyslog forward on each monitored host → one Grafana Alloy on mon01 → Loki 3.x → Grafana 11.x |
| Load tool | k6 |

Pin these versions. Do not upgrade a component in the middle of a scenario
series, because it breaks the comparison with the baseline.

## 6. Repository layout

```
CLAUDE.md                  this file
README.md                  what the project is, how to start, results summary
Vagrantfile                VM definitions only
docs/
  01-test-scenarios.md     the load scenarios and the run protocol
  02-app-stack.md          the application, the configs, the k6 scripts
  03-build-log.md          how the lab was built, step by step
configs/                   a copy of every config file, by host
  lb01/  web01/  web02/  db01/  mon01/
app/                       the PHP application source
  api/  lib/
load/                      k6 scripts
  lib/
runs/                      one folder per test run (evidence, never edited later)
  run-20261020-1430-s1-ramp/
    notes.md  k6-summary.json  k6-run.log  k6-console.log
    client-vmstat.log  graphs/
```

## 7. How work is done in this lab

- **Vagrant manages VM lifecycle only**: `up`, `halt`, `snapshot`, `destroy`.
  It does not configure services. Keep the `Vagrantfile` free of long
  provisioning shell blocks.
- **Services are configured by hand over SSH.** That is a deliberate learning
  choice, not laziness. Every manual step is written down in
  `docs/03-build-log.md` on the same day it is done.
- **Every config file is copied into `configs/<host>/`** after it works, with
  the same filename as on the VM. The repository must be enough to rebuild the
  lab from zero.
- **Snapshots are the undo button.** Keep a snapshot named `clean-stack`: all
  services running, smoke test passed, no load applied. Restore it before each
  scenario.
- **One change per experiment.** Change one value, run the same load, compare.
  Two changes in one run means no usable result.
- **`runs/` is write-once.** After a run is documented, its folder is evidence
  and is not edited again.

## 8. Naming and conventions

- Host names are short and lower case: `lb01`, `web01`. The system hostname,
  the Zabbix host name, and the Loki `host` label must be identical.
- Run folders: `run-<YYYYMMDD-HHMM>-<scenario-id>`, for example
  `run-20261020-1430-s1-ramp`.
- Scenario IDs are `s0` to `s5`, as defined in `docs/01-test-scenarios.md`.
- Config file names follow the distribution style:
  `/etc/rsyslog.d/10-forward.conf`, `/etc/nginx/conf.d/app.conf`.
- Shell scripts: `#!/bin/bash`, then `set -euo pipefail`. Long flags
  (`--quiet`, not `-q`). Quote every variable.
- Lab credentials are weak on purpose and are listed in the docs. Never reuse
  them anywhere else, and never claim this setup is secure.

## 9. Log and metric conventions

rsyslog on each monitored host forwards everything to `mon01` over TCP, with a
disk-assisted queue. rsyslog on `mon01` writes one file per host and per log
source under `/var/log/remote/<host>/<source>.log`. **One** Grafana Alloy
instance, on `mon01`, tails those files and pushes them to Loki.

`mon01` forwards to itself, so every host uses the same forwarding config and
every log ends up in the same layout. The log agent is central and not per
host because the 1 GB nodes have no memory to spare for an agent, and scenario
S1 measures exactly that memory. See `docs/02-app-stack.md` section 7.2.

| Source | How rsyslog gets it | Loki `job` |
|--------|--------------------|-----------|
| HAProxy | syslog, facility `local0` | `haproxy` |
| PHP application | syslog, `local1`, tag `app` | `app` |
| MySQL slow query log | `imfile`, `local2`, tag `mysql_slow` | `mysql_slow` |
| MySQL error log | syslog, tag `mysqld` | `mysql_error` |
| Zabbix server log | `imfile`, `local3`, tag `zabbix_server` | `zabbix_server` |
| PHP-FPM error and slow log | `imfile`, `local5`, tag `phpfpm` | `phpfpm` |
| Nginx | syslog, `local6`, tags `nginx_access` / `nginx_error` | `nginx_access`, `nginx_error` |
| OS, kernel, services | normal syslog | `syslog` |

Rules:

- **Loki labels are only `host` and `job`.** Never add a label that has many
  values, such as a request ID, a URL, or a status code. Everything else is
  parsed at query time with `| json`.
- **Machine-readable logs are JSON**, one line per event (Nginx access log and
  the application log). HAProxy keeps its native log format, because reading
  its timer fields is a skill worth practising.
- **Every request carries an `X-Request-Id`**, created by HAProxy and passed
  down to Nginx and PHP. One ID must find the same request in all three logs.
- **Zabbix item intervals** are 1 minute by default, and 10 seconds only for
  metrics that change in seconds (CPU, connections, queues). Record the reason
  when you shorten an interval.

## 10. Documentation rules

- Every scenario document follows the structure in
  `docs/01-test-scenarios.md`: goal, run, what to watch, what to look for in
  the logs, expected finding, fix, before-and-after table.
- Every claim needs evidence: a metric name, a graph, or a log line. Write
  "p95 grew from 48 ms to 2,100 ms", not "it was slow".
- A scenario is **done** when all of this exists:
  1. A hypothesis written before the run.
  2. The client sanity check passed: the k6 `dropped_iterations` counter and
     the `vmstat` capture show the load generator kept up. A run that fails
     this check is thrown away, not explained.
  3. Zabbix graphs for the metric set.
  4. The LogQL queries used, and the log lines that prove the cause.
  5. A root cause in one paragraph.
  6. One fix, with the value chosen and the reason.
  7. A filled before-and-after table against the baseline.
  8. Two or three sentences of lessons learned.
- Keep the README short: the diagram, how to start the lab, and a results
  table with one line per scenario.

## 11. Working with the user

- The user is a student who already knows HAProxy, Nginx and MySQL, and is new
  to Zabbix and Loki. Explain the observation tools in depth, and keep the
  application work minimal.
- Prefer the built-in and official way: official Zabbix templates, the
  distribution package, the default config file. No custom scripts where a
  template already provides the metric.
- When a choice has a trade-off (a check interval, a retention period, a
  worker count), state both sides in one or two sentences and recommend one.
  Those small notes are what make the project look professional.
- Before adding any new tool, library, or service to the lab, ask first.
