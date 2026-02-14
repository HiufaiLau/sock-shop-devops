SHELL := /bin/bash
NAMESPACE := sock-shop

cluster:
	./devops/scripts/create-cluster.sh

deploy:
	./devops/scripts/deploy.sh

status:
	kubectl -n $(NAMESPACE) get pods,svc

open:
	@echo "Open http://localhost:8080"
	kubectl -n $(NAMESPACE) port-forward svc/front-end 8080:80

monitoring-install:
	./devops/scripts/monitoring-install.sh

monitoring-open:
	@echo "Open http://localhost:3000"
	kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80

destroy:
	./devops/scripts/destroy.sh


monitoring-status:
	kubectl -n monitoring get pods,svc
