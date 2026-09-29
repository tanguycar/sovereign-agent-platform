# sovereign-agent-platform
Sovereign Air-Gapped AI Agent Platform

## Implementation and Validation Strategy (Terraform)
To effectively debug an isolated environment and empirically prove its viability, the Infrastructure as Code (IaC) deployment must follow these 5 incremental steps:

#### 1. Network Bunker and Endpoints
Implement the VPC, multi-AZ private subnets, route tables, and strict Security Groups. Provision VPC Interface Endpoints (Bedrock, Secrets Manager, CloudWatch, KMS) and the S3 Gateway Endpoint.
##### Comment tester?
Se connecter à l'instance et lancer les commandes suivantes:
```
curl -I https://google.com --connect-timeout 10 # il doit être impossible de se connecter à Google
aws s3 ls # on doit pouvoir accéder au S3
```

Sur votre machine locale

#### 2. "Canary" Test (Agentic "Hello World")
Deploy a deliberately basic Python script in an AWS Fargate container with a minimalist IAM role. This script must successfully read a dummy secret from Secrets Manager and receive a simple response from Amazon Bedrock. Success in the CloudWatch logs confirms the functionality of private routing and IAM roles without internet access.
##### Comment tester?
Se connecter à l'instance et lancer les commandes suivantes:
```
sudo dnf install -y python3-boto3
sudo nano agent.py
```

Dans le fichier agent.py, inclure les lignes suivantes:
```
import boto3
import json

# Configuration stricte sur la région de Paris
REGION = 'eu-west-3'

print("--- 1. Test de lecture du Secret d'Entreprise ---")
try:
    sm_client = boto3.client('secretsmanager', region_name=REGION)
    response = sm_client.get_secret_value(SecretId='enterprise/dummy-token')
    secret_dict = json.loads(response['SecretString'])
    print(f"[SUCCÈS] Secret récupéré via PrivateLink : {secret_dict['token']}\n")
except Exception as e:
    print(f"[ÉCHEC] Impossible de lire le secret : {e}\n")

print("--- 2. Test d'inférence LLM Souverain ---")
try:
    bedrock = boto3.client('bedrock-runtime', region_name=REGION)
    
    # Format de payload spécifique attendu par les modèles Mistral
    body = json.dumps({
        "prompt": "<s>[INST] Explique brièvement ce qu'est le Zero-Trust en cybersécurité. [/INST]",
        "max_tokens": 100,
        "temperature": 0.1
    })
    
    response = bedrock.invoke_model(
        modelId='mistral.mistral-large-2402-v1:0', # Utilisation du dernier Mistral Large 3
        contentType='application/json',
        accept='application/json',
        body=body
    )
    
    result = json.loads(response['body'].read())
    
    # Mistral renvoie la réponse dans une clé différente ('outputs')
    print(f"[SUCCÈS] Réponse de Bedrock via PrivateLink : {result['outputs'][0]['text'].strip()}")
except Exception as e:
    print(f"[ÉCHEC] Impossible d'interroger Bedrock : {e}")
```

Pour tester cette partie 2, executer la commande suivante:
```
python3 agent.py
```

#### 3. State Orchestration (Step Functions)
Implement the AWS Step Functions state machine to trigger the Fargate task. This step validates offloading wait-time management (pausing the agent) to an optimized serverless service.

#### 4. Inspection and Micro-segmentation (Guardrails)
Integrate AWS Network Firewall and the LLM Gateway proxy into the architecture. Modify Security Group chaining to force the test Fargate container to route traffic through these new components. Validate traffic interception and tracing within CloudWatch and ElastiCache.

#### 5. Final Remediation Use Case
Replace the canary script with the actual DevSecOps agent (e.g., retrieving a SonarQube report, generating a code fix, and proposing a Pull Request). This step validates the complete authorization chain, from the triggering event to the action on the target information system via an ephemeral token.

## Folder structure
```
code/
├── 1.terraform-bunker-test/   # Socle réseau Air-Gapped (VPC, Endpoints, SSM)
└── 2.terraform-canary/        # Reprend le réseau et ajoute le secret et les permissions IAM
```