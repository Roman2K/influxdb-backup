VERSION := $(shell git describe --abbrev=1 --tags --always)
COMMIT_REF_NAME := $(shell git rev-parse --abbrev-ref HEAD)

REGISTRY_IMAGE := registry.gitlab.com/roman2k/influxdb-backup
REGISTRY_VER := $(REGISTRY_IMAGE):$(VERSION)
REGISTRY_LATEST := $(REGISTRY_IMAGE):latest

default: build push

build: build_local build_wis build_registry

build_local:
	docker build -t influxdb-backup .

build_wis:
	docker -H ssh://wis build -t influxdb-backup .

build_registry:
	docker build -t $(REGISTRY_VER) .
ifeq ($(COMMIT_REF_NAME),master)
	docker tag $(REGISTRY_VER) $(REGISTRY_LATEST)
endif

push: build_registry
	docker push $(REGISTRY_IMAGE)
