# TravelAgency — Manual Setup on One Machine

This branch shows the simplest deployment: the application, Tomcat and MySQL on one Ubuntu 22.04 machine, all installed by hand. It covers the card "Setup a Webapp".

The code in this branch already has two fixes from `main`: Lombok 1.18.34, so the project builds on JDK 17, and the `HBM2DDL_AUTO` / `DB_SEED` settings, so the database is no longer re-created on every start.

---

## 1. Requirements

- Ubuntu 22.04, 2 vCPU, 2–4 GB RAM.
- At least 2 GB of free disk space (`df -h /`).

## 2. Install Packages

```bash
sudo apt update
sudo apt install -y openjdk-17-jdk maven mysql-server wget
java -version            # must be 17
```

If `java -version` shows another version, choose 17 with `sudo update-alternatives --config java`.

## 3. Database

Replace `CHANGE_ME` with your own password here and in step 6.

```bash
sudo systemctl enable --now mysql
sudo mysql <<'SQL'
CREATE DATABASE travelagency;
CREATE USER 'travel'@'localhost' IDENTIFIED BY 'CHANGE_ME';
GRANT ALL PRIVILEGES ON travelagency.* TO 'travel'@'localhost';
SQL
mysql -u travel -p -e "SHOW DATABASES;"      # the list must include travelagency
```

## 4. Build

```bash
cd ~
git clone -b manual-setup git@github.com:Skyllie/Project_Travel_Agency_DevOps.git
cd Project_Travel_Agency_DevOps
mvn -B clean package -DskipTests
ls -lh target/TravelAgency.war
```

## 5. Tomcat 9

Two things matter here:

- **Tomcat 9 only.** The code uses `javax.*`; on Tomcat 10 or newer (`jakarta.*`) the application does not start.
- **Deploy as `ROOT.war`.** The forms in the JSP pages use absolute paths, so the application has to live at `/`.

```bash
sudo useradd -r -U -M -d /opt/tomcat -s /usr/sbin/nologin tomcat
sudo mkdir -p /opt/tomcat
cd /tmp
wget https://archive.apache.org/dist/tomcat/tomcat-9/v9.0.122/bin/apache-tomcat-9.0.122.tar.gz
sudo tar -xzf apache-tomcat-9.0.122.tar.gz -C /opt/tomcat --strip-components=1
sudo rm -rf /opt/tomcat/webapps/*
sudo cp ~/Project_Travel_Agency_DevOps/target/TravelAgency.war /opt/tomcat/webapps/ROOT.war
sudo chown -R tomcat:tomcat /opt/tomcat
```

## 6. Settings and systemd Service

The settings, including the database password, go into a separate file that only root can read:

```bash
sudo tee /etc/travelagency.env > /dev/null <<'EOF'
DB_TRAVELAGENCY_URL=jdbc:mysql://localhost:3306/travelagency?useSSL=false&allowPublicKeyRetrieval=true
DB_TRAVELAGENCY_USER=travel
DB_TRAVELAGENCY_PASSWORD=CHANGE_ME
HBM2DDL_AUTO=update
DB_SEED=true
EOF
sudo chmod 600 /etc/travelagency.env
```

`DB_SEED=true` loads the demo data on the first start; after that it is switched off below.

```bash
sudo tee /etc/systemd/system/tomcat.service > /dev/null <<'EOF'
[Unit]
Description=Apache Tomcat 9 - TravelAgency
After=network.target mysql.service
Wants=mysql.service

[Service]
User=tomcat
Group=tomcat
Environment=JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
EnvironmentFile=/etc/travelagency.env
ExecStart=/opt/tomcat/bin/catalina.sh run
SuccessExitStatus=143
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now tomcat
journalctl -u tomcat -f          # wait for "Server startup in ... milliseconds", then Ctrl+C
```

When Tomcat has started, turn off the demo data, otherwise it would be loaded again on every restart:

```bash
sudo sed -i 's/^DB_SEED=true/DB_SEED=false/' /etc/travelagency.env
sudo systemctl restart tomcat
```

## 7. Firewall

If `ufw` is on (`sudo ufw status`):

```bash
sudo ufw allow OpenSSH
sudo ufw allow 8080/tcp
```

## 8. Check the Deployment

```bash
curl -I http://localhost:8080/form-login      # HTTP/1.1 200
```

- Open `http://<server-IP>:8080/` in a browser: the login page opens.
- Register a new user on the registration page (`/create`), log in, create a hotel.
- Reboot the machine (`sudo reboot`): the site starts by itself and the data is still there.

## 9. Things to Check If Something Goes Wrong

| Problem | Cause and fix |
| --- | --- |
| MySQL does not start: "MySQL has been frozen to prevent damage to your system" | `/var/lib/mysql` has data from an older MariaDB or MySQL (for example `debian-10.6.flag`). If nothing there is needed: `sudo systemctl stop mysql`, `sudo mv /var/lib/mysql /var/lib/mysql.old`, `sudo rm /etc/mysql/FROZEN`, `sudo dpkg-reconfigure mysql-server-8.0`, `sudo systemctl start mysql` |
| Maven build fails in Lombok on JDK 17 | `pom.xml` must have Lombok 1.18.34 (it is already in `main`) |
| `Public Key Retrieval is not allowed` | Add `allowPublicKeyRetrieval=true` to `DB_TRAVELAGENCY_URL` |
| The login page opens, but forms return 404 | The WAR is not deployed as `ROOT.war` |
| 404 for every page, nothing about the app in the log | Tomcat 10 or newer — use Tomcat 9 |
| Data disappears after a restart | `HBM2DDL_AUTO=update` is missing in `/etc/travelagency.env` |
| Demo users (`michael.scott` and others) cannot log in | Their passwords in `insert.sql` are plain text, while login checks BCrypt hashes. Register a new user on `/create` |
| Logs | `journalctl -u tomcat -n 100 --no-pager` |
