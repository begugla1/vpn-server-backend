SHELL := /usr/bin/bash

.DEFAULT_GOAL := help

SUDO ?= sudo
APP_PORT ?= 8000
SSH_PORT ?= 22
BACKEND_IP ?=
ADMIN_IP ?=
X3UI_PORT ?= 65000
X3UI_SUB_PORT ?= 2096
X3UI_WEB_BASE_PATH ?= /
X3UI_SUB_PATH ?= /sub/
X3UI_USERNAME ?= admin
X3UI_PASSWORD ?=
ENABLE_BBR ?= true
ENABLE_FIREWALL ?= true
SQLITE_BUSY_TIMEOUT_MS ?= 15000
SQLITE_RETRY_ATTEMPTS ?= 5
WARP_PROXY_PORT ?= 40000
PANEL_CERT_DAYS ?= 825
JOB ?=

RUN_SAFE := ./ops/run-safe.sh
BACKEND_SCRIPT := ./ops/backend-host/deploy_production.sh
VPN_SCRIPT := ./ops/vpn-node/vpn-server.sh
OPS_STATE_DIR := /var/tmp/ops-run-safe
OPS_LOG_DIR := /var/log

define AS_ROOT
$(if $(strip $(SUDO)),$(SUDO),) $(1)
endef

.PHONY: help up logs migrate backend-deploy backend-deploy-direct vpn-install vpn-install-direct vpn-update vpn-update-direct vpn-backup vpn-version safe-info safe-logs safe-status require-backend-ip require-job

help:
	@echo "Common targets:"
	@echo "  make up"
	@echo "  make logs"
	@echo "  make migrate"
	@echo "  make backend-deploy [SSH_PORT=2222] [APP_PORT=8000]"
	@echo "  make vpn-install BACKEND_IP=203.0.113.10 [ADMIN_IP=198.51.100.25] [SSH_PORT=22]"
	@echo "  make vpn-update BACKEND_IP=203.0.113.10 [ADMIN_IP=198.51.100.25] [SSH_PORT=22]"
	@echo "  make vpn-backup"
	@echo "  make safe-info JOB=vpn-install"
	@echo "  make safe-logs JOB=vpn-install"
	@echo "  make safe-status JOB=vpn-install"
	@echo
	@echo "Recommended:"
	@echo "  backend-deploy, vpn-install and vpn-update use run-safe by default."
	@echo "  Use *-direct targets only when you want to run in the current SSH session."
	@echo "  vpn-server.sh no longer auto-customizes 3X-UI panel settings and installs WARP in best-effort mode."

up:
	docker compose up -d --build

logs:
	docker compose logs -f backend

migrate:
	docker compose run --rm backend alembic upgrade head

backend-deploy:
	$(call AS_ROOT,$(RUN_SAFE) --name backend-deploy -- "APP_PORT=$(APP_PORT)" "SSH_PORT=$(SSH_PORT)" bash $(BACKEND_SCRIPT))

backend-deploy-direct:
	$(call AS_ROOT,env APP_PORT="$(APP_PORT)" SSH_PORT="$(SSH_PORT)" bash $(BACKEND_SCRIPT))

prod-deploy:
	sudo ./ops/backend-host/deploy_production.sh

prod-db-backup:
	sudo /usr/local/bin/backend-db-backup

require-backend-ip:
	@if [[ -z "$(BACKEND_IP)" ]]; then \
		echo "BACKEND_IP is required. Example: make vpn-install BACKEND_IP=203.0.113.10"; \
		exit 1; \
	fi

vpn-install: require-backend-ip
	$(call AS_ROOT,$(RUN_SAFE) --name vpn-install -- "BACKEND_IP=$(BACKEND_IP)" "ADMIN_IP=$(ADMIN_IP)" "SSH_PORT=$(SSH_PORT)" "X3UI_PORT=$(X3UI_PORT)" "X3UI_SUB_PORT=$(X3UI_SUB_PORT)" "X3UI_WEB_BASE_PATH=$(X3UI_WEB_BASE_PATH)" "X3UI_SUB_PATH=$(X3UI_SUB_PATH)" "X3UI_USERNAME=$(X3UI_USERNAME)" "X3UI_PASSWORD=$(X3UI_PASSWORD)" "ENABLE_BBR=$(ENABLE_BBR)" "ENABLE_FIREWALL=$(ENABLE_FIREWALL)" "SQLITE_BUSY_TIMEOUT_MS=$(SQLITE_BUSY_TIMEOUT_MS)" "SQLITE_RETRY_ATTEMPTS=$(SQLITE_RETRY_ATTEMPTS)" "WARP_PROXY_PORT=$(WARP_PROXY_PORT)" "PANEL_CERT_DAYS=$(PANEL_CERT_DAYS)" bash $(VPN_SCRIPT) install)

vpn-install-direct: require-backend-ip
	$(call AS_ROOT,env BACKEND_IP="$(BACKEND_IP)" ADMIN_IP="$(ADMIN_IP)" SSH_PORT="$(SSH_PORT)" X3UI_PORT="$(X3UI_PORT)" X3UI_SUB_PORT="$(X3UI_SUB_PORT)" X3UI_WEB_BASE_PATH="$(X3UI_WEB_BASE_PATH)" X3UI_SUB_PATH="$(X3UI_SUB_PATH)" X3UI_USERNAME="$(X3UI_USERNAME)" X3UI_PASSWORD="$(X3UI_PASSWORD)" ENABLE_BBR="$(ENABLE_BBR)" ENABLE_FIREWALL="$(ENABLE_FIREWALL)" SQLITE_BUSY_TIMEOUT_MS="$(SQLITE_BUSY_TIMEOUT_MS)" SQLITE_RETRY_ATTEMPTS="$(SQLITE_RETRY_ATTEMPTS)" WARP_PROXY_PORT="$(WARP_PROXY_PORT)" PANEL_CERT_DAYS="$(PANEL_CERT_DAYS)" bash $(VPN_SCRIPT) install)

vpn-update: require-backend-ip
	$(call AS_ROOT,$(RUN_SAFE) --name vpn-update -- "BACKEND_IP=$(BACKEND_IP)" "ADMIN_IP=$(ADMIN_IP)" "SSH_PORT=$(SSH_PORT)" "X3UI_PORT=$(X3UI_PORT)" "X3UI_SUB_PORT=$(X3UI_SUB_PORT)" "X3UI_WEB_BASE_PATH=$(X3UI_WEB_BASE_PATH)" "X3UI_SUB_PATH=$(X3UI_SUB_PATH)" "X3UI_USERNAME=$(X3UI_USERNAME)" "X3UI_PASSWORD=$(X3UI_PASSWORD)" "ENABLE_BBR=$(ENABLE_BBR)" "ENABLE_FIREWALL=$(ENABLE_FIREWALL)" "SQLITE_BUSY_TIMEOUT_MS=$(SQLITE_BUSY_TIMEOUT_MS)" "SQLITE_RETRY_ATTEMPTS=$(SQLITE_RETRY_ATTEMPTS)" "WARP_PROXY_PORT=$(WARP_PROXY_PORT)" "PANEL_CERT_DAYS=$(PANEL_CERT_DAYS)" bash $(VPN_SCRIPT) update)

vpn-update-direct: require-backend-ip
	$(call AS_ROOT,env BACKEND_IP="$(BACKEND_IP)" ADMIN_IP="$(ADMIN_IP)" SSH_PORT="$(SSH_PORT)" X3UI_PORT="$(X3UI_PORT)" X3UI_SUB_PORT="$(X3UI_SUB_PORT)" X3UI_WEB_BASE_PATH="$(X3UI_WEB_BASE_PATH)" X3UI_SUB_PATH="$(X3UI_SUB_PATH)" X3UI_USERNAME="$(X3UI_USERNAME)" X3UI_PASSWORD="$(X3UI_PASSWORD)" ENABLE_BBR="$(ENABLE_BBR)" ENABLE_FIREWALL="$(ENABLE_FIREWALL)" SQLITE_BUSY_TIMEOUT_MS="$(SQLITE_BUSY_TIMEOUT_MS)" SQLITE_RETRY_ATTEMPTS="$(SQLITE_RETRY_ATTEMPTS)" WARP_PROXY_PORT="$(WARP_PROXY_PORT)" PANEL_CERT_DAYS="$(PANEL_CERT_DAYS)" bash $(VPN_SCRIPT) update)

vpn-backup:
	$(call AS_ROOT,env BACKEND_IP="$(BACKEND_IP)" ADMIN_IP="$(ADMIN_IP)" SSH_PORT="$(SSH_PORT)" X3UI_PORT="$(X3UI_PORT)" X3UI_SUB_PORT="$(X3UI_SUB_PORT)" X3UI_WEB_BASE_PATH="$(X3UI_WEB_BASE_PATH)" X3UI_SUB_PATH="$(X3UI_SUB_PATH)" X3UI_USERNAME="$(X3UI_USERNAME)" X3UI_PASSWORD="$(X3UI_PASSWORD)" ENABLE_BBR="$(ENABLE_BBR)" ENABLE_FIREWALL="$(ENABLE_FIREWALL)" SQLITE_BUSY_TIMEOUT_MS="$(SQLITE_BUSY_TIMEOUT_MS)" SQLITE_RETRY_ATTEMPTS="$(SQLITE_RETRY_ATTEMPTS)" bash $(VPN_SCRIPT) backup)

vpn-version:
	bash $(VPN_SCRIPT) version

require-job:
	@if [[ -z "$(JOB)" ]]; then \
		echo "JOB is required. Example: make safe-logs JOB=vpn-install"; \
		exit 1; \
	fi

safe-info: require-job
	$(if $(strip $(SUDO)),$(SUDO) ,)cat $(OPS_STATE_DIR)/$(JOB).env

safe-logs: require-job
	$(if $(strip $(SUDO)),$(SUDO) ,)tail -f $(OPS_LOG_DIR)/$(JOB).log

safe-status: require-job
	$(if $(strip $(SUDO)),$(SUDO) ,)bash -lc 'source "$(OPS_STATE_DIR)/$(JOB).env"; if [[ "$$MODE" == "systemd" ]]; then systemctl status "$$UNIT"; else ps -fp "$$PID"; fi'
