#!/bin/bash

# Script to create sealed secrets from decrypted secrets.yaml.dec
# Usage: ./create-sealed-secrets.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOMELAB_DIR="$(dirname "$SCRIPT_DIR")"
SECRETS_FILE="$HOMELAB_DIR/apps/secrets.yaml.dec"
OUTPUT_DIR="$HOMELAB_DIR/apps/templates"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check dependencies
check_dependencies() {
    echo -e "${YELLOW}Checking dependencies...${NC}"
    
    if ! command -v yq &> /dev/null; then
        echo -e "${RED}Error: yq is required but not installed.${NC}"
        echo "Install with: brew install yq"
        exit 1
    fi
    
    if ! command -v kubeseal &> /dev/null; then
        echo -e "${RED}Error: kubeseal is required but not installed.${NC}"
        echo "Install with: brew install kubeseal"
        exit 1
    fi
    
    if ! kubectl get ns kube-system &> /dev/null; then
        echo -e "${RED}Error: kubectl is not configured or cluster is not accessible.${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}✓ All dependencies satisfied${NC}"
}

# Check if secrets file exists
check_secrets_file() {
    if [[ ! -f "$SECRETS_FILE" ]]; then
        echo -e "${RED}Error: secrets.yaml.dec not found at $SECRETS_FILE${NC}"
        echo "Please decrypt your secrets.yaml first with: sops -d apps/secrets.yaml > apps/secrets.yaml.dec"
        exit 1
    fi
    echo -e "${GREEN}✓ Found secrets file${NC}"
}

# Create sealed secret for Tailscale
create_tailscale_secret() {
    echo -e "${YELLOW}Creating tailscale-secret...${NC}"
    
    local client_id=$(yq e '.tailscale.clientId' "$SECRETS_FILE")
    local client_secret=$(yq e '.tailscale.clientSecret' "$SECRETS_FILE")
    
    kubectl create secret generic tailscale-secret \
        --namespace=tailscale \
        --from-literal=clientId="$client_id" \
        --from-literal=clientSecret="$client_secret" \
        --dry-run=client -o yaml | \
    kubeseal --format=yaml --namespace=tailscale > "$OUTPUT_DIR/sealed-tailscale-secret.yaml"
    
    echo -e "${GREEN}✓ Created sealed-tailscale-secret.yaml${NC}"
}

# Create sealed secret for Database
create_db_secret() {
    echo -e "${YELLOW}Creating db-secret...${NC}"
    
    local password=$(yq e '.db.password' "$SECRETS_FILE")
    
    kubectl create secret generic db-secret \
        --namespace=db-system \
        --from-literal=password="$password" \
        --dry-run=client -o yaml | \
    kubeseal --format=yaml --namespace=db-system > "$OUTPUT_DIR/sealed-db-secret.yaml"
    
    echo -e "${GREEN}✓ Created sealed-db-secret.yaml${NC}"
}

# Create sealed secret for Database (scraper namespace)
create_db_secret_scraper() {
    echo -e "${YELLOW}Creating db-secret for scraper namespace...${NC}"
    
    local password=$(yq e '.db.password' "$SECRETS_FILE")
    
    kubectl create secret generic db-secret \
        --namespace=scraper \
        --from-literal=password="$password" \
        --dry-run=client -o yaml | \
    kubeseal --format=yaml --namespace=scraper > "$OUTPUT_DIR/sealed-db-secret-scraper.yaml"
    
    echo -e "${GREEN}✓ Created sealed-db-secret-scraper.yaml${NC}"
}

# Create sealed secret for Database (limitless-tournament-decks namespace)
create_db_secret_limitless() {
    echo -e "${YELLOW}Creating db-secret for limitless-tournament-decks namespace...${NC}"
    
    local password=$(yq e '.db.password' "$SECRETS_FILE")
    
    kubectl create secret generic db-secret \
        --namespace=limitless-tournament-decks \
        --from-literal=password="$password" \
        --dry-run=client -o yaml | \
    kubeseal --format=yaml --namespace=limitless-tournament-decks > "$OUTPUT_DIR/sealed-db-secret-limitless.yaml"
    
    echo -e "${GREEN}✓ Created sealed-db-secret-limitless.yaml${NC}"
}


# Create sealed secret for GitHub
create_github_secret() {
    echo -e "${YELLOW}Creating github-secret...${NC}"
    
    local token=$(yq e '.gh.token' "$SECRETS_FILE")
    
    kubectl create secret generic github-secret \
        --namespace=actions-runner-controller \
        --from-literal=github_token="$token" \
        --dry-run=client -o yaml | \
    kubeseal --format=yaml --namespace=actions-runner-controller > "$OUTPUT_DIR/sealed-github-secret.yaml"
    
    echo -e "${GREEN}✓ Created sealed-github-secret.yaml${NC}"
}

# Create sealed secret for Cloudflare
create_cloudflare_secret() {
    echo -e "${YELLOW}Creating cloudflare-secret...${NC}"
    
    local secret=$(yq e '.cloudflare.secret' "$SECRETS_FILE")
    
    kubectl create secret generic cloudflare-secret \
        --namespace=cloudflare-tunnel \
        --from-literal=credentials.json="$secret" \
        --dry-run=client -o yaml | \
    kubeseal --format=yaml --namespace=cloudflare-tunnel > "$OUTPUT_DIR/sealed-cloudflare-secret.yaml"
    
    echo -e "${GREEN}✓ Created sealed-cloudflare-secret.yaml${NC}"
}

# Create sealed secret for Scraper (Pushover)
create_scraper_secret() {
    echo -e "${YELLOW}Creating scraper-secret...${NC}"
    
    local user=$(yq e '.pushover.scraper.user' "$SECRETS_FILE")
    local token=$(yq e '.pushover.scraper.token' "$SECRETS_FILE")
    
    kubectl create secret generic scraper-secret \
        --namespace=scraper \
        --from-literal=user="$user" \
        --from-literal=token="$token" \
        --dry-run=client -o yaml | \
    kubeseal --format=yaml --namespace=scraper > "$OUTPUT_DIR/sealed-scraper-secret.yaml"
    
    echo -e "${GREEN}✓ Created sealed-scraper-secret.yaml${NC}"
}

# Create sealed secret for GCR Scraper
create_gcr_scraper_secret() {
    echo -e "${YELLOW}Creating gcr-scraper-secret...${NC}"
    
    local dockerconfig=$(yq e '.gcr.scraper' "$SECRETS_FILE")
    
    # The dockerconfig is already base64 encoded, so decode it first then use directly
    echo "$dockerconfig" | base64 -d > /tmp/gcr-scraper-config.json
    kubectl create secret generic gcr-scraper-secret \
        --namespace=scraper \
        --from-file=.dockerconfigjson=/tmp/gcr-scraper-config.json \
        --type=kubernetes.io/dockerconfigjson \
        --dry-run=client -o yaml | \
    kubeseal --format=yaml --namespace=scraper > "$OUTPUT_DIR/sealed-gcr-scraper-secret.yaml"
    
    rm /tmp/gcr-scraper-config.json
    echo -e "${GREEN}✓ Created sealed-gcr-scraper-secret.yaml${NC}"
}

# Create sealed secret for GCR Swiss Rounds
create_gcr_swiss_rounds_secret() {
    echo -e "${YELLOW}Creating gcr-swiss-rounds-secret...${NC}"
    
    local dockerconfig=$(yq e '.gcr.swiss_rounds' "$SECRETS_FILE")
    
    # The dockerconfig is already base64 encoded, so decode it first then use directly
    echo "$dockerconfig" | base64 -d > /tmp/gcr-swiss-rounds-config.json
    kubectl create secret generic gcr-swiss-rounds-secret \
        --namespace=swiss-rounds \
        --from-file=.dockerconfigjson=/tmp/gcr-swiss-rounds-config.json \
        --type=kubernetes.io/dockerconfigjson \
        --dry-run=client -o yaml | \
    kubeseal --format=yaml --namespace=swiss-rounds > "$OUTPUT_DIR/sealed-gcr-swiss-rounds-secret.yaml"
    
    rm /tmp/gcr-swiss-rounds-config.json
    echo -e "${GREEN}✓ Created sealed-gcr-swiss-rounds-secret.yaml${NC}"
}

# Create sealed secret for GCR Limitless Tournament Decks
create_gcr_limitless_tournament_decks_secret() {
    echo -e "${YELLOW}Creating gcr-limitless-tournament-decks-secret...${NC}"
    
    local dockerconfig=$(yq e '.gcr.limitless_tournament_decks' "$SECRETS_FILE")
    
    # The dockerconfig is already base64 encoded, so decode it first then use directly
    echo "$dockerconfig" | base64 -d > /tmp/gcr-limitless-tournament-decks-config.json
    kubectl create secret generic gcr-limitless-tournament-decks-secret \
        --namespace=limitless-tournament-decks \
        --from-file=.dockerconfigjson=/tmp/gcr-limitless-tournament-decks-config.json \
        --type=kubernetes.io/dockerconfigjson \
        --dry-run=client -o yaml | \
    kubeseal --format=yaml --namespace=limitless-tournament-decks > "$OUTPUT_DIR/sealed-gcr-limitless-tournament-decks-secret.yaml"
    
    rm /tmp/gcr-limitless-tournament-decks-config.json
    echo -e "${GREEN}✓ Created sealed-gcr-limitless-tournament-decks-secret.yaml${NC}"
}

# Create sealed secret for GCR Limitless Tournament Decks
create_gcr_end_of_year_secret() {
    echo -e "${YELLOW}Creating gcr-end-of-year-secret...${NC}"
    
    local dockerconfig=$(yq e '.gcr.end_of_year' "$SECRETS_FILE")
    
    # The dockerconfig is already base64 encoded, so decode it first then use directly
    echo "$dockerconfig" | base64 -d > /tmp/gcr-end-of-year-config.json
    kubectl create secret generic gcr-end-of-year-secret \
        --namespace=end-of-year \
        --from-file=.dockerconfigjson=/tmp/gcr-end-of-year-config.json \
        --type=kubernetes.io/dockerconfigjson \
        --dry-run=client -o yaml | \
    kubeseal --format=yaml --namespace=end-of-year > "$OUTPUT_DIR/sealed-gcr-end-of-year-secret.yaml"
    
    rm /tmp/gcr-end-of-year-config.json
    echo -e "${GREEN}✓ Created sealed-gcr-end-of-year-secret.yaml${NC}"
}

# Main function
main() {
    echo -e "${GREEN}🔐 Sealed Secrets Generator${NC}"
    echo "Converting secrets from $SECRETS_FILE to sealed secrets..."
    echo ""
    
    check_dependencies
    check_secrets_file
    
    echo ""
    echo -e "${YELLOW}Creating sealed secrets...${NC}"
    
    create_tailscale_secret
    create_db_secret
    create_db_secret_scraper
    create_db_secret_limitless
    create_github_secret
    create_cloudflare_secret
    create_scraper_secret
    create_gcr_scraper_secret
    create_gcr_swiss_rounds_secret
    create_gcr_limitless_tournament_decks_secret
    create_gcr_end_of_year_secret
    
    echo ""
    echo -e "${GREEN}✅ All sealed secrets created successfully!${NC}"
    echo -e "${YELLOW}📁 Sealed secrets saved to: $OUTPUT_DIR${NC}"
    echo ""
    echo -e "${YELLOW}Next steps:${NC}"
    echo "1. Review the generated sealed secrets"
    echo "2. Commit the sealed secrets to git"
    echo "3. Remove or secure the secrets.yaml.dec file"
    echo ""
    echo -e "${RED}⚠️  Important: Make sure to delete secrets.yaml.dec after use!${NC}"
}

# Run main function
main "$@"
