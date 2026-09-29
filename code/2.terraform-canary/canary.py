import boto3
import json
import os

def main():
    print("[INFO] Démarrage du Canary Air-Gapped...")
    
    try:
        # 1. Test Secrets Manager (via VPC Endpoint)
        print("[INFO] Test de connexion à Secrets Manager...")
        secrets_client = boto3.client('secretsmanager', region_name='eu-west-3')
        secret_response = secrets_client.get_secret_value(SecretId='agent/canary/api-token')
        secret_data = json.loads(secret_response['SecretString'])
        print(f"[SUCCESS] Secret récupéré et déchiffré via KMS. Valeur : {secret_data['dummy_token']}")

        # 2. Test Amazon Bedrock (via VPC Endpoint)
        print("[INFO] Test de connexion à Amazon Bedrock...")
        bedrock_client = boto3.client('bedrock-runtime', region_name='eu-west-3')
        
        # Payload spécifique au schéma Mistral
        payload = {
            "prompt": "<s>[INST] Respond with exactly one word: 'ACKNOWLEDGED'. [/INST]",
            "max_tokens": 10,
            "temperature": 0.0
        }
        
        response = bedrock_client.invoke_model(
            modelId='mistral.mistral-large-2402-v1:0',
            contentType='application/json',
            accept='application/json',
            body=json.dumps(payload)
        )
        
        response_body = json.loads(response.get('body').read())
        # Parsing spécifique au schéma de réponse Mistral
        print(f"[SUCCESS] Réponse de Bedrock : {response_body.get('outputs')[0].get('text').strip()}")
        
    except Exception as e:
        print(f"[FATAL ERROR] {str(e)}")
        exit(1)

if __name__ == "__main__":
    main()