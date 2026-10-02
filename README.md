# sovereign-agent-platform
Sovereign Air-Gapped AI Agent Platform

# Code

## Quickstart : Lifecycle Management

**Construire, déployer et valider toute l'architecture :**
```
./code/tests-deploy.sh
```
**Détruire totalement et vérifier le démantèlement :**
```
./code/tests-destroy.sh
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