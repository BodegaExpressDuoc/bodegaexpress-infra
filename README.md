# bodegaexpress-infra

Infraestructura de despliegue del sistema BodegaExpress: orquestación con
Docker Compose, script de despliegue y recursos de AWS para los microservicios
ms-usuarios, ms-articulos y ms-busqueda.

## Arquitectura

```
Cliente (Postman)
   │ HTTPS + Authorization: Bearer <JWT>
   ▼
AWS API Gateway (HTTP API) ──► Lambda bodegaexpress-autorizador-jwt (valida el token)
   │
   ▼
EC2 (Docker Compose, IP elástica)
   ├─ ms-usuarios  :8081 ── PostgreSQL usuarios   (login JWT)
   ├─ ms-articulos :8082 ── PostgreSQL articulos ──► SQS bodegaexpress-eventos-articulos
   └─ ms-busqueda  :8083 ──► ms-articulos                    │
                                                             ▼
                                 Lambda bodegaexpress-alerta-stock ──► CloudWatch Logs
```

| Repositorio | Contenido |
|---|---|
| `ms-usuarios`, `ms-articulos`, `ms-busqueda` | Código, `Dockerfile` multi-stage y pipeline (build, test, imagen a ECR, despliegue en la EC2) |
| `bodegaexpress-lambda` | Lambdas en Java: autorizador JWT y alerta de stock bajo (crea la cola SQS y las funciones) |
| `bodegaexpress-infra` (este) | `docker-compose.yml`, `cicd.sh`, `aws/configurar-aws.sh` (ECR, SQS, Security Group, API Gateway) |

## Archivos

| Archivo | Uso |
|---|---|
| `docker-compose.yml` | Los 3 microservicios y 2 PostgreSQL |
| `.env.example` | Plantilla del `.env` (credenciales, puertos, imágenes de ECR, cola SQS). El `.env` no se sube |
| `cicd.sh` | Lo ejecuta el pipeline de cada microservicio en la EC2 (vía AWS SSM): baja la nueva imagen de ECR y reinicia ese servicio |
| `aws/configurar-aws.sh` | Crea o actualiza ECR, la cola SQS, el Security Group y el API Gateway. Idempotente |
| `.github/workflows/aws.yml` | Ejecuta `aws/configurar-aws.sh` al cambiar `aws/` en `main` o a mano (Actions → Run workflow) |
| `postman/bodegaexpress-gateway.postman_collection.json` | Prueba de punta a punta a través del API Gateway: seguridad (401/403), registro y login, artículo con stock bajo (alerta en la Lambda), búsqueda, acceso directo a la EC2 (403) y limpieza. Completar `gatewayUrl` y `ec2Url` |

## Uso local

```bash
cp .env.example .env            # completar credenciales y JWT_SECRET
docker build -t ms-usuarios:local  ../ms-usuarios
docker build -t ms-articulos:local ../ms-articulos
docker build -t ms-busqueda:local  ../ms-busqueda
docker compose up -d
docker compose ps
```

En local `SQS_COLA_URL` queda vacía y ms-articulos no publica eventos.

## Despliegue en AWS (AWS Academy Learner Lab)

Learner Lab no permite crear roles IAM: las Lambdas usan `LabRole` y la EC2 usa el
perfil de instancia `LabInstanceProfile`.

### 1. Secrets y variables en GitHub (organización BodegaExpressDuoc)

| Tipo | Nombre | Valor |
|---|---|---|
| Secret | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` | Credenciales de la sesión del Learner Lab (cambian en cada sesión) |
| Secret | `JWT_SECRET` | El mismo secreto que usa ms-usuarios (mínimo 32 caracteres) |
| Secret | `GATEWAY_SECRET` | Secreto que el API Gateway envía a los microservicios (`openssl rand -hex 32`). El mismo valor va en el `.env` de la EC2 |
| Variable | `EC2_INSTANCE_ID` | Id de la EC2 (despliegue de los microservicios por SSM) |
| Variable | `EC2_HOST` | IP elástica de la EC2 (integraciones del API Gateway) |
| Variable | `EC2_SG_ID` | Id del Security Group de la EC2 (opcional) |

### 2. Lambdas y cola SQS

Push a `main` en `bodegaexpress-lambda`: crea la cola `bodegaexpress-eventos-articulos`
y las funciones `bodegaexpress-autorizador-jwt` y `bodegaexpress-alerta-stock`.

### 3. EC2

1. Lanzar una EC2 **Amazon Linux 2023** (`t3.medium` recomendado: 3 JVM + 2 PostgreSQL)
   con el perfil de instancia **`LabInstanceProfile`** y asociarle una **IP elástica**.
2. Instalar Docker, Docker Compose y Git:
   ```bash
   sudo dnf install -y docker git
   sudo systemctl enable --now docker
   sudo usermod -aG docker ec2-user          # cerrar sesión y volver a entrar
   sudo mkdir -p /usr/local/lib/docker/cli-plugins
   sudo curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 \
     -o /usr/local/lib/docker/cli-plugins/docker-compose
   sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
   ```
3. Permitir que los contenedores obtengan las credenciales del perfil de instancia
   (necesario para que ms-articulos publique en SQS):
   ```bash
   aws ec2 modify-instance-metadata-options --instance-id <id-ec2> \
     --http-put-response-hop-limit 2 --http-endpoint enabled
   ```
4. Clonar este repo en `/home/ec2-user` y crear el `.env`:
   ```bash
   git clone https://github.com/BodegaExpressDuoc/bodegaexpress-infra.git
   cd bodegaexpress-infra && cp .env.example .env
   ```
   En el `.env` de la EC2: `HOST_BIND_ADDRESS=0.0.0.0`, las tres `*_IMAGE` apuntando a
   ECR, `SQS_COLA_URL` con la URL de la cola y `GATEWAY_SECRET` con el mismo valor del
   secret de GitHub.

### 4. Recursos AWS y API Gateway

Actions → **Recursos AWS** → Run workflow (o `EC2_HOST=<ip> bash aws/configurar-aws.sh`).
Al final muestra la URL del API Gateway.

### 5. Microservicios

Pull request `develop` → `main` en cada microservicio (en este orden: ms-usuarios,
ms-articulos y ms-busqueda, porque ms-busqueda depende de ms-articulos). El merge
dispara build, test, imagen a ECR y despliegue en la EC2 con `cicd.sh`.

La imagen se sube con tres tags: la versión del `pom.xml` (por ejemplo `0.2.0`), el
sha corto del commit y `latest`. La EC2 usa `latest` (variables `*_IMAGE` del `.env`);
los tags de versión y sha permiten saber qué código corre y volver a una imagen
anterior.

> En `develop` y en los pull request solo se compila y se prueba: a AWS solo se
> despliega lo que llega a `main`.

## Rutas del API Gateway

| Ruta | Destino | Protección |
|---|---|---|
| `POST /api/v1/auth/login` | ms-usuarios | Pública (entrega el JWT) |
| `POST /api/v1/usuarios` | ms-usuarios | Pública (registro) |
| `ANY /api/v1/usuarios`, `ANY /api/v1/usuarios/{proxy+}` | ms-usuarios | JWT |
| `ANY /api/v1/articulos`, `ANY /api/v1/articulos/{proxy+}` | ms-articulos | JWT |
| `GET /api/v1/busqueda` | ms-busqueda | JWT |

## Cómo se protege el backend

1. **Autenticación en el Gateway:** las rutas protegidas invocan el Lambda Authorizer
   `bodegaexpress-autorizador-jwt`. Sin token, o con un token inválido o expirado, el
   Gateway responde **401/403** sin llegar al microservicio.
2. **Solo se entra por el Gateway:** cada integración agrega el header
   `X-Gateway-Secret` (parameter mapping del HTTP API). Los tres microservicios tienen
   un `FiltroGateway` que responde **403** a cualquier petición sin ese header, así que
   llamar directo a `http://<ip-ec2>:8081..8083` no funciona aunque el puerto esté
   abierto. La llamada interna de ms-busqueda a ms-articulos envía el mismo header.
3. **Defensa en profundidad:** ms-usuarios además valida el JWT con Spring Security.

En local `GATEWAY_SECRET` queda vacío y los microservicios se pueden probar directo.

## Prueba de punta a punta

```bash
API=https://<id>.execute-api.us-east-1.amazonaws.com

# 1. Login (público) -> token
curl -s -X POST $API/api/v1/auth/login -H 'Content-Type: application/json' \
  -d '{"email":"<email>","password":"<clave>"}'

# 2. Sin token -> rechazado por el Gateway
curl -i $API/api/v1/articulos

# 2b. Directo a la EC2, saltándose el Gateway -> 403 del microservicio
curl -i http://<ip-ec2>:8082/api/v1/articulos

# 3. Con token: crear un artículo con stock bajo
curl -s -X POST $API/api/v1/articulos -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"nombre":"Caja","descripcion":"Caja mediana","precio":2500,"stock":2}'

# 4. La alerta de stock bajo aparece en CloudWatch
aws logs tail /aws/lambda/bodegaexpress-alerta-stock --since 5m
```

## Versiones

Las ramas `main` de los 5 repositorios están protegidas (solo cambian mediante pull
request desde `develop`) y cada entrega se marca con un tag anotado en `main`:

| Tag | Entrega | Repositorios |
|---|---|---|
| `v0.1.0` | Evaluación Parcial 2: microservicios con PostgreSQL | ms-usuarios, ms-articulos, ms-busqueda |
| `v0.2.0` | Evaluación Parcial 3: Docker, CI/CD, SQS, Lambda y API Gateway en AWS | Los 5 repositorios |

## Mejoras futuras

- Cerrar además los puertos de la EC2 a internet usando VPC Link + Network Load
  Balancer (hoy la protección es por el header secreto del Gateway).
