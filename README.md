# sovereign-agent-platform
Sovereign Air-Gapped AI Agent Platform

# Code

# Code

## ⚠️ Notes d'Implémentation & Limites Actuelles

L'infrastructure déployée via le code Terraform actuel présente des simplifications volontaires par rapport au schéma d'architecture cible strict :

*   **Périmètre Réseau (ANFW) :** Bien que l'AWS Network Firewall soit provisionné, le routage Ingress (Edge Route Table via VGW) n'est pas encore implémenté. Le trafic entrant n'est pas techniquement forcé à travers le pare-feu. La connectivité hybride (Direct Connect/VGW) n'est pas instanciée.
*   **Isolation Zero-Trust :** Le layer Compute (Fargate) dispose d'un accès direct à l'ensemble des VPC Endpoints (HTTPS), incluant Amazon Bedrock. Le trafic vers les LLM n'est donc pas restreint de manière stricte au passage obligatoire par l'Internal LLM Gateway Proxy (LiteLLM) au niveau des Security Groups.
*   **Dépendances AWS :** Pour assurer l'amorçage opérationnel de Fargate, les flux vers les VPCE vitaux (ECR, CloudWatch, KMS, Secrets Manager) sont autorisés, une complexité omise dans la vue logique de l'architecture.

## Quickstart : Lifecycle Management

**Construire, déployer et valider toute l'architecture :**
```
cd code/
for d in [1-5].terraform-*/; do
  echo "==> Déploiement : $d"
  terraform -chdir="$d" init -input=false && \
  terraform -chdir="$d" apply -auto-approve -input=false || { echo "❌ Échec critique sur $d. Arrêt immédiat."; return 1 2>/dev/null || break; }
done

echo "==> Tous les déploiements ont réussi. Lancement de la validation..."
./tests-deploy.sh
```
**Détruire totalement et vérifier le démantèlement :**
```
cd code/
for d in $(ls -d [1-5].terraform-*/ | sort -r); do
  echo "==> Destruction : $d"
  terraform -chdir="$d" destroy -auto-approve -input=false || break
done

echo "==> Tous les suppressions ont réussi. Lancement de la vérification..."
./tests-destroy.sh
```

## Code Folder structure
```
code/
├── 1.terraform-bunker-test/   # Socle réseau Air-Gapped (VPC, Endpoints, SSM)
├── 2.terraform-canary/        # Reprend le réseau et ajoute le secret et les permissions IAM
├── 3.terraform-orchestration/ # State machine Step Functions (Pattern .sync et IAM passRole)
├── 4.terraform-guardrails/    # Proxy LLM, ElastiCache et Cloud Map Service Discovery
└── 5.terraform-remediation/   # Agent final, IAM restreint strict et S3 Target Sink
```