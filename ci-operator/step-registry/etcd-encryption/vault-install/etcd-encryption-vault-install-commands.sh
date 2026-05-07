#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "========================================="
echo "Vault Enterprise Installation via Helm"
echo "========================================="
echo "Version: ${VAULT_VERSION}"
echo "Namespace: ${VAULT_NAMESPACE}"
echo ""

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

# Check if Vault is already installed
if oc get namespace "${VAULT_NAMESPACE}" &>/dev/null; then
  echo "INFO: ${VAULT_NAMESPACE} namespace already exists"
  if helm list -n "${VAULT_NAMESPACE}" 2>/dev/null | grep -q vault; then
    echo "INFO: Vault is already installed"
    INSTALLED_VERSION=$(helm list -n "${VAULT_NAMESPACE}" -o json | jq -r '.[] | select(.name=="vault") | .app_version')
    echo "Installed version: ${INSTALLED_VERSION}"
    echo "Skipping installation"
    exit 0
  fi
fi

# Install Helm if not present
if ! command -v helm &> /dev/null; then
  echo "Installing Helm..."
  HELM_VERSION="3.14.0"
  curl -fsSL "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz" -o /tmp/helm.tar.gz
  tar -xzf /tmp/helm.tar.gz -C /tmp
  mkdir -p /tmp/bin
  mv /tmp/linux-amd64/helm /tmp/bin/helm
  chmod +x /tmp/bin/helm
  export PATH="/tmp/bin:$PATH"
  rm -rf /tmp/helm.tar.gz /tmp/linux-amd64
  echo "Helm installed: $(helm version --short)"
else
  echo "Helm already installed: $(helm version --short)"
fi

echo ""

# Create namespace
echo "Creating namespace ${VAULT_NAMESPACE}..."
oc create namespace "${VAULT_NAMESPACE}" || true

# Add restricted SCC for Vault service account
echo "Adding restricted SCC for Vault service account..."
oc adm policy add-scc-to-user restricted -z vault -n "${VAULT_NAMESPACE}"

# Create Vault license secret from mounted credential
# The license is mounted at /var/run/vault-license/license via prow credentials
if [ -f "/var/run/vault-license/license" ]; then
  echo "Creating Vault license secret from mounted credential..."
  oc create secret generic vault-license \
    --from-file=license=/var/run/vault-license/license \
    -n "${VAULT_NAMESPACE}" || true
else
  echo "WARNING: Vault license file not found at /var/run/vault-license/license"
  echo "Vault will run without a license (may have feature limitations)"
fi

# Add HashiCorp Helm repository
echo "Adding HashiCorp Helm repository..."
helm repo add hashicorp https://helm.releases.hashicorp.com || true
helm repo update

echo ""

# Create Helm values file for Vault
cat > /tmp/vault-values.yaml <<EOF
global:
  enabled: true
  tlsDisable: true

server:
  image:
    repository: ${VAULT_IMAGE_REPOSITORY}
    tag: ${VAULT_VERSION}
    pullPolicy: IfNotPresent

  resources:
    requests:
      memory: 256Mi
      cpu: 250m
    limits:
      memory: 512Mi
      cpu: 500m

  standalone:
    enabled: true
    config: |
      listener "tcp" {
        tls_disable = 1
        address = "[::]:8200"
      }

      storage "file" {
        path = "/vault/data"
      }

      disable_mlock = true

  dataStorage:
    enabled: true
    size: 2Gi
    storageClass: null
    accessMode: ReadWriteOnce

  service:
    enabled: true
    type: ClusterIP
    port: 8200

  extraEnvironmentVars:
    VAULT_LICENSE_PATH: /vault/license/license

  volumes:
    - name: license
      secret:
        secretName: vault-license
        optional: true

  volumeMounts:
    - name: license
      mountPath: /vault/license
      readOnly: true

injector:
  enabled: false

EOF

echo "Helm values file created:"
cat /tmp/vault-values.yaml

echo ""

# Install Vault via Helm
echo "Installing Vault Enterprise v${VAULT_VERSION}..."
helm install vault hashicorp/vault \
  --namespace "${VAULT_NAMESPACE}" \
  --version "${VAULT_CHART_VERSION}" \
  --values /tmp/vault-values.yaml \
  --wait \
  --timeout 10m

echo ""
echo "Vault installed successfully"

# Wait for Vault pod to be ready
echo ""
echo "Waiting for Vault pod to be ready..."
oc wait --for=condition=Ready pods \
  --selector='app.kubernetes.io/name=vault' \
  --selector='component=server' \
  -n "${VAULT_NAMESPACE}" \
  --timeout=10m

echo "Vault pod is ready"

# List pods
echo ""
echo "Vault pods:"
oc get pods -n "${VAULT_NAMESPACE}"

echo ""
echo "========================================="
echo "Vault Enterprise Installation Complete"
echo "========================================="
echo ""
echo "Summary:"
echo "  - Namespace: ${VAULT_NAMESPACE}"
echo "  - Version: ${VAULT_VERSION}"
echo "  - Service: vault.${VAULT_NAMESPACE}.svc:8200"
echo "  - Pod: vault-0 (Ready)"
echo ""
echo "Next step: Run etcd-encryption-vault-configure to initialize and configure Vault"
echo ""
