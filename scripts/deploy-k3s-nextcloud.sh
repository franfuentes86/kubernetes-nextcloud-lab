#!/usr/bin/env bash
# Rebuild the single-node K3s + Nextcloud lab from this repository.
set -Eeuo pipefail

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ "$(id -u)" -ne 0 ]] || die "Run this script as your normal VM user, not with sudo. It calls sudo when needed."
command -v sudo >/dev/null || die "sudo is required."
command -v apt-get >/dev/null || die "This script expects Ubuntu/Debian with apt."

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$REPO_DIR/k8s/00-namespace.yaml" && -f "$REPO_DIR/k8s/20-workloads.yaml" ]] || die "Run this script from a clone of kubernetes-nextcloud-lab."

say "Installing required tools"
sudo apt-get update
sudo apt-get install -y curl git

if ! systemctl is-active --quiet k3s; then
  say "Installing or starting K3s"
  curl -sfL https://get.k3s.io | sudo sh -
fi

k() { sudo kubectl "$@"; }

say "Waiting for the K3s node"
k wait --for=condition=Ready node --all --timeout=300s
k get nodes
k get storageclass

say "Creating namespace"
k apply -f "$REPO_DIR/k8s/00-namespace.yaml"

if k -n nextcloud get secret nextcloud-credentials >/dev/null 2>&1; then
  say "Keeping the existing nextcloud-credentials Secret"
else
  say "Create passwords (input is hidden). Save the Nextcloud admin password in your password manager."
  read -r -s -p "MariaDB root password: " DB_ROOT; printf '\n'
  read -r -s -p "Nextcloud database password: " DB_PASS; printf '\n'
  read -r -s -p "Nextcloud admin password: " NC_ADMIN_PASS; printf '\n'
  [[ -n "$DB_ROOT" && -n "$DB_PASS" && -n "$NC_ADMIN_PASS" ]] || die "Passwords cannot be empty."

  SECRET_FILE="$(mktemp)"
  chmod 600 "$SECRET_FILE"
  cleanup() {
    [[ -z "${SECRET_FILE:-}" ]] || rm -f -- "$SECRET_FILE"
    unset DB_ROOT DB_PASS NC_ADMIN_PASS
  }
  trap cleanup EXIT
  printf 'mariadb-root-password=%s\nmariadb-password=%s\nadmin-password=%s\n' \
    "$DB_ROOT" "$DB_PASS" "$NC_ADMIN_PASS" > "$SECRET_FILE"
  k -n nextcloud create secret generic nextcloud-credentials --from-env-file="$SECRET_FILE"
  rm -f -- "$SECRET_FILE"
  SECRET_FILE=""
  unset DB_ROOT DB_PASS NC_ADMIN_PASS
  trap - EXIT
fi

say "Preparing the shared Nextcloud directory"
NC_DATA_DIR=/var/lib/nextcloud-k8s/html
if [[ ! -e "$NC_DATA_DIR" ]]; then
  sudo install -d -o 33 -g 33 "$NC_DATA_DIR"
else
  printf 'Keeping existing data directory %s; inspect its ownership and contents if pods cannot write.\n' "$NC_DATA_DIR"
fi

say "Applying persistent storage and workloads"
k apply -f "$REPO_DIR/k8s/10-storage.yaml"
k apply -f "$REPO_DIR/k8s/20-workloads.yaml"

say "Waiting for MariaDB and Redis"
k -n nextcloud rollout status deployment/mariadb --timeout=600s
k -n nextcloud rollout status deployment/redis --timeout=300s

say "Waiting for initial Nextcloud setup"
k -n nextcloud rollout status deployment/nextcloud --timeout=900s
installed=false
for attempt in $(seq 1 120); do
  if k -n nextcloud exec deployment/nextcloud -- php -r 'include "/var/www/html/config/config.php"; exit(!empty($CONFIG["installed"]) ? 0 : 1);' >/dev/null 2>&1; then
    installed=true
    break
  fi
  sleep 5
done
[[ "$installed" == true ]] || {
  k -n nextcloud get pods,pvc,svc
  k -n nextcloud logs deployment/nextcloud --tail=100 || true
  die "Nextcloud did not report a completed first-run installation within 10 minutes."
}

say "Scaling Nextcloud to three replicas"
k -n nextcloud scale deployment/nextcloud --replicas=3
k -n nextcloud rollout status deployment/nextcloud --timeout=600s
k -n nextcloud get pods,pvc,svc

cat <<'NEXT'
Deployment finished.

From the VirtualBox host, open:
  http://127.0.0.1:8085

The VM's NAT rule must forward host TCP 8085 to guest TCP 30080.
Log in with username "admin" and the admin password entered above.
NEXT
