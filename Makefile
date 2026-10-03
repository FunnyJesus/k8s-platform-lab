CLUSTER         ?= platform-lab
CLUSTER_CONFIG  ?= configs/cluster.yaml
IMAGE           ?= k8s-platform-lab
TAG             ?= dev
RELEASE         ?= app
NS              ?= app
CHART           ?= charts/app
INGRESS_VERSION ?= controller-v1.15.1

.DEFAULT_GOAL := help
.PHONY: help cluster kubeconfig ingress metrics build deploy up test load down lint

help:  ## показать доступные цели
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

cluster:  ## создать kind-кластер, если его нет
	@kind get clusters | grep -qx $(CLUSTER) \
		&& echo "cluster $(CLUSTER) already exists" \
		|| kind create cluster --name $(CLUSTER) --config $(CLUSTER_CONFIG)
	kind export kubeconfig --name $(CLUSTER)

kubeconfig:  ## освежить ~/.kube/config после перезапуска Docker
	kind export kubeconfig --name $(CLUSTER)

ingress:  ## ingress-nginx, пин на control-plane, ожидание готовности
	-kubectl -n ingress-nginx delete job \
		-l app.kubernetes.io/component=admission-webhook --ignore-not-found
	kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/$(INGRESS_VERSION)/deploy/static/provider/kind/deploy.yaml
	kubectl -n ingress-nginx patch deployment ingress-nginx-controller --type=json \
		-p='[{"op":"add","path":"/spec/template/spec/nodeSelector/ingress-ready","value":"true"}]'
	kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=180s
	kubectl -n ingress-nginx wait --for=condition=ready pod \
		-l app.kubernetes.io/component=controller --timeout=180s

metrics:  ## metrics-server для HPA
	kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
	kubectl -n kube-system patch deployment metrics-server --type=json \
		-p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
	kubectl -n kube-system rollout status deployment/metrics-server --timeout=120s

build:  ## собрать образ и загрузить в кластер
	docker build -t $(IMAGE):$(TAG) .
	kind load docker-image $(IMAGE):$(TAG) --name $(CLUSTER)

deploy: build  ## поставить/обновить чарт
	helm upgrade --install $(RELEASE) $(CHART) \
		--namespace $(NS) --create-namespace \
		--set image.repository=$(IMAGE) --set image.tag=$(TAG) \
		--wait --timeout 5m

up: cluster ingress metrics deploy  ## всё с нуля до рабочей ссылки
	@echo "ready: http://localhost/"

test:  ## helm test
	helm test $(RELEASE) --namespace $(NS) --logs

load:  ## нагрузка для HPA и графиков
	BASE_URL=http://localhost ./scripts/generate-load.sh

down:  ## удалить кластер
	kind delete cluster --name $(CLUSTER)

lint:  ## ruff, hadolint, yamllint, helm lint
	helm lint $(CHART)
	helm template $(RELEASE) $(CHART) >/dev/null
	@if command -v ruff >/dev/null; then ruff check app; else echo "skip: ruff not installed"; fi
	@if command -v hadolint >/dev/null; then hadolint Dockerfile; else echo "skip: hadolint not installed"; fi
	@if command -v yamllint >/dev/null; then yamllint $(CLUSTER_CONFIG) $(CHART); else echo "skip: yamllint not installed"; fi
