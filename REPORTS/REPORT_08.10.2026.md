# DevOps Report

## General Information

**Period:** 01.10.2026 – 08.10.2026
**Report date:** 08.10.2026
**Author:** Rostyslav
**Project:** TravelAgency

**Goal:** Deploy the TravelAgency web application on two Oracle Linux 9 virtual machines — the application and the database on separate machines — with the VMs created by Vagrant and configured by Ansible.

**Summary:** I chose the TravelAgency project because it is not demanding on PC hardware. First I ran the application on a single Ubuntu machine to check how it works. Then I described the whole deployment as code: a Vagrantfile creates two Oracle Linux 9 VMs in VMware Workstation, and an Ansible playbook sets up MySQL on one VM and Tomcat with the application on the other.

## Project Choice

I chose TravelAgency because it is not demanding on PC hardware, and the whole project runs on a regular home PC. It is one Java web application (a WAR file on Tomcat) with a MySQL database. It builds with Maven in about 30 seconds, and the deployment fits on two small VMs (2 GB and 1.5 GB of RAM). For comparison, the reference project GreenCity has three services, including an Angular frontend whose build alone needs 8 GB of RAM.

## Goals

**Main goal:** Deploy TravelAgency on two Oracle Linux VMs according to the checklist of the card "Setup a Webapp (Oracle Linux VMs)": application works, database hosted on a separate machine, OS is Oracle Linux, SELinux in permissive mode, firewall on and configured properly.

**Other goals:**

- Automate the deployment with Ansible (card "Implement Automatisation Setup a Webapp (Ansible)"), so the environment can be rebuilt from scratch with a few commands.
- Write a step-by-step deployment guide.

## Tasks Completed

| # | Task | Status | Owner | Finished | Notes |
| --- | --- | --- | --- | --- | --- |
| 1 | Chose the TravelAgency project | Done | Rostyslav | 01.10.2026 | Not demanding on PC hardware — see "Project Choice" |
| 2 | Test run on a single Ubuntu 22.04 machine: OpenJDK 17, Maven, MySQL 8.0, Tomcat 9.0.122, application deployed as `ROOT.war` | Done | Rostyslav | 06.10.2026 | The site works in the browser |
| 3 | Fixed the build on JDK 17 and stopped the database from being re-created on every start | Done | Rostyslav | 06.10.2026 | WAR built in 26.5 s, 29 MB |
| 4 | Vagrantfile for 2 Oracle Linux 9 VMs on VMware Workstation: `ol-db` (192.168.56.21) and `ol-app` (192.168.56.22), box `bento/oraclelinux-9`, host-only network with static IPs, SSH key for Ansible | Done | Rostyslav | 06.10.2026 | Created with `vagrant up`, deleted with `vagrant destroy -f` |
| 5 | Ansible role `common` for both VMs: hostname, `/etc/hosts`, SELinux in permissive mode, firewalld turned on | Done | Rostyslav | 06.10.2026 | |
| 6 | Ansible role `mysql` for `ol-db`: MySQL 8.4, database `travelagency`, user allowed only from `ol-app`, port 3306 open only for `ol-app` | Done | Rostyslav | 06.10.2026 | |
| 7 | Ansible role `tomcat` for `ol-app`: Java 17, Tomcat 9 as a systemd service, application as `ROOT.war`, settings in `/etc/travelagency.env` (readable by root only), check that the login page answers | Done | Rostyslav | 06.10.2026 | Demo data is loaded only into an empty database |
| 8 | Database password stored in `ansible-vault`; playbook checked with `ansible-lint` | Done | Rostyslav | 06.10.2026 | `ansible-lint` production profile passes |
| 9 | Step-by-step deployment guide `DEPLOY.md` | Done | Rostyslav | 07.10.2026 | |

## Results

**What I did:**

- Ran the application on one machine to see what it needs: Java 17, Tomcat 9, MySQL and three environment variables for the database connection.
- Wrote a Vagrantfile that creates both Oracle Linux 9 VMs in VMware Workstation.
- Wrote an Ansible playbook with three roles (`common`, `mysql`, `tomcat`) that sets up both VMs.
- Wrote a deployment guide.

**What I achieved:**

- The application builds on JDK 17 and works on a single machine.
- The two-VM deployment is fully described in code. The environment is built from scratch with `vagrant up` and one `ansible-playbook site.yml` run.
- The playbook implements every item of the card checklist:

| Checklist item | How it is done |
| --- | --- |
| Application works | Role `tomcat`; the last task waits until `/form-login` answers |
| Database hosted on separated machine | MySQL on `ol-db`; the application connects to `192.168.56.21` |
| OS is Oracle Linux | Vagrant box `bento/oraclelinux-9` |
| SELinux in permissive mode | Role `common`, module `ansible.posix.selinux` |
| Firewall is on and configured properly | firewalld on both VMs; port 3306 open only for `ol-app` |

## Problems and Solutions

| # | Problem | Solution | Status |
| --- | --- | --- | --- |
| 1 | MySQL on Ubuntu would not start: "MySQL has been frozen to prevent damage to your system". `/var/lib/mysql` still had files from an old MariaDB 10.6 | Moved the old data to `/var/lib/mysql.old-mariadb`, removed `/etc/mysql/FROZEN`, ran `dpkg-reconfigure mysql-server-8.0` | Done |
| 2 | Lombok 1.18.20 does not support JDK 17 | Upgraded Lombok to 1.18.34 | Done |
| 3 | `hibernate.hbm2ddl.auto: create` deletes all tables on every start, so all data is lost after a restart | Schema mode and demo-data loading set by environment variables (`HBM2DDL_AUTO=update`, `DB_SEED`) | Done |
| 4 | The JSP forms use absolute paths, and the code uses `javax.*`, so the application only works at `/` and only on Tomcat 9 | Tomcat 9.0.122, application deployed as `ROOT.war` | Done |
| 5 | MySQL 8.4 has the `mysql_native_password` plugin turned off, and the Ansible MySQL module uses it by default, so creating the database user would fail | User created with `caching_sha2_password` | Done |
| 6 | After a reboot `ol-app` can start before MySQL on `ol-db`, and the application fails to start | The Tomcat service waits until port 3306 on `ol-db` is open | Done |

## Next Steps

- Rebuild the environment from scratch (`vagrant destroy -f`, `vagrant up`, `ansible-playbook site.yml`) and check all 5 checklist items with screenshots.
- Start the next card: "Deploying a Containerized Web Application" (Docker, Docker Compose).

## Tools and Technologies Used

- **VMware Workstation Pro:** runs the VMs on a regular PC.
- **Vagrant:** creates the Oracle Linux VMs from a Vagrantfile.
- **Ansible, ansible-vault, ansible-lint:** sets up the VMs, keeps the database password encrypted, checks the playbook.
- **Oracle Linux 9:** OS of the VMs.
- **OpenJDK 17, Maven, Apache Tomcat 9:** build and run the application.
- **MySQL:** database.
- **systemd, firewalld, SELinux:** Tomcat service, firewall rules, SELinux mode.

## Comments and Conclusions

Running the application on one machine first was useful: it showed what the application needs and exposed problems in the template code (the database being deleted on every start, the Java version) before the multi-VM setup. With Vagrant and Ansible, the whole environment is described in code, so it can be deleted and built again the same way at any time.

## Appendix and Resources

- Deployment guide: `DEPLOY.md`
- Infrastructure code: `vagrant/Vagrantfile`, `ansible/`
- Reference project: <https://github.com/TroyanVova/GreenCity_Full>
- Application template: <https://github.com/DevOps-ProjectLevel/travelagency>
