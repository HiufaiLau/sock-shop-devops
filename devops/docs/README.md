# Sock Shop DevOps Project (microservices-demo)

This repository is a DevOps implementation around the **Sock Shop** microservices demo.
Goal: provide a reproducible deployment, basic automation, monitoring, and backup approach.

## What’s included
- Kubernetes deployment of Sock Shop (namespace: `sock-shop`)
- One-command demo via `Makefile`
- Monitoring: Prometheus + Grafana (kube-prometheus-stack)
- Backup script (cluster state + optional DB dump)
- CI validation via GitHub Actions

## Architecture (high-level)
User -> Front-end -> (Catalogue, Carts, Orders, Payment, Shipping, User) + Datastores (Mongo/Redis/etc.)

## Prerequisites
- `kubectl` configured to a Kubernetes cluster (local or cloud)
- `helm`
- `git`

Optional (local cluster):
- `kind` + Docker

## Quickstart
### 1) Create namespace / ensure cluster access
```bash
make cluster
