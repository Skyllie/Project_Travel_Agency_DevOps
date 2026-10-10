# TravelAgency — Oracle Linux VMs with Vagrant and Ansible

This branch deploys TravelAgency to two Oracle Linux 9 VMs: the application on `ol-app` and the database on a separate `ol-db`.
**Vagrant** creates the VMs on Windows, and **Ansible** configures them from an Ubuntu machine.
It covers the cards "Setup a Webapp (Oracle Linux VMs)" and "Implement Automatisation Setup a Webapp (Ansible)".

```
Windows + VMware Workstation Pro
├── Ubuntu (control node)    192.168.56.10   builds the WAR (Maven) and runs Ansible
├── ol-app (Oracle Linux 9)  192.168.56.22   Java 17 + Tomcat 9 + TravelAgency, port 8080
└── ol-db  (Oracle Linux 9)  192.168.56.21   MySQL 8.4, port 3306 open only for ol-app
```

| Path | What it is |
| --- | --- |
| `vagrant/Vagrantfile` | The two VMs: box, IPs, CPU, RAM. Run on Windows |
| `ansible/` | Playbook and roles `common`, `mysql`, `tomcat` — details in [`ansible/README.md`](ansible/README.md) |

---

## 1. What You Need

- Virtualization turned on in BIOS/UEFI (Intel VT-x or AMD-V).
- 16 GB RAM on the PC: the two VMs take 3.5 GB, plus the Ubuntu VM.
- About 15 GB free on the Windows disk (the Oracle Linux box and two VMs).
- An Ubuntu 22.04 VM in VMware as the control node, with at least 2 GB free disk space.

## 2. Windows

### 2.1. VMware Version

Open VMware → **Help → About VMware Workstation**.

- **17.x or 25H2** — go to 2.2.
- **26H1** — the Vagrant VMware Utility does not detect this version on Windows yet
  ([issue #177](https://github.com/hashicorp/vagrant-vmware-desktop/issues/177), still open in August 2026). Two options:
  - install VMware Workstation **25H2u1** instead of 26H1;
  - or keep 26H1 and, after step 2.3, apply the workaround from that issue: it writes the VMware version where the utility looks for it.
    PowerShell **as Administrator**:
    ```powershell
    # Where VMware is installed and which version (if empty, take the version from Help → About)
    Get-ItemProperty 'HKLM:\SOFTWARE\VMware, Inc.\VMware Workstation' | Select-Object InstallPath, ProductVersion

    $base = 'HKLM:\SOFTWARE\WOW6432Node\VMware, Inc.'
    if (-not (Test-Path $base)) { New-Item -Path $base | Out-Null }
    if (-not (Test-Path "$base\VMware Workstation")) { New-Item -Path "$base\VMware Workstation" | Out-Null }
    Set-ItemProperty -Path $base -Name Core -Value 'VMware Workstation'
    Set-ItemProperty -Path "$base\VMware Workstation" -Name InstallPath -Value 'C:\Program Files\VMware\VMware Workstation\'
    Set-ItemProperty -Path "$base\VMware Workstation" -Name ProductVersion -Value '26.0.0.25388281'   # ← your version
    Get-Service *vagrant* | Restart-Service
    ```
    `InstallPath` is the folder with `vmware.exe`; `ProductVersion` is your version in the form `26.0.0.<build>`.

### 2.2. Vagrant

Install Vagrant for Windows AMD64 from <https://developer.hashicorp.com/vagrant/install> and restart the PC.

### 2.3. Vagrant VMware Utility

A separate Windows service that Vagrant uses to control VMware: <https://developer.hashicorp.com/vagrant/install/vmware> (Windows, MSI).

### 2.4. Plugin

PowerShell:

```powershell
vagrant plugin install vagrant-vmware-desktop
vagrant plugin list          # must show vagrant-vmware-desktop
```

### 2.5. Free Subnet 192.168.56.0

VMware → **Edit → Virtual Network Editor**. No vmnet may use `192.168.56.0`: Vagrant creates its own host-only network there.
If VMnet8 uses it, click Change Settings and give VMnet8 another subnet, for example `192.168.100.0`.
If VirtualBox is installed, its host-only adapter also uses `192.168.56.0/24` — remove it or move it to another subnet.

## 3. Ubuntu Control Node

### 3.1. SSH Key

```bash
ls ~/.ssh/id_ed25519.pub || ssh-keygen -t ed25519      # create a key if there is none; press Enter at the questions
cat ~/.ssh/id_ed25519.pub                               # copy this line — it is needed in step 5
```

### 3.2. Ansible

```bash
sudo apt install -y pipx
pipx ensurepath
```

Close the terminal, open a new one:

```bash
pipx install ansible-core
ansible --version          # core 2.17.x — the newest one for Python 3.10 (Ubuntu 22.04)
```

## 4. Get the Code and Build

```bash
cd ~
git clone -b ansible git@github.com:Skyllie/Project_Travel_Agency_DevOps.git
cd Project_Travel_Agency_DevOps
ansible-galaxy collection install -r ansible/requirements.yml
mvn -B clean package -DskipTests
ls -lh target/TravelAgency.war
```

The database password is in `ansible/group_vars/all/vault.yml`, encrypted with ansible-vault. You need the vault password to run the playbook.
To use your own password instead, replace the file content with one line `vault_travel_db_password: <your password>` and run
`ansible-vault encrypt ansible/group_vars/all/vault.yml`.

## 5. Create the VMs (Windows)

1. Clone this branch on Windows too (or copy the `vagrant` folder), for example to `C:\travel`.
2. Put the Ubuntu key from step 3.1 next to the `Vagrantfile`. PowerShell:
   ```powershell
   cd C:\travel\Project_Travel_Agency_DevOps\vagrant
   Set-Content -Encoding ascii -Path control_node.pub -Value 'ssh-ed25519 AAAA... user@user'   # ← your line
   ```
   Notepad also works: choose "Save as type: All files", otherwise the file becomes `control_node.pub.txt`.
3. Create the VMs:
   ```powershell
   vagrant up            # the first time it downloads the bento/oraclelinux-9 box — a few minutes
   vagrant status        # ol-db and ol-app: running (vmware_desktop)
   ```
   If you added `control_node.pub` after `vagrant up`, run `vagrant provision`.

## 6. Network Between Ubuntu and the VMs

Ubuntu is on the NAT network and does not see `192.168.56.0/24`, the network Vagrant created. Give it a second adapter:

1. **Edit → Virtual Network Editor** → find the vmnet with Subnet `192.168.56.0` and type Host-only (for example VMnet2).
2. Shut down Ubuntu → Settings → **Add → Network Adapter** → Custom → that vmnet → start Ubuntu.
3. Set IP `192.168.56.10` on the new adapter. Find its name with `nmcli device` or `ip a`, for example `ens37`.
   - Ubuntu Desktop:
     ```bash
     sudo nmcli con add type ethernet ifname ens37 con-name vagrant-net ipv4.method manual ipv4.addresses 192.168.56.10/24
     sudo nmcli con up vagrant-net
     ```
   - Ubuntu Server (no gateway: internet still goes through the first adapter):
     ```bash
     sudo tee /etc/netplan/60-vagrant-net.yaml > /dev/null <<'EOF'
     network:
       version: 2
       ethernets:
         ens37:
           addresses: [192.168.56.10/24]
     EOF
     sudo chmod 600 /etc/netplan/60-vagrant-net.yaml && sudo netplan apply
     ```
4. Check. Remove old host keys first, otherwise SSH reports "REMOTE HOST IDENTIFICATION HAS CHANGED":
   ```bash
   ssh-keygen -R 192.168.56.21; ssh-keygen -R 192.168.56.22
   ssh vagrant@192.168.56.21 hostname     # answer "yes" once; the output is ol-db, no password asked
   ```

## 7. Run Ansible

```bash
cd ~/Project_Travel_Agency_DevOps/ansible
ansible all -m ping --ask-vault-pass          # both VMs: "pong"
ansible-playbook site.yml --ask-vault-pass
```

The first run takes 5–10 minutes (MySQL, Java, Tomcat download). At the end, `PLAY RECAP` must show `failed=0` for both VMs.
The demo data from `insert.sql` is loaded once into the empty database; after that the `DB_SEED` flag is switched off.

## 8. Check the Deployment

| Card checklist item | How to check | Expected result |
| --- | --- | --- |
| Application works | Browser on Windows: `http://192.168.56.22:8080/` → register (`/create`), log in, create a hotel | Login page; everything is saved |
| Database hosted on separated machine | `vagrant ssh ol-app -c "sudo grep URL /etc/travelagency.env"` | `DB_TRAVELAGENCY_URL=jdbc:mysql://192.168.56.21:3306/...` |
| OS is Oracle Linux | `vagrant ssh ol-app -c "cat /etc/oracle-release"` | `Oracle Linux Server release 9.x` |
| SELinux in permissive mode | `vagrant ssh ol-db -c getenforce`, the same for `ol-app` | `Permissive` |
| Firewall is on and configured properly | `vagrant ssh ol-db -c "sudo firewall-cmd --list-all"`; PowerShell: `Test-NetConnection 192.168.56.21 -Port 3306` | A rich rule for 3306 only for `192.168.56.22`; `TcpTestSucceeded : False` |

Run the `vagrant ssh` commands in PowerShell from the `vagrant` folder.

Two more checks:

- **Reboot:** `vagrant reload` → after 1–2 minutes the site opens again and the data is still there. Tomcat waits until MySQL on `ol-db` is up.
- **Second run:** `ansible-playbook site.yml --ask-vault-pass` again → `PLAY RECAP` shows `changed=0`.

## 9. Day-to-Day Commands

| Task | Where | Command |
| --- | --- | --- |
| Shut down the VMs | Windows | `vagrant halt` |
| Start the VMs (the site starts by itself) | Windows | `vagrant up` |
| Log in to a VM | Windows | `vagrant ssh ol-app` / `vagrant ssh ol-db` |
| Application logs | Windows | `vagrant ssh ol-app -c "sudo journalctl -u tomcat -n 100 --no-pager"` |
| Deploy a new version | Ubuntu | `mvn -B clean package -DskipTests`, then `cd ansible && ansible-playbook site.yml --ask-vault-pass` |
| Rebuild everything from scratch | Windows, then Ubuntu | `vagrant destroy -f; vagrant up` → `ssh-keygen -R 192.168.56.21; ssh-keygen -R 192.168.56.22` → `ansible-playbook site.yml --ask-vault-pass` |

The vmnet stays after `vagrant destroy`, so the second Ubuntu adapter does not need to be set up again.

## 10. Things to Check If Something Goes Wrong

| Problem | What to do |
| --- | --- |
| `vagrant up`: VMware not found, or "did not respond" | Step 2.1 (26H1): the workaround or 25H2u1. Check that the Vagrant VMware Utility service is running: `Get-Service *vagrant*` |
| `vagrant up`: `NetworkingHostOnlyCollision` | Subnet `192.168.56.0` is already used — step 2.5 |
| VMs are very slow | Hyper-V / VBS is on — turn off Memory integrity and the Hyper-V features |
| `ssh vagrant@192.168.56.21` asks for a password | The key did not reach the VM: `control_node.pub` must contain exactly the line from `cat ~/.ssh/id_ed25519.pub` (step 5.2); then run `vagrant provision` |
| `UNREACHABLE` in Ansible | Step 6: is there an adapter with `192.168.56.10`, does `ssh vagrant@192.168.56.21` work without a password |
| `couldn't resolve module/action 'community.mysql...'` | Collections are missing: `ansible-galaxy collection install -r ansible/requirements.yml` |
| `Attempting to decrypt but no vault secrets found` | Add `--ask-vault-pass` |
| Error on `@mysql:8.4/server` | `vagrant ssh ol-db -c "sudo dnf -y update"` — the MySQL 8.4 module is in Oracle Linux 9.6 and newer |
| `.../target/TravelAgency.war not found` | Build the project — step 4 |
| Task "Wait until the login page answers" fails | Logs: `vagrant ssh ol-app -c "sudo journalctl -u tomcat -n 100 --no-pager"` |
| Tomcat stays in `activating` | It is waiting for MySQL: is `ol-db` running (`vagrant status`), `sudo systemctl status mysqld` on it |
| Demo users (`michael.scott` and others) cannot log in | Their passwords in `insert.sql` are plain text, while login checks BCrypt hashes. Register a new user on `/create` |
