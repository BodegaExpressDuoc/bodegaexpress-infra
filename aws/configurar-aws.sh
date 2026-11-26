#!/bin/bash
# Crea o actualiza los recursos de AWS de BodegaExpress (idempotente):
#   1. Repositorios ECR de los 3 microservicios.
#   2. Cola SQS de eventos de artículos.
#   3. (Opcional) Reglas del Security Group de la EC2 para los puertos 8081-8083.
#   4. AWS API Gateway (HTTP API) con Lambda Authorizer JWT, integraciones hacia la EC2 y rutas /api/v1.
#
# Uso: EC2_HOST=<IP elástica> GATEWAY_SECRET=<secreto> bash aws/configurar-aws.sh
# Opcionales: AWS_REGION (us-east-1), EC2_SG_ID (id del Security Group de la EC2).
# Requisito: la Lambda bodegaexpress-autorizador-jwt ya desplegada (repo bodegaexpress-lambda).
#
# Protección del backend: cada integración agrega el header X-Gateway-Secret con GATEWAY_SECRET.
# Los microservicios (con el mismo GATEWAY_SECRET en el .env de la EC2) rechazan con 403 las
# peticiones que no lo traen, así que solo se puede entrar a través del API Gateway.
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash en Windows: no convertir "/api/..." en rutas de Windows

: "${EC2_HOST:?Falta EC2_HOST (IP elástica o DNS público de la EC2)}"
: "${GATEWAY_SECRET:?Falta GATEWAY_SECRET (el mismo valor del .env de la EC2)}"
[[ "$GATEWAY_SECRET" =~ ^[A-Za-z0-9_-]{32,}$ ]] || {
  echo "GATEWAY_SECRET debe tener al menos 32 caracteres alfanuméricos (openssl rand -hex 32)"; exit 1; }
CABECERAS="{\"overwrite:header.X-Gateway-Secret\":\"${GATEWAY_SECRET}\"}"
REGION="${AWS_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$REGION"
API_NOMBRE="bodegaexpress-api"
COLA="bodegaexpress-eventos-articulos"
FN_AUTORIZADOR="bodegaexpress-autorizador-jwt"
AUTORIZADOR_NOMBRE="autorizador-jwt"

CUENTA=$(aws sts get-caller-identity --query Account --output text)

# ---------- 1. ECR ----------
for servicio in ms-usuarios ms-articulos ms-busqueda; do
  if aws ecr describe-repositories --repository-names "$servicio" > /dev/null 2>&1; then
    echo "ECR $servicio: ya existe"
  else
    aws ecr create-repository --repository-name "$servicio" --query repository.repositoryUri --output text
  fi
done

# ---------- 2. SQS ----------
COLA_URL=$(aws sqs create-queue --queue-name "$COLA" --attributes VisibilityTimeout=60 \
  --query QueueUrl --output text)
echo "SQS $COLA: $COLA_URL"

# ---------- 3. Security Group (opcional) ----------
if [ -n "${EC2_SG_ID:-}" ]; then
  aws ec2 authorize-security-group-ingress --group-id "$EC2_SG_ID" \
    --ip-permissions 'IpProtocol=tcp,FromPort=8081,ToPort=8083,IpRanges=[{CidrIp=0.0.0.0/0,Description=bodegaexpress-microservicios}]' \
    > /dev/null 2>&1 && echo "Security Group: puertos 8081-8083 abiertos" \
    || echo "Security Group: la regla 8081-8083 ya existía"
fi

# ---------- 4. API Gateway ----------
FN_ARN=$(aws lambda get-function --function-name "$FN_AUTORIZADOR" \
  --query Configuration.FunctionArn --output text 2>/dev/null) || {
  echo "No existe la Lambda $FN_AUTORIZADOR: despliega primero el repo bodegaexpress-lambda"; exit 1; }

API_ID=$(aws apigatewayv2 get-apis --query "Items[?Name=='$API_NOMBRE'].ApiId | [0]" --output text)
if [ "$API_ID" = "None" ]; then
  API_ID=$(aws apigatewayv2 create-api --name "$API_NOMBRE" --protocol-type HTTP \
    --description "API Gateway de BodegaExpress" --query ApiId --output text)
  echo "API creada: $API_ID"
else
  echo "API existente: $API_ID"
fi

if [ "$(aws apigatewayv2 get-stages --api-id "$API_ID" --query "Items[?StageName=='\$default'] | length(@)")" = "0" ]; then
  aws apigatewayv2 create-stage --api-id "$API_ID" --stage-name '$default' --auto-deploy > /dev/null
fi

# Autorizador: Lambda REQUEST, payload 2.0, respuesta simple, sin caché (valida cada petición)
AUTH_ID=$(aws apigatewayv2 get-authorizers --api-id "$API_ID" \
  --query "Items[?Name=='$AUTORIZADOR_NOMBRE'].AuthorizerId | [0]" --output text)
AUTH_URI="arn:aws:apigateway:${REGION}:lambda:path/2015-03-31/functions/${FN_ARN}/invocations"
if [ "$AUTH_ID" = "None" ]; then
  AUTH_ID=$(aws apigatewayv2 create-authorizer --api-id "$API_ID" --name "$AUTORIZADOR_NOMBRE" \
    --authorizer-type REQUEST --authorizer-uri "$AUTH_URI" \
    --identity-source '$request.header.Authorization' \
    --authorizer-payload-format-version 2.0 --enable-simple-responses \
    --authorizer-result-ttl-in-seconds 0 --query AuthorizerId --output text)
else
  aws apigatewayv2 update-authorizer --api-id "$API_ID" --authorizer-id "$AUTH_ID" \
    --authorizer-uri "$AUTH_URI" > /dev/null
fi
echo "Autorizador: $AUTH_ID"

# Permiso para que el API Gateway invoque la Lambda del autorizador
aws lambda add-permission --function-name "$FN_AUTORIZADOR" --statement-id "apigateway-$API_ID" \
  --action lambda:InvokeFunction --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:${REGION}:${CUENTA}:${API_ID}/*" > /dev/null 2>&1 \
  || echo "Permiso de invocación del autorizador: ya existía"

# Integración HTTP_PROXY identificada por su descripción; si cambia la IP de la EC2 o el secreto,
# se actualiza. Agrega el header X-Gateway-Secret en cada petición hacia el microservicio.
integracion() {
  local clave="$1" uri="$2" id
  id=$(aws apigatewayv2 get-integrations --api-id "$API_ID" \
    --query "Items[?Description=='$clave'].IntegrationId | [0]" --output text)
  if [ "$id" = "None" ]; then
    id=$(aws apigatewayv2 create-integration --api-id "$API_ID" --description "$clave" \
      --integration-type HTTP_PROXY --integration-method ANY --integration-uri "$uri" \
      --payload-format-version 1.0 --request-parameters "$CABECERAS" \
      --query IntegrationId --output text)
  else
    aws apigatewayv2 update-integration --api-id "$API_ID" --integration-id "$id" \
      --integration-uri "$uri" --request-parameters "$CABECERAS" > /dev/null
  fi
  echo "$id"
}

# Ruta: protegida (CUSTOM, con el autorizador) o pública (NONE).
ruta() {
  local clave_ruta="$1" integracion_id="$2" proteccion="$3" id
  local args=(--target "integrations/$integracion_id")
  if [ "$proteccion" = "protegida" ]; then
    args+=(--authorization-type CUSTOM --authorizer-id "$AUTH_ID")
  else
    args+=(--authorization-type NONE)
  fi
  id=$(aws apigatewayv2 get-routes --api-id "$API_ID" \
    --query "Items[?RouteKey=='$clave_ruta'].RouteId | [0]" --output text)
  if [ "$id" = "None" ]; then
    aws apigatewayv2 create-route --api-id "$API_ID" --route-key "$clave_ruta" "${args[@]}" > /dev/null
  else
    aws apigatewayv2 update-route --api-id "$API_ID" --route-id "$id" "${args[@]}" > /dev/null
  fi
  printf '  %-34s %s\n' "$clave_ruta" "$proteccion"
}

U="http://${EC2_HOST}:8081"; A="http://${EC2_HOST}:8082"; B="http://${EC2_HOST}:8083"
I_LOGIN=$(integracion usuarios-login "$U/api/v1/auth/login")
I_USUARIOS=$(integracion usuarios-base "$U/api/v1/usuarios")
I_USUARIOS_P=$(integracion usuarios-proxy "$U/api/v1/usuarios/{proxy}")
I_ARTICULOS=$(integracion articulos-base "$A/api/v1/articulos")
I_ARTICULOS_P=$(integracion articulos-proxy "$A/api/v1/articulos/{proxy}")
I_BUSQUEDA=$(integracion busqueda-base "$B/api/v1/busqueda")

echo "Rutas:"
ruta "POST /api/v1/auth/login"        "$I_LOGIN"        publica
ruta "POST /api/v1/usuarios"          "$I_USUARIOS"     publica
ruta "ANY /api/v1/usuarios"           "$I_USUARIOS"     protegida
ruta "ANY /api/v1/usuarios/{proxy+}"  "$I_USUARIOS_P"   protegida
ruta "ANY /api/v1/articulos"          "$I_ARTICULOS"    protegida
ruta "ANY /api/v1/articulos/{proxy+}" "$I_ARTICULOS_P"  protegida
ruta "GET /api/v1/busqueda"           "$I_BUSQUEDA"     protegida

echo
echo "API Gateway: $(aws apigatewayv2 get-api --api-id "$API_ID" --query ApiEndpoint --output text)"
echo "Cola SQS (SQS_COLA_URL de ms-articulos en el .env de la EC2): $COLA_URL"
