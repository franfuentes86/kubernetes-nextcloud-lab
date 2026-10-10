# Kubernetes Nextcloud lab

Single-node K3s lab that runs Nextcloud with three web pods, MariaDB, and Redis.

> This repository is public. It contains no real passwords or kubeconfig. Create the Kubernetes Secret locally before applying the application manifests.

## Lab setup

- One VirtualBox Linux VM running K3s.
- VM has 1 CPU and about 3.8 GiB RAM. Three Nextcloud pods are for learning and testing; they do not provide high availability and may compete for CPU and memory.
- VirtualBox NAT port forwarding: host TCP `127.0.0.1:8084` to VM TCP `30080`.
- Open Nextcloud at [http://127.0.0.1:8084](http://127.0.0.1:8084) from the host computer.

## Apply

On a fresh VM, create the namespace and secret first. Replace each placeholder with a strong value; do not commit the resulting secret.

```sh
kubectl apply -f k8s/00-namespace.yaml

kubectl -n nextcloud create secret generic nextcloud-credentials \
  --from-literal=mariadb-root-password='REPLACE_WITH_STRONG_ROOT_PASSWORD' \
  --from-literal=mariadb-password='REPLACE_WITH_STRONG_DATABASE_PASSWORD' \
  --from-literal=admin-password='REPLACE_WITH_STRONG_NEXTCLOUD_ADMIN_PASSWORD'
```

Then apply the storage and workloads:

```sh
kubectl apply -f k8s/10-storage.yaml
kubectl apply -f k8s/20-workloads.yaml
kubectl -n nextcloud rollout status deployment/mariadb
kubectl -n nextcloud rollout status deployment/redis
kubectl -n nextcloud rollout status deployment/nextcloud
kubectl -n nextcloud get pods,pvc,svc
```

The first Nextcloud pod initializes the shared data directory. The other replicas wait for the database and shared files. For a new install, wait for initialization to finish before logging in.

## Storage notes

- Nextcloud shared files use a manually provisioned 8 GiB `hostPath` volume at `/var/lib/nextcloud-k8s/html` on the VM, exposed as RWX for this single-node lab. The path is local to that VM and is not a backup.
- MariaDB uses a 3 GiB `local-path` PVC. Back up the database and Nextcloud data before VM maintenance.
- The shared volume and single database are not a production high-availability design.

## Useful commands

```sh
kubectl -n nextcloud get pods -o wide
kubectl -n nextcloud logs deployment/nextcloud
kubectl -n nextcloud logs deployment/mariadb
kubectl -n nextcloud scale deployment/nextcloud --replicas=1
kubectl -n nextcloud scale deployment/nextcloud --replicas=3
kubectl -n nextcloud get secret nextcloud-credentials
```

The last command shows Secret metadata only; avoid printing or sharing Secret data. To see the admin password later, retrieve the `admin-password` key locally and keep it private.

## Network troubleshooting

K3s pulls images from registries such as Docker Hub. If name lookup fails on the VM, fix VM DNS/network access first; Kubernetes cannot pull images until the node can reach the registry. This lab previously used the VirtualBox NAT DNS resolver `10.0.2.3`.

## Layout

- `k8s/00-namespace.yaml`: namespace
- `k8s/10-storage.yaml`: shared Nextcloud PV/PVC
- `k8s/20-workloads.yaml`: MariaDB, Redis, and three Nextcloud replicas
- `.gitignore`: excludes local secret/config artifacts
