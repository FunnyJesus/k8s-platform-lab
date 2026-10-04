CLUSTER_NAME ?= platform-lab
CLUSTER_CONFIG ?= configs/cluster.yaml
APP_NAME ?= my-app
NS ?= my-app
INGRESS_VERSION ?= controller-v1.15.1
IMAGE ?= k8s-platform-lab
RELEASE ?= $(APP_NAME)
TAG ?= dev
CHART ?= charts/$(APP_NAME)
BASE_URL ?= http://localhost

.DEFAULT_GOAL := help
.PHONY: help cluster kubeconfig ingress metrics build deploy up test load down lint

help: ## показать доступные цели
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

cluster: ## создать кластер kind и загрузить образ
	kind get clusters | grep -qx $(CLUSTER_NAME) \
		&& echo "cluster $(CLUSTER_NAME) already exists" \
		|| kind create cluster --name $(CLUSTER_NAME) --config $(CLUSTER_CONFIG)
	kind export kubeconfig --name $(CLUSTER_NAME)

build: cluster ## собрать образ
	docker build -t $(IMAGE):$(TAG) .
	kind load docker-image $(IMAGE):$(TAG) --name $(CLUSTER_NAME)

deploy: build ## поставить/обновить чарт
	helm upgrade --install $(APP_NAME) $(CHART) \
		--namespace $(NS) --create-namespace \
		--set image.repository=$(IMAGE) \
		--set image.tag=$(TAG) --wait --timeout 5m

kubeconfig:  ## освежить ~/.kube/config после перезапуска Docker
	kind export kubeconfig --name $(CLUSTER_NAME)

up: cluster ingress metrics deploy  ## всё с нуля до рабочей ссылки
	@echo "ready: $(BASE_URL)/"

down: ## удалить кластер и приложение
	kind delete cluster --name $(CLUSTER_NAME)

ingress:  ## ingress-nginx, пин на control-plane, ожидание готовности
	-kubectl -n ingress-nginx delete job \
		-l app.kubernetes.io/component=admission-webhook --ignore-not-found
	kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/$(INGRESS_VERSION)/deploy/static/provider/kind/deploy.yaml
	kubectl -n ingress-nginx patch deployment ingress-nginx-controller --type=json \
		-p='[{"op":"add","path":"/spec/template/spec/nodeSelector/ingress-ready","value":"true"}]'
	kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=180s
	kubectl -n ingress-nginx wait --for=condition=ready pod \
		-l app.kubernetes.io/component=controller --timeout=180s

metrics: ## metrics-server для HPA
	kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.9.0/components.yaml
	kubectl -n kube-system patch deployment metrics-server --type=json \
		-p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
	kubectl -n kube-system rollout status deployment/metrics-server --timeout=120s

lint: ## проверить чарты
	helm lint $(CHART)
	helm template $(RELEASE) $(CHART) >/dev/null

test: ## запустить тесты
	helm test $(APP_NAME) --namespace $(NS) --logs

load: ## нагрузка для HPA и графиков
	BASE_URL=$(BASE_URL) ./scripts/generate-load.sh