# product-service

A production-style product catalog microservice built with **FastAPI**, **SQLAlchemy 2.0** and **PostgreSQL**.

## Features
- CRUD for products with search, price filters and pagination
- Atomic stock adjustments (DB-enforced, no overselling under concurrency)
- Consistent JSON error format: `{"error": {"code", "message"}}`
- Structured JSON logs with `X-Request-ID` correlation
- Liveness (`/health/live`) and readiness (`/health/ready`) probes
- 12-factor config via environment variables / `.env`
- Dockerfile (non-root, healthcheck) + docker-compose with Postgres
- Pytest suite using an in-memory database

## Layout
```
app/
  main.py        app factory, middleware, error handlers
  config.py      settings (pydantic-settings)
  database.py    engine, session, Base
  models.py      SQLAlchemy models
  schemas.py     Pydantic request/response models
  crud.py        data-access / business logic
  exceptions.py  domain errors -> HTTP status
  api/           routers (products, health)
tests/           pytest suite
```

## Run locally (SQLite, zero setup)
```bash
python -m venv .venv && source .venv/bin/activate   # Windows: .venv\Scripts\activate
make install        # or: pip install -r requirements-dev.txt
make run            # http://localhost:8000/docs
make test
```

## Run with Docker + Postgres
```bash
docker compose up --build
```

## API (prefix `/api/v1`)
| Method | Path | Description |
|---|---|---|
| POST | `/products` | Create product (409 on duplicate SKU) |
| GET | `/products?q=&is_active=&min_price=&max_price=&limit=&offset=` | List / search |
| GET | `/products/{id}` | Get one |
| PATCH | `/products/{id}` | Partial update (SKU immutable) |
| DELETE | `/products/{id}` | Delete |
| POST | `/products/{id}/stock` | Body `{"delta": -2}`; 409 if it would go negative |
| GET | `/health/live`, `/health/ready` | Probes |

Interactive docs: `/docs` (Swagger) and `/redoc`.

### Example
```bash
curl -X POST localhost:8000/api/v1/products -H 'content-type: application/json' \
  -d '{"sku":"KB-001","name":"Mechanical Keyboard","price":"89.90","stock":25}'
curl -X POST localhost:8000/api/v1/products/1/stock -H 'content-type: application/json' -d '{"delta":-1}'
```
Prices are serialized as strings to avoid float rounding errors.

## Production notes
- Set `AUTO_CREATE_TABLES=false` and manage schema with Alembic migrations.
- Run multiple replicas behind a load balancer; the service is stateless.
- Add authentication (e.g. JWT validation at the gateway) and `/metrics` (Prometheus) as needed.

## Deploy on Kubernetes
Manifests live in `k8s/` (Kustomize): namespace, config/secret, Postgres StatefulSet (5Gi PVC),
schema-init Job, API Deployment (2 replicas, rolling updates, probes, hardened security context),
Service, Ingress, HPA, PodDisruptionBudget and a NetworkPolicy locking Postgres to the app.

### Local cluster (minikube / kind / Docker Desktop)
```bash
make k8s-build                          # docker build -t product-service:1.0.0 .
minikube image load product-service:1.0.0     # kind: kind load docker-image product-service:1.0.0
                                              # Docker Desktop: nothing needed
minikube addons enable ingress && minikube addons enable metrics-server
make k8s-deploy                         # applies manifests, waits for schema Job + rollout

kubectl -n product-service port-forward svc/product-service 8080:80
curl localhost:8080/health/ready        # Swagger UI: http://localhost:8080/docs
```
For Ingress, map `product-service.local` to the cluster IP (minikube: `minikube ip`) in your hosts file.

### Real cluster
1. Push the image: `docker build -t REGISTRY/product-service:1.0.0 . && docker push REGISTRY/product-service:1.0.0`
2. `cd k8s && kustomize edit set image product-service=REGISTRY/product-service:1.0.0`
3. Replace `secret.yaml` with a real secret (strong, URL-safe password) from your secret manager.
4. Set your Ingress host/class and add TLS.
5. `make k8s-deploy`

For production, prefer a managed Postgres (RDS, Cloud SQL, Azure Database): drop `postgres.yaml`
and the NetworkPolicy, and point `DATABASE_URL` at it. The Job re-runs on each deploy (`make k8s-deploy`
deletes the old one first, because Job specs are immutable).
