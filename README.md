# TravelAgency — DevOps Project

TravelAgency is a web application for a travel agency: users find and book hotels in different countries, and a manager role adds hotels and rooms and sees all users and their bookings. It is built with Java, Spring MVC, Spring Security, Hibernate, JSP and MySQL, and is packaged as a WAR file for Tomcat 9.

This repository is a DevOps project built around the application. Each deployment approach lives in its own branch with its own README. Weekly reports are in [`REPORTS/`](REPORTS).

## Branches

| Branch | What it shows |
| --- | --- |
| `manual-setup` | Manual deployment on one Ubuntu machine: Java 17, Maven, MySQL, Tomcat 9 as a systemd service |
| `ansible` | Two Oracle Linux 9 VMs — the application and the database on separate machines — created with Vagrant and configured with Ansible |

## Application Settings

The application reads its settings from environment variables:

| Variable | Meaning |
| --- | --- |
| `DB_TRAVELAGENCY_URL` | JDBC URL, for example `jdbc:mysql://localhost:3306/travelagency?useSSL=false&allowPublicKeyRetrieval=true` |
| `DB_TRAVELAGENCY_USER` | Database user |
| `DB_TRAVELAGENCY_PASSWORD` | Database password |
| `HBM2DDL_AUTO` | Hibernate schema mode; default `update` (tables are created if missing, data is kept) |
| `DB_SEED` | `true` loads the demo data from `insert.sql` at startup — use it only once, on an empty database; default `false` |

Build with JDK 17 and Maven:

```bash
mvn -B clean package -DskipTests      # result: target/TravelAgency.war
```

Deploy it to **Tomcat 9** as **`ROOT.war`**. The code uses `javax.*`, so it does not run on Tomcat 10 or newer, and the forms use absolute paths, so the application has to live at `/`.
