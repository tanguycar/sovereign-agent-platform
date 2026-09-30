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
echo "====================================================="
echo "🎉 TOUS LES TESTS SONT PASSÉS AVEC SUCCÈS !"
echo "La plateforme Agentique Souveraine est certifiée fonctionnelle."
echo "====================================================="