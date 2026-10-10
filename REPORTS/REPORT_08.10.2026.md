# DevOps Report

## General Information

**Period:** 01.10.2026 – 08.10.2026
**Report date:** 08.10.2026
**Author:** Rostyslav
**Project:** TravelAgency

**Goal:** Deploy the TravelAgency web application on two Oracle Linux 9 virtual machines — the application and the database on separate machines — with the VMs created by Vagrant and configured by Ansible.

**Summary:** I chose the TravelAgency project because it is not demanding on PC hardware. First I ran the application on a single Ubuntu machine to check how it works. Then I described the whole deployment as code: a Vagrantfile creates two Oracle Linux 9 VMs in VMware Workstation, and an Ansible playbook sets up MySQL on one VM and Tomcat with the application on the other. The deployment was run for real: both VMs are up, the playbook finished without errors, and the site works.

## Project Choice

I chose TravelAgency because it is not demanding on PC hardware, and the whole project runs on a regular home PC. It is one Java web application (a WAR file on Tomcat) with a MySQL database. It builds with Maven in about 30 seconds, and the deployment fits on two small VMs (2 GB and 1.5 GB of RAM). For comparison, the reference project GreenCity has three services, including an Angular frontend whose build alone needs 8 GB of RAM.

## Goals

**Main goal:** Deploy TravelAgency on two Oracle Linux VMs according to the checklist of the card "Setup a Webapp (Oracle Linux VMs)": application works, database hosted on a separate machine, OS is Oracle Linux, SELinux in permissive mode, firewall on and configured properly.

**Other goals:**

- Automate the deployment with Ansible (card "Implement Automatisation Setup a Webapp (Ansible)"), so the environment can be rebuilt from scratch with a few commands.
- Organize the GitHub repository the same way as the reference project: one branch per deployment approach.
- Write a step-by-step deployment guide.

## Tasks Completed

| # | Task | Status | Owner | Finished | Notes |
| --- | --- | --- | --- | --- | --- |
| 1 | Chose the TravelAgency project | Done | Rostyslav | 01.10.2026 | Not demanding on PC hardware — see "Project Choice" |
| 2 | Test run on a single Ubuntu 22.04 machine: OpenJDK 17, Maven, MySQL 8.0, Tomcat 9.0.122, application deployed as `ROOT.war` | Done | Rostyslav | 06.10.2026 | The site works in the browser |
| 3 | Fixed the build on JDK 17 and stopped the database from being re-created on every start | Done | Rostyslav | 06.10.2026 | WAR built in 26.5 s, 29 MB |
| 4 | Vagrantfile for 2 Oracle Linux 9 VMs on VMware Workstation: `ol-db` (192.168.56.21) and `ol-app` (192.168.56.22), box `bento/oraclelinux-9`, host-only network with static IPs, SSH key for Ansible | Done | Rostyslav | 06.10.2026 | |
| 5 | Ansible role `common` for both VMs: hostname, `/etc/hosts`, SELinux in permissive mode, firewalld turned on | Done | Rostyslav | 06.10.2026 | |
| 6 | Ansible role `mysql` for `ol-db`: MySQL 8.4, database `travelagency`, user allowed only from `ol-app`, port 3306 open only for `ol-app` | Done | Rostyslav | 06.10.2026 | |
| 7 | Ansible role `tomcat` for `ol-app`: Java 17, Tomcat 9 as a systemd service, application as `ROOT.war`, settings in `/etc/travelagency.env` (readable by root only), check that the login page answers | Done | Rostyslav | 06.10.2026 | Demo data is loaded only into an empty database |
| 8 | Database password stored in `ansible-vault`; playbook checked with `ansible-lint` | Done | Rostyslav | 06.10.2026 | `ansible-lint` production profile passes |
| 9 | Step-by-step deployment guide | Done | Rostyslav | 07.10.2026 | README of the `ansible` branch |
| 10 | Organized the GitHub repository like the reference project: `main` (code, branch list, reports), `manual-setup`, `ansible` | Done | Rostyslav | 08.10.2026 | Each branch has its own README with instructions |
| 11 | Installed Vagrant, Vagrant VMware Utility and the `vagrant-vmware-desktop` plugin on Windows; boxes and VMs kept on disk S: (`VAGRANT_HOME=S:\vagrant.d`) | Done | Rostyslav | 08.10.2026 | VMware Workstation 26H1 needed two registry workarounds — Problems 7 and 9 |
| 12 | Created both VMs with `vagrant up --provider=vmware_desktop` | Done | Rostyslav | 08.10.2026 | Host-only network VMnet2, 192.168.56.0/24 |
| 13 | SSH access from the Ubuntu control node to the VMs: key added with `control_node.pub` and `vagrant provision` | Done | Rostyslav | 08.10.2026 | Ubuntu reaches the VMs through the VMware NAT network; no extra network adapter needed |
| 14 | Ran the playbook `ansible-playbook site.yml` | Done | Rostyslav | 08.10.2026 | `ol-app`: ok=27, changed=17; `ol-db`: ok=16, changed=10; failed=0 |
| 15 | Checked the card checklist, a second playbook run and a reboot of both VMs | Done | Rostyslav | 08.10.2026 | Second run: `changed=0`; after `vagrant reload` the site starts by itself and the data is kept |

## Results

**What I did:**

- Ran the application on one machine to see what it needs: Java 17, Tomcat 9, MySQL and three environment variables for the database connection.
- Wrote a Vagrantfile that creates both Oracle Linux 9 VMs in VMware Workstation, and an Ansible playbook with three roles (`common`, `mysql`, `tomcat`) that sets them up.
- Organized the repository into branches and wrote a deployment guide.
- Ran the whole deployment on my PC and fixed the problems that came up on the way.

**What I achieved:**

- TravelAgency runs on two Oracle Linux 9 VMs: the application on `ol-app` (`http://192.168.56.22:8080/`) and the database on a separate VM, `ol-db`.
- The environment is described in code and is built with `vagrant up` and one `ansible-playbook site.yml` run. The first run finished with `failed=0`.
- Every item of the card checklist is implemented and checked:

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
| 7 | The Vagrant VMware Utility installer stopped with "requires a valid installation of VMware Workstation". VMware Workstation 26H1 is a 64-bit program and registers itself in the 64-bit part of the registry, while the utility looks in the 32-bit part (`WOW6432Node`). Known issue: hashicorp/vagrant-vmware-desktop #177 | Created `HKLM\SOFTWARE\WOW6432Node\VMware, Inc.\VMware Workstation` with `InstallPath` (`S:\VMWare Workstation\`) and `ProductVersion` (`26.0.0.25388281`), then installed the utility again | Done |
| 8 | The first `vagrant up` created the VMs in VirtualBox instead of VMware. The `vagrant-vmware-desktop` plugin was not installed (Vagrant keeps plugins in `VAGRANT_HOME`, which had just moved to disk S:), so Vagrant silently used VirtualBox | Deleted the VirtualBox VMs, installed the plugin, removed the VirtualBox host-only adapter on 192.168.56.1 (same subnet), set `VAGRANT_DEFAULT_PROVIDER=vmware_desktop` and ran `vagrant up --provider=vmware_desktop` | Done |
| 9 | `vagrant up` failed with "Vagrant failed to create a new VMware networking device: Failed to create new device". From the utility's source code: it reads VMware networks from `WOW6432Node\VMware, Inc.\VMnetLib\VMnetConfig`, which is empty on 26H1, so it tried to create a network device named "unknown" | Created host-only network VMnet2 (192.168.56.0/24, no DHCP) in the Virtual Network Editor and copied the network settings to the 32-bit part of the registry with `reg copy`; Vagrant then reused VMnet2 | Done |
| 10 | `ssh` on the Ubuntu control node would not start: `/etc/ssh/ssh_config: line 54: Bad configuration option: allowusers`. `AllowUsers` is an SSH server option, but it was in the client config | Commented out the line (backup in `/etc/ssh/ssh_config.bak`) | Done |

## Next Steps

- Remove the need for the VMware 26H1 registry workarounds: use VMware Workstation 25H2u1 or a fixed Vagrant VMware Utility. Until then, run `reg copy` again after any change in the Virtual Network Editor.
- Start the next card: "Deploying a Containerized Web Application" (Docker, Docker Compose).

## Tools and Technologies Used

- **VMware Workstation Pro 26H1:** runs the VMs on a regular PC.
- **Vagrant, `vagrant-vmware-desktop`, Vagrant VMware Utility:** create the Oracle Linux VMs from a Vagrantfile.
- **Ansible, ansible-vault, ansible-lint:** set up the VMs, keep the database password encrypted, check the playbook.
- **Oracle Linux 9:** OS of the VMs.
- **OpenJDK 17, Maven, Apache Tomcat 9:** build and run the application.
- **MySQL:** database.
- **systemd, firewalld, SELinux:** Tomcat service, firewall rules, SELinux mode.
- **Windows registry (`reg`), VMware Virtual Network Editor:** workarounds for VMware 26H1.
- **Git, GitHub:** one branch per deployment approach, reports in `main`.

## Comments and Conclusions

Running the application on one machine first was useful: it showed what the application needs and exposed problems in the template code before the multi-VM setup. Most of the time during the real deployment went not into the application but into the tools: VMware Workstation 26H1 is newer than the Vagrant VMware Utility supports. Reading the utility's source code showed the exact cause — it looks for VMware in the 32-bit part of the registry — and led to a small, targeted workaround instead of guessing. With Vagrant and Ansible, the whole environment is described in code, so it can be deleted and built again the same way at any time.

## Appendix and Resources

- Deployment guide: README of the `ansible` branch
- Infrastructure code: `vagrant/Vagrantfile`, `ansible/` (branch `ansible`)
- Reference project: <https://github.com/TroyanVova/GreenCity_Full>
- Application template: <https://github.com/DevOps-ProjectLevel/travelagency>
- Vagrant VMware Utility and VMware Workstation 26H1, issue #177: <https://github.com/hashicorp/vagrant-vmware-desktop/issues/177>
