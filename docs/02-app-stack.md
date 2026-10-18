# Part 2 — Minimal Application Stack

The goal of this document is a web application that is **just big enough** to
produce interesting metrics and logs. There is no frontend and no business
logic. Four small API endpoints, one database table, and a request ID that you
can follow through all three tiers.

Every design choice here answers one question: *does it help me observe or
debug the system?* If the answer is no, it is not in this project.

---

## 1. Choices and why

| Choice | Decision | Why |
|--------|----------|-----|
| Web application | Nginx + PHP-FPM, four `.php` files | Fewest moving parts. No virtual env, no systemd unit to write, no build step. |
| Why not Python / Node | Not used | They need a process manager and a service unit, which is extra work with no extra observability. |
| URL style | `/api/read.php`, not `/api/read` | The URL maps to a file one to one, so debugging is obvious. No rewrite rules to confuse you. |
| Database access | PDO, one connection per request | A new connection per request is what makes the connection limit scenario (S4) visible. |
| Log format | JSON for Nginx access and for the app | Loki can parse it with `\| json`, so you can filter by status or latency without regex. |
| Request ID | Created by HAProxy, passed down to PHP | One ID links the HAProxy, Nginx, and app log lines of the same request. |
| Secrets | `/etc/app/db.ini`, mode 0640 | Keeps credentials out of the web root and out of git. Lab-only passwords. |

**Worker pool choice.** PHP-FPM has a fixed worker pool (`pm.max_children`).
That limit is the reason scenario S1 works: it creates a visible queue and a
clear log message, instead of a slow slide into CPU saturation.

---

## 2. Request path

```
 k6 (mgmt01 192.168.10.111)
        |
        |  HTTP, port 80
        v
 HAProxy (lb01 192.168.10.10)
   - creates X-Request-Id
   - health check: GET /api/health.php
   - round robin, maxconn 60 per server
        |
        +-----------------------------+
        v                             v
 Nginx (web01 .20)             Nginx (web02 .30)
   - JSON access log              (identical)
   - stub_status for Zabbix
        |
        |  FastCGI, unix socket
        v
 PHP-FPM pool "app"
   - 4 endpoint files
   - app log -> syslog local1
        |
        |  MySQL protocol, port 3306
        v
 MySQL 8.0 (db01 192.168.10.40)
   - slow query log
   - error log -> syslog
```

Log and metric paths:

```
 each monitored host: rsyslog --(TCP 514)--> mon01
        |                                      |
        |                              /var/log/remote/<host>/<source>.log
        |                                      |
        |                              Grafana Alloy (one instance)
        |                                      |
        |                               Loki --> Grafana
        |
        +-- Zabbix agent 2 --(active checks)--> Zabbix server on mon01
```

The five monitored hosts are `lb01`, `web01`, `web02`, `db01`, and `mon01`.
Each one runs a Zabbix agent and an rsyslog forwarder; only `mon01` runs
Alloy. `mon01` is a monitored host as well, because it holds Loki and the
Zabbix database: when its disk fills up, all monitoring stops without a single
alert. Section 7.2 explains why the log agent is central and not per host.

`mgmt01` is **not** monitored and ships no logs. It only runs k6. Its own
health is checked by hand during a run, see
[01-test-scenarios.md](01-test-scenarios.md) section 2.2.

---

## 3. Database on db01

### 3.1 Schema

```sql
-- One table is enough: it supports a write, a cheap read, and a slow search.
CREATE DATABASE IF NOT EXISTS appdb
  CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;

USE appdb;

CREATE TABLE IF NOT EXISTS events (
    id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    created_at  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    source_host VARCHAR(64)     NOT NULL,
    event_type  VARCHAR(32)     NOT NULL,
    payload     VARCHAR(255)    NOT NULL,
    PRIMARY KEY (id)
) ENGINE = InnoDB;

-- Note: event_type has NO index on purpose.
-- Scenario S4 adds idx_type_created later and measures the difference.
```

### 3.2 Users and grants

```sql
-- Application user. The web nodes connect from the 192.168.10.0/24 network.
CREATE USER 'appuser'@'192.168.10.%' IDENTIFIED BY 'App_Lab_Pass_123';
GRANT SELECT, INSERT ON appdb.* TO 'appuser'@'192.168.10.%';

-- Monitoring user for the Zabbix agent 2 MySQL plugin. Read-only.
CREATE USER 'zbx_monitor'@'127.0.0.1' IDENTIFIED BY 'Zbx_Lab_Pass_123';
GRANT USAGE, REPLICATION CLIENT, PROCESS, SHOW DATABASES, SHOW VIEW
  ON *.* TO 'zbx_monitor'@'127.0.0.1';

FLUSH PRIVILEGES;
```

### 3.3 Seed data for the slow query scenario

Doubling the table is the fastest way to reach 500,000 rows without a script.

```sql
USE appdb;

-- Start with 8 rows that have different event types.
INSERT INTO events (source_host, event_type, payload) VALUES
  ('seed', 'login',  'user login from web client'),
  ('seed', 'logout', 'user logout'),
  ('seed', 'order',  'order created abc123'),
  ('seed', 'order',  'order cancelled xyz789'),
  ('seed', 'login',  'user login from mobile'),
  ('seed', 'view',   'page view dashboard'),
  ('seed', 'view',   'page view report abc'),
  ('seed', 'error',  'payment gateway timeout');

-- Run this statement about 16 times. Each run doubles the row count.
INSERT INTO events (source_host, event_type, payload)
SELECT source_host, event_type, payload FROM events;

SELECT COUNT(*) FROM events;
```

Or in one shell loop:

```bash
for i in $(seq 1 16); do
    mysql -u root -p appdb -e \
      "INSERT INTO events (source_host, event_type, payload)
       SELECT source_host, event_type, payload FROM events;"
    echo "round $i done"
done
```

### 3.4 MySQL configuration

File: `/etc/mysql/mysql.conf.d/99-lab.cnf`

```ini
[mysqld]
# The web nodes are on another VM, so do not listen on localhost only.
bind-address = 0.0.0.0

# Connection limit. Scenario S4 lowers this to 40 on purpose.
max_connections = 100

# 1.5 GB of RAM in total, so leave room for the OS and for connections.
innodb_buffer_pool_size = 512M

# Slow query log. This file is the main evidence in scenario S4.
slow_query_log      = ON
slow_query_log_file = /var/log/mysql/mysql-slow.log
long_query_time     = 0.5

# Keep this OFF by default: it floods the log.
# Turn it ON only while you investigate scenario S4.
log_queries_not_using_indexes = OFF

# Send the error log to syslog, so rsyslog forwards it with everything else.
# The slow query log stays a file, and rsyslog reads it with imfile.
log_error_services = log_filter_internal; log_sink_syseventlog
```

Apply and check:

```bash
sudo systemctl restart mysql
mysql -u root -p -e "SHOW VARIABLES LIKE 'slow_query%'; SHOW VARIABLES LIKE 'max_connections';"
```

---

## 4. The application on web01 and web02

Directory layout (identical on both nodes):

```
/var/www/app/
  api/
    health.php     GET  - is the application alive
    read.php       GET  - read the newest rows
    write.php      POST - insert one row
    search.php     GET  - the slow query for scenario S4
  lib/
    db.php         builds the PDO connection
    log.php        writes one JSON line per event to syslog
/etc/app/db.ini    credentials, owner root:www-data, mode 0640
```

### 4.1 Credentials file

File: `/etc/app/db.ini`

```ini
; Lab credentials only. Never reuse these outside this lab.
[database]
host     = 192.168.10.40
port     = 3306
dbname   = appdb
user     = appuser
password = App_Lab_Pass_123
```

```bash
sudo install -o root -g www-data -m 0640 /dev/null /etc/app/db.ini
```

### 4.2 `lib/db.php`

```php
<?php

/**
 * Open one database connection for the current request.
 * Errors are thrown as exceptions so each endpoint can log them and
 * answer with HTTP 500.
 */
function db_connect(): PDO
{
    $config = parse_ini_file('/etc/app/db.ini', true);
    if ($config === false || !isset($config['database'])) {
        throw new RuntimeException('cannot read /etc/app/db.ini');
    }

    $database = $config['database'];
    $dsn = 'mysql:host=' . $database['host']
         . ';port=' . $database['port']
         . ';dbname=' . $database['dbname']
         . ';charset=utf8mb4';

    $options = [
        PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
        // Use real prepared statements, so the slow log shows the real query.
        PDO::ATTR_EMULATE_PREPARES   => false,
        // Fail fast instead of hanging when the database is overloaded.
        PDO::ATTR_TIMEOUT            => 3,
    ];

    return new PDO($dsn, $database['user'], $database['password'], $options);
}
```

### 4.3 `lib/log.php`

```php
<?php

/**
 * Write one JSON line to syslog facility local1.
 * One line per event keeps Loki queries simple: {job="app"} | json
 */
function app_log(string $level, string $message, array $extra = []): void
{
    $record = [
        'time'       => gmdate('Y-m-d\TH:i:s\Z'),
        'level'      => $level,
        'host'       => gethostname(),
        'request_id' => $_SERVER['REQUEST_ID'] ?? '-',
        'method'     => $_SERVER['REQUEST_METHOD'] ?? '-',
        'uri'        => $_SERVER['REQUEST_URI'] ?? '-',
        'message'    => $message,
    ];

    $line = json_encode(array_merge($record, $extra), JSON_UNESCAPED_SLASHES);

    // LOG_LOCAL1 is reserved for the application in this lab.
    openlog('app', LOG_PID, LOG_LOCAL1);
    syslog($level === 'error' ? LOG_ERR : LOG_INFO, $line);
    closelog();
}

/**
 * Send a JSON answer with the right status code.
 * The request ID goes back in a header so k6 and curl can show it.
 */
function send_json(int $status, array $body): void
{
    http_response_code($status);
    header('Content-Type: application/json');
    header('X-Request-Id: ' . ($_SERVER['REQUEST_ID'] ?? '-'));
    echo json_encode($body, JSON_UNESCAPED_SLASHES);
}
```

### 4.4 `api/health.php`

```php
<?php
require_once __DIR__ . '/../lib/log.php';
require_once __DIR__ . '/../lib/db.php';

// GET /api/health.php          -> checks Nginx + PHP-FPM only (HAProxy uses this)
// GET /api/health.php?deep=1   -> also checks the database (Zabbix uses this)
//
// The routing health check must NOT touch the database. If it did, one
// database problem would mark every web node down and cause a full outage.

$deep = isset($_GET['deep']);

if (!$deep) {
    send_json(200, ['status' => 'ok', 'host' => gethostname(), 'check' => 'shallow']);
    return;
}

try {
    $pdo = db_connect();
    $pdo->query('SELECT 1');
    send_json(200, ['status' => 'ok', 'host' => gethostname(), 'check' => 'deep']);
} catch (Throwable $error) {
    app_log('error', 'deep health check failed', ['error' => $error->getMessage()]);
    send_json(503, ['status' => 'error', 'check' => 'deep']);
}
```

### 4.5 `api/read.php`

```php
<?php
require_once __DIR__ . '/../lib/log.php';
require_once __DIR__ . '/../lib/db.php';

// GET /api/read.php?limit=10 -> the newest rows, read by primary key order.

$limit = isset($_GET['limit']) ? (int) $_GET['limit'] : 10;
if ($limit < 1 || $limit > 100) {
    $limit = 10;
}

$started_at = microtime(true);

try {
    $pdo = db_connect();
    $statement = $pdo->prepare(
        'SELECT id, created_at, source_host, event_type
           FROM events
          ORDER BY id DESC
          LIMIT :row_limit'
    );
    $statement->bindValue(':row_limit', $limit, PDO::PARAM_INT);
    $statement->execute();
    $rows = $statement->fetchAll();

    $db_ms = round((microtime(true) - $started_at) * 1000, 1);
    app_log('info', 'read ok', ['rows' => count($rows), 'db_ms' => $db_ms]);

    send_json(200, ['status' => 'ok', 'count' => count($rows), 'rows' => $rows]);
} catch (Throwable $error) {
    $db_ms = round((microtime(true) - $started_at) * 1000, 1);
    app_log('error', 'read failed', ['db_ms' => $db_ms, 'error' => $error->getMessage()]);

    send_json(500, ['status' => 'error', 'message' => 'database read failed']);
}
```

### 4.6 `api/write.php`

```php
<?php
require_once __DIR__ . '/../lib/log.php';
require_once __DIR__ . '/../lib/db.php';

// POST /api/write.php with a JSON body: {"event_type": "...", "payload": "..."}
// Both fields are optional; defaults keep the k6 script short.

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    send_json(405, ['status' => 'error', 'message' => 'use POST']);
    return;
}

$raw_body = file_get_contents('php://input');
$input = json_decode($raw_body, true);
if (!is_array($input)) {
    $input = [];
}

$event_type = substr((string) ($input['event_type'] ?? 'load_test'), 0, 32);
$payload    = substr((string) ($input['payload'] ?? 'generated by k6'), 0, 255);

$started_at = microtime(true);

try {
    $pdo = db_connect();
    $statement = $pdo->prepare(
        'INSERT INTO events (source_host, event_type, payload)
         VALUES (:source_host, :event_type, :payload)'
    );
    $statement->execute([
        ':source_host' => gethostname(),
        ':event_type'  => $event_type,
        ':payload'     => $payload,
    ]);

    $db_ms = round((microtime(true) - $started_at) * 1000, 1);
    app_log('info', 'write ok', ['id' => (int) $pdo->lastInsertId(), 'db_ms' => $db_ms]);

    send_json(201, ['status' => 'ok', 'id' => (int) $pdo->lastInsertId()]);
} catch (Throwable $error) {
    $db_ms = round((microtime(true) - $started_at) * 1000, 1);
    app_log('error', 'write failed', ['db_ms' => $db_ms, 'error' => $error->getMessage()]);

    send_json(500, ['status' => 'error', 'message' => 'database write failed']);
}
```

### 4.7 `api/search.php`

```php
<?php
require_once __DIR__ . '/../lib/log.php';
require_once __DIR__ . '/../lib/db.php';

// GET /api/search.php?type=login&q=abc
//
// This query is slow on purpose: event_type has no index, and the LIKE
// pattern starts with a wildcard, so MySQL must scan the whole table.
// Scenario S4 measures it, adds an index, and measures it again.

$event_type = substr((string) ($_GET['type'] ?? 'login'), 0, 32);
$search     = substr((string) ($_GET['q'] ?? 'abc'), 0, 32);

$started_at = microtime(true);

try {
    $pdo = db_connect();
    $statement = $pdo->prepare(
        'SELECT id, created_at, payload
           FROM events
          WHERE event_type = :event_type
            AND payload LIKE :search
          ORDER BY created_at DESC
          LIMIT 20'
    );
    $statement->execute([
        ':event_type' => $event_type,
        ':search'     => '%' . $search . '%',
    ]);
    $rows = $statement->fetchAll();

    $db_ms = round((microtime(true) - $started_at) * 1000, 1);
    // Log the duration on every call, so Loki can show the latency trend.
    app_log('info', 'search ok', ['rows' => count($rows), 'db_ms' => $db_ms]);

    send_json(200, ['status' => 'ok', 'count' => count($rows), 'rows' => $rows]);
} catch (Throwable $error) {
    $db_ms = round((microtime(true) - $started_at) * 1000, 1);
    app_log('error', 'search failed', ['db_ms' => $db_ms, 'error' => $error->getMessage()]);

    send_json(500, ['status' => 'error', 'message' => 'database search failed']);
}
```

### 4.8 PHP-FPM pool

File: `/etc/php/8.3/fpm/pool.d/app.conf` (or edit `www.conf`)

```ini
[app]
user  = www-data
group = www-data
listen = /run/php/php8.3-fpm-app.sock
listen.owner = www-data
listen.group = www-data

; Static pool: a fixed number of workers makes the capacity limit easy to see.
pm = static
pm.max_children = 30

; Status page for the Zabbix agent and for scenario S1.
pm.status_path = /fpm-status

; Log any request slower than 1 second, with its PHP stack trace.
; This is strong evidence in scenario S4.
slowlog = /var/log/php8.3-fpm-app-slow.log
request_slowlog_timeout = 1s

; Send worker output to the PHP-FPM error log instead of losing it.
catch_workers_output = yes
php_admin_value[error_log] = /var/log/php8.3-fpm-app-error.log
php_admin_flag[log_errors] = on
```

> `pm.max_children = 30` on two nodes means up to 60 database connections.
> MySQL `max_connections` must be larger than that. Scenario S4 breaks this
> rule on purpose.

---

## 5. Nginx on web01 and web02

File: `/etc/nginx/conf.d/app.conf`

```nginx
# JSON access log. Loki can parse it with "| json", so no regex is needed.
log_format json_combined escape=json
  '{'
    '"time":"$time_iso8601",'
    '"host":"$hostname",'
    '"remote_addr":"$remote_addr",'
    '"method":"$request_method",'
    '"uri":"$uri",'
    '"status":$status,'
    '"body_bytes":$body_bytes_sent,'
    '"request_time":$request_time,'
    '"upstream_addr":"$upstream_addr",'
    '"upstream_status":"$upstream_status",'
    '"upstream_response_time":"$upstream_response_time",'
    '"request_id":"$request_id_final"'
  '}';

# Reuse the request ID from HAProxy when it exists, otherwise create one.
map $http_x_request_id $request_id_final {
    default  $http_x_request_id;
    ""       $request_id;
}

server {
    listen 80 default_server;
    server_name _;
    root /var/www/app;

    # Send both logs to mon01 through the local rsyslog, with a clear tag.
    access_log syslog:server=unix:/dev/log,facility=local6,tag=nginx_access,severity=info json_combined;
    error_log  syslog:server=unix:/dev/log,facility=local6,tag=nginx_error,severity=warn warn;

    # A static file. Scenario S3 shows why this is a bad health check target.
    location = /healthz {
        access_log off;
        return 200 "static-ok\n";
    }

    location ~ ^/api/.+\.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.3-fpm-app.sock;

        # Give PHP the request ID, so app logs can be joined with access logs.
        fastcgi_param REQUEST_ID $request_id_final;

        # Fail after 10 seconds instead of waiting forever.
        fastcgi_read_timeout 10s;
    }

    # Everything else is not part of this lab.
    location / {
        return 404 "not found\n";
    }
}

# Status pages for the Zabbix agent only. Local access, no logging.
server {
    listen 127.0.0.1:8080;
    server_name localhost;

    location = /basic_status {
        stub_status;
        access_log off;
    }

    location = /fpm-status {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.3-fpm-app.sock;
        access_log off;
    }
}
```

Enable and check:

```bash
sudo nginx -t
sudo systemctl reload nginx
curl -s http://127.0.0.1:8080/basic_status
curl -s http://127.0.0.1:8080/fpm-status
```

---

## 6. HAProxy on lb01

File: `/etc/haproxy/haproxy.cfg`

```haproxy
global
    # Log to the local rsyslog socket. Do not add "chroot" to this config:
    # a chrooted HAProxy cannot reach /dev/log and logs nothing.
    log /dev/log local0 info
    maxconn 4000
    user  haproxy
    group haproxy
    daemon

defaults
    mode http
    log global
    option dontlognull
    timeout connect 5s
    timeout client  30s
    timeout server  30s
    retries 2

    # Default httplog fields plus the request ID at the end.
    # Timers: TR=client request, Tw=queue wait, Tc=connect, Tr=server, Ta=total
    log-format "%ci:%cp [%tr] %ft %b/%s %TR/%Tw/%Tc/%Tr/%Ta %ST %B %tsc %ac/%fc/%bc/%sc/%rc %sq/%bq %{+Q}r id=%ID"

frontend app_front
    bind 192.168.10.10:80

    # Create one ID per request and pass it to the web nodes.
    unique-id-format %{+X}o\ %ci:%cp_%fi:%fp_%Ts_%rt:%pid
    unique-id-header X-Request-Id

    default_backend app_back

backend app_back
    balance roundrobin

    # Check the real application path: Nginx AND PHP must both work.
    # Scenario S3 compares this with a check on the static /healthz file.
    option httpchk
    http-check send meth GET uri /api/health.php
    http-check expect status 200

    # inter 2s, fall 3 -> a dead node is detected in about 6 seconds.
    default-server inter 2s fall 3 rise 2

    # maxconn per server creates a visible queue under high load (S1, S2).
    server web01 192.168.10.20:80 check maxconn 60
    server web02 192.168.10.30:80 check maxconn 60

# Stats page, read by the Zabbix "HAProxy by HTTP" template.
listen stats
    bind 192.168.10.10:8404
    mode http
    stats enable
    stats uri /stats
    stats refresh 10s
    # Lab only: no authentication. Add "stats auth user:pass" if you prefer,
    # and set the matching macros on the Zabbix host.
```

Check:

```bash
sudo haproxy -c -f /etc/haproxy/haproxy.cfg
sudo systemctl reload haproxy
curl -s "http://192.168.10.10:8404/stats;csv" | head -3
curl -i http://192.168.10.10/api/health.php      # look for the X-Request-Id header
```

### 6.1 How to read a HAProxy log line

This is a core skill. Learn the five timers:

| Field | Meaning | What a high value tells you |
|-------|---------|-----------------------------|
| `TR` | time to receive the client request | slow client or network |
| `Tw` | time waiting in the queue | the backend is full: `maxconn` reached |
| `Tc` | time to connect to the server | the server is refusing or the network is slow |
| `Tr` | server response time | the application or database is slow |
| `Ta` | total active time | the sum the user actually feels |

The termination state `%tsc` is just as useful: `----` is normal, `sQ` means
the request died in the queue, `sH` is a server timeout during the headers,
and `SC` means the connection to the server failed.

---

## 7. Logging pipeline

### 7.1 Design: rsyslog forwards, one Alloy on mon01

Every monitored host collects its own logs with rsyslog and forwards them to
`mon01`. On `mon01`, rsyslog writes one file per host and per log source, and
a single Grafana Alloy agent tails those files and pushes them to Loki.

```
on lb01, web01, web02, db01, mon01:

  haproxy, nginx, php app, OS  --syslog--> rsyslog
  mysql slow log, php-fpm log, zabbix server log  --imfile--> rsyslog
                                   |
                                   |  omfwd, TCP 514, disk-assisted queue
                                   v
                      rsyslog on mon01 (imtcp, port 514)
                                   |
                                   v
                   /var/log/remote/<host>/<source>.log
                                   |
                            Grafana Alloy (one instance)
                                   |
                                   |  HTTP push to 127.0.0.1:3100
                                   v
                           Loki --> Grafana
```

`mon01` forwards to itself, to `192.168.10.100:514`. That looks odd at first,
but it means **every host uses the same forwarding config**, and every log in
the lab ends up under the same `/var/log/remote/` layout. There is no special
case to remember.

`mgmt01` has no Zabbix agent, no Alloy, and does not forward logs. It only
runs k6.

### 7.2 Why this design, and not an agent on every host

An agent on every host is the standard Grafana deployment. This lab does the
opposite on purpose, for one measurable reason: `lb01`, `web01` and `web02`
have only 1 GB of RAM, and scenario S1 tunes `pm.max_children` against the
free memory on those nodes. An extra agent of 50 to 150 MB on each node would
take memory out of the exact budget the experiment measures.

Two things are given up for that, and both are written in section 10:
`mon01` becomes a single point for the log path, and the rsyslog disk queue
has to be configured by hand on every node.

### 7.3 Log sources and Loki jobs

| Source | How rsyslog gets it | File on mon01 | Loki `job` |
|--------|--------------------|---------------|-----------|
| HAProxy | syslog, facility `local0` | `lb01/haproxy.log` | `haproxy` |
| Nginx access | syslog, `local6`, tag `nginx_access` | `webNN/nginx_access.log` | `nginx_access` |
| Nginx error | syslog, `local6`, tag `nginx_error` | `webNN/nginx_error.log` | `nginx_error` |
| PHP application | syslog, `local1`, tag `app` | `webNN/app.log` | `app` |
| PHP-FPM error and slow log | `imfile`, `local5`, tag `phpfpm` | `webNN/phpfpm.log` | `phpfpm` |
| MySQL slow query log | `imfile`, `local2`, tag `mysql_slow` | `db01/mysql_slow.log` | `mysql_slow` |
| MySQL error log | syslog, tag `mysqld` | `db01/mysqld.log` | `mysql_error` |
| Zabbix server log | `imfile`, `local3`, tag `zabbix_server` | `mon01/zabbix_server.log` | `zabbix_server` |
| OS, kernel, services | normal syslog | `<host>/syslog.log` | `syslog` |

The file name is the contract between rsyslog and Alloy. Change a tag on a
node and you must change the Alloy target as well.

### 7.4 rsyslog on every monitored host: forward

File: `/etc/rsyslog.d/10-forward.conf`

```rsyslog
# Forward every message to mon01 over TCP.
# The disk-assisted queue keeps logs while mon01 is down, and resumes
# afterwards. Without it, a mon01 restart loses logs with no warning.
action(type="omfwd"
       target="192.168.10.100"
       port="514"
       protocol="tcp"
       template="RSYSLOG_SyslogProtocol23Format"
       queue.type="linkedList"
       queue.filename="fwd_mon01"
       queue.maxdiskspace="100m"
       queue.saveonshutdown="on"
       action.resumeRetryCount="-1")
```

Why each setting matters:

| Setting | Reason |
|---------|--------|
| `protocol="tcp"` | UDP drops messages silently and gives no backpressure |
| `queue.filename` | turns the memory queue into a disk-assisted queue, under `/var/spool/rsyslog` |
| `queue.maxdiskspace="100m"` | an upper bound, so a long outage cannot fill `/var` |
| `queue.saveonshutdown="on"` | a reboot does not throw the queue away |
| `action.resumeRetryCount="-1"` | retry forever instead of giving up on the action |

This file is identical on all five hosts, including `mon01`.

> Note for scenario S5: the queue lives on disk. When a filesystem fills up,
> the forward queue stops too. That is not a bug in the design, it is the
> failure the scenario is built to show.

### 7.5 rsyslog on each host: the file inputs

Logs that are already files need `imfile`. Install only the input that belongs
on the host.

On `web01` and `web02`, file `/etc/rsyslog.d/11-phpfpm.conf`:

```rsyslog
module(load="imfile")

input(type="imfile"
      File="/var/log/php8.3-fpm-app-error.log"
      Tag="phpfpm"
      Facility="local5"
      Severity="warning")

input(type="imfile"
      File="/var/log/php8.3-fpm-app-slow.log"
      Tag="phpfpm"
      Facility="local5"
      Severity="warning")
```

On `db01`, file `/etc/rsyslog.d/11-mysql-slow.conf`:

```rsyslog
module(load="imfile")

input(type="imfile"
      File="/var/log/mysql/mysql-slow.log"
      Tag="mysql_slow"
      Facility="local2"
      Severity="info")
```

On `mon01`, file `/etc/rsyslog.d/11-zabbix.conf`:

```rsyslog
module(load="imfile")

input(type="imfile"
      File="/var/log/zabbix/zabbix_server.log"
      Tag="zabbix_server"
      Facility="local3"
      Severity="info")
```

**Permissions.** rsyslog drops privileges to the user `syslog` on Ubuntu, so
it cannot read a log owned by `mysql` or `zabbix` unless it is in the `adm`
group. Check before you blame the pipeline:

```bash
sudo usermod --append --groups adm syslog
sudo systemctl restart rsyslog

sudo --user=syslog head -n 1 /var/log/mysql/mysql-slow.log
```

### 7.6 rsyslog on mon01: receive and sort

This is the only host with a receiver. The ruleset is bound to the TCP input,
so only forwarded messages go through it and a message is never forwarded
twice.

File: `/etc/rsyslog.d/10-remote.conf`

```rsyslog
# One directory per sending host, one file per log source.
template(name="RemoteSourcePath" type="string"
         string="/var/log/remote/%HOSTNAME%/%PROGRAMNAME%.log")

# Everything that is not a known lab source shares one file per host.
template(name="RemoteSyslogPath" type="string"
         string="/var/log/remote/%HOSTNAME%/syslog.log")

# JSON sources are written with no syslog prefix, so "| json" works in Loki.
template(name="RawMessage" type="string"
         string="%msg:::drop-last-lf%\n")

# Plain text sources keep a timestamp and the program name.
template(name="RemoteTextLine" type="string"
         string="%TIMESTAMP:::date-rfc3339% %syslogtag%%msg:::sp-if-no-1st-sp%%msg:::drop-last-lf%\n")

# The ruleset must be defined before the input that uses it.
ruleset(name="remote") {
    # The Nginx access log and the PHP app send one JSON object per line.
    if ($programname == "nginx_access") or ($programname == "app") then {
        action(type="omfile" dynaFile="RemoteSourcePath" template="RawMessage"
               dirCreateMode="0755" fileCreateMode="0640"
               fileOwner="syslog" fileGroup="adm")
        stop
    }

    # Known lab sources, one file each.
    if ($programname == "haproxy")
    or ($programname == "nginx_error")
    or ($programname == "phpfpm")
    or ($programname == "mysql_slow")
    or ($programname == "mysqld")
    or ($programname == "zabbix_server") then {
        action(type="omfile" dynaFile="RemoteSourcePath" template="RemoteTextLine"
               dirCreateMode="0755" fileCreateMode="0640"
               fileOwner="syslog" fileGroup="adm")
        stop
    }

    # Operating system, kernel and every other service.
    action(type="omfile" dynaFile="RemoteSyslogPath" template="RemoteTextLine"
           dirCreateMode="0755" fileCreateMode="0640"
           fileOwner="syslog" fileGroup="adm")
    stop
}

module(load="imtcp")
input(type="imtcp" port="514" ruleset="remote")
```

Apply and check the result. This single command is the best thing about this
design: one place shows whether collection works for the whole lab.

```bash
sudo systemctl restart rsyslog
ls -R /var/log/remote/
```

You must see exactly five directories: `lb01`, `web01`, `web02`, `db01`,
`mon01`. If a directory has a different name, such as a fully qualified
`web01.lab.internal`, fix the hostname on that node now. The Alloy targets in
section 7.8 use these names, so a wrong directory name means no logs for that
host, which is an obvious failure rather than a silent wrong label.

### 7.7 Rotate the collected files on mon01

All five hosts write into `/var/log/remote` on one machine, so this grows five
times faster than a normal log directory. Nothing rotates it by default.

File: `/etc/logrotate.d/remote-logs`

```
/var/log/remote/*/*.log {
    daily
    # Rotate early if one host floods, instead of waiting for midnight.
    maxsize 100M
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 0640 syslog adm
    sharedscripts
    postrotate
        /usr/lib/rsyslog/rsyslog-rotate
    endscript
}
```

```bash
sudo logrotate --debug /etc/logrotate.d/remote-logs
```

Loki has its own retention (`retention_period`), and these files are a second
copy with its own lifetime. Keep both short, and keep both in mind during
scenario S5.

### 7.8 Grafana Alloy on mon01

Every target is written out in full. There is no regex and no label pipeline,
so both labels come straight from this file and cannot be wrong. The list also
documents which host produces which log source.

File: `/etc/alloy/config.alloy`

```alloy
// Every log file the lab collects, with its host and job label.
// A file that does not exist yet is simply not tailed.
local.file_match "remote_logs" {
    path_targets = [
        { __path__ = "/var/log/remote/lb01/haproxy.log",       host = "lb01",  job = "haproxy" },
        { __path__ = "/var/log/remote/lb01/syslog.log",        host = "lb01",  job = "syslog" },

        { __path__ = "/var/log/remote/web01/nginx_access.log", host = "web01", job = "nginx_access" },
        { __path__ = "/var/log/remote/web01/nginx_error.log",  host = "web01", job = "nginx_error" },
        { __path__ = "/var/log/remote/web01/app.log",          host = "web01", job = "app" },
        { __path__ = "/var/log/remote/web01/phpfpm.log",       host = "web01", job = "phpfpm" },
        { __path__ = "/var/log/remote/web01/syslog.log",       host = "web01", job = "syslog" },

        { __path__ = "/var/log/remote/web02/nginx_access.log", host = "web02", job = "nginx_access" },
        { __path__ = "/var/log/remote/web02/nginx_error.log",  host = "web02", job = "nginx_error" },
        { __path__ = "/var/log/remote/web02/app.log",          host = "web02", job = "app" },
        { __path__ = "/var/log/remote/web02/phpfpm.log",       host = "web02", job = "phpfpm" },
        { __path__ = "/var/log/remote/web02/syslog.log",       host = "web02", job = "syslog" },

        { __path__ = "/var/log/remote/db01/mysql_slow.log",    host = "db01",  job = "mysql_slow" },
        { __path__ = "/var/log/remote/db01/mysqld.log",        host = "db01",  job = "mysql_error" },
        { __path__ = "/var/log/remote/db01/syslog.log",        host = "db01",  job = "syslog" },

        { __path__ = "/var/log/remote/mon01/zabbix_server.log", host = "mon01", job = "zabbix_server" },
        { __path__ = "/var/log/remote/mon01/syslog.log",        host = "mon01", job = "syslog" },
    ]
    sync_period = "10s"
}

loki.source.file "remote_logs" {
    targets    = local.file_match.remote_logs.targets
    forward_to = [loki.write.local_loki.receiver]
}

loki.write "local_loki" {
    endpoint {
        url = "http://127.0.0.1:3100/loki/api/v1/push"
    }
}
```

**Permissions.** Alloy runs as the user `alloy`, and these files are
`syslog:adm` with mode 0640. Without this step Alloy starts fine and reads
nothing, which is a confusing failure.

```bash
sudo usermod --append --groups adm alloy
sudo systemctl restart alloy

sudo --user=alloy head -n 1 /var/log/remote/web01/nginx_access.log
```

**The Alloy web UI** shows the health and the last error of every component,
and it is the fastest way to see whether a target was found.

```bash
# In /etc/default/alloy, add the listen address to CUSTOM_ARGS:
#   CUSTOM_ARGS="--server.http.listen-addr=0.0.0.0:12345"
sudo systemctl restart alloy
```

Then open `http://192.168.10.100:12345` from the host machine.

**Known limit.** A MySQL slow query entry is several lines, and each line
arrives as its own log line. For this lab that is fine: the entry is still
readable in the Grafana log panel. If you want one entry per record, add a
`stage.multiline` block in a `loki.process` component later.

### 7.9 Loki on mon01

File: `/etc/loki/config.yml`

```yaml
auth_enabled: false

server:
  # Alloy pushes from the same host, so localhost would be enough. Leaving
  # the default makes it easy to query the API from the host machine.
  http_listen_port: 3100
  grpc_listen_port: 9096
  log_level: info

common:
  path_prefix: /var/lib/loki
  storage:
    filesystem:
      chunks_directory: /var/lib/loki/chunks
      rules_directory: /var/lib/loki/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: 2026-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

limits_config:
  # One week is enough for this lab, and it protects the disk.
  retention_period: 168h
  ingestion_rate_mb: 8
  ingestion_burst_size_mb: 16
  reject_old_samples: true
  reject_old_samples_max_age: 24h

compactor:
  working_directory: /var/lib/loki/compactor
  retention_enabled: true
  delete_request_store: filesystem
```

```bash
curl -s http://127.0.0.1:3100/ready
curl -s "http://192.168.10.100:3100/loki/api/v1/labels"
```

### 7.10 Debug the pipeline hop by hop

When a Grafana panel is empty, walk the hops in order. Never guess.

| Hop | Check on | Command |
|-----|----------|---------|
| 1. Does the service log at all? | the node | `tail -f /var/log/nginx/error.log`, or the service log |
| 2. Does rsyslog receive it? | the node | `logger -t test "ping"`, then `tail /var/log/syslog` |
| 3. Can rsyslog read the input file? | the node | `sudo --user=syslog head -n 1 <file>` |
| 4. Is the forward queue stuck? | the node | `ls -l /var/spool/rsyslog/`, `journalctl -u rsyslog -n 50` |
| 5. **Did it arrive?** | mon01 | `ls -R /var/log/remote/`, then `tail` the file |
| 6. Can Alloy read the file? | mon01 | `sudo --user=alloy head -n 1 <file>` |
| 7. Is the Alloy component healthy? | mon01 | `http://192.168.10.100:12345` |
| 8. Did Loki accept the labels? | mon01 | `curl -s "http://192.168.10.100:3100/loki/api/v1/label/job/values"` |
| 9. Is the Grafana time range right? | Grafana | widen it to the last 6 hours |

Hop 5 is the one that makes this design worth its cost: it splits the problem
in half in one command. If the file is there, collection works and the fault
is in Alloy, Loki or Grafana. If it is not, the fault is on the node.

Hop 9 is still the most common cause of an empty panel.

## 8. Load scripts on mgmt01

Install k6 from the official apt repository. The repository is mounted at
`/lab` on `mgmt01`, so the scripts in `load/` are used straight from there and
the results are written back into `runs/` on the host.

**Why `maxVUs` is capped at 400.** An arrival-rate executor starts more VUs
when responses get slower, and each VU costs memory. `mgmt01` has 1 GB of RAM,
so an unlimited cap would let k6 swap or be killed by the kernel in the middle
of a run. A cap makes the client fail **loudly** instead: k6 cannot start the
next iteration, and `dropped_iterations` grows, which is the one client signal
the k6 summary always gives you. A visible client limit is much better than a
silent one.

### 8.0 How to start a run

`mgmt01` has no Alloy, so nothing from this host reaches Loki. Every piece of
client evidence is a file in the run folder instead.

```bash
# Run from inside the run folder: handleSummary writes k6-summary.json
# into the current directory.
cd /lab/runs/run-20261020-1430-s1-ramp

# Sample the client itself while the load runs, and stop it afterwards.
vmstat 5 > client-vmstat.log &
vmstat_pid=$!

k6 run --log-output=file=k6-run.log --log-format=json \
       /lab/load/ramp.js 2>&1 | tee k6-console.log

kill "$vmstat_pid"
```

Four files, and each one answers a different question:

| File | What it holds | Question it answers |
|------|---------------|---------------------|
| `k6-summary.json` | the metric summary (`handleSummary`) | what did the client measure |
| `k6-run.log` | k6's own warnings and errors, as JSON | did k6 itself have a problem |
| `k6-console.log` | what you saw on screen | what did the run look like live |
| `client-vmstat.log` | client CPU, memory and swap every 5 s | was the client healthy |

The last two are the manual replacement for the Zabbix agent that `mgmt01`
does not have. `vmstat` is part of the base system, so nothing extra is
installed on the client.

> k6 can push its log straight to Loki with
> `--log-output=loki=http://192.168.10.100:3100/loki/api/v1/push`. It works, but
> it creates its own labels and brings the unmonitored client into the log
> pipeline through a side door. Keep the client out, and keep its evidence in
> the run folder.

### 8.1 `load/lib/common.js`

```javascript
import http from 'k6/http';
import { check } from 'k6';

// One place for the target and for the request helpers.
export const BASE_URL = __ENV.BASE_URL || 'http://192.168.10.10';

// 80% of the traffic is a read, 20% is a write.
export function readOrWrite() {
    if (Math.random() < 0.8) {
        const response = http.get(`${BASE_URL}/api/read.php?limit=10`, {
            tags: { endpoint: 'read' },
        });
        check(response, { 'read status is 200': (r) => r.status === 200 });
        return;
    }

    const body = JSON.stringify({ event_type: 'load_test', payload: 'k6 write' });
    const response = http.post(`${BASE_URL}/api/write.php`, body, {
        headers: { 'Content-Type': 'application/json' },
        tags: { endpoint: 'write' },
    });
    check(response, { 'write status is 201': (r) => r.status === 201 });
}

// Save the summary next to the run notes, so every run keeps its evidence.
export function saveSummary(data) {
    return { 'k6-summary.json': JSON.stringify(data, null, 2) };
}
```

### 8.2 `load/baseline.js` (S0)

```javascript
import { readOrWrite, saveSummary } from './lib/common.js';

export const options = {
    scenarios: {
        baseline: {
            executor: 'constant-arrival-rate',
            rate: 50,
            timeUnit: '1s',
            duration: '10m',
            preAllocatedVUs: 50,
            maxVUs: 200,
        },
    },
    thresholds: {
        http_req_failed: ['rate < 0.01'],
        http_req_duration: ['p(95) < 500'],
    },
};

export default function () {
    readOrWrite();
}

export function handleSummary(data) {
    return saveSummary(data);
}
```

### 8.3 `load/ramp.js` (S1)

```javascript
import { readOrWrite, saveSummary } from './lib/common.js';

// Climb slowly, so the knee point is easy to read on the graph.
export const options = {
    scenarios: {
        ramp: {
            executor: 'ramping-arrival-rate',
            startRate: 20,
            timeUnit: '1s',
            preAllocatedVUs: 100,
            maxVUs: 400,
            stages: [
                { target: 100, duration: '4m' },
                { target: 250, duration: '4m' },
                { target: 400, duration: '4m' },
                { target: 600, duration: '3m' },
                { target: 600, duration: '5m' },
            ],
        },
    },
};

export default function () {
    readOrWrite();
}

export function handleSummary(data) {
    return saveSummary(data);
}
```

### 8.4 `load/microburst.js` (S2)

```javascript
import { readOrWrite, saveSummary } from './lib/common.js';

// Build ten bursts: 10 seconds high, 50 seconds low.
// A long stage list is clearer here than a clever loop.
function burstStages(cycles) {
    const stages = [];
    for (let i = 0; i < cycles; i++) {
        stages.push({ target: 500, duration: '1s' });   // jump up fast
        stages.push({ target: 500, duration: '9s' });   // hold the burst
        stages.push({ target: 20, duration: '1s' });    // drop back
        stages.push({ target: 20, duration: '49s' });   // quiet period
    }
    return stages;
}

export const options = {
    scenarios: {
        microburst: {
            executor: 'ramping-arrival-rate',
            startRate: 20,
            timeUnit: '1s',
            preAllocatedVUs: 100,
            maxVUs: 400,
            stages: burstStages(10),
        },
    },
};

export default function () {
    readOrWrite();
}

export function handleSummary(data) {
    return saveSummary(data);
}
```

### 8.5 `load/steady.js` (S3 and S5)

```javascript
import { readOrWrite, saveSummary } from './lib/common.js';

// Fixed rate, so the only variable is the failure you inject.
// Run it with: k6 run load/steady.js --env RPS=200
const requestsPerSecond = Number(__ENV.RPS || 150);

export const options = {
    scenarios: {
        steady: {
            executor: 'constant-arrival-rate',
            rate: requestsPerSecond,
            timeUnit: '1s',
            duration: '12m',
            preAllocatedVUs: 100,
            maxVUs: 400,
        },
    },
};

export default function () {
    readOrWrite();
}

export function handleSummary(data) {
    return saveSummary(data);
}
```

### 8.6 `load/search.js` (S4)

```javascript
import http from 'k6/http';
import { check } from 'k6';
import { BASE_URL, saveSummary } from './lib/common.js';

// Only the slow endpoint, at a low rate. A slow query does not need
// much traffic to hurt the database.
export const options = {
    scenarios: {
        search: {
            executor: 'constant-arrival-rate',
            rate: 20,
            timeUnit: '1s',
            duration: '8m',
            preAllocatedVUs: 20,
            maxVUs: 200,
        },
    },
};

const eventTypes = ['login', 'order', 'view', 'error'];

export default function () {
    const type = eventTypes[Math.floor(Math.random() * eventTypes.length)];
    const response = http.get(`${BASE_URL}/api/search.php?type=${type}&q=abc`, {
        tags: { endpoint: 'search' },
    });
    check(response, { 'search status is 200': (r) => r.status === 200 });
}

export function handleSummary(data) {
    return saveSummary(data);
}
```

---

## 9. Smoke test checklist

Run this after the stack is built, and again after every snapshot restore.

```bash
# 1. Each web node answers on its own
curl -s http://192.168.10.20/api/health.php
curl -s http://192.168.10.30/api/health.php

# 2. The database path works
curl -s "http://192.168.10.20/api/health.php?deep=1"

# 3. The load balancer answers, and returns a request ID
curl -i http://192.168.10.10/api/health.php | grep -i x-request-id

# 4. Read and write through the load balancer
curl -s "http://192.168.10.10/api/read.php?limit=3"
curl -s -X POST http://192.168.10.10/api/write.php \
     -H 'Content-Type: application/json' \
     -d '{"event_type":"smoke","payload":"manual check"}'

# 5. Round robin: ten calls must hit both hosts
for i in $(seq 1 10); do curl -s http://192.168.10.10/api/health.php | grep -o '"host":"[^"]*"'; done

# 6. Both backends are UP in HAProxy
curl -s "http://192.168.10.10:8404/stats;csv" | cut -d, -f1,2,18

# 7. Zabbix sees fresh data: Monitoring -> Latest data, all five hosts

# 8. Loki has all the jobs
curl -s "http://192.168.10.100:3100/loki/api/v1/label/job/values"

# 9. Collection works: five directories, and the files inside them (on mon01)
ls -R /var/log/remote/

# 10. All five monitored hosts reached Loki, and mgmt01 did not
curl -s "http://192.168.10.100:3100/loki/api/v1/label/host/values"
```

- [ ] All ten steps pass.
- [ ] Step 8 lists the jobs `haproxy`, `nginx_access`, `nginx_error`, `app`,
      `phpfpm`, `mysql_slow`, `mysql_error`, `zabbix_server`, `syslog`.
- [ ] Step 9 shows exactly five directories, named `lb01`, `web01`, `web02`,
      `db01`, `mon01`. A name such as `web01.lab.internal` means the hostname
      on that node is wrong, and Alloy will not pick up its files.
- [ ] Step 10 lists exactly those same five hosts. If `mgmt01` appears,
      something was installed on the client by mistake.
- [ ] One request ID from step 3 can be found in the HAProxy, Nginx, and app
      logs in Grafana.

When all of this works, take the snapshot `clean-stack` and start with S0.

---

## 10. Known limits of this stack

Write these in the README too. Naming the limits of your own work is a strong
signal in an interview.

- One connection per request, with no connection pool. It is realistic for
  classic PHP, and it is what makes the connection limit visible.
- No TLS, no authentication, no input validation beyond length limits. This is
  a lab on a private network.
- Passwords are stored in plain text in `/etc/app/db.ini`. Acceptable for a
  lab, never for production.
- One flat host-only lab network with no firewall rules, so the focus stays on
  observation.
- `pm = static` wastes a little memory at low load, but it keeps the capacity
  measurement simple.
- The load generator has 2 vCPU and 1 GB of RAM, so there is a rate above
  which `mgmt01` becomes the bottleneck. `mgmt01` is outside the monitoring
  scope on purpose, so this is checked by hand on every run: the
  `dropped_iterations` counter in the k6 summary, plus the `vmstat` capture in
  the run folder. See `docs/01-test-scenarios.md` section 2.2. Measure the
  client ceiling once and write it in the README.
- `mon01` monitors itself. That catches a slow problem such as a disk filling
  up or memory running out, which is the common case. It cannot catch `mon01`
  failing completely, because then nothing is left to send the alert. Say this
  openly: in real work the answer is an external check, and that is out of
  scope for a lab of this size.
- `mon01` is a single point for the log path as well as for storage. If it is
  down, each node keeps its logs in the rsyslog disk queue for up to 100 MB
  and sends them when it comes back, so a short outage costs nothing. A long
  outage loses the oldest messages, with no alert. Section 7.2 says why that was accepted.
- Logs exist twice: as files under `/var/log/remote` on `mon01`, and inside
  Loki. Both have their own retention, and both must be kept short. The file
  copy is kept on purpose, because it is the fastest way to tell a collection
  problem from a query problem.
