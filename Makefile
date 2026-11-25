# Staging is in account 414772274298. Override AWS_PROFILE if yours is named differently.
export AWS_PROFILE ?= sockshop
REGION      := eu-central-1
# Looked up by Name tag (Terraform can replace the instance); evaluated on use.
INSTANCE_ID  = $(shell AWS_REGION=$(REGION) staging/find-instance.sh)
APP_URL     := https://sockshop-staging.link

.PHONY: up down status url snapshots restore

## Start the app (instance boots in ~2 minutes)
up:
	@id=$(INSTANCE_ID); \
	state=$$(aws ec2 describe-instances --region $(REGION) --instance-ids $$id --query 'Reservations[0].Instances[0].State.Name' --output text); \
	if [ "$$state" = "stopping" ]; then \
		echo "Instance is still stopping; waiting for it to reach 'stopped'..."; \
		aws ec2 wait instance-stopped --region $(REGION) --instance-ids $$id; \
	fi; \
	aws ec2 start-instances --region $(REGION) --instance-ids $$id --output text --query 'StartingInstances[0].CurrentState.Name'
	@echo "Starting... app will be ready at $(APP_URL) in ~2 minutes"

## Stop the app manually (also auto-stops after 30 min idle)
down:
	aws ec2 stop-instances --region $(REGION) --instance-ids $(INSTANCE_ID) --output text --query 'StoppingInstances[0].CurrentState.Name'

## Show current instance state
status:
	@aws ec2 describe-instances --region $(REGION) --instance-ids $(INSTANCE_ID) \
		--query 'Reservations[0].Instances[0].State.Name' --output text

## List the daily snapshots of the server disk (newest last)
snapshots:
	@aws ec2 describe-snapshots --region $(REGION) --owner-ids self \
		--filters "Name=tag:Backup,Values=sockshop-staging" \
		--query 'sort_by(Snapshots,&StartTime)[].[SnapshotId,StartTime,State,VolumeSize]' --output table

## Rebuild the server from the latest snapshot in another AZ: make restore AZ=b
## (SNAPSHOT=snap-... for a specific one, SNAPSHOT=none for a fresh server)
restore:
	@test -n "$(AZ)" || { echo "usage: make restore AZ=a|b|c [SNAPSHOT=latest|snap-...|none]"; exit 1; }
	AWS_REGION=$(REGION) staging/restore.sh $(AZ) $(or $(SNAPSHOT),latest)

## Print the app URL
url:
	@echo $(APP_URL)

gen-complete-demo:
	make -C deploy/kubernetes docker-gen-complete-demo

check-generated-files:
	make -C deploy/kubernetes docker-check-complete-demo
