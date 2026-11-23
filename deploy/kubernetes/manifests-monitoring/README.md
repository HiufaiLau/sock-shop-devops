# Montoring

First create the monitoring namespace using the `00-monitoring-ns.yaml` file:

`$ kubectl create -f 00-monitoring-ns.yaml`


### Prometheus

To deploy simply apply all the prometheus manifests (01-10) in any order:

`kubectl apply $(ls *-prometheus-*.yaml | awk ' { print " -f " $1 } ')`

The prometheus server will be exposed on Nodeport `31090`.

### Grafana

Apply the grafana manifests (20 to 22):

`kubectl apply $(ls *-grafana-*.yaml | awk ' { print " -f " $1 }')`

The Prometheus datasource and the dashboards are provisioned from the
ConfigMaps in `20-grafana-configmap.yaml` every time Grafana starts, so no
import step is needed and they survive pod restarts. Login: `admin` / `admin`.

Grafana will be exposed on the NodePort `31300` 
