# Rebuild the Nextcloud Kubernetes lab on another VM

This guide recreates the single-node K3s lab from scratch in a second VirtualBox Linux VM. It runs Nextcloud, MariaDB, Redis, and a Nextcloud web Deployment that you can scale to three pods.

The example uses VirtualBox NAT and opens the site only on the host computer. It is a learning lab, not a highly available or production deployment.

## What you need

- A second VM running Ubuntu Server LTS or another supported Debian-based Linux.
- Internet access from the VM to install K3s and pull container images.
- Recommended VM size: 2 virtual CPUs, 4 GiB RAM, and 25 GiB disk. The earlier VM had 1 CPU and about 3.8 GiB RAM; it worked for learning but was resource constrained.
- The public GitHub repository: [kubernetes-nextcloud-lab](https://github.com/franfuentes86/kubernetes-nextcloud-lab).

K3s documents a single-node server as a complete cluster that can host workloads. See the [K3s quick-start guide](https://docs.k3s.io/quick-start).

## 1. Configure the VM network

In VirtualBox, use **NAT** for the VM's network adapter. Bridged networking is not needed for this local-only setup.

Add a NAT port-forwarding rule for the second VM:

| Setting | Value |
| --- | --- |
| Name | nextcloud-lab-2 |
| Protocol | TCP |
| Host IP | 127.0.0.1 |
| Host Port | 8085 |
| Guest IP | blank |
| Guest Port | 30080 |

The host port is 8085 so it can coexist with the first VM's example port 8084. If 8085 is already in use, choose another unused host port and use that port in the browser later. Keep the guest port at 30080 because that is the Kubernetes NodePort in the manifest.

With Host IP set to 127.0.0.1, the site is reachable from the same computer running VirtualBox, not from other devices on the LAN.

## 2. Install K3s

Open a terminal in the new Linux VM:

```sh
sudo apt update
sudo apt install -y curl git
curl -sfL https://get.k3s.io | sudo sh -
```

K3s installs and starts a single-node cluster. Its bundled `kubectl` uses the local K3s configuration when run with `sudo`.

Check the node and system pods:

```sh
sudo kubectl get nodes
sudo kubectl get pods -A
sudo kubectl get storageclass
```

Wait until the node is `Ready` and the K3s system pods are running. The default `local-path` StorageClass should appear; MariaDB uses it for its database PVC. The K3s installer and kubeconfig behavior are described in the [official quick-start guide](https://docs.k3s.io/quick-start).

## 3. Get the manifests

Clone the public repository in the VM:

```sh
git clone https://github.com/franfuentes86/kubernetes-nextcloud-lab.git
cd kubernetes-nextcloud-lab
```

No GitHub token is needed to clone this public repository.

## 4. Create the namespace and credentials

Create the namespace:

```sh
sudo kubectl apply -f k8s/00-namespace.yaml
```

Create strong passwords locally. This prompts without showing what you type, creates a temporary protected environment file, sends it to Kubernetes, then deletes the temporary file. Store the passwords in a password manager so you can log in later.

```sh
read -rsp "MariaDB root password: " DB_ROOT; printf '\n'
read -rsp "Nextcloud database password: " DB_PASS; printf '\n'
read -rsp "Nextcloud admin password: " NC_ADMIN_PASS; printf '\n'

SECRET_FILE=$(mktemp)
chmod 600 "$SECRET_FILE"
printf 'mariadb-root-password=%s\nmariadb-password=%s\nadmin-password=%s\n' \
  "$DB_ROOT" "$DB_PASS" "$NC_ADMIN_PASS" > "$SECRET_FILE"

sudo kubectl -n nextcloud create secret generic nextcloud-credentials \
  --from-env-file="$SECRET_FILE"

rm -f "$SECRET_FILE"
unset DB_ROOT DB_PASS NC_ADMIN_PASS SECRET_FILE
```

Use a password with no newline characters. Do not save Secret YAML or paste these passwords into GitHub. If you need to recreate the Secret, the MariaDB data volume must be considered too: changing Secret values does not change passwords inside an already initialized database.

## 5. Apply storage and workloads

Create the shared Nextcloud volume, then the MariaDB, Redis, and Nextcloud workloads:

```sh
sudo kubectl apply -f k8s/10-storage.yaml
sudo kubectl apply -f k8s/20-workloads.yaml
```

The Nextcloud volume is a hostPath directory at `/var/lib/nextcloud-k8s/html` on this VM. Create it and set ownership for the official Nextcloud container before starting the app:

```sh
sudo install -d -o 33 -g 33 /var/lib/nextcloud-k8s/html
```

If Nextcloud has already started and initialized this directory, do not change ownership blindly; inspect the pod and directory first.

Wait for the one initial Nextcloud pod to be ready:

```sh
sudo kubectl -n nextcloud get pods,pvc,svc
sudo kubectl -n nextcloud rollout status deployment/mariadb
sudo kubectl -n nextcloud rollout status deployment/redis
sudo kubectl -n nextcloud rollout status deployment/nextcloud
```

A newly created Nextcloud instance needs a few minutes for first-run initialization. Check pod logs if the rollout does not complete:

```sh
sudo kubectl -n nextcloud logs deployment/nextcloud
sudo kubectl -n nextcloud describe pods
```

## 6. Open Nextcloud, then scale to three pods

From the host computer running VirtualBox, open:

```text
http://127.0.0.1:8085
```

Log in as `admin` with the Nextcloud admin password you entered earlier. Confirm the initial install works before scaling.

Then scale the Nextcloud web Deployment to three replicas:

```sh
sudo kubectl -n nextcloud scale deployment/nextcloud --replicas=3
sudo kubectl -n nextcloud get pods -o wide
```

All three pods use the same shared files volume and the same MariaDB and Redis services. This is suitable for practicing Kubernetes scaling on one node; it does not provide high availability. The VM may be CPU or memory constrained. Scale back to one replica if it becomes sluggish:

```sh
sudo kubectl -n nextcloud scale deployment/nextcloud --replicas=1
```

## Troubleshooting

### Pods cannot pull images

Test DNS and HTTPS from the VM:

```sh
getent hosts registry-1.docker.io
curl -I https://registry-1.docker.io/v2/
```

An HTTP `401` response from the registry endpoint means DNS and TLS reached the registry; it is expected without registry credentials. If DNS lookup fails in VirtualBox NAT, identify the VM's network interface with `ip route` and check its DNS configuration. The prior lab used VirtualBox NAT DNS `10.0.2.3`; on a system using systemd-resolved, a temporary setting can be applied with `sudo resolvectl dns <interface> 10.0.2.3`, then `sudo resolvectl flush-caches`. Replace `<interface>` with the actual interface name. Fix VM network access before restarting failed pods.

Inspect image-pull errors with:

```sh
sudo kubectl -n nextcloud describe pod <pod-name>
```

### PVC is Pending

Check that K3s has a default StorageClass and that the static Nextcloud claim binds:

```sh
sudo kubectl get storageclass
sudo kubectl -n nextcloud get pvc
sudo kubectl get pv
```

MariaDB should use `local-path`; Nextcloud HTML should bind to `nextcloud-shared` with `nextcloud-rwx`.

### Nextcloud reports an untrusted domain

Use the same host name/IP that is in `NEXTCLOUD_TRUSTED_DOMAINS` in `k8s/20-workloads.yaml`. The current manifest trusts `127.0.0.1` and `localhost`, matching the local forwarded URL. If you change the URL or expose it to your LAN, update the trusted domain and the VirtualBox port-forwarding/listening settings deliberately.

### Port 8085 does not open

Check that the NAT rule forwards host TCP 8085 to guest TCP 30080, then inspect the NodePort Service:

```sh
sudo kubectl -n nextcloud get service nextcloud
sudo kubectl -n nextcloud get pods
curl -I http://127.0.0.1:30080
```

The curl test runs inside the VM. From the host, use the host port from the NAT rule (8085 in this guide).

## Data and cleanup

The Nextcloud hostPath and MariaDB PVC contain persistent data. Deleting a Deployment does not necessarily delete its PVC or the files on disk. Do not remove `/var/lib/nextcloud-k8s/html` or the MariaDB PVC unless you intend to discard the instance. Keep backups of both Nextcloud files and the database; a VM snapshot alone is not a tested backup.

For a full disposable reset, uninstalling K3s removes the cluster and its workloads, but hostPath data may remain on disk. Review the [K3s uninstall documentation](https://docs.k3s.io/installation/uninstall) and inspect the VM's data before deleting anything.
