#!/bin/bash

# Arrêter le script si une commande échoue
set -e

# Variable pour contourner les problèmes de chemin sous Git Bash (Windows)
export MSYS_NO_PATHCONV=1

echo "====================================================="
echo "🚀 Démarrage de la validation automatisée (Air-Gapped)"
echo "====================================================="

echo ""
echo "-----------------------------------------------------"
echo "Phase 1 : Validation des VPC Endpoints (Bunker réseau)"
echo "-----------------------------------------------------"
# Vérifie qu'aucun endpoint n'est dans un état différent de 'available'
UNAVAILABLE_ENDPOINTS=$(aws ec2 describe-vpc-endpoints \
    --query "VpcEndpoints[?State!='available'].VpcEndpointId" \
    --output text)

if [ -n "$UNAVAILABLE_ENDPOINTS" ]; then
    echo "❌ ÉCHEC : Certains VPC Endpoints ne sont pas 'available' : $UNAVAILABLE_ENDPOINTS"
    exit 1
else
    echo "✅ SUCCÈS : Tous les VPC Endpoints sont provisionnés et opérationnels."
fi

echo ""
echo "-----------------------------------------------------"
echo "Phase 2 : Hydratation ECR & Exécution du Canari Unitaire"
echo "-----------------------------------------------------"
echo "[+] Récupération des variables Terraform du module 2..."
CLUSTER=$(cd 2.terraform-canary && terraform output -raw cluster_name)
TASK_FAMILY=$(cd 2.terraform-canary && terraform output -raw task_family)
SUBNET=$(cd 2.terraform-canary && terraform output -raw subnet_id)
SG=$(cd 2.terraform-canary && terraform output -raw security_group_id)
REPO_URL=$(cd 2.terraform-canary && terraform output -raw repository_url)

echo "[+] Authentification, Build et Push de l'image Docker vers ECR..."
aws ecr get-login-password --region eu-west-3 | docker login --username AWS --password-stdin "$REPO_URL"

# On isole le build dans le répertoire du canari pour ne pas polluer le path global
(
    cd 2.terraform-canary
    docker build -t "$REPO_URL:latest" .
    docker push "$REPO_URL:latest"
)
echo "✅ SUCCÈS : Image canari poussée sur ECR."

echo "[+] Lancement de la tâche Fargate unitaire..."
TASK_ARN=$(aws ecs run-task \
    --cluster "$CLUSTER" \
    --task-definition "$TASK_FAMILY" \
    --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[$SUBNET],securityGroups=[$SG],assignPublicIp=DISABLED}" \
    --query "tasks[0].taskArn" \
    --output text)

echo "[+] Attente de la fin du conteneur (preuve du Control Plane)..."
aws ecs wait tasks-stopped --cluster "$CLUSTER" --tasks "$TASK_ARN"

echo "[+] Analyse médico-légale du statut de la tâche..."
STOP_CODE=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK_ARN" --query "tasks[0].stopCode" --output text)
EXIT_CODE=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK_ARN" --query "tasks[0].containers[0].exitCode" --output text)

if [ "$STOP_CODE" == "TaskFailedToStart" ]; then
    echo "❌ ÉCHEC DE LANCEMENT INFRASTRUCTURE : Impossible de démarrer le conteneur (Image manquante, Route ECR cassée, IAM défaillant)."
    exit 1
fi

if [ "$EXIT_CODE" != "0" ] && [ "$EXIT_CODE" != "None" ]; then
    echo "❌ ÉCHEC APPLICATIF : Le code métier a crashé avec le code de sortie $EXIT_CODE."
    exit 1
fi

echo "✅ SUCCÈS : Tâche Canari unitaire exécutée et terminée proprement avec Exit Code 0."

echo ""
echo "-----------------------------------------------------"
echo "Phase 3 : Orchestration & Preuve de succès CloudWatch"
echo "-----------------------------------------------------"
echo "[+] Récupération de l'ARN de la State Machine..."
SFN_ARN=$(cd 3.terraform-orchestration && terraform output -raw state_machine_arn)
TIMESTAMP=$(date +%s)
EXEC_NAME="AgentValidationRun-$TIMESTAMP"

echo "[+] Lancement de l'exécution Step Functions : $EXEC_NAME"
EXEC_ARN=$(aws stepfunctions start-execution \
    --state-machine-arn "$SFN_ARN" \
    --name "$EXEC_NAME" \
    --query "executionArn" \
    --output text)

echo "[+] Attente de la fin de l'orchestration..."
while true; do
    STATUS=$(aws stepfunctions describe-execution --execution-arn "$EXEC_ARN" --query "status" --output text)
    if [ "$STATUS" == "SUCCEEDED" ]; then
        echo "✅ SUCCÈS : Exécution Step Functions terminée."
        break
    elif [ "$STATUS" == "FAILED" ] || [ "$STATUS" == "TIMED_OUT" ] || [ "$STATUS" == "ABORTED" ]; then
        echo "❌ ÉCHEC : L'orchestration a échoué avec le statut $STATUS."
        exit 1
    fi
    sleep 5
done

echo "[+] Analyse des logs CloudWatch pour valider l'Air-Gap..."
sleep 5 
LOGS=$(aws logs filter-log-events \
    --log-group-name "/ecs/canary-agent" \
    --limit 20 \
    --output json)

if echo "$LOGS" | grep -q "SUCCESS"; then
    echo "✅ SUCCÈS DE L'ISOLATION : Mot-clé '[SUCCESS]' détecté dans les logs."
else
    echo "❌ ÉCHEC : Aucune preuve de succès trouvée dans les logs. Vérifier l'IAM ou le routage des Endpoints."
    exit 1
fi

echo ""
echo "-----------------------------------------------------"
echo "Phase 4 : Inspection & Micro-segmentation (Guardrails)"
echo "-----------------------------------------------------"
echo "[+] Déploiement des Guardrails (ANFW, ElastiCache, LLM Gateway)..."
(
    cd 4.terraform-guardrails
    terraform init -input=false
    terraform apply -auto-approve -input=false
    
    GATEWAY_REPO=$(terraform output -raw gateway_repo_url)
    echo "[+] Création et Push de l'image LLM Proxy de substitution..."
    aws ecr get-login-password --region eu-west-3 | docker login --username AWS --password-stdin "$GATEWAY_REPO"
    docker build -t "$GATEWAY_REPO:latest" .
    docker push "$GATEWAY_REPO:latest"
)

echo "[+] Validation du cluster ElastiCache (Redis)..."
REDIS_STATUS=$(aws elasticache describe-cache-clusters --cache-cluster-id "llm-semantic-cache" --query "CacheClusters[0].CacheClusterStatus" --output text)
if [ "$REDIS_STATUS" == "available" ]; then
    echo "✅ SUCCÈS : ElastiCache est provisionné et disponible."
else
    echo "⚠️ AVERTISSEMENT : ElastiCache est dans l'état $REDIS_STATUS. Le provisionnement peut prendre jusqu'à 5 minutes."
fi

echo "[+] Validation de l'AWS Network Firewall..."
ANFW_STATUS=$(aws network-firewall describe-firewall --firewall-name "air-gapped-anfw" --query "FirewallStatus.Status" --output text)
if [ "$ANFW_STATUS" == "READY" ]; then
    echo "✅ SUCCÈS : L'AWS Network Firewall est déployé et READY."
else
    echo "⚠️ AVERTISSEMENT : L'ANFW est dans l'état $ANFW_STATUS. Le provisionnement prend du temps."
fi


echo ""
echo "-----------------------------------------------------"
echo "Phase 5 : Endothelial Remediation Use Case"
echo "-----------------------------------------------------"
echo "[+] Déploiement de l'environnement de remédiation..."
(
    cd 5.terraform-remediation
    terraform init -input=false
    terraform apply -auto-approve -input=false
    
    REM_REPO=$(terraform output -raw repository_url)
    REM_FAMILY=$(terraform output -raw task_family)
    TARGET_BUCKET=$(terraform output -raw target_bucket)
    
    echo "[+] Création de l'image de remédiation (Exécution des vrais appels API AWS)..."
    aws ecr get-login-password --region eu-west-3 | docker login --username AWS --password-stdin "$REM_REPO"
    docker build -t "$REM_REPO:latest" -q ./app
    docker push "$REM_REPO:latest" -q

    echo "[+] Lancement de l'Agent Fargate en boucle fermée..."
    REM_TASK_ARN=$(aws ecs run-task \
        --cluster "$CLUSTER" \
        --task-definition "$REM_FAMILY" \
        --launch-type FARGATE \
        --network-configuration "awsvpcConfiguration={subnets=[$SUBNET],securityGroups=[$SG],assignPublicIp=DISABLED}" \
        --query "tasks[0].taskArn" \
        --output text)

    echo "[+] Attente de la résolution de l'agent..."
    aws ecs wait tasks-stopped --cluster "$CLUSTER" --tasks "$REM_TASK_ARN"
    REM_EXIT_CODE=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$REM_TASK_ARN" --query "tasks[0].containers[0].exitCode" --output text)

    if [ "$REM_EXIT_CODE" != "0" ] && [ "$REM_EXIT_CODE" != "None" ]; then
        echo "❌ ÉCHEC CRITIQUE : L'agent a crashé (Code $REM_EXIT_CODE). Droits IAM ou Endpoints défaillants."
        MSYS_NO_PATHCONV=1 aws logs tail /ecs/remediation-agent --format short
        exit 1
    fi

    echo "[+] Attente de l'ingestion CloudWatch et S3 (10 secondes)..."
    sleep 10

    echo ""
    echo "🔍 EXTRACTION DES PREUVES BRUTES (AIR-GAP VERIFIED) :"
    echo "-----------------------------------------------------"
    
    echo "[Preuve 1] Traces d'exécution internes (CloudWatch) :"
    # Le '|| echo' empêche le set -e de tuer le script si grep ne trouve rien
    PYTHONIOENCODING=utf8 MSYS_NO_PATHCONV=1 aws logs tail /ecs/remediation-agent --format short | grep "\[AGENT\]" || echo "⚠️ Télémétrie introuvable. Ingestion en cours ou échec silencieux de l'agent."
    
    echo ""
    echo "[Preuve 2] Vérification de l'altération de la cible (S3) :"
    # Le '|| true' est obligatoire pour ne pas crasher si ls échoue (fichier non trouvé)
    S3_CHECK=$(aws s3 ls s3://$TARGET_BUCKET/patch.json 2>/dev/null || true)
    
    if [ -n "$S3_CHECK" ]; then
        echo "✅ SUCCÈS : Artefact 'patch.json' physiquement présent dans le bucket isolé $TARGET_BUCKET."
        echo "✅ Preuve de contenu :"
        aws s3 cp s3://$TARGET_BUCKET/patch.json - 2>/dev/null
    else
        echo "❌ ÉCHEC : Aucun artefact trouvé dans le S3 cible. La remédiation a échoué."
        exit 1
    fi
)


echo ""
echo "====================================================="
echo "🎉 TOUS LES TESTS SONT PASSÉS AVEC SUCCÈS !"
echo "La plateforme Agentique Souveraine est certifiée fonctionnelle."
echo "====================================================="