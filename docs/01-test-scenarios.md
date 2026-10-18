# Part 1 — Test Scenarios

This document describes the load scenarios of the lab. Each scenario has one
clear goal: create a problem on purpose, watch the metrics in Zabbix, read the
logs in Grafana Loki, find the root cause, fix it, and compare the numbers with
the baseline.

The lab has 6 VMs. Monitored hosts are `lb01`, `web01`, `web02`, `db01`, and
`mon01`. Each of the five runs a Zabbix agent and forwards its logs with
rsyslog to `mon01`, where one Grafana Alloy instance pushes them to Loki. See
[CLAUDE.md](../CLAUDE.md) for the topology and
[02-app-stack.md](02-app-stack.md) for the application.

The first four hosts are the system under test. `mon01` is in scope because it
holds Loki and the Zabbix database, so a full disk there stops all monitoring
with no alert. Scenario S5 uses that fact.

`mgmt01` runs the k6 load generator and is **not** monitored. It is still the
**instrument** of every measurement, and an instrument has to be checked
before you trust its reading. Section 2.2 is that check, done by hand.

---

## 1. What each scenario proves

| # | Scenario | Main layer | Skill it proves |
|---|----------|-----------|-----------------|
| S0 | Baseline | all | Measure a healthy system before you change anything |
| S1 | Sustained high load | CPU / worker pool | Find the capacity limit and the first bottleneck |
| S2 | Microburst traffic | monitoring design | Understand sampling interval, avg vs max |
| S3 | One backend fails | service / health check | Failure detection, health check design, time to detect |
| S4 | Slow query + connection limit | database | Query tuning, log correlation, resource math |
| S5 | Disk fills up from log flood | storage / logging | Proactive alerting, protect the log pipeline |

Scenario S0 is the baseline and does not count as one of the five scenarios.

---

## 2. Standard run protocol

Every scenario follows the same steps. This makes the results comparable.

1. **Start clean.** Restore the VM snapshot `clean-stack`, then wait until
   Zabbix shows no problem and Grafana shows new log lines from all five
   monitored hosts.
2. **Create a run folder.** `runs/run-<YYYYMMDD-HHMM>-<scenario-id>/`
   Example: `runs/run-20261020-1430-s1-ramp/`.
3. **Write your hypothesis first** in `notes.md`, before you start the load.
   One or two sentences: what will break first, and why. This is the most
   valuable habit in the whole project.
4. **Note the exact start time** (local and UTC). You need it to align the
   Zabbix graph with the Loki query window.
5. **Run the load** from `mgmt01`, and keep every client file in the run
   folder. `mgmt01` sends nothing to Loki, so these files are the only client
   evidence you will ever have:

   ```bash
   cd /lab/runs/run-20261020-1430-s1-ramp

   vmstat 5 > client-vmstat.log &
   vmstat_pid=$!

   k6 run --log-output=file=k6-run.log --log-format=json \
          /lab/load/ramp.js 2>&1 | tee k6-console.log

   kill "$vmstat_pid"
   ```

6. **Watch during the run.** Keep the Zabbix dashboard and the Grafana log
   panel open. Write down what you see at the moment it changes, not later.
7. **Run the client sanity check** (section 2.2) **before you read any
   server result.**
8. **After the run**, collect the evidence:
   - Zabbix graphs (PNG) for the metric set below.
   - The LogQL queries you used, and their output.
   - The filled comparison table.
9. **Apply one fix only**, then repeat the same load and compare. Changing two
   things at the same time destroys the result.

### 2.1 The metric set

Record these values for every run. "Peak" means the highest 1-minute average
inside the load window, unless the scenario says something else.

**Client side (k6, on `mgmt01`)**

| Metric | k6 field |
|--------|----------|
| Requests per second | `http_reqs` rate |
| Latency p50 / p95 / p99 | `http_req_duration` |
| Failed requests | `http_req_failed` |
| Dropped iterations | `dropped_iterations` |

**lb01 (HAProxy)**

| Metric | Where |
|--------|-------|
| CPU utilization | `system.cpu.util` |
| Requests per second (frontend) | HAProxy template, "Requests rate" |
| Backend queue, current | HAProxy template, backend `qcur` |
| HTTP 5xx responses | HAProxy template, `hrsp_5xx` |
| Server status up / down | HAProxy template, server status |

**web01 / web02 (Nginx + PHP-FPM)**

| Metric | Where |
|--------|-------|
| CPU utilization, iowait, load average | `system.cpu.util`, `system.cpu.util[,iowait]`, `system.cpu.load[all,avg1]` |
| Available memory | `vm.memory.size[available]` |
| Nginx active and waiting connections | Nginx template (stub_status) |
| Nginx requests per second | Nginx template |
| PHP-FPM active processes and listen queue | PHP-FPM status page, see 02-app-stack.md |

**db01 (MySQL)**

| Metric | Where |
|--------|-------|
| CPU utilization and iowait | `system.cpu.util`, `system.cpu.util[,iowait]` |
| Available memory, free swap | `vm.memory.size[available]`, `system.swap.size[,pfree]` |
| Disk write await | `vfs.dev.write.await[sda]` |
| Threads connected and running | MySQL template |
| Queries per second | MySQL template |
| Slow queries per second | MySQL template |
| InnoDB buffer pool utilization | MySQL template |

**mon01 (the monitoring host itself)**

| Metric | Where |
|--------|-------|
| CPU utilization | `system.cpu.util` |
| Available memory | `vm.memory.size[available]` |
| Free space on `/` | `vfs.fs.size[/,pfree]` |
| Free space on `/var/lib/loki` | `vfs.fs.size[/var/lib/loki,pfree]` |

Read `mon01` as a background check, not as a result. It answers one question:
"can this host still store what the other four send me?"

**Log side (Loki)**

| Metric | LogQL |
|--------|-------|
| HTTP 5xx per minute | `sum(count_over_time({job="nginx_access"} \| json \| status >= 500 [1m]))` |
| Application error lines | `sum by (host) (count_over_time({job="app", level="error"} [1m]))` |
| Log volume per host | `sum by (host) (bytes_over_time({job="syslog"} [1h]))` |
| Monitoring problems | `{host="mon01", job="zabbix_server"} \|= "error"` |

> Check the exact Zabbix item keys in **Monitoring → Latest data** after you
> link the templates. Template item names change a little between Zabbix
> versions, so always confirm instead of copying a key blindly.

### 2.2 The client sanity check: is the measurement valid?

`mgmt01` is outside the monitoring scope, so this check is manual. Do it
**before** you read any server result. It does not describe the stack, it
describes whether you are allowed to believe the run at all.

Start the sampler in the same command as the load:

```bash
vmstat 5 > client-vmstat.log &
vmstat_pid=$!

k6 run --log-output=file=k6-run.log --log-format=json \
       /lab/load/ramp.js 2>&1 | tee k6-console.log

kill "$vmstat_pid"
```

| Check | Source | Pass | Fail means |
|-------|--------|------|-----------|
| `dropped_iterations` | k6 summary | 0 | k6 wanted to send requests and could not start them |
| Idle CPU (`id` column) | `client-vmstat.log` | above 30% | the client could not keep up: your "limit" is the client's limit |
| Free memory (`free`) and swap (`si`/`so`) | `client-vmstat.log` | swap stays at 0 | k6 is close to being killed by the kernel; `maxVUs` is too high |
| k6 warnings | `k6-run.log` | no "insufficient VUs" | the arrival rate was never reached |

If any check fails, the run is **invalid**. Do not explain the numbers, and do
not put them in a comparison table. Fix the client and run again:

- Lower `maxVUs`, or raise the RAM of `mgmt01`, or both.
- Write the failed run in the notes anyway, as one line. "Run 1 was invalid:
  the client saturated at 480 rps" is an honest and professional result, and a
  much better interview story than a clean number you cannot defend.

**Find the client ceiling once**, before the real runs. Raise the rate against
`/api/health.php` only (no database work, so the servers stay almost idle)
until the client checks above start to fail. That number is the ceiling of
your whole test rig. Write it in the README and keep every scenario well
below it.

> Why not put a Zabbix agent on `mgmt01` too? Because the client is not part
> of the system being observed, and mixing it into the dashboards invites you
> to report client numbers as if they were results. Keeping it out, and
> checking it by hand with files in the run folder, keeps the two roles clear.

---

## 3. S0 — Baseline (reference run, not counted)

**Goal.** Know what "healthy" looks like. Without this number, every later
result is only a feeling.

**Load.** Constant arrival rate, 50 requests per second, 10 minutes, 80% read
and 20% write (`load/baseline.js`).

```bash
# On mgmt01
k6 run load/baseline.js
```

**Expected result.** No errors at all. p95 latency stays flat for the whole 10
minutes. CPU on the web nodes stays well under 50%.

**What to write down.** The full metric set. Put it in
`runs/<run-id>/baseline.md` and copy the table into every later scenario
document, so the comparison is always visible.

**Checklist before you accept a baseline**

- [ ] Error rate is 0%.
- [ ] p95 is stable (the graph is a flat line, not a slope).
- [ ] Both web nodes get about the same number of requests (round robin works).
- [ ] Logs from all five hosts arrive in Loki, with no gap.
- [ ] No Zabbix problem is active.
- [ ] The client sanity check passed. At 50 requests per second the client
      should be almost idle. If it is already busy here, every later scenario
      is built on sand, so fix it now.

Keep `client-vmstat.log` from the baseline run as well. It is the reference
for "the client is idle", and it makes the later checks easy to judge.

If any item fails, fix the lab first. Do not run the scenarios on a broken
baseline.

---

## 4. S1 — Sustained high load: find the capacity limit

**Story.** The team wants to know how many requests per second the system can
serve before users feel pain. Nobody knows the limit, so you measure it.

**Goal.** Find the "knee point": the load level where latency starts to grow
fast while throughput stops growing. Then find which resource causes it.

### 4.1 Run

Ramping arrival rate from 20 to 600 requests per second over 15 minutes, then
hold 5 minutes at the level where it broke (`load/ramp.js`).

```bash
k6 run load/ramp.js
```

### 4.2 What to watch in Zabbix

Open one dashboard with these graphs side by side:

- k6 reported RPS against p95 latency (from the k6 summary).
- `web01` and `web02` CPU utilization.
- Nginx active and waiting connections.
- PHP-FPM active processes.
- HAProxy backend queue (`qcur`) and session rate.
- `db01` CPU and threads running.
**A ramp test has two possible knees, and they look the same in the k6
summary.** Telling them apart is the whole skill here:

| What you see | What it means |
|--------------|---------------|
| Server CPU or queue grows, client stays idle in `client-vmstat.log` | a real server limit: this is the result you want |
| Client idle CPU falls towards 0, servers still calm | you measured your own client; the run is invalid |

This is why the client sanity check of section 2.2 runs before you read the
server graphs, and why the client ceiling is measured once in advance.

### 4.3 What to look for in Loki

```logql
# Latency per host, from the Nginx JSON access log
quantile_over_time(0.95,
  {job="nginx_access"} | json | unwrap request_time [1m]) by (host)

# Where the time is spent: Nginx itself, or the PHP-FPM upstream
quantile_over_time(0.95,
  {job="nginx_access"} | json | unwrap upstream_response_time [1m]) by (host)

# The classic worker pool warning
{job="phpfpm"} |= "reached pm.max_children"

# Nginx gives up on the upstream
{job="nginx_error"} |= "upstream timed out"
```

The client side is not in Loki. Read `k6-run.log` in the run folder instead:

```bash
grep -i insufficient k6-run.log
```

### 4.4 Expected finding

In most cases the PHP-FPM worker pool fills up **before** the CPU reaches
100%. The chain is:

1. All `pm.max_children` workers are busy.
2. New requests wait in the PHP-FPM listen queue, so `upstream_response_time`
   grows while CPU stays under 100%.
3. Nginx hits `fastcgi_read_timeout` and returns 504, or the HAProxy `maxconn`
   per server is reached and the backend queue grows.
4. k6 p95 jumps from tens of milliseconds to seconds.

The lesson: **a queue, not the CPU, is usually the first bottleneck.** The
proof is "workers busy = workers available" together with a CPU that is not
yet saturated.

### 4.5 Fix and verify

Raise the pool size with a simple memory budget:

```
pm.max_children = (RAM available for PHP) / (average worker memory)
```

Measure the average worker memory during the run:

```bash
ps -o rss= -C php-fpm8.3 | awk '{ sum += $1 } END { print sum / NR / 1024, "MB" }'
```

Keep about 300 MB for the OS and Nginx, set the new value, reload PHP-FPM, and
run the exact same `load/ramp.js` again.

### 4.6 Comparison table

| Metric | Baseline (50 rps) | Run 1 (before fix) | Run 2 (after fix) |
|--------|------------------|--------------------|-------------------|
| Knee point (rps) | – | | |
| Max stable rps (p95 < 500 ms) | – | | |
| p95 at knee (ms) | | | |
| Error rate at knee (%) | 0 | | |
| web CPU at knee (%) | | | |
| PHP-FPM workers busy / max | | | |
| HAProxy backend queue (peak) | 0 | | |
| db01 threads running (peak) | | | |
| Client idle CPU at knee (%) | | | |
| k6 dropped iterations | 0 | 0 | 0 |

**CV sentence.** "Measured the capacity limit of the stack with k6 and Zabbix,
proved from PHP-FPM pool metrics and Nginx `upstream_response_time` that the
worker pool, not the CPU, was the bottleneck, and raised stable throughput
from X to Y requests per second, with a client-side check on every run to show
the limit was the server's and not the test tool's."

---

## 5. S2 — Microburst: why a 1-minute average lies

**Story.** Users complain about short freezes a few times per hour, but the
Zabbix CPU graph looks calm. Management says "the monitoring says it is fine".
You have to prove that the monitoring itself is not good enough.

**Goal.** Show that a monitoring system can hide a real problem when the
sampling interval is longer than the event, then fix the monitoring design.

### 5.1 Run

Ten cycles of: 10 seconds at 500 requests per second, then 50 seconds at 20
requests per second (`load/microburst.js`). Total about 10 minutes.

```bash
k6 run load/microburst.js
```

### 5.2 Prepare the measurement before the run

This scenario is about monitoring design, so build the comparison on purpose:

1. Clone the CPU item of `web01` two times, with update intervals of `1m` (the
   template default), `10s`, and `1s`.
2. Create three triggers on the same data:
   - `avg(/web01/system.cpu.util,5m)>80`
   - `avg(/web01/system.cpu.util,1m)>80`
   - `max(/web01/system.cpu.util,1m)>80`
3. Put the three items in one Zabbix graph, so the difference is visible in one
   picture.
4. Decide how you will prove the **input** was really a burst. A client that
   needs 4 seconds to reach 500 requests per second did not send a 10-second
   burst, it sent a slope, and then the whole argument falls apart. The client
   has no agent, so the proof comes from the Nginx access log, which records
   every single request with its own timestamp:

   ```logql
   # Requests per second, straight from the access log
   sum(count_over_time({job="nginx_access"} [1s]))
   ```

   Measure the rise time on that graph: how many seconds from 20 requests per
   second to 500. If it is above 2 seconds, lower the burst rate until the
   client can produce a sharp edge.

> This is a nice result of logging every request: the log is a better record
> of the input than any sampled metric could be, because it is not sampled at
> all. The Zabbix item is a measurement of the server; the access log is a
> measurement of what actually arrived.

### 5.3 Expected finding

| What you look at | What it shows during a burst |
|------------------|------------------------------|
| CPU item, 1 minute interval | around 30–40%: looks healthy |
| CPU item, 1 second interval | peaks near 100% |
| Trigger with `avg(...,5m)` | never fires |
| Trigger with `max(...,1m)` | fires on every burst |
| Nginx access log in Loki | clear spikes, and 499 / 502 lines |

LogQL, at a 10-second resolution that Zabbix misses:

```logql
# Request rate in 10-second windows: the burst is obvious here
sum by (host) (count_over_time({job="nginx_access"} [10s]))

# Latency inside the burst
quantile_over_time(0.99,
  {job="nginx_access"} | json | unwrap request_time [10s]) by (host)

# Clients that gave up before the answer came (Nginx status 499)
sum(count_over_time({job="nginx_access"} | json | status = 499 [1m]))

# HAProxy termination state: sQ means "died in the queue"
{job="haproxy"} |= "sQ"
```

Also read the HAProxy timers in the log line (`%TR/%Tw/%Tc/%Tr/%Ta`). During a
microburst, `Tw` (time waiting in the queue) is the field that grows, while
`Tr` (server response time) stays small. That single fact tells you the
servers were fast but the queue was full.

**Optional extra.** Check the kernel TCP accept queue on `web01` before and
after the run:

```bash
nstat -az TcpExtListenDrops TcpExtListenOverflows
```

A value above zero proves that connections were dropped before Nginx even saw
them. You can add this as a Zabbix user parameter.

### 5.4 Fix: change the monitoring, not the system

The system is not broken here, the monitoring is. Document a decision:

| Item | New interval | Why |
|------|-------------|-----|
| CPU utilization | 10s | Short spikes must be visible |
| Nginx connections | 10s | Queue growth happens in seconds |
| Disk space | 5m | It changes slowly, 1m is a waste |
| Triggers on spiky metrics | `max()`, not `avg()` | An average hides the peak |

Then write the cost side in one sentence: a 10-second interval creates six
times more history rows than a 1-minute interval, so use it only on the items
where the speed matters.

### 5.5 Comparison table

| Metric | Baseline | Microburst run |
|--------|----------|----------------|
| k6 average rps | 50 | about 100 |
| k6 p95 / p99 (ms) | | |
| Error rate (%) | 0 | |
| CPU peak, 1m item (%) | | |
| CPU peak, 1s item (%) | | |
| Burst rise time, from the access log (s) | – | |
| Triggers that fired | none | |
| HAProxy `Tw` peak (ms) | | |
| 499 + 5xx count in logs | 0 | |

**CV sentence.** "Showed that a 1-minute polling interval hid CPU peaks of
about 100%, and redesigned the Zabbix items and trigger functions (`max()`
instead of `avg()`) so that 10-second bursts became visible."

---

## 6. S3 — One backend fails under load

**Story.** During a busy period, one web node stops serving. You must detect
it, measure how long detection takes, and check that the users are protected.

**Goal.** Compare two very different failures, and learn why the health check
definition decides whether HAProxy can protect the users.

### 6.1 Run

Start a steady load at about 70% of the knee point from S1, then inject the
failure after 3 minutes.

```bash
k6 run load/steady.js --env RPS=<value>
```

**Case A — the whole web server stops**

```bash
# On web02, 3 minutes after the load starts
sudo systemctl stop nginx
# After 3 more minutes
sudo systemctl start nginx
```

**Case B — only PHP-FPM stops, Nginx keeps running**

```bash
# On web02
sudo systemctl stop php8.3-fpm
```

### 6.2 Expected finding

| | Case A (Nginx down) | Case B (PHP-FPM down) |
|---|---|---|
| TCP port 80 on web02 | closed | open |
| HAProxy with a *static file* health check | marks web02 DOWN | keeps web02 UP (bad) |
| HAProxy with an *application* health check | marks web02 DOWN | marks web02 DOWN (good) |
| What the user sees | short failover, then normal | about 50% of requests get HTTP 502 |

Case B is the important lesson: a health check on a static file only proves
that Nginx can read a file. The application path was dead, HAProxy was happy,
and half of the traffic was lost. This is why the lab checks
`GET /api/health.php`.

### 6.3 Logs to read

```logql
# HAProxy decides the server is down, and gives the reason
{job="haproxy"} |= "is DOWN"
{job="haproxy"} |= "is UP"

# Nginx cannot reach the PHP socket (case B)
{host="web02", job="nginx_error"} |= "php-fpm.sock"

# 502 answers counted on the web tier
sum(count_over_time({job="nginx_access"} | json | status = 502 [1m]))

# Traffic moves to the surviving node
sum by (host) (count_over_time({job="nginx_access"} [30s]))
```

### 6.4 Measure the time to detect

This is the number that makes the scenario strong:

```
TTD (HAProxy) = time of the "is DOWN" log line  - time of the systemctl stop
TTD (Zabbix)  = time the problem appears in Problems - time of the stop
```

With `default-server inter 2s fall 3`, HAProxy needs about 6 seconds. Zabbix
with a 1-minute interval needs up to about 1 minute, plus the trigger window.
Explain the trade-off: faster checks detect faster, but they add load and can
cause false alarms during a short network problem.

### 6.5 Comparison table

| Metric | Baseline | Case A | Case B (static check) | Case B (app check) |
|--------|----------|--------|-----------------------|--------------------|
| Error rate (%) | 0 | | | |
| Failed requests (count) | 0 | | | |
| p95 after failover (ms) | | | | |
| web01 CPU after failover (%) | | | | |
| TTD HAProxy (s) | – | | | |
| TTD Zabbix (s) | – | | | |
| 5xx lines in logs | 0 | | | |

### 6.6 Fix and note

- Use a health check that goes through Nginx **and** PHP: `/api/health.php`.
- Keep the health check free of a database query, and write down why: if the
  check needs the database, one database hiccup marks *all* web nodes down and
  turns a small problem into a full outage. A separate deep check
  (`/api/health.php?deep=1`) is monitored by Zabbix, but is never used for
  routing.

**CV sentence.** "Proved with HAProxy logs and Zabbix that a file-based health
check kept a broken node in rotation and lost about 50% of requests, and fixed
detection by checking the real application path; time to detect dropped from
about 60 s to about 6 s."

---

## 7. S4 — Slow query and connection limit on the database

**Story.** A new search feature was released. Page loads are slow, but the web
nodes are almost idle. The database is the suspect.

**Goal.** Walk the full path: metric → log → query plan → fix → measure again.
Then show that a connection limit is a maths problem, not a mystery.

### 7.1 Phase A: the slow query

Seed about 500,000 rows (see 02-app-stack.md), then run a moderate load against
`/api/search.php`, which filters on a column with no index.

```bash
k6 run load/search.js
```

**Metrics.** `db01` CPU high and `web01` / `web02` CPU low. That split alone
points at the database. Also watch slow queries per second, threads running,
InnoDB rows read per second, and disk read await.

**Logs.**

```logql
# The MySQL slow query log, forwarded by rsyslog
{job="mysql_slow"}

# Slow queries per minute
sum(count_over_time({job="mysql_slow"} |= "Query_time" [1m]))

# Which URI is slow, seen from the Nginx side
topk(5, sum by (uri) (
  count_over_time({job="nginx_access"} | json | request_time > 1 [5m])))

# Follow one single request through all three tiers
{job=~"haproxy|nginx_access|app"} |= "<request id from the response header>"
```

**Confirm the cause.** On `db01`:

```sql
EXPLAIN SELECT id, created_at, payload FROM events
WHERE event_type = 'login' AND payload LIKE '%abc%'
ORDER BY created_at DESC LIMIT 20;
```

You should see `type: ALL` and a row count close to the whole table. The slow
log shows the same thing in its `Rows_examined` field.

**Fix.**

```sql
ALTER TABLE events ADD INDEX idx_type_created (event_type, created_at);
```

Run the same load again and compare.

| Metric | Baseline | Before index | After index |
|--------|----------|--------------|-------------|
| p95 of `/api/search.php` (ms) | | | |
| `Rows_examined` per query | | | |
| Slow queries per second | 0 | | |
| db01 CPU (%) | | | |
| db01 disk read await (ms) | | | |
| Max rps with p95 < 500 ms | | | |

### 7.2 Phase B: the connection limit

Set `max_connections = 40` on `db01` on purpose, then raise the load.

**Metrics.** `threads_connected` stops exactly at the limit, and the aborted
connects counter starts to grow. CPU is **not** high: that is the clue. This
is a resource limit, not a resource shortage.

**Logs.**

```logql
# The application error message, with the MySQL error text
{job="app", level="error"} |= "Too many connections"

# The same failure seen one tier higher
{job="nginx_error"} |= "FastCGI sent in stderr"
```

**The maths.** The real root cause is a sizing mistake:

```
2 web nodes x pm.max_children 30 = up to 60 database connections
MySQL max_connections = 40  ->  20 connections are refused
```

**Fix.** Make the two numbers agree. Either lower `pm.max_children`, or raise
`max_connections` to a value the RAM can support:

```
max_connections x memory per connection + innodb_buffer_pool_size < total RAM
```

Write the chosen numbers and the reason in the run notes. This small table is
exactly what a system engineer is paid to produce.

| Metric | Before | After |
|--------|--------|-------|
| `max_connections` | 40 | |
| `pm.max_children` per node | 30 | |
| Threads connected (peak) | | |
| Aborted connects per second | | |
| Error rate (%) | | |
| "Too many connections" log lines | | 0 |

**CV sentence.** "Found an unindexed query with the MySQL slow log in Loki and
`EXPLAIN`, cut p95 from X ms to Y ms with one index, and fixed connection
refusals by sizing PHP-FPM workers against MySQL `max_connections`."

---

## 8. S5 — Disk fills up because of a log flood

**Story.** Somebody enabled debug logging on `web01` and forgot it. Two hours
later the node behaves strangely, and, worse, `web01` disappears from the log
dashboard.

**Goal.** Show proactive alerting (warn *before* the disk is full), and show
that the log pipeline needs monitoring too.

### 8.1 Prepare a small filesystem

A 20 GB disk takes too long to fill, so give `/var/log` its own small
filesystem on `web01`:

```bash
# Create a 1 GB file and format it as a filesystem
sudo fallocate -l 1G /var/logdisk.img
sudo mkfs.ext4 /var/logdisk.img

# Copy the current logs into it, then mount it over /var/log
sudo mkdir -p /mnt/logdisk
sudo mount -o loop /var/logdisk.img /mnt/logdisk
sudo cp -a /var/log/. /mnt/logdisk/
sudo umount /mnt/logdisk
sudo mount -o loop /var/logdisk.img /var/log
sudo systemctl restart rsyslog nginx php8.3-fpm
```

Add a Zabbix item and two triggers for this mount point:

```
Item:    vfs.fs.size[/var/log,pfree]        interval 1m
Item:    vfs.fs.size[/var/log,free]         interval 1m
Trigger: last(/web01/vfs.fs.size[/var/log,pfree])<10
Trigger: timeleft(/web01/vfs.fs.size[/var/log,free],30m,0)<1h
```

The `timeleft()` trigger is the interesting one: it uses the trend of the last
30 minutes to predict when the disk will reach zero. That is the difference
between an alarm and a prediction.

### 8.2 Run

```bash
# On web01: simulate the bad change
sudo sed -i 's|error_log /var/log/nginx/error.log warn;|error_log /var/log/nginx/error.log debug;|' /etc/nginx/nginx.conf
sudo nginx -t && sudo systemctl reload nginx
sudo systemctl stop logrotate.timer

# On mgmt01
k6 run load/steady.js
```

### 8.3 Expected finding, in this order

1. Free space falls in a straight line. The `timeleft()` trigger fires while
   there is still space, so you have time to act.
2. The low-space trigger fires at 10%.
3. At 0% the real damage starts:
   - Nginx: `write() ... failed (28: No space left on device)`
   - rsyslog cannot write its local copy, and its forward queue stops
   - PHP-FPM cannot write its error log
4. **`web01` stops appearing in Loki.** The failure made you blind exactly
   when you needed the logs most.

```logql
# Log volume per host per hour: find who floods
sum by (host) (bytes_over_time({job="syslog"} [1h]))

# The disk-full message
{host="web01"} |= "No space left on device"

# Was anything received from web01 in the last 5 minutes?
sum(count_over_time({host="web01"} [5m]))
```

### 8.4 The dead man's switch

A monitoring system must also notice silence. Add in Zabbix, on `web01`:

```
Trigger: nodata(/web01/agent.ping,3m)=1
```

and in Grafana, a panel with
`sum by (host) (count_over_time({job="syslog"} [5m]))` for the five monitored
hosts. An empty line is an alarm, not an empty graph.

**Now do the same for the monitoring host.** `mon01` is in scope for exactly
this reason: a flood on `web01` is also a flood arriving at Loki, so the same
event grows `/var/lib/loki` on `mon01`. Watch both ends during this scenario:

```
Trigger: last(/mon01/vfs.fs.size[/var/lib/loki,pfree])<15
Trigger: timeleft(/mon01/vfs.fs.size[/var/lib/loki,free],1h,0)<4h
```

```logql
# The Loki and Zabbix server side of the same flood
{host="mon01", job="syslog"} |= "loki"
{host="mon01", job="zabbix_server"} |= "error"
```

With central forwarding, a full disk on `mon01` has **two** effects, and this
scenario is the place to see both:

1. `/var/log/remote` can no longer be written, so rsyslog on `mon01` stops
   storing what the other hosts send. Their own forward queues fill up next,
   under `/var/spool/rsyslog`, and after 100 MB they start dropping.
2. `/var/lib/loki` can no longer be written, so Alloy gets an error on every
   push and retries. Nothing is queried any more, and no alert says so.

Check both during the run:

```bash
# On mon01: is collection still writing?
ls -l --human-readable /var/log/remote/web01/

# On web01: is the forward queue growing?
ls -l /var/spool/rsyslog/
```

A `mon01` disk alert has to fire **before** that point, which is why it uses
`timeleft()` with a wider window than the `web01` one. The forward queue is a
delay, not a safety net: it buys minutes, then loses the oldest data.

> Honest limit: `mon01` monitors itself. That works for a slow problem such as
> a disk filling up, which is the common case. It cannot catch `mon01` failing
> completely, because then nothing is left to send the alert. In real work the
> answer is a check from outside; for a lab of this size, saying so clearly is
> enough.

### 8.5 Fix and verify

1. Put the log level back to `warn`, and write down the measured cost of
   `debug` (MB per hour at the same load).
2. Add a size-based logrotate rule, so a flood does not have to wait for
   midnight:

```
/var/log/nginx/*.log {
    size 50M
    rotate 5
    compress
    missingok
    notifempty
    sharedscripts
    postrotate
        [ -f /run/nginx.pid ] && kill -USR1 $(cat /run/nginx.pid)
    endscript
}
```

3. Set a retention period in Loki (`retention_period: 168h`), so the
   monitoring node cannot fill up either.
4. Re-run and show that the straight line is gone.

### 8.6 Comparison table

| Metric | Baseline (`warn`) | Flood (`debug`) | After fix |
|--------|-------------------|-----------------|-----------|
| Log growth (MB per hour) | | | |
| Loki bytes ingested per hour | | | |
| Free space on web01 `/var/log` at the end (%) | | | |
| Free space on mon01 `/var/lib/loki` (%) | | | |
| First trigger that fired | – | | |
| Warning time before full (min) | – | | |
| Minutes with no logs from web01 | 0 | | 0 |
| Error rate (%) | 0 | | 0 |

**CV sentence.** "Built a predictive disk alert with the Zabbix `timeleft()`
function that warned N minutes before a log flood filled the filesystem, and
added a `nodata()` dead man's switch after proving in Loki that the node went
silent when the disk was full."

---

## 9. Optional variants (only if you have time)

These are not part of the five scenarios. Use them if you want one more story.

- **Out of memory on db01.** Set `innodb_buffer_pool_size` too high for the
  1.5 GB of RAM, run the search load, and watch available memory fall and swap
  grow. The kernel OOM killer stops `mysqld`, and the kernel message appears in
  Loki: `{host="db01"} |= "Out of memory"`. It teaches the difference between a
  memory metric and a memory failure.
- **Network latency with `tc netem`.** Add 100 ms of delay between `web01` and
  `db01`. The web CPU drops, the database CPU drops, but latency explodes: the
  picture of a system that is waiting, not working.

---

## 10. Report template for every run

Copy this into `runs/<run-id>/notes.md`.

```markdown
# <run-id>

- Scenario: S<n> - <name>
- Date and time (local / UTC):
- Load profile: <k6 script, rps, duration>
- Snapshot used: clean-stack
- Changes made before the run: <none, or config X = Y>

## 1. Hypothesis (written before the run)

## 2. Client sanity check (valid / invalid)
| Check | Source | Value | Pass |
|-------|--------|-------|------|
| k6 dropped_iterations | k6-summary.json | | |
| Client idle CPU, lowest (%) | client-vmstat.log | | |
| Swap in / out during the run | client-vmstat.log | | |
| "insufficient VUs" warnings | k6-run.log | | |

If this check failed, stop here and write one line about why. The rest of the
report is not valid.

## 3. What I observed
- Metrics (Zabbix): ...
- Logs (the LogQL queries I used, and what they showed): ...
- First symptom, and the time it appeared: ...

## 4. Root cause
One paragraph. Name the metric and the log line that prove it.

## 5. Fix applied
What I changed, the exact value, and why that value.

## 6. Before and after
| Metric | Baseline | Before fix | After fix |
|--------|----------|------------|-----------|

## 7. What I learned
Two or three sentences, including what I would monitor differently next time.
```

---

## 11. Appendix A — Zabbix foundation checklist

Learn these in order. Everything in this project uses only this list.

1. **Agent model.** Install Zabbix agent 2 on the five monitored hosts. Use
   **active checks** (`ServerActive=192.168.10.100`): the agent opens the
   connection to the server, so the Zabbix server never has to reach back into
   a host, and there is nothing to open on the agent side.
2. **Hosts and host groups.** Two groups, because the two roles are read in
   different ways:
   - `lab-core`: `lb01`, `web01`, `web02`, `db01` — the system under test
   - `lab-mon`: `mon01` — the monitoring host watching itself

   Two groups are not decoration. You can put a maintenance window on
   `lab-core` during a destructive test without silencing `mon01`, which is
   the one host that must keep alerting.

   Use the host name exactly as the system hostname, so the Zabbix host and
   the Loki `host` label match.
3. **Templates.** Link only what you need:
   - `Linux by Zabbix agent` on all five hosts
   - `Nginx by Zabbix agent 2` on web01 and web02
   - `MySQL by Zabbix agent 2` on db01
   - `HAProxy by HTTP` on lb01
   - nothing extra on mon01. The Linux template already gives CPU, memory and
     filesystem items. Add one item by hand for `/var/lib/loki`, because that
     is the directory that fills up.
4. **Items.** Understand key, type, update interval, history, trends, value
   type, units, and preprocessing (especially "Change per second" for
   counters). Build one item by hand, so the idea is clear.
5. **Dependent items.** The MySQL and Nginx templates use one master item and
   many dependent items. Open one and follow the data path.
6. **Triggers.** Use the current expression syntax and learn these five
   functions: `last()`, `avg()`, `max()`, `nodata()`, `timeleft()`. Learn the
   severity levels and the "OK event generation" option.
7. **Macros.** Change a threshold with a host macro (for example
   `{$CPU.UTIL.CRIT}`) instead of editing the template.
8. **Dashboards.** One dashboard per scenario, with the graphs of the metric
   set. Use the "Problems" and "Latest data" widgets.
9. **Maintenance windows.** Create one before a destructive test, so the test
   does not create false problem history.
10. **Housekeeping.** Know where history and trends are stored, and why a
    1-second interval is expensive.
11. **Self-monitoring.** `mon01` is a Zabbix host like the others, but it is
    the one host whose own failure cannot raise an alert. Keep its item set to
    CPU, memory, and disk space, and remember the limit: self-monitoring finds
    a slow problem, never a dead host.

Skip in this project: Zabbix proxies, your own discovery rules, external
scripts, escalation chains, and the Zabbix API.

## 12. Appendix B — Loki and Grafana foundation checklist

1. **The pipeline.** rsyslog on each monitored host collects the syslog
   sources, reads the file-based logs with `imfile`, and forwards everything
   to `mon01` over TCP with a disk-assisted queue. rsyslog on `mon01` writes
   one file per host and per source under `/var/log/remote/`. One Alloy
   instance tails those files, adds the `host` and `job` labels, and pushes to
   Loki. Grafana queries Loki.

   Learn the hop-by-hop debug routine in
   [02-app-stack.md](02-app-stack.md) section 7.10 and use it every time a
   panel is empty. Hop 5, `ls -R /var/log/remote/` on `mon01`, splits the
   problem in half with one command: if the file is there, collection works
   and the fault is in Alloy, Loki or Grafana.
2. **Labels are an index, not a field.** Keep them few and low in cardinality:
   `host`, `job`, and nothing per request. Never use a request ID or a URL as a
   label.
3. **The log selector comes first.** Every query starts with `{job="..."}`. A
   query with no label selector is invalid.
4. **Filter expressions.** `|=` contains, `!=` does not contain, `|~` regex.
5. **Parsers at query time.** `| json`, `| logfmt`, `| pattern`, `| regexp`.
   Parsing at query time keeps the index small. This is why the Nginx access
   log is written as JSON.
6. **Metric queries.** `count_over_time`, `rate`, `bytes_over_time`,
   `sum by (...)`, `topk`, and `quantile_over_time(... | unwrap field ...)`.
7. **Time alignment.** Set the Grafana time range to the run window, and check
   that the log timestamp is the real event time, not the ingest time.
8. **Retention.** `retention_period` plus the compactor. Know where the chunks
   live on disk.
9. **Grafana basics.** A data source, the Explore view, a Logs panel, a time
   series panel built from a metric query, and one variable (`$host`) for a
   small dashboard.

Skip in this project: a Loki cluster, object storage, the Loki ruler and its
alerts, recording rules, and tracing.
