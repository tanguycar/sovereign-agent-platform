#!/bin/bash
set +e
export MSYS_NO_PATHCONV=1

REGION="eu-west-3"
ORPHANS=0

log_fail() { echo -e "❌ ORPHELIN DÉTECTÉ : $1"; ORPHANS=$((ORPHANS + 1)); }

echo "🕵️ Audit de destruction par empreinte (Patterns: air-gap, canary, gateway, remediation)"

# 1. Racine Réseau (VPC) - La suppression du VPC garantit la suppression des SG et Subnets
VPC_ID=$(aws ec2 describe-vpcs --region $REGION --filters "Name=tag:Name,Values=*Air-Gapped*" --query "Vpcs[*].VpcId" --output text 2>/dev/null)
[ -n "$VPC_ID" ] && log_fail "VPC résiduel: $VPC_ID"

# 2. Compute & Conteneurs (ECS, ECR)
CLUSTERS=$(aws ecs list-clusters --region $REGION --query "clusterArns[*]" --output text 2>/dev/null | tr '\t' '\n' | grep -iE "air-gapped|guardrails|canary" || true)
for C in $CLUSTERS; do
    STATUS=$(aws ecs describe-clusters --region $REGION --clusters "$C" --query "clusters[0].status" --output text 2>/dev/null)
    [[ "$STATUS" == "ACTIVE" || "$STATUS" == "PROVISIONING" ]] && log_fail "Cluster ECS actif: $C"
done

REPOS=$(aws ecr describe-repositories --region $REGION --query "repositories[*].repositoryName" --output text 2>/dev/null | tr '\t' '\n' | grep -iE "canary|gateway|remediation" || true)
for R in $REPOS; do log_fail "Dépôt ECR: $R"; done

# 3. IAM (Rôles)
ROLES=$(aws iam list-roles --query "Roles[*].RoleName" --output text 2>/dev/null | tr '\t' '\n' | grep -iE "canary|air-gapped|gateway|remediation" || true)
for R in $ROLES; do log_fail "Rôle IAM: $R"; done

# 4. Gouvernance (Secrets, SFN, KMS)
SECRETS=$(aws secretsmanager list-secrets --region $REGION --query "SecretList[?DeletedDate==null].Name" --output text 2>/dev/null | tr '\t' '\n' | grep -iE "canary|remediation" || true)
for S in $SECRETS; do log_fail "Secret actif: $S"; done

SFNS=$(aws stepfunctions list-state-machines --region $REGION --query "stateMachines[*].name" --output text 2>/dev/null | tr '\t' '\n' | grep -iE "AgentOrchestrator" || true)
for S in $SFNS; do log_fail "State Machine: $S"; done

KMS=$(aws kms list-aliases --region $REGION --query "Aliases[*].AliasName" --output text 2>/dev/null | tr '\t' '\n' | grep -iE "agent-cmk" || true)
for K in $KMS; do log_fail "Clé KMS (Alias): $K"; done

# 5. Stockage (S3)
BUCKETS=$(aws s3api list-buckets --query "Buckets[*].Name" --output text 2>/dev/null | tr '\t' '\n' | grep -iE "remediation-target" || true)
for B in $BUCKETS; do log_fail "Bucket S3: $B"; done

# 6. Guardrails (ElastiCache, ANFW, Cloud Map)
CACHE=$(aws elasticache describe-cache-clusters --region $REGION --query "CacheClusters[*].CacheClusterId" --output text 2>/dev/null | tr '\t' '\n' | grep -iE "semantic-cache" || true)
for C in $CACHE; do log_fail "ElastiCache: $C"; done

FW=$(aws network-firewall list-firewalls --region $REGION --query "Firewalls[*].FirewallName" --output text 2>/dev/null | tr '\t' '\n' | grep -iE "air-gapped" || true)
for F in $FW; do log_fail "Network Firewall: $F"; done

NS=$(aws servicediscovery list-namespaces --region $REGION --query "Namespaces[*].Name" --output text 2>/dev/null | tr '\t' '\n' | grep -iE "airgap.local" || true)
for N in $NS; do log_fail "Cloud Map Namespace: $N"; done

# 7. Logs (CloudWatch)
LOGS=$(aws logs describe-log-groups --region $REGION --query "logGroups[*].logGroupName" --output text 2>/dev/null | tr '\t' '\n' | grep -iE "canary|gateway|remediation" || true)
for L in $LOGS; do log_fail "Log Group: $L"; done

echo "====================================================="
if [ $ORPHANS -eq 0 ]; then
    echo -e "✅ INFRA DÉTRUITE. Zéro ressource fantôme."
    exit 0
else
    echo -e "⚠️  $ORPHANS ORPHELINS DÉTECTÉS."
    exit 1
fi