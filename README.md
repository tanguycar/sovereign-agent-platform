# sovereign-agent-platform
Sovereign Air-Gapped AI Agent Platform

# Code

## Implementation and Validation Strategy (Terraform)
To effectively debug an isolated environment and empirically prove its viability, the Infrastructure as Code (IaC) deployment must follow these 5 incremental steps:

#### 1. Network Bunker and Endpoints
Implement the VPC, multi-AZ private subnets, route tables, and strict Security Groups. Provision VPC Interface Endpoints (Bedrock, Secrets Manager, CloudWatch, KMS, ECR) and the S3 Gateway Endpoint.

##### Validation (Sans Compute)
Puisqu'aucun serveur bastion ou EC2 n'est autorisé dans ce bunker, la validation de cette étape 1 s'effectue exclusivement via l'API AWS pour s'assurer du provisionnement et de la disponibilité des interfaces réseau privées (ENI). 

```
# Vérifier que tous les VPC Endpoints sont au statut "available"
aws ec2 describe-vpc-endpoints \
    --query "VpcEndpoints[*].{Service:ServiceName, State:State, VpcId:VpcId}" \
    --output table
```

#### 2. "Canary" Test (Agentic "Hello World")
Deploy a deliberately basic Python script in an AWS Fargate container with a minimalist IAM role. This script must successfully read a dummy secret from Secrets Manager and receive a simple response from Amazon Bedrock. Success in the CloudWatch logs confirms the functionality of private routing and IAM roles without internet access.
##### Validation (Le Test Empirique)
Le déploiement et l'exécution se font en 3 phases pour respecter le cycle de vie des conteneurs. Se placer dans `code/2.terraform-canary/`.
##### 1. Provisionner l'infrastructure vide**
```
terraform init && terraform apply -auto-approve
export REPO_URL=$(terraform output -raw repository_url)
export CLUSTER=$(terraform output -raw cluster_name)
export TASK_FAMILY=$(terraform output -raw task_family)
export SUBNET=$(terraform output -raw subnet_id)
export SG=$(terraform output -raw security_group_id)
```
##### 2.Pousser l'image du Canari (via la machine locale connectée à internet)
```
aws ecr get-login-password --region eu-west-3 | docker login --username AWS --password-stdin $REPO_URL
docker build -t $REPO_URL:latest .
docker push $REPO_URL:latest
```
##### 3.Exécuter le test dans le Bunker (Control Plane Execution)
On déclenche la tâche Fargate de manière unitaire. C'est l'API AWS qui instruit Fargate de démarrer le conteneur dans notre VPC privé.
```
aws ecs run-task \
    --cluster $CLUSTER \
    --task-definition $TASK_FAMILY \
    --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[$SUBNET],securityGroups=[$SG],assignPublicIp=DISABLED}"
```
##### 4.Vérifier les logs (Preuve de l'Air-Gap)
Récupérer les logs émis par le script Python via CloudWatch (attendre ~30 secondes que la tâche s'exécute).
```
MSYS_NO_PATHCONV=1 aws logs tail /ecs/canary-agent --format short --follow
```
Résultat attendu : Les logs doivent afficher [SUCCESS] pour la récupération du secret ET pour la réponse de l'IA. Si le réseau n'était pas correctement routé via les Endpoints (timeout) ou si l'IAM était défaillant (AccessDenied), les logs afficheraient une erreur fatale.


#### 3. State Orchestration (Step Functions)
Implement the AWS Step Functions state machine to trigger the Fargate task. This step validates offloading wait-time management (pausing the agent) to an optimized serverless service.

##### Validation (Le Test Empirique)
Se placer dans `code/3.terraform-orchestration/`.
```
terraform init && terraform apply -auto-approve
export SFN_ARN=$(terraform output -raw state_machine_arn)

# Déclencher l'orchestration
aws stepfunctions start-execution \
    --state-machine-arn $SFN_ARN \
    --name "AgentValidationRun"

# Vérifier le statut de l'exécution
aws stepfunctions describe-execution \
    --execution-arn "${SFN_ARN/stateMachine/execution}:AgentValidationRun"
MSYS_NO_PATHCONV=1 aws logs tail /ecs/canary-agent --format short
```

#### 4. Inspection and Micro-segmentation (Guardrails)
Integrate AWS Network Firewall (for Egress/On-Prem perimeter) and the LLM Gateway proxy (Semantic Guardrail) into the architecture. Modify Security Group chaining to force the test Fargate container to route traffic through the Gateway proxy. Validate traffic interception and tracing within CloudWatch and ElastiCache.

##### Validation (Le Test Empirique)
Se placer dans `code/4.terraform-guardrails/`.
1. **Provisionner les Guardrails (ElastiCache, ECS Service, ANFW)**
```
terraform init && terraform apply -auto-approve
export GATEWAY_REPO=$(terraform output -raw gateway_repo_url)
export REDIS_ENDPOINT=$(terraform output -raw redis_endpoint)
```
2. **Pousser l'image proxy (LiteLLM Mock)**
```
aws ecr get-login-password --region eu-west-3 | docker login --username AWS --password-stdin $GATEWAY_REPO
cat <<EOF> Dockerfile
FROM nginx:alpine
EXPOSE 4000
CMD ["nginx", "-g", "daemon off;"]
EOF
docker build -t $GATEWAY_REPO:latest .
docker push $GATEWAY_REPO:latest
```
3. **Vérifier l'état de l'infrastructure**
L'API AWS confirmera que le composant de micro-segmentation est actif, prouvant que le chaînage d'accès (Agent -> Proxy -> Bedrock) est mécaniquement imposé.
```
# Vérifier que le cluster ElastiCache est actif
aws elasticache describe-cache-clusters --cache-cluster-id "llm-semantic-cache" --query "CacheClusters[0].CacheClusterStatus"
# Vérifier que le Firewall est provisionné (Ready)
aws network-firewall describe-firewall --firewall-name "air-gapped-anfw" --query "FirewallStatus.Status"
```



#### 5. Final Remediation Use Case
Replace the canary script with the actual DevSecOps agent (e.g., retrieving a SonarQube report, generating a code fix, and proposing a Pull Request). This step validates the complete authorization chain, from the triggering event to the action on the target information system via an ephemeral token.

## Folder structure
```
code/
├── 1.terraform-bunker-test/   # Socle réseau Air-Gapped (VPC, Endpoints, SSM)
├── 2.terraform-canary/        # Reprend le réseau et ajoute le secret et les permissions IAM
└── 3.terraform-orchestration/ # State machine Step Functions (Pattern .sync et IAM passRole)
```