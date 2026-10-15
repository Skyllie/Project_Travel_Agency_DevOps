# TravelAgency — Load Balancing with Nginx

This branch puts **three application servers** behind an **Nginx load balancer**, all in Docker Compose.
It covers the card "Setup Load Balancing for Webapp": deploy a couple of servers, set up Nginx as a load balancer, try different load-balancing algorithms and options.
It builds on the `docker` branch (same `Dockerfile` and entrypoint).

```
Browser ──► lb  nginx:1.28-alpine   172.30.0.20   host port 80
             │  algorithm: LB_ALGORITHM, sticky sessions: LB_STICKY
             ├──► app1  Tomcat 9 + ROOT.war   172.30.0.11   jvmRoute app1
             ├──► app2  Tomcat 9 + ROOT.war   172.30.0.12   jvmRoute app2
             └──► app3  Tomcat 9 + ROOT.war   172.30.0.13   jvmRoute app3
                          │
                          ▼
                  db  mysql:8.4   172.30.0.10   volume db_data
```

| File | What it is |
| --- | --- |
| `docker-compose.yml` | MySQL, three application servers, the balancer, a network with fixed IPs |
| `lb/templates/default.conf.template` | Nginx config: includes the chosen algorithm, sticky sessions, failover, `X-Served-By` header, log format |
| `lb/upstreams/*.conf` | One file per algorithm, each defines the pool `travel_pool` |
| `lb/sticky/on.conf`, `off.conf` | Where `proxy_pass` sends a request: to the session owner or always to the pool |
| `lb/demo.sh` | Sends 15 requests and shows which server answered each |
| `.env.example` | Passwords, port, algorithm, sticky on/off |

## 1. Run

Docker installation is in the README of the `docker` branch. Then on Ubuntu:

```bash
git clone -b docker-load-balancer https://github.com/Skyllie/Project_Travel_Agency_DevOps.git ~/travel-lb
cd ~/travel-lb
cp .env.example .env
nano .env                                 # change MYSQL_ROOT_PASSWORD and DB_PASSWORD
docker compose up -d --build              # app2 and app3 start after app1 is healthy: 2–3 minutes
docker compose ps                         # db, app1, app2, app3, lb: healthy
```

If the stack from the `docker` branch is running, stop it first (`docker compose down` in its folder): it uses port 8080 and the same project name.
The three Tomcats need about 1.5 GB of RAM; give the Ubuntu VM at least 4 GB.

Open `http://<Ubuntu IP>/` in the browser on Windows. If port 80 is taken, set `LB_PORT=8088` in `.env`.

## 2. Algorithms

Every algorithm is a file in `lb/upstreams/`. Switch with one command; only the `lb` container is recreated:

```bash
LB_ALGORITHM=weighted docker compose up -d lb
./lb/demo.sh                              # 15 new visitors: which server answered each
```

`demo.sh` sends requests without cookies (each one is a new visitor) and reads the `X-Served-By` header that Nginx adds.
Expected results with the three servers:

| `LB_ALGORITHM` | How Nginx chooses | 15 requests from `demo.sh` |
| --- | --- | --- |
| `round_robin` | In turn: app1, app2, app3, app1, … (the default) | about 5 / 5 / 5 |
| `weighted` | Round robin with weights 3 : 1 : 1 — for servers of different power | 9 / 3 / 3 |
| `least_conn` | To the server with the fewest active connections | one request at a time: like round robin |
| `ip_hash` | By the client IP: one client always lands on one server | 15 on one server |
| `hash` | By the URL (`hash $request_uri consistent`): one URL always on one server | one URL — one server; different URLs spread |
| `random` | Two random servers, the less busy of them (`random two least_conn`) | uneven, changes from run to run |
| `backup` | app1 and app2 work; app3 is a backup and gets requests only when both are down | app1 / app2 only |

To see `hash` spread different URLs:

```bash
LB_ALGORITHM=hash docker compose up -d lb
for u in /form-login /hotels /bookings /users /create; do
  echo "$u -> $(curl -s -o /dev/null -D - http://localhost$u | grep -i x-served-by)"
done
```

To make the `least_conn` difference visible, the requests have to overlap: run several `./lb/demo.sh &` at the same time and compare with `round_robin`.

## 3. Options

| Option | Where | What it does |
| --- | --- | --- |
| `weight=3` | `weighted.conf` | Share of requests for a server |
| `max_fails=3 fail_timeout=10s` | all pools | After 3 failed attempts within 10 s the server is skipped for 10 s (passive health check) |
| `backup` | `backup.conf`, `node_appN` | The server gets requests only when the main ones are down |
| `down` | add to a `server` line | Takes a server out of the pool, for example for maintenance |
| `zone` | all pools | Counters and failed servers are shared by all Nginx workers, so round robin is exact |
| `keepalive 16` | all pools | Keeps connections to Tomcat open instead of opening a new one per request |
| `proxy_next_upstream`, `proxy_connect_timeout 2s` | template | If a server does not answer in 2 s or returns 502–504, the request goes to the next one |
| Sticky sessions (`LB_STICKY`) | template + `lb/sticky/` | A logged-in user stays on the server that holds the session |

### Sticky sessions

The login session lives in the memory of the Tomcat that created it. Each Tomcat starts with `-DjvmRoute=appN`, and Tomcat adds this name to the session id: `JSESSIONID=4F1C0D…E2.app2`.
The `map` in the template reads the suffix and sends the request back to `app2`; a visitor without a session goes through the algorithm.

```bash
./lb/demo.sh --sticky                      # one visitor keeps the cookie: 15 times the same server
LB_STICKY=off docker compose up -d lb      # the cookie is ignored
./lb/demo.sh --sticky                      # the visitor jumps between servers
```

With `LB_STICKY=off` the site breaks in the browser: after login the next page goes to another Tomcat, which does not know the session, and you are back on the login page. This is the reason for sticky sessions.
`ip_hash` also keeps a user on one server, but by IP: all users behind one NAT end up on one server.

## 4. Failover

```bash
docker compose stop app2
./lb/demo.sh                               # only app1 and app3, no errors
docker compose logs lb | grep "timed out"  # Nginx tried app2 and skipped it
docker compose start app2                  # app2 returns to the pool in about 10 s
```

A request that hits the stopped server waits 2 s (`proxy_connect_timeout`) and is sent to the next one. After 3 such failures within 10 s (`max_fails=3`) the server is skipped for 10 s (`fail_timeout`), then Nginx tries it again.
If the stopped server held your session, you get another server and log in again — no error page: each `node_appN` pool has the other servers as `backup`.

## 5. Check

| What | Command | Expected |
| --- | --- | --- |
| Everything is up | `docker compose ps` | five containers, all `healthy` |
| The site answers through the balancer | `curl -s -o /dev/null -w '%{http_code}\n' http://localhost/form-login` | `200` |
| Requests are spread | `./lb/demo.sh` | app1, app2 and app3 |
| Which config Nginx uses | `docker compose exec lb head -4 /etc/nginx/conf.d/default.conf` | `LB_ALGORITHM=...   LB_STICKY=...` |
| Config is valid | `docker compose exec lb nginx -t` | `syntax is ok` |
| Log of the balancer | `docker compose logs lb` | `"GET /form-login HTTP/1.1" 200 -> app2 (tried: 172.30.0.12:8080, 0.004 s)` |
| Nginx counters | `curl http://localhost/nginx-status` | active connections, requests |
| Demo data loaded once | `docker compose logs app1 app2 app3 \| grep entrypoint` | app1: `DB_SEED=true` on the first start; app2, app3: `DB_SEED=false` |

## 6. Why It Is Built This Way

- **Fixed IPs.** Nginx reads the upstream addresses once, at start. With fixed IPs (`172.30.0.0/24`) a stopped or recreated application container comes back at the same address, and Nginx starts even if one server is down.
- **app1 first.** On an empty database the first Tomcat creates the tables and loads the demo data; app2 and app3 start after app1 is healthy and have `DB_SEED=false`, so two servers never create the tables at the same time.
- **One image, three containers.** All servers run the same `travelagency:local` image; only `jvmRoute` differs.
- **Algorithm as a file.** The official Nginx image renders `/etc/nginx/templates/*.template` with environment variables at start, so `LB_ALGORITHM` just picks which file is included.

## 7. If Something Goes Wrong

| Problem | What to do |
| --- | --- |
| `lb` exits: `open() "/etc/nginx/upstreams/xxx.conf" failed` | `LB_ALGORITHM` has a typo: it must be a file name from `lb/upstreams/` without `.conf` |
| `Pool overlaps with other one on this address space` | Another Docker network uses `172.30.0.0/24`: `docker network ls`, remove the old one or change the subnet and the IPs |
| `port is already allocated` | Port 80 is busy: `LB_PORT=8088` in `.env` |
| After login you are sent back to the login page | `LB_STICKY=off` — set it to `on` |
| A container is `unhealthy` | `docker compose logs app1`; with an empty database the first start takes 1–2 minutes |
| Other problems | See the README of the `docker` branch |
