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
KPS_RELEASE ?= kps
KPS_NS      ?= monitoring
KPS_VERSION ?= 92.16.1
KPS_VALUES  ?= monitoring/kube-prometheus-stack/values.yaml
PROM_OPERATOR_VERSION ?= v0.94.2   # должна совпадать с appVersion чарта kps
SERVICE_MONITOR ?= true

.DEFAULT_GOAL := help
.PHONY: help cluster kubeconfig ingress metrics build deploy up test load down lint monitoring crds

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

crds: ## CRD оператора без установки всего стека (для CI)
      kubectl apply --server-side -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/$(PROM_OPERATOR_VERSION)/example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml
      kubectl apply --server-side -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/$(PROM_OPERATOR_VERSION)/example/prometheus-operator-crd/monitoring.coreos.com_prometheusrules.yam

deploy: build ## поставить/обновить чарт
	helm upgrade --install $(APP_NAME) $(CHART) \
		--namespace $(NS) --create-namespace \
		--set image.repository=$(IMAGE) \
		--set image.tag=$(TAG) --wait --timeout 5m \
		--set serviceMonitor.enabled=true

kubeconfig:  ## освежить ~/.kube/config после перезапуска Docker
	kind export kubeconfig --name $(CLUSTER_NAME)

up: cluster ingress metrics monitoring deploy  ## всё с нуля до рабочей ссылки
	@echo "приложение: $(BASE_URL)/"
	@echo "Grafana:    $(BASE_URL)/grafana   (admin/admin)"
	@echo "Prometheus: $(BASE_URL)/prometheus/targets"

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

monitoring: ## kube-prometheus-stack + ServiceMonitor + правила алертов
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
	helm repo update prometheus-community
	helm upgrade --install $(KPS_RELEASE) prometheus-community/kube-prometheus-stack \
			--namespace $(KPS_NS) --create-namespace \
			--version $(KPS_VERSION) \
			-f $(KPS_VALUES) \
			--wait --timeout 10m
	kubectl apply -f monitoring/k8s/alert-rules.yaml
	@echo "Grafana:    $(BASE_URL)/grafana   (admin/admin)"
	@echo "Prometheus: $(BASE_URL)/prometheus/targets"
