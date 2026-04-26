#!/usr/bin/env bash
#
# iam-route53-setup.sh — Provision the AWS IAM user, least-privilege
# Route53 policy, and access key needed by Traefik's letsencrypt-dns
# resolver (see traefik/traefik.yml + the AWS_* schema in install.sh).
#
# Run this from a TRUSTED OPERATOR WORKSTATION, NOT the prod portal host.
# The AWS credentials this script *uses* (iam:CreateUser, iam:PutUserPolicy,
# iam:CreateAccessKey) are admin-level; the credentials it *produces* are
# scoped to writing TXT records under one Route53 hosted zone. Keep them
# on different machines. Do not invoke via the `portal` wrapper — it would
# sudo to the portal user, which has no AWS credentials.
#
# Usage:
#   ./bin/iam-route53-setup.sh --domain admitly.io
#   ./bin/iam-route53-setup.sh --domain admitly.io --user my-iam-user
#   ./bin/iam-route53-setup.sh --domain admitly.io --rotate-key
#
# Idempotent: re-running with the same --domain updates the policy in
# place (PutUserPolicy is upsert) and skips access-key creation if one
# already exists. Pass --rotate-key to delete the existing key and mint
# a new one (refuses if the user has 2 keys — disambiguate manually).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

# --- arg parsing -----------------------------------------------------------

DOMAIN=""
IAM_USER=""
ROTATE_KEY=0

usage() {
    sed -n '3,23p' "$0" | sed 's|^# \?||'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --domain)       DOMAIN="${2:-}"; shift 2 ;;
        --domain=*)     DOMAIN="${1#*=}"; shift ;;
        --user)         IAM_USER="${2:-}"; shift 2 ;;
        --user=*)       IAM_USER="${1#*=}"; shift ;;
        --rotate-key)   ROTATE_KEY=1; shift ;;
        -h|--help)      usage 0 ;;
        *)              log_error "Unknown argument: $1"; usage 1 ;;
    esac
done

[ -n "$DOMAIN" ] || { log_error "Missing required --domain"; usage 1; }
validate_fqdn "$DOMAIN" || die "Invalid FQDN: $DOMAIN"

# Sanitize for IAM names (a-z 0-9 hyphen). FQDNs are already lowercase per
# validate_fqdn, so just swap dots for hyphens.
DOMAIN_SAFE="${DOMAIN//./-}"
[ -n "$IAM_USER" ] || IAM_USER="portal-route53-acme-${DOMAIN_SAFE}"
POLICY_NAME="Route53AcmeDns01-${DOMAIN_SAFE}"

# --- preflight -------------------------------------------------------------

command -v aws >/dev/null 2>&1 || die "aws CLI not found in PATH"
command -v jq  >/dev/null 2>&1 || die "jq not found in PATH (needed to parse aws output)"

log_info "Verifying AWS identity..."
if ! IDENTITY_JSON="$(aws sts get-caller-identity --output json 2>&1)"; then
    log_error "aws sts get-caller-identity failed:"
    log_error "  $IDENTITY_JSON"
    die "Check your AWS credentials / AWS_PROFILE."
fi
ACCOUNT_ID="$(jq -r .Account <<<"$IDENTITY_JSON")"
CALLER_ARN="$(jq -r .Arn     <<<"$IDENTITY_JSON")"
log_info "  Account: $ACCOUNT_ID"
log_info "  Caller:  $CALLER_ARN"

log_info "Looking up Route53 hosted zone for $DOMAIN..."
HOSTED_ZONE_ID="$(aws route53 list-hosted-zones-by-name \
    --dns-name "${DOMAIN}." \
    --query "HostedZones[?Name=='${DOMAIN}.'].Id | [0]" \
    --output text 2>/dev/null | sed 's|/hostedzone/||')"
if [ -z "$HOSTED_ZONE_ID" ] || [ "$HOSTED_ZONE_ID" = "None" ]; then
    log_error "No Route53 hosted zone found for $DOMAIN in account $ACCOUNT_ID."
    log_error "List zones with: aws route53 list-hosted-zones --output table"
    exit 1
fi
log_info "  Hosted zone: $HOSTED_ZONE_ID"

# --- confirm --------------------------------------------------------------

echo
echo "About to create/update in AWS account ${BOLD}${ACCOUNT_ID}${RESET}:"
echo "  IAM user:    $IAM_USER"
echo "  Policy:      $POLICY_NAME (inline, scoped to zone $HOSTED_ZONE_ID)"
if [ "$ROTATE_KEY" -eq 1 ]; then
    echo "  Access key:  ROTATE existing (delete current + create new)"
else
    echo "  Access key:  create only if user has none"
fi
echo
ANSWER=""
printf "Proceed? (yes/no) "
read -r ANSWER || ANSWER=""
[ "$ANSWER" = "yes" ] || die "Aborted by user."

# --- cleanup trap ---------------------------------------------------------
# POLICY_FILE and KEY_OUT_RAW are temp files containing sensitive data.
# Always remove on exit. ENV_SNIPPET is intentionally NOT cleaned up here
# because the operator needs it to outlive this script (scp to prod).

POLICY_FILE=""
KEY_OUT_RAW=""
cleanup() {
    [ -n "$POLICY_FILE"  ] && rm -f "$POLICY_FILE"
    [ -n "$KEY_OUT_RAW"  ] && rm -f "$KEY_OUT_RAW"
}
trap cleanup EXIT

# --- 1. create user (skip if exists) --------------------------------------

if aws iam get-user --user-name "$IAM_USER" >/dev/null 2>&1; then
    log_skip "IAM user $IAM_USER already exists"
else
    log_info "Creating IAM user $IAM_USER..."
    aws iam create-user --user-name "$IAM_USER" \
        --tags "Key=purpose,Value=traefik-acme-dns01" \
               "Key=domain,Value=${DOMAIN}" \
               "Key=managed-by,Value=portal-iam-route53-setup" \
        >/dev/null
    log_ok "Created user $IAM_USER"
fi

# --- 2. attach inline policy (PutUserPolicy is upsert) --------------------

log_info "Attaching policy $POLICY_NAME..."
POLICY_FILE="$(mktemp)"
chmod 600 "$POLICY_FILE"

cat > "$POLICY_FILE" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "GetChangeStatus",
      "Effect": "Allow",
      "Action": "route53:GetChange",
      "Resource": "arn:aws:route53:::change/*"
    },
    {
      "Sid": "EditAcmeChallengeRecords",
      "Effect": "Allow",
      "Action": [
        "route53:ChangeResourceRecordSets",
        "route53:ListResourceRecordSets"
      ],
      "Resource": "arn:aws:route53:::hostedzone/${HOSTED_ZONE_ID}"
    }
  ]
}
EOF

# Local JSON sanity check before round-tripping to AWS — catches malformed
# substitutions (the most common foot-gun: empty HOSTED_ZONE_ID).
jq . "$POLICY_FILE" >/dev/null || die "Generated policy is not valid JSON; see $POLICY_FILE"

aws iam put-user-policy \
    --user-name "$IAM_USER" \
    --policy-name "$POLICY_NAME" \
    --policy-document "file://$POLICY_FILE"
log_ok "Attached $POLICY_NAME"

# --- 3. access key handling -----------------------------------------------

EXISTING_KEYS_JSON="$(aws iam list-access-keys --user-name "$IAM_USER" --output json)"
EXISTING_KEY_COUNT="$(jq '.AccessKeyMetadata | length' <<<"$EXISTING_KEYS_JSON")"

CREATE_KEY=0
if [ "$ROTATE_KEY" -eq 1 ]; then
    if [ "$EXISTING_KEY_COUNT" -gt 1 ]; then
        die "User has $EXISTING_KEY_COUNT existing access keys; refusing to rotate ambiguously. Delete the unwanted one(s) manually first."
    fi
    if [ "$EXISTING_KEY_COUNT" -eq 1 ]; then
        OLD_KEY_ID="$(jq -r '.AccessKeyMetadata[0].AccessKeyId' <<<"$EXISTING_KEYS_JSON")"
        log_info "Deleting existing access key $OLD_KEY_ID..."
        aws iam delete-access-key --user-name "$IAM_USER" --access-key-id "$OLD_KEY_ID"
        log_ok "Deleted $OLD_KEY_ID"
    fi
    CREATE_KEY=1
elif [ "$EXISTING_KEY_COUNT" -gt 0 ]; then
    log_skip "User already has $EXISTING_KEY_COUNT access key(s); pass --rotate-key to replace"
else
    CREATE_KEY=1
fi

if [ "$CREATE_KEY" -eq 1 ]; then
    log_info "Creating access key..."
    KEY_OUT_RAW="$(mktemp)"
    chmod 600 "$KEY_OUT_RAW"
    aws iam create-access-key --user-name "$IAM_USER" --output json > "$KEY_OUT_RAW"

    ACCESS_KEY_ID="$(jq -r .AccessKey.AccessKeyId    "$KEY_OUT_RAW")"
    SECRET_KEY="$(   jq -r .AccessKey.SecretAccessKey "$KEY_OUT_RAW")"

    # Write a self-contained .env snippet to a mode-600 file. This file
    # outlives the script (no trap-rm) so the operator can scp it to prod.
    # Same dir as KEY_OUT_RAW (mktemp default), distinct name.
    ENV_SNIPPET="$(mktemp)"
    chmod 600 "$ENV_SNIPPET"
    cat > "$ENV_SNIPPET" <<EOF
# Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by bin/iam-route53-setup.sh
# Domain: ${DOMAIN}   AWS account: ${ACCOUNT_ID}   Hosted zone: ${HOSTED_ZONE_ID}
# Append/merge into /srv/portal/.env on the prod host. Keep mode 600.
AWS_ACCESS_KEY_ID=${ACCESS_KEY_ID}
AWS_SECRET_ACCESS_KEY=${SECRET_KEY}
AWS_REGION=us-east-1
AWS_HOSTED_ZONE_ID=${HOSTED_ZONE_ID}
EOF

    echo
    log_ok "Access key created: $ACCESS_KEY_ID"
    log_info ".env snippet (mode 600) written to:"
    printf "    %s\n" "$ENV_SNIPPET"
    echo
    echo "Next steps:"
    echo "  1. Transport the snippet to prod:"
    echo "       scp \"$ENV_SNIPPET\" portal-host:/tmp/portal-route53-env"
    echo "  2. On prod, merge into .env (manual edit recommended — review first):"
    echo "       sudoedit /srv/portal/.env"
    echo "       # Replace the AWS_* lines with the contents of /tmp/portal-route53-env"
    echo "       sudo shred -u /tmp/portal-route53-env   # (or rm -P on macOS)"
    echo "  3. Restart traefik so the new resolver picks up the credentials:"
    echo "       sudo systemctl restart portal-traefik"
    echo "  4. On THIS workstation, remove the snippet once transferred:"
    echo "       shred -u \"$ENV_SNIPPET\"   # Linux"
    echo "       rm -P    \"$ENV_SNIPPET\"   # macOS"
    echo
    log_warn "The access-key SECRET is in the file above. AWS will not show it again."
fi

echo
log_ok "Done."
