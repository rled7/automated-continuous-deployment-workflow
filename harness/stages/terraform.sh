#!/usr/bin/env bash
# Exercise Terraform modules against Floci, a local AWS emulator: fmt, validate,
# `terraform test`, then apply → plan (drift must be empty) → destroy.
#
# TF_DIRS: space-separated module dirs, relative to the repo root
#          (default: harness/terraform/example).
# Modules need no changes: each is copied to a temp dir and an override file
# points the aws provider at Floci and swaps any remote backend for local state.
source "$(dirname "$0")/../lib/common.sh"
source "$HARNESS_DIR/lib/tools.sh"

FLOCI_IMAGE="${FLOCI_IMAGE:-floci/floci:2.2.0}"
FLOCI_PORT="${FLOCI_PORT:-4566}"
FLOCI_URL="http://localhost:$FLOCI_PORT"
TF_DIRS="${TF_DIRS:-harness/terraform/example}"
# Provider endpoint keys routed to Floci.
AWS_SERVICES="acm apigateway apigatewayv2 autoscaling cloudformation cloudwatch dynamodb ec2 ecr ecs eks
  elasticache elbv2 events firehose iam kinesis kms lambda logs rds route53 s3 secretsmanager sns sqs ssm
  stepfunctions sts"

need_tools terraform || exit 1
ensure_docker || exit 1

started_floci=0
teardown() {
  if [ "$started_floci" = 1 ] && [ "${KEEP:-0}" != 1 ]; then docker rm -f harness-floci >/dev/null 2>&1; fi
}
trap teardown EXIT

start_floci() {
  curl -sf -m 2 -o /dev/null "$FLOCI_URL" && { log "reusing emulator already on $FLOCI_URL"; return 0; }
  docker image inspect "$FLOCI_IMAGE" >/dev/null 2>&1 ||
    { docker pull -q "mirror.gcr.io/$FLOCI_IMAGE" >/dev/null && docker tag "mirror.gcr.io/$FLOCI_IMAGE" "$FLOCI_IMAGE"; } ||
    docker pull -q "$FLOCI_IMAGE" >/dev/null || return 1
  docker rm -f harness-floci >/dev/null 2>&1
  docker run -d --name harness-floci -p "$FLOCI_PORT:4566" "$FLOCI_IMAGE" >/dev/null || return 1
  started_floci=1
  timeout 60 bash -c "until curl -sf -m 2 -o /dev/null $FLOCI_URL; do sleep 1; done"
}
step "start Floci ($FLOCI_IMAGE)" start_floci || finish_stage

write_overrides() {
  local dir=$1 file=zz_harness_provider.tf
  # A provider block that already exists can only be changed from an *_override.tf file.
  grep -qsE '^\s*provider\s+"aws"' "$dir"/*.tf && file=zz_harness_override.tf
  {
    echo 'provider "aws" {'
    echo '  access_key                  = "test"'
    echo '  secret_key                  = "test"'
    echo '  skip_credentials_validation = true'
    echo '  skip_requesting_account_id  = true'
    echo '  skip_metadata_api_check     = true'
    echo '  s3_use_path_style           = true'
    [ "$file" = zz_harness_provider.tf ] && echo '  region                      = "us-east-1"'
    echo '  endpoints {'
    for s in $AWS_SERVICES; do printf '    %-14s = "%s"\n' "$s" "$FLOCI_URL"; done
    echo '  }'
    echo '}'
    if grep -qsE '^\s*backend\s+"' "$dir"/*.tf; then
      echo 'terraform {'
      echo '  backend "local" {}'
      echo '}'
    fi
  } > "$dir/$file"
}

export TF_IN_AUTOMATION=1 TF_INPUT=0
for rel in $TF_DIRS; do
  src="$REPO_ROOT/$rel"
  [ -d "$src" ] || { step "$rel exists" false; continue; }
  work=$(mktemp -d)
  cp -R "$src/." "$work/"
  rm -rf "$work/.terraform" "$work"/terraform.tfstate*
  write_overrides "$work"

  step "$rel fmt" terraform -chdir="$src" fmt -check -recursive -diff
  step "$rel init" terraform -chdir="$work" init -no-color || { rm -rf "$work"; continue; }
  step "$rel validate" terraform -chdir="$work" validate -no-color
  if compgen -G "$work/tests/*.tftest.hcl" >/dev/null || compgen -G "$work/*.tftest.hcl" >/dev/null; then
    step "$rel terraform test" terraform -chdir="$work" test -no-color
  fi
  if step "$rel apply" terraform -chdir="$work" apply -auto-approve -no-color; then
    # Exit code 2 means the plan has changes right after apply: drift or a
    # resource that never converges.
    step "$rel no drift after apply" terraform -chdir="$work" plan -detailed-exitcode -no-color
  fi
  step "$rel destroy" timeout 300 terraform -chdir="$work" destroy -auto-approve -no-color
  rm -rf "$work"
done

finish_stage
