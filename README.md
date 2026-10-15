# TravelAgency — Docker

This branch runs TravelAgency in containers with **Docker Compose**: MySQL 8.4 in one container, the application on Tomcat 9 in another.
It covers the card "Deploying a Containerized Web Application".

```
Ubuntu + Docker
└── network travelagency_backend
    ├── db   mysql:8.4            volume db_data → /var/lib/mysql
    └── app  travelagency:local   Tomcat 9 + ROOT.war, port 8080 → host 8080
```

| File | What it is |
| --- | --- |
| `Dockerfile` | Two stages: Maven + JDK 17 build `TravelAgency.war`, then Tomcat 9 runs it as `ROOT.war` |
| `docker/entrypoint.sh` | Waits for MySQL, decides whether to load the demo data, starts Tomcat |
| `docker-compose.yml` | The two services, the volume for the database and the network |
| `.env.example` | Passwords and settings; copy to `.env` |
| `.dockerignore` | Keeps the build context small: only `pom.xml`, `src/` and `docker/` are needed |

The host needs only Docker: Java and Maven run inside the build stage.

## 1. Install Docker on Ubuntu 22.04

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker "$USER"          # then log out and log in again
docker run --rm hello-world               # check: "Hello from Docker!"
```

The images and the build cache take about 3 GB. Check free space first: `df -h /` should show at least 6 GB available.

## 2. Run

```bash
git clone -b docker https://github.com/Skyllie/Project_Travel_Agency_DevOps.git ~/travel-docker
cd ~/travel-docker
cp .env.example .env
nano .env                                  # change MYSQL_ROOT_PASSWORD and DB_PASSWORD
docker compose up -d --build               # the first build takes 3–5 minutes
docker compose ps                          # wait until both are "healthy"
```

Use letters, digits, `-` and `_` in the passwords: `$` and quotes have a special meaning in `.env`.

Open `http://<Ubuntu IP>:8080/` in the browser on Windows (`hostname -I` on Ubuntu shows the IP), register on `/create` and log in.

## 3. Check

| What | Command | Expected |
| --- | --- | --- |
| Both containers are up | `docker compose ps` | `db` and `app`: `Up (healthy)` |
| The site answers | `curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/form-login` | `200` |
| Demo data loaded once | `docker compose logs app \| grep entrypoint` | first start: `0 tables in travelagency -> DB_SEED=true` |
| Not loaded again | `docker compose restart app`, then the same command | `... tables in travelagency -> DB_SEED=false` |
| Data is in MySQL | `docker compose exec db sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -e "SELECT COUNT(*) FROM travelagency.Hotel"'` | `8` (+ the hotels you created) |
| Data survives a restart | `docker compose down`, `docker compose up -d`, log in again | your user and hotels are still there |
| Tomcat does not run as root | `docker compose exec app id` | `uid=...(tomcat)` |

## 4. How It Works

- **Multi-stage build.** The first stage (`maven:3.9-eclipse-temurin-17`) builds the WAR; only the WAR goes into the final image (`tomcat:9.0-jdk17-temurin-noble`), so Maven and the sources are not shipped. The Maven cache is kept between builds (`RUN --mount=type=cache`), so a rebuild after a code change takes seconds.
- **Settings from the environment.** The application already reads `DB_TRAVELAGENCY_URL`, `DB_TRAVELAGENCY_USER`, `DB_TRAVELAGENCY_PASSWORD`, `HBM2DDL_AUTO` and `DB_SEED`. Compose takes the values from `.env`; nothing secret is in the image.
- **Demo data only once.** `DB_SEED=auto`: before Tomcat starts, the entrypoint counts the tables in the database. No tables → first start → `DB_SEED=true`; otherwise `false`. This is the same rule as in the Ansible role.
- **Start order.** MySQL has a health check (`mysqladmin ping` over TCP), and `app` starts only when it is healthy. The entrypoint also waits for the database (up to 3 minutes), so the container survives a slow MySQL start.
- **Health check of the app.** The image checks `http://localhost:8080/form-login` every 10 seconds; `docker compose ps` shows `healthy` when the site really works.
- **Data in a volume.** MySQL files live in the named volume `travelagency_db_data`, not in the container: `docker compose down` keeps the data, `docker compose down -v` deletes it.
- **Not root.** Tomcat runs as the system user `tomcat`; the default Tomcat web apps are removed.
- **Restart policy.** `restart: unless-stopped`: after a reboot of Ubuntu both containers start by themselves.

## 5. Day-to-Day Commands

| Task | Command |
| --- | --- |
| Start / rebuild after a code change | `docker compose up -d --build` |
| Stop (data is kept) | `docker compose down` |
| Delete everything, including the database | `docker compose down -v` |
| Logs of the app | `docker compose logs -f app` |
| Shell in the app container | `docker compose exec app bash` |
| MySQL console | `docker compose exec db sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" travelagency'` |
| Free disk space (old images, build cache) | `docker system prune` |

## 6. If Something Goes Wrong

| Problem | What to do |
| --- | --- |
| `permission denied ... /var/run/docker.sock` | Log out and log in after `usermod -aG docker`, or run `newgrp docker` |
| `set DB_PASSWORD in .env` | `.env` is missing: `cp .env.example .env` |
| `app` stays `starting` / `unhealthy` | `docker compose logs app`: the first start with an empty database takes 1–2 minutes |
| `entrypoint: MySQL is not reachable: Access denied` | The password in `.env` was changed after the first start: MySQL keeps the old one in the volume. `docker compose down -v` and start again (the data is lost) |
| `port is already allocated` | Port 8080 is busy (for example, a Tomcat from the manual setup): change `APP_PORT` in `.env` |
| `no space left on device` | `docker system prune`, or give the Ubuntu VM a bigger disk |
| Demo users (`michael.scott` and others) cannot log in | Their passwords in `insert.sql` are plain text, while login checks BCrypt hashes. Register a new user on `/create` |
