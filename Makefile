OS := $(shell uname -s)

.PHONY: setup watch run teardown status dashboard

setup:
	@echo "Detected OS: $(OS)"
	@ansible-playbook ansible/sandbox.yml

watch:
	@bash scripts/watch-sandbox.sh

run:
	@bash scripts/run-agent.sh $(CMD)

dashboard:
ifeq ($(OS), Darwin)
	@echo "Starting dashboard (macOS mode — gVisor strace source)..."
	@cd dashboard && npm install --silent && node server.js
else
	@echo "Starting dashboard (Linux mode — Falco + gVisor source)..."
	@cd dashboard && npm install --silent && node server.js
endif

teardown:
ifeq ($(OS), Darwin)
	@limactl stop podman
else
	@sudo systemctl stop falco podman 2>/dev/null || true
endif
	@echo "Sandbox stopped."

status:
	@echo "--- OS ---"
	@echo "$(OS)"
ifeq ($(OS), Darwin)
	@echo "--- Lima VM ---"
	@limactl list
	@echo "--- Containers ---"
	@limactl shell podman -- sudo podman ps -a
	@echo "--- gVisor ---"
	@limactl shell podman -- runsc --version 2>&1 | head -1
	@echo "--- Dozzle ---"
	@limactl shell podman -- sudo podman inspect dozzle --format 'Dozzle: {{.State.Status}}' 2>/dev/null || echo "Dozzle: not running"
	@echo "--- Falco ---"
	@echo "Falco: skipped (macOS)"
else
	@echo "--- Podman ---"
	@podman ps -a
	@echo "--- gVisor ---"
	@runsc --version 2>&1 | head -1
	@echo "--- Falco ---"
	@systemctl is-active falco 2>/dev/null && echo "Falco: running" || echo "Falco: not running"
	@echo "--- Dozzle ---"
	@podman inspect dozzle --format 'Dozzle: {{.State.Status}}' 2>/dev/null || echo "Dozzle: not running"
	@echo "--- Dashboard ---"
	@curl -s http://localhost:9999 > /dev/null 2>&1 && echo "Dashboard: running at http://localhost:9999" || echo "Dashboard: not running (run: make dashboard)"
endif
