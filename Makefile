# routedns-ingress — Makefile
# Run `make` or `make help` to see available targets.

SHELL       := /bin/bash
ROOT        := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
SCRIPTS     := $(ROOT)/scripts
INSTALLED   := /usr/local/lib/routedns-ingress
HAPROXY_CFG := /etc/haproxy/haproxy.cfg

.DEFAULT_GOAL := help

SUDO ?= sudo
SETUP_ENV := $(ROOT)/.env

.PHONY: help
help: ## Show this help
	@printf '\nroutedns-ingress\n\n  Quick start:\n'
	@printf '    make init\n'
	@printf '    edit .env  (3 backend IPs + VIP + role)\n'
	@printf '    sudo make setup\n\n'
	@printf 'Targets:\n'
	@grep -E '^[a-zA-Z0-9_.-]+:.*##' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*## "}; {printf "  %-22s %s\n", $$1, $$2}'
	@printf '\n'

# ---------------------------------------------------------------------------
# Production setup (recommended)
# ---------------------------------------------------------------------------

.PHONY: init setup render
init: ## Create .env from .env.example
	@if [ -f "$(SETUP_ENV)" ]; then \
		echo ".env already exists"; \
	else \
		cp .env.example "$(SETUP_ENV)"; \
		echo "Created .env — edit BACKEND_1/2/3, VIP, ROLE, then: sudo make setup"; \
	fi

setup: ## Full A-Z production setup (install, configure, validate, preflight)
	@test -f "$(SETUP_ENV)" || { echo "Run: make init && edit .env"; exit 1; }
	$(SUDO) bash $(SCRIPTS)/setup.sh

render: ## Render configs from .env only (no install)
	@test -f "$(SETUP_ENV)" || { echo "Run: make init"; exit 1; }
	$(SUDO) bash $(SCRIPTS)/render-config.sh

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

.PHONY: install install-master install-backup install-standalone
.PHONY: install-master-firewall install-backup-firewall
.PHONY: install-master-ufw install-backup-ufw

install: install-master ## Alias for install-master

install-master: ## Install on primary node (MASTER + Keepalived)
	$(SUDO) $(ROOT)/install.sh --role master

install-backup: ## Install on secondary node (BACKUP + Keepalived)
	$(SUDO) $(ROOT)/install.sh --role backup

install-standalone: ## Install HAProxy only (no Keepalived/VIP)
	$(SUDO) $(ROOT)/install.sh --skip-keepalived

install-master-firewall: ## Install MASTER and configure firewall (safe)
	$(SUDO) $(ROOT)/install.sh --role master --firewall

install-backup-firewall: ## Install BACKUP and configure firewall (safe)
	$(SUDO) $(ROOT)/install.sh --role backup --firewall

install-master-ufw: install-master-firewall ## Alias for install-master-firewall
install-backup-ufw: install-backup-firewall ## Alias for install-backup-firewall

.PHONY: uninstall uninstall-purge uninstall-all
uninstall: ## Remove routedns-ingress overlays (services stopped)
	$(SUDO) $(ROOT)/uninstall.sh

uninstall-purge: ## Uninstall and remove config files
	$(SUDO) $(ROOT)/uninstall.sh --purge-configs

uninstall-all: ## Uninstall, purge configs, remove packages
	$(SUDO) $(ROOT)/uninstall.sh --purge-configs --remove-packages

# ---------------------------------------------------------------------------
# Operations
# ---------------------------------------------------------------------------

.PHONY: preflight reload reload-strict validate healthcheck
preflight: ## Production preflight (fails on placeholders/missing backends)
	$(SUDO) $(INSTALLED)/preflight.sh

reload: ## Validate and zero-downtime reload HAProxy
	$(SUDO) $(INSTALLED)/reload.sh

reload-strict: ## Preflight + reload (production-safe)
	$(SUDO) env PREFLIGHT_STRICT=true $(INSTALLED)/reload.sh

validate: ## Validate installation and configuration
	$(SUDO) $(INSTALLED)/validate.sh

healthcheck: ## Run HAProxy health check (Keepalived script)
	$(SUDO) $(INSTALLED)/healthcheck.sh

.PHONY: check-config status restart-haproxy restart-keepalived logs stats
check-config: ## Validate haproxy.cfg syntax (no reload)
	@haproxy -c -f $(HAPROXY_CFG)

status: ## Show haproxy and keepalived service status
	@systemctl status haproxy --no-pager || true
	@echo ""
	@systemctl status keepalived --no-pager 2>/dev/null || true

restart-haproxy: ## Restart HAProxy (drops connections)
	$(SUDO) systemctl restart haproxy

restart-keepalived: ## Restart Keepalived
	$(SUDO) systemctl restart keepalived

logs: ## Tail HAProxy and Keepalived journal logs
	$(SUDO) journalctl -u haproxy -u keepalived -f

stats: ## Show HAProxy stats via admin socket
	@echo "show stat" | socat stdio /run/haproxy/admin.sock 2>/dev/null || \
		curl -s http://127.0.0.1:8404/stats || \
		echo "Stats unavailable — is HAProxy running?"

# ---------------------------------------------------------------------------
# Development / CI
# ---------------------------------------------------------------------------

.PHONY: lint test-config test-platform test-e2e ci ci-all
lint: ## Run ShellCheck on all scripts
	@command -v shellcheck >/dev/null || { echo "Install shellcheck first"; exit 1; }
	shellcheck -S warning $(ROOT)/scripts/*.sh $(ROOT)/install.sh $(ROOT)/uninstall.sh

test-config: ## Validate bundled haproxy.cfg (local, no install)
	@sed '/server _install_placeholder/d' $(ROOT)/configs/haproxy.cfg > /tmp/haproxy-test.cfg
	@echo '    server test1 127.0.0.1:853 check' >> /tmp/haproxy-test.cfg
	@command -v haproxy >/dev/null || { echo "Install haproxy to run test-config"; exit 1; }
	haproxy -c -f /tmp/haproxy-test.cfg
	@rm -f /tmp/haproxy-test.cfg
	@echo "Config OK"

test-platform: ## Run platform compatibility tests (requires root)
	$(SUDO) $(SCRIPTS)/test-platform.sh

test-e2e: ## Run full E2E install test with systemd (requires root)
	$(SUDO) $(SCRIPTS)/test-e2e-install.sh

ci: lint test-config ## Run local CI checks

ci-all: ci test-platform ## Run CI + platform tests (requires root)
