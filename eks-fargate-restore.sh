#!/usr/bin/env bash
# =============================================================================
# EKS Fargate Cluster Restore Helper
# =============================================================================
# Guides you through restoring resources from a backup created by
# eks-fargate-backup.sh. Supports dry-run and selective restore.
#
# NOTE: Full cluster restore (EKS control plane, VPC, IAM) must be done via
#       Terraform / CloudFormation / AWS CLI — this script handles Kubernetes
#       resource re-application after the cluster exists.
# =============================================================================
set -euo pipefail

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ------------- Colors ---------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ------------- Defaults -------------------------------------------------------
BACKUP_DIR=""
DRY_RUN=false
FORCE=false
ONLY_SECTION=""
RESTORE_SECRETS=false
KUBECTL_FLAGS=""

APPLIED=0
SKIPPED=0
FAILED=0
declare -a FAILED_ITEMS=()

# =============================================================================
# Logging
# =============================================================================
log_header() {
    echo -e "\n${BOLD}${BLUE}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}  $1${NC}"
    echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════════════════${NC}"
}

log_section() { echo -e "\n${BOLD}${CYAN}▶ $1${NC}"; }
log_info()    { echo -e "  ${GREEN}✓${NC} $1"; ((APPLIED++)) || true; }
log_warn()    { echo -e "  ${YELLOW}⚠${NC} $1"; ((SKIPPED++)) || true; }
log_error()   { echo -e "  ${RED}✗${NC} $1" >&2; ((FAILED++)) || true; FAILED_ITEMS+=("$1"); }
log_step()    { echo -e "    ${CYAN}→${NC} $1"; }

# =============================================================================
# Usage
# =============================================================================
usage() {
    cat <<EOF
${BOLD}EKS Fargate Restore Helper v${VERSION}${NC}

${BOLD}USAGE:${NC}
  $(basename "$0") --backup-dir <path> [OPTIONS]

${BOLD}REQUIRED:${NC}
  -b, --backup-dir <path>   Path to the backup directory (not the .tar.gz)

${BOLD}OPTIONS:${NC}
  --dry-run                 Show what would be applied, make no changes
  --force                   Apply even if resources already exist (kubectl apply)
  --only <section>          Only restore: namespaces|rbac|workloads|networking|
                            config|storage|policy|crds|helm|addons
  --restore-secrets         Include secrets in restore (default: skipped)
  --namespace <ns>          Limit restore to a specific namespace
  -h, --help                Show this help

${BOLD}RESTORE ORDER (recommended):${NC}
  1. Namespaces & RBAC
  2. CRDs (must exist before custom resources)
  3. ConfigMaps & Secrets
  4. Storage (PVs/PVCs)
  5. Workloads (Deployments, etc.)
  6. Networking (Services, Ingresses)
  7. Policy (HPA, PDB)
  8. Add-on configs
  9. Helm releases

${BOLD}IMPORTANT NOTES:${NC}
  - Remove 'resourceVersion', 'uid', 'creationTimestamp' from resources before applying
  - Status fields are ignored by kubectl apply
  - Some system resources (kube-system CRDs) should NOT be re-applied
  - aws-auth ConfigMap: apply carefully — wrong values lock you out

${BOLD}EXAMPLE:${NC}
  # Extract first
  tar -xzf my-cluster_20240101_120000.tar.gz

  # Dry-run to verify
  $(basename "$0") --backup-dir ./my-cluster_20240101_120000 --dry-run

  # Restore everything
  $(basename "$0") --backup-dir ./my-cluster_20240101_120000 --force

  # Restore only workloads
  $(basename "$0") --backup-dir ./my-cluster_20240101_120000 --only workloads
EOF
}

# =============================================================================
# Argument parsing
# =============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -b|--backup-dir)    BACKUP_DIR="$2"; shift 2 ;;
            --dry-run)          DRY_RUN=true; shift ;;
            --force)            FORCE=true; shift ;;
            --only)             ONLY_SECTION="$2"; shift 2 ;;
            --restore-secrets)  RESTORE_SECRETS=true; shift ;;
            --namespace)        KUBECTL_FLAGS="-n $2"; shift 2 ;;
            -h|--help)          usage; exit 0 ;;
            *) echo "Unknown option: $1"; usage; exit 1 ;;
        esac
    done

    if [[ -z "${BACKUP_DIR}" ]]; then
        echo -e "${RED}Error: --backup-dir is required${NC}" >&2
        usage; exit 1
    fi

    if [[ ! -d "${BACKUP_DIR}" ]]; then
        echo -e "${RED}Backup directory not found: ${BACKUP_DIR}${NC}" >&2
        exit 1
    fi
}

# =============================================================================
# Helpers
# =============================================================================
apply_file() {
    local label="$1"
    local file="$2"

    [[ ! -f "${file}" ]] && { log_warn "${label}: file not found ($(basename "${file}"))"; return; }

    # Check if file has actual content (not just empty/null)
    local item_count
    item_count="$(grep -c '^kind:' "${file}" 2>/dev/null || echo 0)"
    if [[ "${item_count}" -eq 0 ]]; then
        log_warn "${label}: empty (no resources)"
        return
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_step "(dry-run) kubectl apply -f $(basename "${file}") [${item_count} resource(s)]"
        return
    fi

    local cmd="kubectl apply"
    [[ -n "${KUBECTL_FLAGS}" ]] && cmd="${cmd} ${KUBECTL_FLAGS}"

    if ${cmd} -f "${file}" 2>/dev/null; then
        log_info "${label} (${item_count} resources)"
    else
        # Try with --server-side for conflicts
        if ${cmd} --server-side -f "${file}" 2>/dev/null; then
            log_info "${label} (${item_count} resources, server-side)"
        else
            log_error "${label}: apply failed → ${file}"
        fi
    fi
}

confirm_step() {
    local prompt="$1"
    [[ "${FORCE}" == "true" ]] && return 0
    [[ "${DRY_RUN}" == "true" ]] && return 0

    echo -e "\n  ${YELLOW}${prompt}${NC}"
    read -r -p "  Continue? [y/N] " response
    [[ "${response}" =~ ^[Yy]$ ]] || { echo "  Skipped."; return 1; }
}

should_run() {
    local section="$1"
    [[ -z "${ONLY_SECTION}" ]] && return 0
    [[ "${ONLY_SECTION}" == "${section}" ]] && return 0
    return 1
}

# =============================================================================
# Show backup manifest
# =============================================================================
show_manifest() {
    local manifest="${BACKUP_DIR}/BACKUP_MANIFEST.json"
    if [[ -f "${manifest}" ]]; then
        log_header "Backup Manifest"
        jq . "${manifest}" 2>/dev/null || cat "${manifest}"
    fi
}

# =============================================================================
# Restore sections
# =============================================================================
restore_namespaces() {
    log_section "Restoring Namespaces"
    local dir="${BACKUP_DIR}/kubernetes"

    echo -e "  ${YELLOW}⚠ System namespaces (kube-system, default, etc.) will be skipped${NC}"
    confirm_step "Apply namespaces?" || return

    if [[ "${DRY_RUN}" == "false" ]] && [[ -f "${dir}/namespaces.yaml" ]]; then
        # Filter out system namespaces
        grep -v 'kubernetes.io/metadata.name: \(kube-system\|kube-public\|kube-node-lease\|default\)' \
            "${dir}/namespaces.yaml" | kubectl apply -f - 2>/dev/null || \
        log_warn "Some namespace applies failed (may already exist)"
        log_info "Namespaces applied"
    else
        apply_file "Namespaces" "${dir}/namespaces.yaml"
    fi
}

restore_rbac() {
    log_section "Restoring RBAC"
    local dir="${BACKUP_DIR}/kubernetes/rbac"

    confirm_step "Apply RBAC (ClusterRoles, RoleBindings, etc.)?" || return

    apply_file "ClusterRoles" "${dir}/clusterroles.yaml"
    apply_file "ClusterRoleBindings" "${dir}/clusterrolebindings.yaml"
    apply_file "Roles" "${dir}/roles.yaml"
    apply_file "RoleBindings" "${dir}/rolebindings.yaml"
    apply_file "ServiceAccounts" "${dir}/serviceaccounts.yaml"

    echo ""
    echo -e "  ${RED}${BOLD}IMPORTANT: aws-auth ConfigMap${NC}"
    echo -e "  The aws-auth ConfigMap controls IAM → Kubernetes RBAC mapping."
    echo -e "  Applying a wrong aws-auth can lock you out of the cluster."
    echo -e "  Review ${dir}/aws-auth-configmap.yaml before applying manually."
    log_warn "aws-auth: NOT automatically applied — review and apply manually"
}

restore_crds() {
    log_section "Restoring CRDs"
    local dir="${BACKUP_DIR}/kubernetes/crds"

    echo -e "  ${YELLOW}⚠ CRDs must be applied before custom resource instances${NC}"
    confirm_step "Apply CRDs?" || return

    apply_file "CRDs" "${dir}/crds.yaml"

    if [[ "${DRY_RUN}" == "false" ]]; then
        log_step "Waiting for CRDs to become established..."
        kubectl wait --for=condition=Established crds --all --timeout=60s 2>/dev/null || \
            log_warn "Some CRDs may not be established yet"
    fi

    # Custom resource instances
    local cr_dir="${BACKUP_DIR}/custom-resources"
    if [[ -d "${cr_dir}" ]]; then
        log_section "Restoring Custom Resource Instances"
        confirm_step "Apply custom resource instances?" || return

        for cr_file in "${cr_dir}"/*.yaml; do
            [[ -f "${cr_file}" ]] || continue
            local crd_name
            crd_name="$(basename "${cr_file}" .yaml)"
            apply_file "CR: ${crd_name}" "${cr_file}"
        done
    fi
}

restore_config() {
    log_section "Restoring ConfigMaps"
    local dir="${BACKUP_DIR}/kubernetes/config"

    confirm_step "Apply ConfigMaps?" || return
    apply_file "ConfigMaps" "${dir}/configmaps.yaml"

    if [[ "${RESTORE_SECRETS}" == "true" ]]; then
        echo -e "  ${RED}${BOLD}WARNING: Restoring Secrets — ensure cluster-at-rest encryption is enabled${NC}"
        confirm_step "Apply Secrets?" || return
        apply_file "Secrets" "${dir}/secrets.yaml"
    else
        log_warn "Secrets: skipped (use --restore-secrets to include)"
    fi
}

restore_storage() {
    log_section "Restoring Storage"
    local dir="${BACKUP_DIR}/kubernetes/storage"

    echo -e "  ${YELLOW}⚠ PersistentVolumes with 'Retain' policy can be re-bound.${NC}"
    echo -e "  ${YELLOW}  PVs with 'Delete' policy may reference deleted EBS volumes.${NC}"
    confirm_step "Apply StorageClasses?" || return
    apply_file "StorageClasses" "${dir}/storageclasses.yaml"

    confirm_step "Apply PersistentVolumes?" || return
    apply_file "PersistentVolumes" "${dir}/persistentvolumes.yaml"

    confirm_step "Apply PersistentVolumeClaims?" || return
    apply_file "PersistentVolumeClaims" "${dir}/persistentvolumeclaims.yaml"
}

restore_workloads() {
    log_section "Restoring Workloads"
    local dir="${BACKUP_DIR}/kubernetes/workloads"

    confirm_step "Apply Deployments?" || return
    apply_file "Deployments" "${dir}/deployments.yaml"

    confirm_step "Apply StatefulSets?" || return
    apply_file "StatefulSets" "${dir}/statefulsets.yaml"

    confirm_step "Apply DaemonSets?" || return
    apply_file "DaemonSets" "${dir}/daemonsets.yaml"

    confirm_step "Apply CronJobs?" || return
    apply_file "CronJobs" "${dir}/cronjobs.yaml"

    log_warn "Jobs: not auto-applied (may re-trigger one-off jobs)"
}

restore_networking() {
    log_section "Restoring Kubernetes Networking"
    local dir="${BACKUP_DIR}/kubernetes/networking"

    confirm_step "Apply Services?" || return
    apply_file "Services" "${dir}/services.yaml"

    confirm_step "Apply Ingresses?" || return
    apply_file "Ingresses" "${dir}/ingresses.yaml"

    apply_file "IngressClasses" "${dir}/ingressclasses.yaml"
    apply_file "NetworkPolicies" "${dir}/networkpolicies.yaml"
}

restore_policy() {
    log_section "Restoring Policy Resources"
    local dir="${BACKUP_DIR}/kubernetes/policy"

    apply_file "HorizontalPodAutoscalers" "${dir}/hpa.yaml"
    apply_file "PodDisruptionBudgets" "${dir}/pdb.yaml"
    apply_file "ResourceQuotas" "${dir}/resourcequotas.yaml"
    apply_file "LimitRanges" "${dir}/limitranges.yaml"
}

restore_helm() {
    log_section "Restoring Helm Releases"
    local dir="${BACKUP_DIR}/helm"

    if [[ ! -d "${dir}" ]]; then
        log_warn "No Helm backup found"
        return
    fi

    if ! command -v helm &>/dev/null; then
        log_warn "helm not installed"
        return
    fi

    echo ""
    echo -e "  ${YELLOW}Helm releases cannot be automatically re-installed — each release${NC}"
    echo -e "  ${YELLOW}requires its chart repo and version. The saved values are shown below.${NC}"
    echo ""

    local releases_json="${dir}/releases-list.json"
    if [[ -f "${releases_json}" ]]; then
        echo -e "  ${BOLD}Backed-up Helm releases:${NC}"
        jq -r '.[] | "  \(.namespace)/\(.name) — chart: \(.chart) — status: \(.status)"' \
            "${releases_json}" 2>/dev/null || cat "${releases_json}"
        echo ""
        echo -e "  ${CYAN}Values files are in: ${dir}/values/${NC}"
        echo -e "  ${CYAN}Re-install example:${NC}"
        echo -e "    helm repo add eks https://aws.github.io/eks-charts"
        echo -e "    helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \\"
        echo -e "      -n kube-system -f ${dir}/values/kube-system-aws-load-balancer-controller-values.yaml"
    fi
}

restore_addon_configs() {
    log_section "Restoring Add-on Configurations"
    local dir="${BACKUP_DIR}/addons"

    echo -e "  ${YELLOW}⚠ Managed EKS add-ons (kube-proxy, CoreDNS, VPC CNI) should be${NC}"
    echo -e "  ${YELLOW}  re-enabled via 'aws eks create-addon', not by applying their yamls.${NC}"
    echo ""

    # CoreDNS custom config
    if [[ -f "${dir}/coredns/configmap.yaml" ]]; then
        confirm_step "Apply CoreDNS ConfigMap (custom DNS config)?" || true
        apply_file "CoreDNS ConfigMap" "${dir}/coredns/configmap.yaml"
    fi

    # LBC configuration
    if [[ -d "${dir}/aws-load-balancer-controller" ]]; then
        echo -e "  ${CYAN}AWS LB Controller:${NC} Re-install via Helm using backed-up values."
        echo -e "  ${CYAN}Values location:${NC} ${BACKUP_DIR}/helm/values/kube-system-aws-load-balancer-controller-values.yaml"
    fi
}

print_post_restore_checklist() {
    cat <<EOF

${BOLD}${GREEN}═══════════════════════════════════════════════════════════════${NC}
${BOLD}${GREEN}  Post-Restore Checklist${NC}
${BOLD}${GREEN}═══════════════════════════════════════════════════════════════${NC}

${BOLD}1. Verify EKS Add-ons${NC}
   aws eks list-addons --cluster-name <name> --region <region>
   aws eks update-addon --cluster-name <name> --addon-name coredns ...

${BOLD}2. Check Fargate Profile coverage${NC}
   kubectl get pods --all-namespaces | grep Pending
   (Pending pods may lack a matching Fargate profile)

${BOLD}3. Verify aws-auth / Access Entries${NC}
   kubectl get configmap aws-auth -n kube-system -o yaml
   OR
   aws eks list-access-entries --cluster-name <name>

${BOLD}4. Verify AWS Load Balancer Controller${NC}
   kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
   kubectl get ingressclass

${BOLD}5. Verify IRSA (IAM Roles for Service Accounts)${NC}
   kubectl get sa --all-namespaces -o yaml | grep eks.amazonaws.com/role-arn

${BOLD}6. Check Ingresses provisioned ALBs/NLBs${NC}
   kubectl get ingress --all-namespaces
   aws elbv2 describe-load-balancers --region <region>

${BOLD}7. Run a smoke test${NC}
   kubectl get nodes
   kubectl get pods --all-namespaces | grep -v Running | grep -v Completed

EOF
}

# =============================================================================
# Main
# =============================================================================
main() {
    parse_args "$@"

    log_header "EKS Fargate Restore Helper v${VERSION}"
    echo -e "  Backup dir: ${BOLD}${BACKUP_DIR}${NC}"
    [[ "${DRY_RUN}" == "true" ]] && echo -e "  ${YELLOW}Mode: DRY RUN (no changes will be made)${NC}"
    [[ -n "${ONLY_SECTION}" ]] && echo -e "  Section: ${BOLD}${ONLY_SECTION}${NC}"

    show_manifest

    if [[ "${DRY_RUN}" == "false" ]] && [[ "${FORCE}" == "false" ]]; then
        echo ""
        echo -e "  ${RED}${BOLD}⚠ This will apply Kubernetes resources to the CURRENT cluster.${NC}"
        echo -e "  ${YELLOW}Make sure your kubeconfig points to the correct cluster:${NC}"
        kubectl cluster-info 2>/dev/null | head -1 || true
        echo ""
        read -r -p "  Are you sure you want to continue? [y/N] " response
        [[ "${response}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
    fi

    should_run "namespaces"  && restore_namespaces
    should_run "rbac"        && restore_rbac
    should_run "crds"        && restore_crds
    should_run "config"      && restore_config
    should_run "storage"     && restore_storage
    should_run "workloads"   && restore_workloads
    should_run "networking"  && restore_networking
    should_run "policy"      && restore_policy
    should_run "addons"      && restore_addon_configs
    should_run "helm"        && restore_helm

    echo ""
    log_header "Restore Summary"
    echo -e "  ${GREEN}✓ Applied:${NC} ${APPLIED}"
    echo -e "  ${YELLOW}○ Skipped:${NC} ${SKIPPED}"
    echo -e "  ${RED}✗ Failed:${NC}  ${FAILED}"

    if [[ ${#FAILED_ITEMS[@]} -gt 0 ]]; then
        echo ""
        echo -e "  ${RED}Failed items:${NC}"
        for item in "${FAILED_ITEMS[@]}"; do
            echo -e "    - ${item}"
        done
    fi

    print_post_restore_checklist
}

main "$@"
