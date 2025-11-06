#!/usr/bin/env python3
"""
Convert a Google service account JSON key to a base64-encoded dockerconfigjson format
suitable for use in secrets.yaml.dec for GCR authentication.

Usage:
    ./encode-gcr-secret.py <service-account-key.json>
    ./encode-gcr-secret.py <service-account-key.json> --registry gcr.io
"""

import json
import base64
import sys
import argparse


def create_dockerconfigjson(service_account: dict, registry: str = "gcr.io") -> dict:
    """
    Convert a service account JSON to dockerconfigjson format.

    Args:
        service_account: The service account JSON dictionary
        registry: The container registry (default: gcr.io)

    Returns:
        dockerconfigjson dictionary
    """
    email = service_account['client_email']

    # Convert service account to compact JSON string (this will be the password)
    password = json.dumps(service_account)

    # Create the auth field (base64 of "_json_key:password")
    auth_string = f"_json_key:{password}"
    auth_base64 = base64.b64encode(auth_string.encode()).decode()

    # Create the dockerconfigjson structure
    docker_config = {
        "auths": {
            registry: {
                "username": "_json_key",
                "password": password,
                "email": email,
                "auth": auth_base64
            }
        }
    }

    return docker_config


def main():
    parser = argparse.ArgumentParser(
        description='Convert Google service account JSON to base64-encoded dockerconfigjson',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s my-service-account.json
  %(prog)s my-service-account.json --registry gcr.io
  %(prog)s my-service-account.json > encoded-secret.txt
        """
    )
    parser.add_argument(
        'service_account_file',
        help='Path to the Google service account JSON key file'
    )
    parser.add_argument(
        '--registry',
        default='gcr.io',
        help='Container registry (default: gcr.io)'
    )
    parser.add_argument(
        '--verify',
        action='store_true',
        help='Verify the output by decoding it back'
    )

    args = parser.parse_args()

    try:
        # Read the service account JSON
        with open(args.service_account_file, 'r') as f:
            service_account = json.load(f)

        # Validate it's a service account
        if service_account.get('type') != 'service_account':
            print(f"Error: File does not appear to be a service account JSON (type: {service_account.get('type')})",
                  file=sys.stderr)
            sys.exit(1)

        if 'client_email' not in service_account:
            print("Error: Service account JSON missing 'client_email' field", file=sys.stderr)
            sys.exit(1)

        # Create dockerconfigjson
        docker_config = create_dockerconfigjson(service_account, args.registry)

        # Convert to JSON and base64 encode
        docker_config_json = json.dumps(docker_config)
        docker_config_base64 = base64.b64encode(docker_config_json.encode()).decode()

        # Output
        print(docker_config_base64)

        # Verify if requested
        if args.verify:
            print("\n" + "="*80, file=sys.stderr)
            print("Verification (decoded structure):", file=sys.stderr)
            print("="*80, file=sys.stderr)
            decoded = base64.b64decode(docker_config_base64).decode()
            decoded_json = json.loads(decoded)
            print(json.dumps(decoded_json, indent=2)[:500] + "...", file=sys.stderr)
            print("\n✓ Successfully encoded and verified!", file=sys.stderr)
            print(f"✓ Email: {service_account['client_email']}", file=sys.stderr)
            print(f"✓ Project: {service_account['project_id']}", file=sys.stderr)
            print(f"✓ Registry: {args.registry}", file=sys.stderr)

    except FileNotFoundError:
        print(f"Error: File '{args.service_account_file}' not found", file=sys.stderr)
        sys.exit(1)
    except json.JSONDecodeError as e:
        print(f"Error: Invalid JSON in file: {e}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
