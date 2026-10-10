# Vagrant: Two Oracle Linux 9 VMs for TravelAgency

The `Vagrantfile` creates `ol-db` (192.168.56.21) and `ol-app` (192.168.56.22) in VMware Workstation
from the box `bento/oraclelinux-9`. Ansible configures them. The full procedure is in [`../README.md`](../README.md).

```powershell
vagrant plugin install vagrant-vmware-desktop   # once (also needs the Vagrant VMware Utility service)
vagrant up                                      # create / start
vagrant status
vagrant ssh ol-app                              # log in to a VM
vagrant halt                                    # shut down
vagrant destroy -f                              # delete both VMs
```

Put `control_node.pub` next to the `Vagrantfile`: the public SSH key of the Ubuntu machine that runs Ansible.
The file is in `.gitignore`.
