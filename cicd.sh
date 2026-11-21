#!/bin/bash
# Despliega en la EC2 la última imagen de un microservicio.
# Uso: bash cicd.sh <servicio>   (ejemplo: bash cicd.sh ms-articulos)
# Lo ejecuta el pipeline de GitHub Actions a través de AWS SSM.
set -euo pipefail

SERVICIO="${1:?Indica el servicio, por ejemplo: bash cicd.sh ms-articulos}"
REGION="${AWS_REGION:-us-east-1}"

cd "$(dirname "$0")"
git pull --ff-only

CUENTA=$(aws sts get-caller-identity --region "$REGION" --query Account --output text)
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$CUENTA.dkr.ecr.$REGION.amazonaws.com"

docker compose pull "$SERVICIO"
docker compose up -d "$SERVICIO"
docker image prune -f
docker compose ps
