# EKS Fargate Backup & Restore

Scripts voor een volledige backup van een AWS EKS Fargate cluster vóór een upgrade, inclusief herstel na calamiteiten.

---

## Inhoud

- [Wat wordt er gebackupt?](#wat-wordt-er-gebackupt)
- [Vereisten](#vereisten)
- [Snelstart](#snelstart)
- [Backup Script](#backup-script)
- [Restore Script](#restore-script)
- [Mapstructuur backup](#mapstructuur-backup)
- [Component Details](#component-details)
- [Restore Procedure](#restore-procedure)
- [Veiligheidsnotes](#veiligheidsnotes)
- [Troubleshooting](#troubleshooting)

---

## Wat wordt er gebackupt?

### AWS Resources
| Component | Wat | Locatie in backup |
|-----------|-----|-------------------|
| EKS Cluster | Config, versie, logging, encryptie | `cluster/cluster-config.json` |
| Fargate Profiles | Alle profielen met selectors | `cluster/fargate-profiles/` |
| Managed Node Groups | Config per node group | `cluster/nodegroups/` |
| EKS Managed Add-ons | kube-proxy, CoreDNS, VPC CNI, EBS CSI | `cluster/addons/` |
| IAM Roles | Cluster role, Fargate pod execution role, IRSA roles | `iam/` |
| OIDC Provider | Identity provider voor IRSA | `iam/oidc-provider.json` |
| VPC | Subnets, route tables, IGW, NAT, endpoints | `networking/` |
| Security Groups | Cluster SG, node SG, alle getagde SGs | `networking/security-groups/` |
| Load Balancers | ALB/NLB met listeners, attributes, tags | `networking/load-balancers/` |
| Target Groups | Alle ELBv2 target groups | `networking/load-balancers/target-groups.json` |
| Classic ELBs | Legacy ELBs | `networking/load-balancers/classic-load-balancers.json` |

### Kubernetes Resources
| Component | Wat | Locatie in backup |
|-----------|-----|-------------------|
| Namespaces | Alle namespaces | `kubernetes/namespaces.yaml` |
| RBAC | ClusterRoles, RoleBindings, ServiceAccounts | `kubernetes/rbac/` |
| aws-auth ConfigMap | IAM → k8s RBAC mapping (voor EKS <1.29) | `kubernetes/rbac/aws-auth-configmap.yaml` |
| Deployments | Alle namespaces | `kubernetes/workloads/deployments.yaml` |
| StatefulSets | Alle namespaces | `kubernetes/workloads/statefulsets.yaml` |
| DaemonSets | Alle namespaces | `kubernetes/workloads/daemonsets.yaml` |
| Jobs / CronJobs | Alle namespaces | `kubernetes/workloads/` |
| Services | ClusterIP, NodePort, LoadBalancer | `kubernetes/networking/services.yaml` |
| Ingresses | Alle ingress resources | `kubernetes/networking/ingresses.yaml` |
| IngressClasses | incl. AWS ALB IngressClass | `kubernetes/networking/ingressclasses.yaml` |
| NetworkPolicies | Alle namespaces | `kubernetes/networking/networkpolicies.yaml` |
| Webhook configs | MutatingWebhook, ValidatingWebhook | `kubernetes/networking/` |
| ConfigMaps | Alle namespaces | `kubernetes/config/configmaps.yaml` |
| Secrets | Alle namespaces (optioneel) | `kubernetes/config/secrets.yaml` |
| StorageClasses | Alle storage classes | `kubernetes/storage/storageclasses.yaml` |
| PersistentVolumes | Alle PVs | `kubernetes/storage/persistentvolumes.yaml` |
| PersistentVolumeClaims | Alle namespaces | `kubernetes/storage/persistentvolumeclaims.yaml` |
| HPA | HorizontalPodAutoscalers | `kubernetes/policy/hpa.yaml` |
| VPA | VerticalPodAutoscalers (indien aanwezig) | `kubernetes/policy/vpa.yaml` |
| PDB | PodDisruptionBudgets | `kubernetes/policy/pdb.yaml` |
| ResourceQuotas / LimitRanges | Alle namespaces | `kubernetes/policy/` |
| CRDs | Alle Custom Resource Definitions | `kubernetes/crds/crds.yaml` |
| Custom Resources | Alle instanties per CRD | `custom-resources/` |
| PriorityClasses | | `kubernetes/priorityclasses.yaml` |

### Add-on Specifieke Configs
| Add-on | Wat | Locatie |
|--------|-----|---------|
| AWS Load Balancer Controller | Deployment, ConfigMap, Webhooks, TargetGroupBindings | `addons/aws-load-balancer-controller/` |
| CoreDNS | Deployment + Corefile ConfigMap | `addons/coredns/` |
| kube-proxy | DaemonSet + ConfigMap | `addons/kube-proxy/` |
| VPC CNI (aws-node) | DaemonSet + ConfigMap | `addons/vpc-cni/` |
| Metrics Server | Deployment + Service | `addons/metrics-server/` |
| Cluster Autoscaler | Deployment | `addons/cluster-autoscaler/` |
| External DNS | Deployment + ConfigMap | `addons/external-dns/` |
| cert-manager | Deployments, Certificates, Issuers | `addons/cert-manager/` |

### Helm
| Component | Wat | Locatie |
|-----------|-----|---------|
| Releases lijst | Alle Helm releases | `helm/releases-list.json` |
| Values | User-supplied en all-values per release | `helm/values/` |
| Manifests | Rendered Kubernetes manifests | `helm/manifests/` |
| History | Release history per chart | `helm/values/*-history.json` |

---

## Vereisten

### CLI Tools
```bash
# Verplicht
kubectl   >= 1.24
aws       >= 2.x  (AWS CLI v2)
jq        >= 1.6

# Optioneel (voor Helm backup)
helm      >= 3.x
```

### AWS Permissies
De IAM user/role moet minimaal hebben:
```json
{
  "Effect": "Allow",
  "Action": [
    "eks:Describe*",
    "eks:List*",
    "ec2:Describe*",
    "iam:Get*",
    "iam:List*",
    "sts:GetCallerIdentity",
    "elasticloadbalancing:Describe*",
    "elb:Describe*"
  ],
  "Resource": "*"
}
```

### Kubernetes Permissies
```bash
# Controleer huidige rechten
kubectl auth can-i get deployments --all-namespaces
kubectl auth can-i get secrets --all-namespaces
```

De kubeconfig moet al geconfigureerd zijn:
```bash
aws eks update-kubeconfig --name <cluster-naam> --region <regio>
```

---

## Snelstart

```bash
# Clone repository
git clone https://github.com/meeuw2000/aws-eks-fargate-backup.git
cd aws-eks-fargate-backup

# Maak scripts uitvoerbaar
chmod +x eks-fargate-backup.sh eks-fargate-restore.sh

# Volledige backup (inclusief secrets)
./eks-fargate-backup.sh --cluster mijn-cluster --region eu-west-1

# Backup zonder secrets
./eks-fargate-backup.sh --cluster mijn-cluster --region eu-west-1 --skip-secrets

# Dry-run: zie wat er gebackupt wordt zonder te schrijven
./eks-fargate-backup.sh --cluster mijn-cluster --dry-run
```

---

## Backup Script

### Syntax
```
./eks-fargate-backup.sh --cluster <naam> [OPTIES]
```

### Opties

| Optie | Beschrijving | Default |
|-------|-------------|---------|
| `-c, --cluster <naam>` | **Verplicht.** EKS cluster naam | — |
| `-r, --region <regio>` | AWS regio | `eu-west-1` of `$AWS_DEFAULT_REGION` |
| `-o, --output <dir>` | Basis output directory | `./backups` |
| `--skip-secrets` | Sla Kubernetes Secrets over | false |
| `--skip-helm` | Sla Helm releases over | false |
| `--skip-custom-resources` | Sla CRD-instanties over | false |
| `--skip-aws` | Sla AWS API calls over (alleen k8s) | false |
| `--no-compress` | Geen `.tar.gz` archief maken | false |
| `--dry-run` | Toon wat er gebackupt zou worden | false |
| `-v, --verbose` | Uitgebreide output | false |
| `-h, --help` | Toon help | — |

### Voorbeelden

```bash
# Standaard backup
./eks-fargate-backup.sh --cluster productie --region eu-west-1

# Backup zonder secrets en Helm
./eks-fargate-backup.sh \
  --cluster productie \
  --region eu-west-1 \
  --skip-secrets \
  --skip-helm

# Backup naar specifieke directory
./eks-fargate-backup.sh \
  --cluster productie \
  --region eu-west-1 \
  --output /mnt/backup/eks

# Alleen Kubernetes resources (geen AWS API calls)
./eks-fargate-backup.sh \
  --cluster productie \
  --skip-aws

# Dry-run voor verificatie
./eks-fargate-backup.sh --cluster productie --dry-run
```

### Backup Output

Na afloop staat er:
```
backups/
├── productie_20240101_120000/          # Backup directory
│   ├── BACKUP_MANIFEST.json            # Samenvatting
│   ├── backup.log                      # Volledig logbestand
│   ├── cluster/
│   ├── iam/
│   ├── networking/
│   ├── kubernetes/
│   ├── custom-resources/
│   ├── addons/
│   └── helm/
└── productie_20240101_120000.tar.gz    # Gecomprimeerd archief
```

---

## Restore Script

### Syntax
```
./eks-fargate-restore.sh --backup-dir <pad> [OPTIES]
```

### Opties

| Optie | Beschrijving |
|-------|-------------|
| `-b, --backup-dir <pad>` | **Verplicht.** Pad naar de backup directory |
| `--dry-run` | Toon wat er hersteld zou worden |
| `--force` | Pas toe zonder bevestiging per stap |
| `--only <sectie>` | Herstel alleen een sectie (zie hieronder) |
| `--restore-secrets` | Includeer Secrets bij herstel |
| `--namespace <ns>` | Beperk tot een specifieke namespace |

**Beschikbare secties voor `--only`:**
`namespaces`, `rbac`, `crds`, `config`, `storage`, `workloads`, `networking`, `policy`, `addons`, `helm`

### Voorbeelden

```bash
# Eerst archief uitpakken
tar -xzf backups/productie_20240101_120000.tar.gz -C backups/

# Dry-run
./eks-fargate-restore.sh \
  --backup-dir backups/productie_20240101_120000 \
  --dry-run

# Alleen workloads herstellen
./eks-fargate-restore.sh \
  --backup-dir backups/productie_20240101_120000 \
  --only workloads

# Volledig herstel (inclusief secrets, zonder bevestiging per stap)
./eks-fargate-restore.sh \
  --backup-dir backups/productie_20240101_120000 \
  --restore-secrets \
  --force
```

---

## Mapstructuur backup

```
<cluster>_<timestamp>/
│
├── BACKUP_MANIFEST.json                  # Metadata: wat, wanneer, statistieken
├── backup.log                            # Volledig logbestand
│
├── cluster/
│   ├── cluster-config.json               # EKS cluster beschrijving
│   ├── fargate-profiles-list.json        # Lijst van Fargate profiles
│   ├── fargate-profiles/
│   │   └── <profile-naam>.json           # Detail per Fargate profile
│   ├── nodegroups-list.json              # Managed node groups
│   ├── nodegroups/
│   │   └── <nodegroup-naam>.json
│   ├── addons-list.json                  # EKS managed add-ons lijst
│   ├── addons/
│   │   ├── coredns.json                  # Add-on versie & config
│   │   ├── kube-proxy.json
│   │   ├── vpc-cni.json
│   │   └── <addon>.json
│   ├── access-entries.json               # EKS access entries (>=1.29)
│   └── pod-identity-associations.json    # EKS Pod Identity
│
├── iam/
│   ├── cluster-role.json                 # EKS cluster IAM role
│   ├── cluster-role-policies.json        # Bijgevoegde policies
│   ├── oidc-providers.json               # Alle OIDC providers
│   ├── oidc-provider.json                # Cluster OIDC provider
│   ├── irsa-roles.json                   # IAM roles voor IRSA
│   ├── caller-identity.json              # AWS caller identity
│   └── fargate/
│       ├── <role-naam>.json              # Fargate pod execution role
│       └── <role-naam>-policies.json
│
├── networking/
│   ├── vpc.json                          # VPC configuratie
│   ├── subnets.json                      # Alle subnets in VPC
│   ├── subnets-tagged.json               # Subnets getagd met cluster
│   ├── route-tables.json
│   ├── internet-gateways.json
│   ├── nat-gateways.json
│   ├── vpc-endpoints.json
│   ├── security-groups-tagged.json       # SGs getagd met cluster
│   ├── security-groups/
│   │   └── sg-xxxx.json                  # Detail per security group
│   └── load-balancers/
│       ├── load-balancers.json           # Alle ALB/NLB
│       ├── target-groups.json            # Alle target groups
│       ├── classic-load-balancers.json   # Legacy ELBs
│       └── details/
│           ├── <lb-naam>-attributes.json
│           ├── <lb-naam>-listeners.json
│           └── <lb-naam>-tags.json
│
├── kubernetes/
│   ├── namespaces.yaml
│   ├── nodes.yaml                        # Fargate virtual nodes
│   ├── priorityclasses.yaml
│   ├── runtimeclasses.yaml
│   │
│   ├── rbac/
│   │   ├── clusterroles.yaml
│   │   ├── clusterrolebindings.yaml
│   │   ├── roles.yaml
│   │   ├── rolebindings.yaml
│   │   ├── serviceaccounts.yaml
│   │   └── aws-auth-configmap.yaml       # ⚠ Kritisch — zie notes
│   │
│   ├── workloads/
│   │   ├── deployments.yaml
│   │   ├── statefulsets.yaml
│   │   ├── daemonsets.yaml
│   │   ├── replicasets.yaml
│   │   ├── jobs.yaml
│   │   ├── cronjobs.yaml
│   │   └── pods.yaml
│   │
│   ├── networking/
│   │   ├── services.yaml
│   │   ├── endpoints.yaml
│   │   ├── endpointslices.yaml
│   │   ├── ingresses.yaml
│   │   ├── ingressclasses.yaml
│   │   ├── networkpolicies.yaml
│   │   ├── mutatingwebhookconfigurations.yaml
│   │   └── validatingwebhookconfigurations.yaml
│   │
│   ├── config/
│   │   ├── configmaps.yaml
│   │   └── secrets.yaml                  # ⚠ Gevoelig — base64 encoded
│   │
│   ├── storage/
│   │   ├── storageclasses.yaml
│   │   ├── persistentvolumes.yaml
│   │   ├── persistentvolumeclaims.yaml
│   │   ├── volumeattachments.yaml
│   │   └── volumesnapshots.yaml
│   │
│   ├── policy/
│   │   ├── hpa.yaml
│   │   ├── vpa.yaml
│   │   ├── pdb.yaml
│   │   ├── resourcequotas.yaml
│   │   └── limitranges.yaml
│   │
│   └── crds/
│       └── crds.yaml                     # Alle CRD definities
│
├── custom-resources/
│   └── <crd-naam>.yaml                   # Instanties per CRD
│
├── addons/
│   ├── aws-load-balancer-controller/
│   │   ├── deployment.yaml
│   │   ├── webhook-service.yaml
│   │   ├── configmap.yaml
│   │   ├── ingressclasses.yaml
│   │   ├── ingressclassparams.yaml
│   │   ├── targetgroupbindings.yaml
│   │   └── mutating-webhook.yaml
│   ├── coredns/
│   │   ├── deployment.yaml
│   │   ├── configmap.yaml                # Corefile
│   │   └── service.yaml
│   ├── kube-proxy/
│   │   ├── daemonset.yaml
│   │   ├── configmap.yaml
│   │   └── configmap-config.yaml
│   ├── vpc-cni/
│   │   ├── daemonset.yaml
│   │   └── configmap.yaml
│   ├── metrics-server/
│   ├── cluster-autoscaler/
│   ├── external-dns/
│   └── cert-manager/
│       ├── certificates.yaml
│       ├── clusterissuers.yaml
│       └── issuers.yaml
│
└── helm/
    ├── releases-list.json                # Overzicht alle Helm releases
    ├── values/
    │   ├── <ns>-<release>-values.yaml    # User-supplied values
    │   ├── <ns>-<release>-values-all.yaml
    │   ├── <ns>-<release>-metadata.json
    │   └── <ns>-<release>-history.json
    └── manifests/
        └── <ns>-<release>-manifest.yaml  # Rendered Kubernetes YAML
```

---

## Component Details

### AWS Load Balancer Controller

De AWS LB Controller is verantwoordelijk voor het provisioneren van ALB/NLB voor `Ingress` en `Service` resources. Op Fargate is dit verplicht voor externe toegang.

**Backup bevat:**
- Deployment configuratie (image versie, args, resource limits)
- IRSA ServiceAccount annotatie (IAM role ARN)
- MutatingWebhookConfiguration
- IngressClass `alb`
- TargetGroupBinding resources

**Herstel via Helm:**
```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm upgrade --install aws-load-balancer-controller \
  eks/aws-load-balancer-controller \
  -n kube-system \
  -f backups/<cluster>_<ts>/helm/values/kube-system-aws-load-balancer-controller-values.yaml
```

### kube-proxy

Op EKS Fargate draait kube-proxy als een **managed EKS add-on**, niet als klassieke DaemonSet (Fargate ondersteunt geen DaemonSets). De add-on versie is gekoppeld aan de Kubernetes versie.

**Backup bevat:** add-on versie in `cluster/addons/kube-proxy.json`

**Herstel:**
```bash
# Bekijk huidige versie
cat backups/<cluster>/cluster/addons/kube-proxy.json | jq '.addon.addonVersion'

# Herstel als EKS managed add-on
aws eks create-addon \
  --cluster-name <naam> \
  --addon-name kube-proxy \
  --addon-version <versie> \
  --region eu-west-1
```

### CoreDNS

Managed add-on voor DNS-resolutie. De Corefile (ConfigMap) kan aangepast zijn met custom DNS regels.

**Backup bevat:**
- `cluster/addons/coredns.json` — versie info
- `addons/coredns/configmap.yaml` — Corefile met eventuele aanpassingen

**Na upgrade:** Controleer altijd of de Corefile compatibel is met de nieuwe CoreDNS versie.

### VPC CNI (aws-node)

Regelt IP-toewijzing aan pods. Op Fargate wordt dit beheerd door AWS, maar de ConfigMap kan custom instellingen bevatten.

**Backup bevat:**
- `cluster/addons/vpc-cni.json` — versie
- `addons/vpc-cni/configmap.yaml` — custom instellingen

### IRSA (IAM Roles for Service Accounts)

Service accounts met een IAM role annotatie voor AWS permissies.

**Backup bevat:**
- ServiceAccount YAML (inclusief annotaties) in `kubernetes/rbac/serviceaccounts.yaml`
- IAM roles met cluster-naam in `iam/irsa-roles.json`
- OIDC provider in `iam/oidc-provider.json`

**Let op:** Na een cluster-recreatie verandert de OIDC issuer URL. Alle IRSA trust policies moeten dan bijgewerkt worden.

### Fargate Profiles

Bepalen welke pods op Fargate draaien via namespace/label selectors.

**Backup bevat:** `cluster/fargate-profiles/<naam>.json` per profiel

```bash
# Controleer backup
cat backups/<cluster>/cluster/fargate-profiles/fp-default.json | jq '.fargateProfile.selectors'
```

---

## Restore Procedure

### Scenario 1: Upgrade mislukt — terug naar vorige versie

```bash
# 1. Downgrade EKS cluster versie (via AWS Console of Terraform)
#    (Let op: EKS downgrade is niet direct mogelijk — maak nieuw cluster)

# 2. Update kubeconfig
aws eks update-kubeconfig --name <cluster> --region eu-west-1

# 3. Herstel in volgorde
./eks-fargate-restore.sh --backup-dir backups/<cluster>_<ts> --dry-run
./eks-fargate-restore.sh --backup-dir backups/<cluster>_<ts> --force
```

### Scenario 2: Gedeeltelijk herstel (bijv. alleen workloads)

```bash
# Herstel alleen workloads na een fout
./eks-fargate-restore.sh \
  --backup-dir backups/<cluster>_<ts> \
  --only workloads \
  --force
```

### Scenario 3: Nieuw cluster opzetten van backup

```bash
# 1. Maak EKS cluster aan (via Terraform/eksctl/AWS Console)
#    Gebruik cluster-config.json als referentie:
cat backups/<cluster>_<ts>/cluster/cluster-config.json | jq '.cluster | {version, roleArn, resourcesVpcConfig}'

# 2. Maak Fargate profiles opnieuw aan
aws eks create-fargate-profile \
  --cluster-name nieuw-cluster \
  --fargate-profile-name fp-default \
  --pod-execution-role-arn <arn> \
  --selectors namespace=default

# 3. Update kubeconfig
aws eks update-kubeconfig --name nieuw-cluster --region eu-west-1

# 4. Installeer EKS managed add-ons
aws eks create-addon --cluster-name nieuw-cluster --addon-name coredns --addon-version v1.11.1-eksbuild.4
aws eks create-addon --cluster-name nieuw-cluster --addon-name kube-proxy --addon-version v1.29.3-eksbuild.2
aws eks create-addon --cluster-name nieuw-cluster --addon-name vpc-cni --addon-version v1.18.1-eksbuild.3

# 5. Herstel CRDs (vóór workloads!)
./eks-fargate-restore.sh --backup-dir backups/<cluster>_<ts> --only crds --force

# 6. Herstel namespaces en RBAC
./eks-fargate-restore.sh --backup-dir backups/<cluster>_<ts> --only namespaces --force
./eks-fargate-restore.sh --backup-dir backups/<cluster>_<ts> --only rbac --force

# 7. Installeer AWS LB Controller via Helm
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  -f backups/<cluster>_<ts>/helm/values/kube-system-aws-load-balancer-controller-values.yaml

# 8. Herstel ConfigMaps en Secrets
./eks-fargate-restore.sh --backup-dir backups/<cluster>_<ts> --only config --restore-secrets --force

# 9. Herstel workloads
./eks-fargate-restore.sh --backup-dir backups/<cluster>_<ts> --only workloads --force

# 10. Herstel networking (Services, Ingresses)
./eks-fargate-restore.sh --backup-dir backups/<cluster>_<ts> --only networking --force
```

### Volgorde van herstel

```
1. EKS Cluster (AWS)
2. IAM Roles & OIDC provider
3. VPC, Subnets, Security Groups
4. Fargate Profiles
5. EKS Managed Add-ons (kube-proxy, CoreDNS, VPC CNI)
6. CRDs                    ← vóór custom resources!
7. Namespaces
8. RBAC                    ← vóór workloads (ServiceAccounts eerst)
9. ConfigMaps & Secrets    ← vóór workloads
10. StorageClasses & PVs
11. AWS Load Balancer Controller (Helm)
12. Werkloads (Deployments, StatefulSets, etc.)
13. Services & Ingresses
14. HPA, PDB, etc.
15. Overige Helm releases
```

---

## Veiligheidsnotes

### Secrets
- Kubernetes Secrets zijn **base64 encoded**, niet versleuteld
- Sla de backup op in een beveiligde locatie (S3 met SSE, versleuteld archief)
- Gebruik `--skip-secrets` als je alleen de cluster-structuur wilt bewaren
- Overweeg [AWS Secrets Manager](https://aws.amazon.com/secrets-manager/) of [External Secrets Operator](https://external-secrets.io/) voor productie

```bash
# Backup versleutelen met GPG
gpg --symmetric --cipher-algo AES256 productie_20240101_120000.tar.gz

# Of uploaden naar versleutelde S3 bucket
aws s3 cp productie_20240101_120000.tar.gz \
  s3://mijn-backup-bucket/eks-backups/ \
  --sse aws:kms \
  --sse-kms-key-id <key-id>
```

### aws-auth ConfigMap
- De `aws-auth` ConfigMap (`kubernetes/rbac/aws-auth-configmap.yaml`) bevat IAM-to-k8s mappings
- Een foutieve `aws-auth` kan je **permanent buitensluiten** van het cluster
- Pas altijd handmatig toe en verifieer via AWS Console of een ander IAM identity
- Vanaf EKS 1.29 kun je overstappen op [EKS Access Entries](https://docs.aws.amazon.com/eks/latest/userguide/access-entries.html)

### IAM Backup
- IAM roles en policies zijn **read-only** gebackupt (geen policy documenten)
- Gebruik de `iam/irsa-roles.json` als referentie bij het recreëren van IRSA

---

## Troubleshooting

### "Cannot access EKS cluster"
```bash
# Controleer AWS credentials
aws sts get-caller-identity

# Update kubeconfig
aws eks update-kubeconfig --name <cluster> --region eu-west-1

# Controleer cluster status
aws eks describe-cluster --name <cluster> --region eu-west-1 | jq '.cluster.status'
```

### "kubectl: connection refused"
```bash
# Controleer welk cluster kubeconfig gebruikt
kubectl config current-context
kubectl config get-contexts

# Zet naar juiste context
kubectl config use-context arn:aws:eks:eu-west-1:<account>:cluster/<naam>
```

### Pods blijven Pending na restore
```bash
# Controleer Fargate profile selectors
kubectl describe pod <pod> | grep -A5 Events

# Fargate profiles beschikbaar?
aws eks list-fargate-profiles --cluster-name <naam> --region eu-west-1

# Voeg namespace toe aan Fargate profiel als het er niet staat
aws eks create-fargate-profile \
  --cluster-name <naam> \
  --fargate-profile-name fp-<namespace> \
  --pod-execution-role-arn <arn> \
  --selectors namespace=<namespace>
```

### AWS LB Controller maakt geen ALB aan
```bash
# Check controller logs
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# Controleer IRSA annotatie
kubectl get sa aws-load-balancer-controller -n kube-system -o yaml | grep role-arn

# Controleer IngressClass
kubectl get ingressclass alb
```

### Helm release toepassen na restore
```bash
# Bekijk welke repos nodig zijn
cat backups/<cluster>_<ts>/helm/releases-list.json | jq '.[].chart'

# Voeg repos toe
helm repo add eks https://aws.github.io/eks-charts
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

# Installeer met opgeslagen values
helm upgrade --install <release> <repo>/<chart> \
  --version <versie> \
  -n <namespace> \
  -f backups/<cluster>_<ts>/helm/values/<ns>-<release>-values.yaml
```

---

## Licentie

MIT — zie [LICENSE](LICENSE)
