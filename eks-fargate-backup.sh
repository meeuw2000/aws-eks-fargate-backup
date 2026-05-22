#!/usr/bin/env bash
# =============================================================================
# EKS Fargate Cluster Backup Script
# =============================================================================
# Backs up all components of an AWS EKS (Fargate) cluster before an upgrade:
#   - EKS cluster configuration & Fargate profiles
#   - EKS managed add-ons (kube-proxy, CoreDNS, VPC CNI, EBS CSI, etc.)
#   - IAM roles, policies & OIDC provider
#   - VPC, subnets, security groups
#   - AWS Load Balancers (ALB/NLB) and Target Groups
#   - All Kubernetes resources across all namespaces
#   - Helm releases with values
#   - Custom Resource Definitions + instances
#   - Special add-on configs (AWS LB Controller, CoreDNS, kube-proxy, VPC CNI)
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ------------- Colors ---------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ------------- Defaults -------------------------------------------------------
CLUSTER_NAME=""
REGION="${AWS_DEFAULT_REGION:-eu-central-1}"
OUTPUT_BASE_DIR="${SCRIPT_DIR}/backups"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR=""
SKIP_SECRETS=false
SKIP_HELM=false
SKIP_CUSTOM_RESOURCES=false
SKIP_AWS=false
COMPRESS=true
DRY_RUN=false
VERBOSE=false

# ------------- Counters -------------------------------------------------------
BACKED_UP=0
SKIPPED=0
FAILED=0
declare -a FAILED_ITEMS=()
LOG_FILE=""

# =============================================================================
# Logging
# =============================================================================
log_header() {
    echo -e "\n${BOLD}${BLUE}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}  $1${NC}"
    echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════════════════${NC}"
    [[ -n "${LOG_FILE}" ]] && echo -e "\n=== $1 ===" >> "${LOG_FILE}"
}

log_section() {
    echo -e "\n${BOLD}${CYAN}▶ $1${NC}"
    [[ -n "${LOG_FILE}" ]] && echo -e "\n▶ $1" >> "${LOG_FILE}"
}

log_info() {
    echo -e "  ${GREEN}✓${NC} $1"
    [[ -n "${LOG_FILE}" ]] && echo "[OK]   $1" >> "${LOG_FILE}"
    ((BACKED_UP++)) || true
}

log_warn() {
    echo -e "  ${YELLOW}⚠${NC} $1"
    [[ -n "${LOG_FILE}" ]] && echo "[WARN] $1" >> "${LOG_FILE}"
    ((SKIPPED++)) || true
}

log_error() {
    echo -e "  ${RED}✗${NC} $1" >&2
    [[ -n "${LOG_FILE}" ]] && echo "[ERR]  $1" >> "${LOG_FILE}"
    ((FAILED++)) || true
    FAILED_ITEMS+=("$1")
}

log_step() {
    echo -e "    ${CYAN}→${NC} $1"
    [[ -n "${LOG_FILE}" ]] && echo "      → $1" >> "${LOG_FILE}"
}

# =============================================================================
# Usage
# =============================================================================
usage() {
    cat <<EOF
${BOLD}EKS Fargate Backup Script v${VERSION}${NC}

${BOLD}USAGE:${NC}
  $(basename "$0") --cluster <name> [OPTIONS]

${BOLD}REQUIRED:${NC}
  -c, --cluster <name>        EKS cluster name

${BOLD}OPTIONS:${NC}
  -r, --region <region>       AWS region (default: ${REGION})
  -o, --output <dir>          Base output directory (default: ./backups)
  --skip-secrets              Skip backing up Kubernetes Secrets
  --skip-helm                 Skip Helm release backup
  --skip-custom-resources     Skip Custom Resource instances
  --skip-aws                  Skip AWS API calls (k8s resources only)
  --no-compress               Do not create .tar.gz archive
  --dry-run                   Show what would be backed up, no files written
  -v, --verbose               Verbose output
  -h, --help                  Show this help

${BOLD}EXAMPLES:${NC}
  $(basename "$0") --cluster my-cluster --region eu-central-1
  $(basename "$0") --cluster my-cluster --skip-secrets --no-compress
  $(basename "$0") --cluster my-cluster --dry-run

${BOLD}PREREQUISITES:${NC}
  kubectl, aws cli, jq, helm (optional)
  AWS credentials with EKS read access
  kubeconfig configured for the target cluster
EOF
}

# =============================================================================
# Argument parsing
# =============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--cluster)     CLUSTER_NAME="$2"; shift 2 ;;
            -r|--region)      REGION="$2"; shift 2 ;;
            -o|--output)      OUTPUT_BASE_DIR="$2"; shift 2 ;;
            --skip-secrets)   SKIP_SECRETS=true; shift ;;
            --skip-helm)      SKIP_HELM=true; shift ;;
            --skip-custom-resources) SKIP_CUSTOM_RESOURCES=true; shift ;;
            --skip-aws)       SKIP_AWS=true; shift ;;
            --no-compress)    COMPRESS=false; shift ;;
            --dry-run)        DRY_RUN=true; COMPRESS=false; shift ;;
            -v|--verbose)     VERBOSE=true; shift ;;
            -h|--help)        usage; exit 0 ;;
            *) echo "Unknown option: $1"; usage; exit 1 ;;
        esac
    done

    if [[ -z "${CLUSTER_NAME}" ]]; then
        echo -e "${RED}Error: --cluster is required${NC}" >&2
        usage; exit 1
    fi
}

# =============================================================================
# Prerequisites
# =============================================================================
check_dependencies() {
    log_section "Checking dependencies"
    local missing=()
    local deps=("kubectl" "aws" "jq")
    [[ "${SKIP_HELM}" == "false" ]] && deps+=("helm")

    for dep in "${deps[@]}"; do
        if command -v "${dep}" &>/dev/null; then
            log_step "${dep} found: $(command -v "${dep}")"
        else
            missing+=("${dep}")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${RED}Missing dependencies: ${missing[*]}${NC}" >&2
        exit 1
    fi
}

check_cluster_access() {
    log_section "Verifying cluster access"

    if [[ "${DRY_RUN}" == "false" ]] && [[ "${SKIP_AWS}" == "false" ]]; then
        if ! aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${REGION}" &>/dev/null; then
            echo -e "${RED}Cannot access EKS cluster '${CLUSTER_NAME}' in ${REGION}${NC}" >&2
            echo -e "${YELLOW}Check your AWS credentials and cluster name.${NC}" >&2
            exit 1
        fi
        log_step "AWS EKS access OK"
    fi

    if [[ "${DRY_RUN}" == "false" ]]; then
        if ! kubectl cluster-info &>/dev/null; then
            echo -e "${RED}Cannot connect to Kubernetes API${NC}" >&2
            echo -e "${YELLOW}Run: aws eks update-kubeconfig --name ${CLUSTER_NAME} --region ${REGION}${NC}" >&2
            exit 1
        fi
        local server
        server="$(kubectl cluster-info 2>/dev/null | head -1 | sed 's/.*at //')"
        log_step "Kubernetes API access OK: ${server}"
    fi
}

setup_backup_dir() {
    BACKUP_DIR="${OUTPUT_BASE_DIR}/${CLUSTER_NAME}_${TIMESTAMP}"
    LOG_FILE="${BACKUP_DIR}/backup.log"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_step "DRY RUN — backup directory would be: ${BACKUP_DIR}"
        return
    fi

    mkdir -p "${BACKUP_DIR}"
    touch "${LOG_FILE}"
    echo "Backup started: $(date)" >> "${LOG_FILE}"
    echo "Cluster: ${CLUSTER_NAME}" >> "${LOG_FILE}"
    echo "Region:  ${REGION}" >> "${LOG_FILE}"
    log_step "Backup directory: ${BACKUP_DIR}"
}

# =============================================================================
# Helper: save a kubectl resource
# =============================================================================
# save_k8s [flags...] <resource_type> <output_file>
save_k8s() {
    local output_file="${@: -1}"   # last arg
    local resource="${@: -2:1}"    # second to last
    local flags=("${@:1:$#-2}")   # everything before resource and file

    [[ "${DRY_RUN}" == "true" ]] && { log_step "(dry-run) kubectl get ${resource}"; return 0; }

    mkdir -p "$(dirname "${output_file}")"

    local raw_output
    if raw_output="$(kubectl get "${resource}" "${flags[@]}" -o yaml 2>/dev/null)"; then
        echo "${raw_output}" > "${output_file}"
        local count
        count="$(kubectl get "${resource}" "${flags[@]}" --no-headers 2>/dev/null | grep -c . || echo 0)"
        log_info "k8s/${resource} (${count}) → $(realpath --relative-to="${BACKUP_DIR}" "${output_file}")"
    else
        log_warn "k8s/${resource}: not found or no access"
    fi
}

# Helper: save AWS CLI call
save_aws() {
    local label="$1"
    local output_file="$2"
    shift 2

    [[ "${DRY_RUN}" == "true" ]] && { log_step "(dry-run) ${*}"; return 0; }
    [[ "${SKIP_AWS}" == "true" ]] && { log_warn "${label}: skipped (--skip-aws)"; return 0; }

    mkdir -p "$(dirname "${output_file}")"

    if "$@" > "${output_file}" 2>/dev/null; then
        log_info "${label} → $(realpath --relative-to="${BACKUP_DIR}" "${output_file}")"
    else
        log_warn "${label}: failed or empty"
        rm -f "${output_file}"
    fi
}

# =============================================================================
# Section 1: EKS Cluster
# =============================================================================
backup_eks_cluster() {
    log_header "EKS Cluster Configuration"
    local dir="${BACKUP_DIR}/cluster"

    # Cluster description
    save_aws "EKS cluster config" "${dir}/cluster-config.json" \
        aws eks describe-cluster \
            --name "${CLUSTER_NAME}" \
            --region "${REGION}"

    # Fargate profiles
    local profile_list
    profile_list="$(aws eks list-fargate-profiles \
        --cluster-name "${CLUSTER_NAME}" \
        --region "${REGION}" \
        --output json 2>/dev/null | jq -r '.fargateProfileNames[]' 2>/dev/null || true)"

    if [[ -n "${profile_list}" ]]; then
        mkdir -p "${dir}/fargate-profiles"
        while IFS= read -r profile; do
            save_aws "Fargate profile: ${profile}" "${dir}/fargate-profiles/${profile}.json" \
                aws eks describe-fargate-profile \
                    --cluster-name "${CLUSTER_NAME}" \
                    --fargate-profile-name "${profile}" \
                    --region "${REGION}"
        done <<< "${profile_list}"
    else
        log_warn "No Fargate profiles found (or --skip-aws set)"
    fi

    # List all profiles in one file too
    save_aws "Fargate profiles list" "${dir}/fargate-profiles-list.json" \
        aws eks list-fargate-profiles \
            --cluster-name "${CLUSTER_NAME}" \
            --region "${REGION}"

    # Node groups (managed node groups, may not exist on pure Fargate clusters)
    save_aws "Managed node groups" "${dir}/nodegroups-list.json" \
        aws eks list-nodegroups \
            --cluster-name "${CLUSTER_NAME}" \
            --region "${REGION}"

    local ng_list
    ng_list="$(aws eks list-nodegroups \
        --cluster-name "${CLUSTER_NAME}" \
        --region "${REGION}" \
        --output json 2>/dev/null | jq -r '.nodegroups[]' 2>/dev/null || true)"

    if [[ -n "${ng_list}" ]]; then
        mkdir -p "${dir}/nodegroups"
        while IFS= read -r ng; do
            save_aws "Node group: ${ng}" "${dir}/nodegroups/${ng}.json" \
                aws eks describe-nodegroup \
                    --cluster-name "${CLUSTER_NAME}" \
                    --nodegroup-name "${ng}" \
                    --region "${REGION}"
        done <<< "${ng_list}"
    fi

    # EKS Managed Add-ons
    save_aws "EKS add-ons list" "${dir}/addons-list.json" \
        aws eks list-addons \
            --cluster-name "${CLUSTER_NAME}" \
            --region "${REGION}"

    local addon_list
    addon_list="$(aws eks list-addons \
        --cluster-name "${CLUSTER_NAME}" \
        --region "${REGION}" \
        --output json 2>/dev/null | jq -r '.addons[]' 2>/dev/null || true)"

    if [[ -n "${addon_list}" ]]; then
        mkdir -p "${dir}/addons"
        while IFS= read -r addon; do
            save_aws "EKS add-on: ${addon}" "${dir}/addons/${addon}.json" \
                aws eks describe-addon \
                    --cluster-name "${CLUSTER_NAME}" \
                    --addon-name "${addon}" \
                    --region "${REGION}"

            # Also get available versions for reference
            save_aws "EKS add-on versions: ${addon}" "${dir}/addons/${addon}-versions.json" \
                aws eks describe-addon-versions \
                    --addon-name "${addon}" \
                    --region "${REGION}"
        done <<< "${addon_list}"
    fi

    # Access entries (EKS 1.29+ access management)
    save_aws "EKS access entries" "${dir}/access-entries.json" \
        aws eks list-access-entries \
            --cluster-name "${CLUSTER_NAME}" \
            --region "${REGION}"

    # EKS Pod Identity associations
    save_aws "EKS pod identity associations" "${dir}/pod-identity-associations.json" \
        aws eks list-pod-identity-associations \
            --cluster-name "${CLUSTER_NAME}" \
            --region "${REGION}"
}

# =============================================================================
# Section 2: IAM & OIDC
# =============================================================================
backup_iam() {
    log_header "IAM & OIDC"
    local dir="${BACKUP_DIR}/iam"

    [[ "${SKIP_AWS}" == "true" ]] && { log_warn "Skipping IAM (--skip-aws)"; return; }

    # Get cluster details to extract role ARN and VPC ID
    local cluster_json="${BACKUP_DIR}/cluster/cluster-config.json"
    if [[ ! -f "${cluster_json}" ]]; then
        log_warn "Cluster config not found, skipping IAM role details"
        return
    fi

    local cluster_role_arn vpc_id oidc_issuer
    cluster_role_arn="$(jq -r '.cluster.roleArn // empty' "${cluster_json}" 2>/dev/null || true)"
    oidc_issuer="$(jq -r '.cluster.identity.oidc.issuer // empty' "${cluster_json}" 2>/dev/null || true)"

    # Cluster service role
    if [[ -n "${cluster_role_arn}" ]]; then
        local role_name="${cluster_role_arn##*/}"
        save_aws "Cluster IAM role" "${dir}/cluster-role.json" \
            aws iam get-role --role-name "${role_name}"
        save_aws "Cluster IAM role policies" "${dir}/cluster-role-policies.json" \
            aws iam list-attached-role-policies --role-name "${role_name}"
    fi

    # OIDC provider
    if [[ -n "${oidc_issuer}" ]]; then
        local oidc_id="${oidc_issuer##*/}"
        save_aws "OIDC providers list" "${dir}/oidc-providers.json" \
            aws iam list-open-id-connect-providers

        local account_id
        account_id="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
        if [[ -n "${account_id}" ]]; then
            local oidc_arn="arn:aws:iam::${account_id}:oidc-provider/${oidc_issuer#https://}"
            save_aws "OIDC provider detail" "${dir}/oidc-provider.json" \
                aws iam get-open-id-connect-provider \
                    --open-id-connect-provider-arn "${oidc_arn}"
        fi
    fi

    # Get all IAM roles tagged with the cluster name (IRSA roles)
    save_aws "IAM roles with cluster tag" "${dir}/irsa-roles.json" \
        aws iam list-roles \
            --query "Roles[?contains(RoleName, \`${CLUSTER_NAME}\`)]"

    # Fargate pod execution role(s)
    local fargate_dir="${BACKUP_DIR}/cluster/fargate-profiles"
    if [[ -d "${fargate_dir}" ]]; then
        mkdir -p "${dir}/fargate"
        for profile_file in "${fargate_dir}"/*.json; do
            [[ -f "${profile_file}" ]] || continue
            local pod_exec_role
            pod_exec_role="$(jq -r '.fargateProfile.podExecutionRoleArn // empty' "${profile_file}" 2>/dev/null || true)"
            if [[ -n "${pod_exec_role}" ]]; then
                local role_name="${pod_exec_role##*/}"
                save_aws "Fargate pod exec role: ${role_name}" "${dir}/fargate/${role_name}.json" \
                    aws iam get-role --role-name "${role_name}"
                save_aws "Fargate pod exec role policies: ${role_name}" "${dir}/fargate/${role_name}-policies.json" \
                    aws iam list-attached-role-policies --role-name "${role_name}"
            fi
        done
    fi

    # Current caller identity (for reference)
    save_aws "Caller identity" "${dir}/caller-identity.json" \
        aws sts get-caller-identity
}

# =============================================================================
# Section 3: VPC & Networking (AWS)
# =============================================================================
backup_networking_aws() {
    log_header "AWS Networking (VPC, Subnets, Security Groups)"
    local dir="${BACKUP_DIR}/networking"

    [[ "${SKIP_AWS}" == "true" ]] && { log_warn "Skipping AWS networking (--skip-aws)"; return; }

    local cluster_json="${BACKUP_DIR}/cluster/cluster-config.json"
    [[ -f "${cluster_json}" ]] || { log_warn "Cluster config missing, skipping networking"; return; }

    local vpc_id
    vpc_id="$(jq -r '.cluster.resourcesVpcConfig.vpcId // empty' "${cluster_json}" 2>/dev/null || true)"

    if [[ -n "${vpc_id}" ]]; then
        log_step "VPC: ${vpc_id}"

        save_aws "VPC config" "${dir}/vpc.json" \
            aws ec2 describe-vpcs \
                --vpc-ids "${vpc_id}" \
                --region "${REGION}"

        save_aws "Subnets" "${dir}/subnets.json" \
            aws ec2 describe-subnets \
                --filters "Name=vpc-id,Values=${vpc_id}" \
                --region "${REGION}"

        save_aws "Route tables" "${dir}/route-tables.json" \
            aws ec2 describe-route-tables \
                --filters "Name=vpc-id,Values=${vpc_id}" \
                --region "${REGION}"

        save_aws "Internet gateways" "${dir}/internet-gateways.json" \
            aws ec2 describe-internet-gateways \
                --filters "Name=attachment.vpc-id,Values=${vpc_id}" \
                --region "${REGION}"

        save_aws "NAT gateways" "${dir}/nat-gateways.json" \
            aws ec2 describe-nat-gateways \
                --filter "Name=vpc-id,Values=${vpc_id}" \
                --region "${REGION}"

        save_aws "VPC endpoints" "${dir}/vpc-endpoints.json" \
            aws ec2 describe-vpc-endpoints \
                --filters "Name=vpc-id,Values=${vpc_id}" \
                --region "${REGION}"
    fi

    # Security groups for the cluster
    local sg_ids
    sg_ids="$(jq -r '.cluster.resourcesVpcConfig.securityGroupIds[]? // empty' "${cluster_json}" 2>/dev/null || true)"
    local cluster_sg
    cluster_sg="$(jq -r '.cluster.resourcesVpcConfig.clusterSecurityGroupId // empty' "${cluster_json}" 2>/dev/null || true)"

    if [[ -n "${sg_ids}" ]] || [[ -n "${cluster_sg}" ]]; then
        local all_sgs="${sg_ids} ${cluster_sg}"
        # Save each SG
        mkdir -p "${dir}/security-groups"
        while IFS= read -r sg; do
            [[ -z "${sg}" ]] && continue
            save_aws "Security group: ${sg}" "${dir}/security-groups/${sg}.json" \
                aws ec2 describe-security-groups \
                    --group-ids "${sg}" \
                    --region "${REGION}"
        done <<< "$(echo "${all_sgs}" | tr ' ' '\n' | sort -u)"
    fi

    # All security groups tagged with cluster name
    save_aws "Security groups (cluster tagged)" "${dir}/security-groups-tagged.json" \
        aws ec2 describe-security-groups \
            --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned,shared" \
            --region "${REGION}"

    # Subnets tagged with cluster
    save_aws "Subnets (cluster tagged)" "${dir}/subnets-tagged.json" \
        aws ec2 describe-subnets \
            --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned,shared" \
            --region "${REGION}"
}

# =============================================================================
# Section 4: Load Balancers (AWS)
# =============================================================================
backup_load_balancers() {
    log_header "AWS Load Balancers (ALB/NLB)"
    local dir="${BACKUP_DIR}/networking/load-balancers"

    [[ "${SKIP_AWS}" == "true" ]] && { log_warn "Skipping LB backup (--skip-aws)"; return; }

    # All ELBv2 (ALB/NLB)
    save_aws "Load balancers" "${dir}/load-balancers.json" \
        aws elbv2 describe-load-balancers \
            --region "${REGION}"

    local lb_arns
    lb_arns="$(aws elbv2 describe-load-balancers \
        --region "${REGION}" \
        --output json 2>/dev/null | jq -r '.LoadBalancers[].LoadBalancerArn' 2>/dev/null || true)"

    if [[ -n "${lb_arns}" ]]; then
        mkdir -p "${dir}/details"
        while IFS= read -r arn; do
            [[ -z "${arn}" ]] && continue
            local lb_name
            lb_name="$(basename "${arn}")"

            save_aws "LB attributes: ${lb_name}" "${dir}/details/${lb_name}-attributes.json" \
                aws elbv2 describe-load-balancer-attributes \
                    --load-balancer-arn "${arn}" \
                    --region "${REGION}"

            save_aws "LB listeners: ${lb_name}" "${dir}/details/${lb_name}-listeners.json" \
                aws elbv2 describe-listeners \
                    --load-balancer-arn "${arn}" \
                    --region "${REGION}"

            save_aws "LB tags: ${lb_name}" "${dir}/details/${lb_name}-tags.json" \
                aws elbv2 describe-tags \
                    --resource-arns "${arn}" \
                    --region "${REGION}"
        done <<< "${lb_arns}"
    fi

    # Target groups
    save_aws "Target groups" "${dir}/target-groups.json" \
        aws elbv2 describe-target-groups \
            --region "${REGION}"

    # Classic ELBs (legacy)
    save_aws "Classic ELBs" "${dir}/classic-load-balancers.json" \
        aws elb describe-load-balancers \
            --region "${REGION}"
}

# =============================================================================
# Section 5: Kubernetes Core Resources
# =============================================================================
backup_k8s_core() {
    log_header "Kubernetes Core Resources"
    local dir="${BACKUP_DIR}/kubernetes"

    # Namespaces
    save_k8s --all-namespaces=false namespaces "${dir}/namespaces.yaml"

    # Nodes (Fargate virtual nodes)
    save_k8s nodes "${dir}/nodes.yaml"

    # Priority classes
    save_k8s priorityclasses "${dir}/priorityclasses.yaml"

    # Runtime classes
    save_k8s runtimeclasses "${dir}/runtimeclasses.yaml"

    # Pod security policies (deprecated, may still exist)
    save_k8s podsecuritypolicies "${dir}/podsecuritypolicies.yaml"
}

# =============================================================================
# Section 6: RBAC
# =============================================================================
backup_k8s_rbac() {
    log_header "Kubernetes RBAC"
    local dir="${BACKUP_DIR}/kubernetes/rbac"

    save_k8s --all-namespaces clusterroles "${dir}/clusterroles.yaml"
    save_k8s --all-namespaces clusterrolebindings "${dir}/clusterrolebindings.yaml"
    save_k8s --all-namespaces roles "${dir}/roles.yaml"
    save_k8s --all-namespaces rolebindings "${dir}/rolebindings.yaml"
    save_k8s --all-namespaces serviceaccounts "${dir}/serviceaccounts.yaml"

    # aws-auth ConfigMap (critical for IAM → k8s RBAC mapping in older EKS)
    save_k8s -n kube-system configmap/aws-auth "${dir}/aws-auth-configmap.yaml" 2>/dev/null || \
        log_warn "aws-auth ConfigMap not found (cluster may use access entries instead)"
}

# =============================================================================
# Section 7: Workloads
# =============================================================================
backup_k8s_workloads() {
    log_header "Kubernetes Workloads"
    local dir="${BACKUP_DIR}/kubernetes/workloads"

    save_k8s --all-namespaces deployments "${dir}/deployments.yaml"
    save_k8s --all-namespaces statefulsets "${dir}/statefulsets.yaml"
    save_k8s --all-namespaces daemonsets "${dir}/daemonsets.yaml"
    save_k8s --all-namespaces replicasets "${dir}/replicasets.yaml"
    save_k8s --all-namespaces jobs "${dir}/jobs.yaml"
    save_k8s --all-namespaces cronjobs "${dir}/cronjobs.yaml"
    save_k8s --all-namespaces pods "${dir}/pods.yaml"
}

# =============================================================================
# Section 8: Networking (Kubernetes)
# =============================================================================
backup_k8s_networking() {
    log_header "Kubernetes Networking"
    local dir="${BACKUP_DIR}/kubernetes/networking"

    save_k8s --all-namespaces services "${dir}/services.yaml"
    save_k8s --all-namespaces endpoints "${dir}/endpoints.yaml"
    save_k8s --all-namespaces endpointslices "${dir}/endpointslices.yaml"
    save_k8s --all-namespaces ingresses "${dir}/ingresses.yaml"
    save_k8s ingressclasses "${dir}/ingressclasses.yaml"
    save_k8s --all-namespaces networkpolicies "${dir}/networkpolicies.yaml"

    # Webhook configurations (important for LB controller, etc.)
    save_k8s mutatingwebhookconfigurations "${dir}/mutatingwebhookconfigurations.yaml"
    save_k8s validatingwebhookconfigurations "${dir}/validatingwebhookconfigurations.yaml"
}

# =============================================================================
# Section 9: Config & Secrets
# =============================================================================
backup_k8s_config() {
    log_header "Kubernetes ConfigMaps & Secrets"
    local dir="${BACKUP_DIR}/kubernetes/config"

    save_k8s --all-namespaces configmaps "${dir}/configmaps.yaml"

    if [[ "${SKIP_SECRETS}" == "true" ]]; then
        log_warn "Secrets: skipped (--skip-secrets)"
    else
        echo -e "  ${YELLOW}⚠${NC}  Secrets are base64-encoded — protect this backup!"
        save_k8s --all-namespaces secrets "${dir}/secrets.yaml"
    fi
}

# =============================================================================
# Section 10: Storage
# =============================================================================
backup_k8s_storage() {
    log_header "Kubernetes Storage"
    local dir="${BACKUP_DIR}/kubernetes/storage"

    save_k8s storageclasses "${dir}/storageclasses.yaml"
    save_k8s persistentvolumes "${dir}/persistentvolumes.yaml"
    save_k8s --all-namespaces persistentvolumeclaims "${dir}/persistentvolumeclaims.yaml"
    save_k8s volumeattachments "${dir}/volumeattachments.yaml"
    save_k8s --all-namespaces volumesnapshots "${dir}/volumesnapshots.yaml"
    save_k8s volumesnapshotclasses "${dir}/volumesnapshotclasses.yaml"
    save_k8s volumesnapshotcontents "${dir}/volumesnapshotcontents.yaml"
}

# =============================================================================
# Section 11: Autoscaling & Policy
# =============================================================================
backup_k8s_policy() {
    log_header "Kubernetes Autoscaling & Policy"
    local dir="${BACKUP_DIR}/kubernetes/policy"

    # HPA
    save_k8s --all-namespaces horizontalpodautoscalers "${dir}/hpa.yaml"

    # VPA (if installed)
    save_k8s --all-namespaces verticalpodautoscalers "${dir}/vpa.yaml"

    # PDB
    save_k8s --all-namespaces poddisruptionbudgets "${dir}/pdb.yaml"

    # Resource quotas & limits
    save_k8s --all-namespaces resourcequotas "${dir}/resourcequotas.yaml"
    save_k8s --all-namespaces limitranges "${dir}/limitranges.yaml"
}

# =============================================================================
# Section 12: Custom Resource Definitions
# =============================================================================
backup_crds() {
    log_header "Custom Resource Definitions (CRDs)"
    local dir="${BACKUP_DIR}/kubernetes/crds"

    save_k8s customresourcedefinitions "${dir}/crds.yaml"

    [[ "${SKIP_CUSTOM_RESOURCES}" == "true" ]] && {
        log_warn "Custom resource instances: skipped (--skip-custom-resources)"
        return
    }

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_step "(dry-run) would backup all CRD instances"
        return
    fi

    local crd_list
    crd_list="$(kubectl get crds -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"

    if [[ -z "${crd_list}" ]]; then
        log_warn "No CRDs found"
        return
    fi

    local cr_dir="${BACKUP_DIR}/custom-resources"
    mkdir -p "${cr_dir}"
    local count=0

    for crd in ${crd_list}; do
        local output="${cr_dir}/${crd}.yaml"
        if kubectl get "${crd}" --all-namespaces -o yaml > "${output}" 2>/dev/null; then
            local items
            items="$(kubectl get "${crd}" --all-namespaces --no-headers 2>/dev/null | grep -c . || echo 0)"
            if [[ "${items}" -gt 0 ]]; then
                log_step "CRD instances: ${crd} (${items})"
                ((count++)) || true
            else
                rm -f "${output}"
            fi
        else
            rm -f "${output}"
        fi
    done
    log_info "Custom resource instances backed up: ${count} CRDs with data"
}

# =============================================================================
# Section 13: Add-on Specific Configs
# =============================================================================
backup_addon_configs() {
    log_header "Add-on Specific Configurations"

    # --- AWS Load Balancer Controller ---
    log_section "AWS Load Balancer Controller"
    local lbc_dir="${BACKUP_DIR}/addons/aws-load-balancer-controller"

    # Try to find in kube-system (default namespace)
    for ns in kube-system default; do
        if kubectl get deployment aws-load-balancer-controller -n "${ns}" &>/dev/null 2>&1; then
            save_k8s -n "${ns}" deployment/aws-load-balancer-controller \
                "${lbc_dir}/deployment.yaml"
            save_k8s -n "${ns}" service/aws-load-balancer-webhook-service \
                "${lbc_dir}/webhook-service.yaml"
            save_k8s -n "${ns}" configmap/aws-load-balancer-controller \
                "${lbc_dir}/configmap.yaml"
            break
        fi
    done

    # IngressClass and IngressClassParams
    save_k8s ingressclasses "${lbc_dir}/ingressclasses.yaml"
    save_k8s --all-namespaces ingressclassparams "${lbc_dir}/ingressclassparams.yaml"

    # TargetGroupBindings (LBC CRD)
    save_k8s --all-namespaces targetgroupbindings "${lbc_dir}/targetgroupbindings.yaml"

    # LBC webhook
    save_k8s mutatingwebhookconfigurations/aws-load-balancer-webhook \
        "${lbc_dir}/mutating-webhook.yaml"

    # --- CoreDNS ---
    log_section "CoreDNS"
    local dns_dir="${BACKUP_DIR}/addons/coredns"
    save_k8s -n kube-system deployment/coredns "${dns_dir}/deployment.yaml"
    save_k8s -n kube-system configmap/coredns "${dns_dir}/configmap.yaml"
    save_k8s -n kube-system service/kube-dns "${dns_dir}/service.yaml"

    # --- kube-proxy ---
    log_section "kube-proxy"
    local proxy_dir="${BACKUP_DIR}/addons/kube-proxy"
    # On Fargate, kube-proxy may run as a managed add-on (not a DaemonSet)
    save_k8s -n kube-system daemonset/kube-proxy "${proxy_dir}/daemonset.yaml"
    save_k8s -n kube-system configmap/kube-proxy "${proxy_dir}/configmap.yaml"
    save_k8s -n kube-system configmap/kube-proxy-config "${proxy_dir}/configmap-config.yaml"

    # --- VPC CNI (aws-node) ---
    log_section "VPC CNI (aws-node)"
    local cni_dir="${BACKUP_DIR}/addons/vpc-cni"
    save_k8s -n kube-system daemonset/aws-node "${cni_dir}/daemonset.yaml"
    save_k8s -n kube-system configmap/amazon-vpc-cni "${cni_dir}/configmap.yaml"

    # --- Metrics Server ---
    log_section "Metrics Server"
    local ms_dir="${BACKUP_DIR}/addons/metrics-server"
    save_k8s -n kube-system deployment/metrics-server "${ms_dir}/deployment.yaml"
    save_k8s -n kube-system service/metrics-server "${ms_dir}/service.yaml"

    # --- Cluster Autoscaler ---
    log_section "Cluster Autoscaler"
    local ca_dir="${BACKUP_DIR}/addons/cluster-autoscaler"
    save_k8s -n kube-system deployment/cluster-autoscaler "${ca_dir}/deployment.yaml"
    save_k8s -n kube-system configmap/cluster-autoscaler-status "${ca_dir}/status-configmap.yaml"

    # --- External DNS ---
    log_section "External DNS"
    local ed_dir="${BACKUP_DIR}/addons/external-dns"
    for ns in kube-system default; do
        if kubectl get deployment external-dns -n "${ns}" &>/dev/null 2>&1; then
            save_k8s -n "${ns}" deployment/external-dns "${ed_dir}/deployment.yaml"
            save_k8s -n "${ns}" configmap/external-dns "${ed_dir}/configmap.yaml"
            break
        fi
    done

    # --- cert-manager ---
    log_section "cert-manager"
    local cm_dir="${BACKUP_DIR}/addons/cert-manager"
    if kubectl get deployment cert-manager -n cert-manager &>/dev/null 2>&1; then
        save_k8s -n cert-manager deployment/cert-manager "${cm_dir}/deployment.yaml"
        save_k8s -n cert-manager deployment/cert-manager-webhook "${cm_dir}/webhook-deployment.yaml"
        save_k8s -n cert-manager deployment/cert-manager-cainjector "${cm_dir}/cainjector-deployment.yaml"
        save_k8s --all-namespaces certificates "${cm_dir}/certificates.yaml"
        save_k8s --all-namespaces clusterissuers "${cm_dir}/clusterissuers.yaml"
        save_k8s --all-namespaces issuers "${cm_dir}/issuers.yaml"
    fi
}

# =============================================================================
# Section 14: Helm Releases
# =============================================================================
backup_helm() {
    log_header "Helm Releases"

    if [[ "${SKIP_HELM}" == "true" ]]; then
        log_warn "Helm backup skipped (--skip-helm)"
        return
    fi

    if ! command -v helm &>/dev/null; then
        log_warn "helm not installed, skipping"
        return
    fi

    local dir="${BACKUP_DIR}/helm"
    mkdir -p "${dir}"

    [[ "${DRY_RUN}" == "true" ]] && { log_step "(dry-run) helm list --all-namespaces"; return; }

    local releases
    releases="$(helm list --all-namespaces -o json 2>/dev/null || echo '[]')"
    echo "${releases}" > "${dir}/releases-list.json"
    log_info "Helm releases list → helm/releases-list.json"

    local release_count
    release_count="$(echo "${releases}" | jq '. | length' 2>/dev/null || echo 0)"
    log_step "Found ${release_count} Helm releases"

    if [[ "${release_count}" -gt 0 ]]; then
        mkdir -p "${dir}/values" "${dir}/manifests"

        while IFS=$'\t' read -r name namespace; do
            [[ -z "${name}" ]] && continue

            # User-supplied values
            if helm get values "${name}" -n "${namespace}" > "${dir}/values/${namespace}-${name}-values.yaml" 2>/dev/null; then
                log_info "Helm values: ${namespace}/${name}"
            fi

            # All values (including chart defaults)
            helm get values "${name}" -n "${namespace}" --all > \
                "${dir}/values/${namespace}-${name}-values-all.yaml" 2>/dev/null || true

            # Release metadata
            helm get metadata "${name}" -n "${namespace}" -o json > \
                "${dir}/values/${namespace}-${name}-metadata.json" 2>/dev/null || true

            # Rendered manifests
            helm get manifest "${name}" -n "${namespace}" > \
                "${dir}/manifests/${namespace}-${name}-manifest.yaml" 2>/dev/null || true

            # Release history
            helm history "${name}" -n "${namespace}" -o json > \
                "${dir}/values/${namespace}-${name}-history.json" 2>/dev/null || true

        done < <(echo "${releases}" | jq -r '.[] | [.name, .namespace] | @tsv')
    fi
}

# =============================================================================
# Section 15: Manifest
# =============================================================================
write_manifest() {
    [[ "${DRY_RUN}" == "true" ]] && return

    local manifest="${BACKUP_DIR}/BACKUP_MANIFEST.json"
    local end_time
    end_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    cat > "${manifest}" <<EOF
{
  "backup_version": "${VERSION}",
  "cluster_name": "${CLUSTER_NAME}",
  "region": "${REGION}",
  "timestamp": "${TIMESTAMP}",
  "completed_at": "${end_time}",
  "options": {
    "skip_secrets": ${SKIP_SECRETS},
    "skip_helm": ${SKIP_HELM},
    "skip_custom_resources": ${SKIP_CUSTOM_RESOURCES},
    "skip_aws": ${SKIP_AWS},
    "compressed": ${COMPRESS}
  },
  "stats": {
    "backed_up": ${BACKED_UP},
    "skipped": ${SKIPPED},
    "failed": ${FAILED}
  },
  "failed_items": $(printf '%s\n' "${FAILED_ITEMS[@]+"${FAILED_ITEMS[@]}"}" | jq -R . | jq -s . 2>/dev/null || echo '[]')
}
EOF
    log_info "Manifest written → BACKUP_MANIFEST.json"
}

# =============================================================================
# Compress
# =============================================================================
compress_backup() {
    [[ "${DRY_RUN}" == "true" ]] && return
    [[ "${COMPRESS}" == "false" ]] && return

    log_section "Compressing backup"
    local archive="${OUTPUT_BASE_DIR}/${CLUSTER_NAME}_${TIMESTAMP}.tar.gz"
    tar -czf "${archive}" -C "${OUTPUT_BASE_DIR}" "$(basename "${BACKUP_DIR}")"
    local size
    size="$(du -sh "${archive}" | cut -f1)"
    log_info "Archive created: ${archive} (${size})"
}

# =============================================================================
# Summary
# =============================================================================
print_summary() {
    echo ""
    log_header "Backup Summary"
    echo -e "  Cluster:    ${BOLD}${CLUSTER_NAME}${NC}"
    echo -e "  Region:     ${REGION}"
    echo -e "  Backup dir: ${BACKUP_DIR}"
    echo ""
    echo -e "  ${GREEN}✓ Backed up:${NC} ${BACKED_UP}"
    echo -e "  ${YELLOW}○ Skipped:${NC}   ${SKIPPED}"
    echo -e "  ${RED}✗ Failed:${NC}    ${FAILED}"

    if [[ ${#FAILED_ITEMS[@]} -gt 0 ]]; then
        echo ""
        echo -e "  ${RED}Failed items:${NC}"
        for item in "${FAILED_ITEMS[@]}"; do
            echo -e "    - ${item}"
        done
    fi

    if [[ "${COMPRESS}" == "true" ]] && [[ "${DRY_RUN}" == "false" ]]; then
        local archive="${OUTPUT_BASE_DIR}/${CLUSTER_NAME}_${TIMESTAMP}.tar.gz"
        if [[ -f "${archive}" ]]; then
            echo ""
            echo -e "  ${BOLD}Archive:${NC} ${archive}"
        fi
    fi

    echo ""
    if [[ "${FAILED}" -eq 0 ]]; then
        echo -e "  ${GREEN}${BOLD}Backup completed successfully!${NC}"
    else
        echo -e "  ${YELLOW}${BOLD}Backup completed with ${FAILED} warning(s).${NC}"
    fi
    echo ""
}

# =============================================================================
# Main
# =============================================================================
main() {
    parse_args "$@"

    log_header "EKS Fargate Backup v${VERSION}"
    echo -e "  Cluster: ${BOLD}${CLUSTER_NAME}${NC}"
    echo -e "  Region:  ${REGION}"
    [[ "${DRY_RUN}" == "true" ]] && echo -e "  ${YELLOW}Mode: DRY RUN (no files written)${NC}"
    [[ "${SKIP_SECRETS}" == "true" ]] && echo -e "  ${YELLOW}Secrets: SKIPPED${NC}"

    check_dependencies
    check_cluster_access
    setup_backup_dir

    # Run all backup sections
    backup_eks_cluster
    backup_iam
    backup_networking_aws
    backup_load_balancers
    backup_k8s_core
    backup_k8s_rbac
    backup_k8s_workloads
    backup_k8s_networking
    backup_k8s_config
    backup_k8s_storage
    backup_k8s_policy
    backup_crds
    backup_addon_configs
    backup_helm

    write_manifest
    compress_backup
    print_summary
}

main "$@"
