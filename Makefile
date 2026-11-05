.PHONY: install run test up down k8s-build k8s-deploy k8s-delete smoke

install:
	pip install -r requirements-dev.txt

run:
	uvicorn app.main:app --reload

test:
	pytest -q

up:
	docker compose up --build -d

down:
	docker compose down -v

IMAGE ?= product-service:1.0.0
NS ?= product-service

k8s-build:
	docker build -t $(IMAGE) .

k8s-deploy:
	kubectl delete job product-service-migrate -n $(NS) --ignore-not-found
	kubectl apply -k k8s
	kubectl -n $(NS) wait --for=condition=complete job/product-service-migrate --timeout=300s
	kubectl -n $(NS) rollout status deploy/product-service --timeout=180s

k8s-delete:
	kubectl delete -k k8s --ignore-not-found

URL ?= http://localhost:8080

smoke:
	bash scripts/smoke.sh $(URL)
