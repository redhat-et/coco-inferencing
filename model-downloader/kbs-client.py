#!/usr/bin/env python3
"""
KBS Client for retrieving private keys via attestation.
Simulates TEE attestation and retrieves secrets from KBS.
"""
import requests
import json
import time
import sys
import os
from base64 import b64decode

class KBSClient:
    def __init__(self, kbs_url="https://kbs-service:8080", as_url="http://mock-attestation-service:8080"):
        self.kbs_url = kbs_url
        self.as_url = as_url
        self.session_id = None

    def simulate_tee_evidence(self):
        """Generate simulated TEE evidence for demo purposes"""
        return {
            "tee_type": "simulated",
            "platform": "kind-cluster",
            "measurement": "demo-measurement-hash",
            "nonce": str(int(time.time())),
            "demo_mode": True
        }

    def request_attestation(self):
        """Request attestation from mock AS"""
        print("🔍 Requesting attestation...")

        evidence = self.simulate_tee_evidence()

        try:
            response = requests.post(
                f"{self.as_url}/attest",
                json={"evidence": evidence},
                timeout=10
            )

            if response.status_code == 200:
                attestation_result = response.json()
                print("✅ Attestation successful!")
                print(f"   Platform: {attestation_result.get('tee_evidence', {}).get('platform', 'unknown')}")
                print(f"   Security Version: {attestation_result.get('tee_evidence', {}).get('security_version', 'unknown')}")
                return attestation_result
            elif response.status_code == 403:
                error_result = response.json()
                print("❌ Attestation failed!")
                print(f"   Reason: {error_result.get('error', 'Unknown error')}")
                return None
            else:
                print(f"❌ Attestation service error: {response.status_code}")
                return None

        except requests.exceptions.RequestException as e:
            print(f"❌ Failed to connect to attestation service: {e}")
            return None

    def get_attestation_token(self, attestation_result):
        """Get attestation token from KBS using two-step RCAR handshake with session persistence"""
        print("🔐 Starting RCAR handshake with KBS...")

        # Create a session to maintain cookies between requests
        session = requests.Session()
        session.verify = False  # Disable TLS verification for self-signed certificates

        headers = {
            "Content-Type": "application/json"
        }

        # Step 1: Initial RCAR request to get nonce
        payload = {
            "version": "0.4.0",
            "tee": "sample",
            "extra-params": ""
        }

        try:
            # First request - get nonce from KBS (this sets session cookie)
            response = session.post(
                f"{self.kbs_url}/kbs/v0/auth",
                headers=headers,
                json=payload,
                timeout=10
            )

            if response.status_code != 200:
                print(f"❌ Failed to get nonce: {response.status_code}")
                print(f"   Response: {response.text}")
                return None

            result = response.json()
            nonce = result.get("nonce")
            if not nonce:
                print("❌ No nonce in response")
                return None

            print("✅ Received nonce from KBS")
            print(f"🔍 Session cookies: {session.cookies}")

            # Step 2: Send attestation evidence with nonce (using same session)
            tee_evidence = attestation_result.get("tee_evidence", {})

            # Create attestation payload for sample TEE testing
            # Based on ear_broker.rs TeeClaims structure for sample evidence
            attestation_payload = {
                "tee": "sample",
                "runtime-data": {
                    "nonce": nonce,  # Challenge nonce from KBS
                    "tee-pubkey": {  # JWK-formatted public key
                        "kty": "RSA",  # Key type (required for JWK)
                        "alg": "RS256",
                        "n": "sample-modulus-for-demo",  # Modulus (use 'n' not 'k-mod')
                        "e": "AQAB"  # Exponent (use 'e' not 'k-exp')
                    }
                },
                "tee-evidence": {
                    "primary_evidence": {
                        "sample": {
                            "tee": "sample",
                            "tee_class": "cpu",
                            "svn": tee_evidence.get("security_version", 2),
                            "claims": {
                                "platform": tee_evidence.get("platform", "simulated-tee"),
                                "measurement": tee_evidence.get("measurement", "abc123def456"),
                                "security_version": tee_evidence.get("security_version", 2),
                                "svn": tee_evidence.get("security_version", 2)
                            },
                            "runtime_data_claims": {
                                "nonce": nonce,
                                "runtime_data": "111",
                                "svn": tee_evidence.get("security_version", 2)
                            },
                            "init_data_claims": {
                                "initdata": "111"
                            }
                        }
                    },
                    "additional_evidence": ""
                }
            }

            # Second request - send evidence with nonce (session cookie will be included)
            response = session.post(
                f"{self.kbs_url}/kbs/v0/attest",
                headers=headers,
                json=attestation_payload,
                timeout=10
            )

            if response.status_code == 200:
                result = response.json()
                print(f"🔍 KBS attest response: {result}")
                token = result.get("token") or result.get("session_id") or result.get("challenge")
                if token:
                    print("✅ Attestation token received!")
                    return token
                else:
                    print("❌ No token in attest response")
                    print(f"   Available fields: {list(result.keys())}")
                    return None
            else:
                print(f"❌ Failed to complete attestation: {response.status_code}")
                print(f"   Response: {response.text}")
                return None

        except requests.exceptions.RequestException as e:
            print(f"❌ Failed to connect to KBS: {e}")
            return None
        finally:
            session.close()

    def retrieve_secret(self, resource_path, token):
        """Retrieve secret from KBS using attestation token"""
        print(f"🔑 Requesting secret: {resource_path}")

        headers = {
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json"
        }

        try:
            response = requests.get(
                f"{self.kbs_url}/kbs/v0/resource/{resource_path}",
                headers=headers,
                timeout=10,
                verify=False  # Disable TLS verification for self-signed certificates
            )

            if response.status_code == 200:
                print("✅ Secret retrieved successfully!")
                return response.content
            else:
                print(f"❌ Failed to retrieve secret: {response.status_code}")
                print(f"   Response: {response.text}")
                return None

        except requests.exceptions.RequestException as e:
            print(f"❌ Failed to connect to KBS: {e}")
            return None

    def get_private_key(self, key_path="private.key"):
        """Main method to get private key via attestation"""
        print("🚀 Starting KBS key retrieval process...")

        # Step 1: Get attestation
        attestation_result = self.request_attestation()
        if not attestation_result:
            print("💥 Attestation failed - cannot retrieve key")
            return False

        # Step 2: Get attestation token from KBS
        attestation_token = self.get_attestation_token(attestation_result)
        if not attestation_token:
            print("💥 Failed to get attestation token")
            return False

        # Step 3: Retrieve secret from KBS using token
        secret_data = self.retrieve_secret(key_path, attestation_token)
        if not secret_data:
            print("💥 Secret retrieval failed")
            return False

        # Step 4: Save to expected location
        os.makedirs(os.path.dirname("/shared/keys/private.key"), exist_ok=True)

        try:
            # Decode if base64 encoded
            if secret_data.startswith(b'LS0t'):  # "---" in base64
                decoded_data = b64decode(secret_data)
                with open("/shared/keys/private.key", "wb") as f:
                    f.write(decoded_data)
            else:
                with open("/shared/keys/private.key", "wb") as f:
                    f.write(secret_data)

            os.chmod("/shared/keys/private.key", 0o400)
            print("✅ Private key saved to /shared/keys/private.key")
            return True

        except Exception as e:
            print(f"💥 Failed to save private key: {e}")
            return False

def main():
    """Main entry point"""
    kbs_client = KBSClient()

    print("=" * 60)
    print("🔐 KBS-based Private Key Retrieval")
    print("=" * 60)

    # Wait for services to be ready
    print("⏳ Waiting for KBS and Attestation Service...")
    max_retries = 30
    for i in range(max_retries):
        try:
            # Check if services are up
            requests.get(f"{kbs_client.as_url}/health", timeout=2)
            print("✅ Services are ready!")
            break
        except:
            if i == max_retries - 1:
                print("💥 Services not available after 30 seconds")
                sys.exit(1)
            time.sleep(1)

    # Attempt key retrieval
    success = kbs_client.get_private_key()

    if success:
        print("🎉 Key retrieval completed successfully!")
        sys.exit(0)
    else:
        print("💥 Key retrieval failed!")
        sys.exit(1)

if __name__ == "__main__":
    main()
