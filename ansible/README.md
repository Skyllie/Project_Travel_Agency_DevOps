# Ansible: Application and Database on Two Oracle Linux VMs

**How to run it — step by step in [`../README.md`](../README.md).** This file describes what the playbook does and where things are.

The VMs are created by Vagrant (`../vagrant/Vagrantfile`); Ansible configures them:

| VM | IP | What Ansible sets up |
| --- | --- | --- |
| `ol-db` | 192.168.56.21 | MySQL 8.4, database `travelagency`, user `travel` (allowed only from the `ol-app` IP), port 3306 open only for `ol-app` |
| `ol-app` | 192.168.56.22 | Java 17, Tomcat 9 as a systemd service, the application as `ROOT.war`, port 8080 |
| both | — | hostname, `/etc/hosts`, SELinux in permissive mode, firewalld on |

Checklist of the card "Setup a Webapp (Oracle Linux VMs)":

| Item | Where it is done |
| --- | --- |
| Application works | Role `tomcat`; the last task waits until `/form-login` answers |
| Database hosted on separated machine | Role `mysql` on `ol-db`; the application connects to `192.168.56.21` |
| OS is Oracle Linux | Box `bento/oraclelinux-9` in `../vagrant/Vagrantfile` |
| SELinux in permissive mode | Role `common`, module `ansible.posix.selinux` |
| Firewall is on and configured properly | Role `common` (firewalld on) + a rich rule for port 3306 in role `mysql` |

## Structure

```
ansible/
├── ansible.cfg
├── requirements.yml        ← collections ansible.posix and community.mysql (versions pinned)
├── inventory/hosts.yml     ← VM IPs, user vagrant
├── group_vars/all/
│   ├── main.yml            ← database name, user, addresses taken from the inventory
│   └── vault.yml           ← database password (encrypted with ansible-vault)
├── site.yml                ← common → mysql → tomcat
└── roles/
    ├── common/             ← hostname, /etc/hosts, SELinux, firewalld
    ├── mysql/              ← MySQL 8.4, database, user, firewall rule
    └── tomcat/             ← Java 17, Tomcat 9, systemd, WAR, settings
```

## How It Works

- The database password comes from `group_vars/all/vault.yml` (ansible-vault). On `ol-app` it is written to `/etc/travelagency.env` with mode `0600`, and the Tomcat systemd unit reads it from there.
- The MySQL user is created with `caching_sha2_password`, because MySQL 8.4 has the old `mysql_native_password` plugin turned off.
- The demo data from `insert.sql` is loaded only when the database is empty (`DB_SEED=true` on the first start). After that the flag is switched off.
- After a reboot, Tomcat waits until port 3306 on `ol-db` is open; otherwise the application would fail to start.
- A second run of the playbook changes nothing (`changed=0`). If the WAR has changed, Ansible removes the old unpacked version and restarts Tomcat.
