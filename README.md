# TravelAgency — Infrastructure as Code with Terraform

This branch describes the whole load-balanced stack in **Terraform** (provider `kreuzwerker/docker`): the network, the database volume, MySQL, the application servers and the Nginx load balancer.
It covers the card "Implement Infrastructure as Code".
It builds on the `docker-load-balancer` branch: the same image, the same Nginx logic, but created, changed and deleted by `terraform apply` / `terraform destroy` instead of Docker Compose.

```
terraform apply
   │  provider kreuzwerker/docker  →  /var/run/docker.sock
   ▼
network travelagency-tf-net 172.31.0.0/24        volume travelagency-tf-db-data
   ├── travelagency-tf-db     mysql:8.4            172.31.0.10
   ├── travelagency-tf-app1   travelagency:local   172.31.0.11  DB_SEED=auto
   ├── travelagency-tf-app2…N travelagency:local   172.31.0.12… DB_SEED=false
   └── travelagency-tf-lb     nginx:1.28-alpine    172.31.0.20  host port 80
                              config generated from templates/nginx.conf.tftpl
```

| File | What it is |
| --- | --- |
| `terraform/versions.tf` | Terraform and provider versions, local state, the Docker provider |
| `terraform/variables.tf` | Everything that can change: number of servers, algorithm, sticky sessions, port, passwords |
| `terraform/main.tf` | The resources: network, volume, images, `db`, `app_first`, `app_more`, `lb` |
| `terraform/templates/nginx.conf.tftpl` | Nginx config, generated for the chosen algorithm and number of servers |
| `terraform/outputs.tf` | URL, servers and their IPs, algorithm, image |
| `terraform/terraform.tfvars.example` | Passwords and settings; copy to `terraform.tfvars` |

## 1. Install Terraform on Ubuntu

Docker is needed as well (README of the `docker` branch).

```bash
sudo apt-get install -y gnupg software-properties-common wget
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install -y terraform
terraform -version
```

## 2. Create the Stack

```bash
git clone -b terraform https://github.com/Skyllie/Project_Travel_Agency_DevOps.git ~/travel-tf
cd ~/travel-tf
docker build -t travelagency:local .          # Terraform uses this image, it does not build it
cd terraform
cp terraform.tfvars.example terraform.tfvars
nano terraform.tfvars                         # change the two passwords
terraform init                                # downloads the Docker provider
terraform fmt -check && terraform validate    # style and syntax
terraform plan                                # what will be created: 9 resources with 3 servers
terraform apply                               # answer "yes"; 2–3 minutes
terraform output
```

Port 80 must be free: stop the Compose stack of the `docker-load-balancer` branch first (`docker compose down` in its folder) or set `lb_port = 8088`.

`apply` creates the resources in this order, and waits for each `healthy` before the next step (`wait = true`): network and volume → MySQL → app1 (creates the tables, loads the demo data) → the other servers → the load balancer.

## 3. Change the Infrastructure

Every change is a change of a variable and one `terraform apply`. `plan` shows what will happen before anything is touched.

| Change | Command | What Terraform does |
| --- | --- | --- |
| Another algorithm | `terraform apply -var lb_algorithm=weighted` | Generates a new Nginx config and recreates only the `lb` container |
| Fewer servers | `terraform apply -var app_replicas=2` | Removes `app3`, recreates `lb` without it |
| More servers | `terraform apply -var app_replicas=5` | Adds `app4` and `app5` (172.31.0.14, .15), recreates `lb` with them |
| Sticky sessions off | `terraform apply -var lb_sticky=false` | Recreates `lb` |
| New version of the app | `docker build -t travelagency:v2 ..` and `terraform apply -var app_image=travelagency:v2` | Recreates the application servers with the new image |
| Delete everything | `terraform destroy` | Removes containers, network and volume (the database too); the images stay |

To keep a change, write it into `terraform.tfvars` instead of `-var`.

Check the result with the script from the previous branch: `../lb/demo.sh` (it calls `http://localhost/form-login`).

### Drift: Terraform restores what was changed by hand

```bash
docker rm -f travelagency-tf-app2      # "someone" deleted a server
terraform plan                          # Plan: 1 to add — travelagency-tf-app2
terraform apply                         # it is back
```

## 4. Check

| What | Command | Expected |
| --- | --- | --- |
| Code is formatted and valid | `terraform fmt -check && terraform validate` | `Success! The configuration is valid.` |
| Everything was created | `terraform state list` | `data.docker_image.app`, network, volume, two images, `db`, `app_first`, `app_more[0]`, `app_more[1]`, `lb` |
| Containers are healthy | `docker ps --filter name=travelagency-tf` | all `healthy` |
| The site answers | `curl -s -o /dev/null -w '%{http_code}\n' http://localhost/form-login` | `200` |
| Requests are spread | `../lb/demo.sh` | app1, app2, app3 |
| Nothing to change | `terraform plan` right after `apply` | `No changes. Your infrastructure matches the configuration.` |
| Demo data loaded once | `docker logs travelagency-tf-app1 \| grep entrypoint` | first apply: `DB_SEED=true` |

## 5. Why It Is Built This Way

- **Image built outside Terraform.** `data "docker_image"` only reads the local image. Building is the job of `docker build` (and later of Jenkins); Terraform describes where and how the image runs. A new version is a new tag in `app_image`.
- **`app_first` and `app_more`.** On an empty database the first server must create the tables alone. `app_more` depends on `app_first`, and `wait = true` makes Terraform wait until it is healthy.
- **Config generated from a template.** `templatefile()` writes the pool for the chosen algorithm and one upstream per server. The file is uploaded into the container (`upload`), so the algorithm or the number of servers changes in one variable.
- **Validation of variables.** A wrong algorithm name or `app_replicas = 7` stops at `plan` with a clear message, before anything changes.
- **Secrets.** Passwords are `sensitive`: `plan` shows them as `(sensitive value)`. They are in `terraform.tfvars` and in the state, both in `.gitignore`. The state file holds them in plain text, so it stays on the Ubuntu machine only.
- **Separate subnet and names.** `172.31.0.0/24` and the `travelagency-tf-` prefix do not clash with the Compose stack (`172.30.0.0/24`, `travelagency-`).

## 6. If Something Goes Wrong

| Problem | What to do |
| --- | --- |
| `did not find docker image 'travelagency:local'` | Build it: `docker build -t travelagency:local ..` (from the `terraform` folder) |
| `port is already allocated` | Port 80 is busy (the Compose stack?): `docker compose down` there, or `lb_port = 8088` |
| `Pool overlaps with other one on this address space` | Another Docker network uses `172.31.0.0/24`: `docker network ls`, or set `subnet` |
| `container ... is not healthy` / timeout at `app_first` | `docker logs travelagency-tf-app1`; with an empty database the first start takes 1–2 minutes |
| `Error acquiring the state lock` | Another `terraform` is running; if it crashed: `terraform force-unlock <ID>` |
| `permission denied ... docker.sock` | The user is not in the `docker` group: `sudo usermod -aG docker $USER`, log in again |
