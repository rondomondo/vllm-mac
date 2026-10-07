PROJECT    := vllm-runner
MODEL      ?= /path/to/model
HOST       ?= 0.0.0.0
PORT       ?= 8000
DTYPE      ?= float16
GPU_MEM    ?= 0.9
MAX_LEN    ?= 4096
EXTRA      ?=
OLLAMA_DIR ?= $(HOME)/.ollama/models

.DEFAULT_GOAL := help
MAKEFLAGS     += --no-print-directory

BOLD  := \033[1m
CYAN  := \033[36m
RESET := \033[0m

.PHONY: help install lint format typecheck test ci serve serve-bg stop status health models chat clean

help: ## Show this help message
	@awk 'BEGIN {FS = ":.*##"; printf "Usage: make $(CYAN)<target>$(RESET)\n"} \
	  /^##@/ { printf "\n$(BOLD)%s$(RESET)\n", substr($$0,5) } \
	  /^[a-zA-Z0-9_-]+:.*?##/ { printf "  $(CYAN)%-14s$(RESET) %s\n", $$1, $$2 }' \
	  $(MAKEFILE_LIST)

##@ Setup

install: ## Install all dependencies (including dev)
	uv sync --extra dev
	git config core.hooksPath .githooks
	chmod +x .githooks/commit-msg

##@ Quality

lint: ## Run ruff linter
	uv run ruff check src tests

format: ## Run ruff formatter
	uv run ruff format src tests
	uv run ruff check --fix src tests

typecheck: ## Run mypy
	uv run mypy src

##@ Test

test: ## Run pytest with coverage
	uv run pytest --cov=vllm_runner --cov-report=term-missing

ci: format lint typecheck test ## Run full CI pipeline

##@ Server

serve: ## Serve a model -- pass a HuggingFace ID or a local path from 'make models' (MODEL=... make serve)
	@if [ "$(MODEL)" = "/path/to/model" ]; then \
		echo "ERROR: set MODEL= to a HuggingFace ID or a local path shown by 'make models'"; exit 1; \
	fi
	@if [ -f "$(MODEL)" ]; then \
		echo "Detected local GGUF file -- using --load-format gguf --dtype auto"; \
		uv run vllm serve $(MODEL) \
			--host $(HOST) \
			--port $(PORT) \
			--load-format gguf \
			--dtype auto \
			--gpu-memory-utilization $(GPU_MEM) \
			--max-model-len $(MAX_LEN) \
			$(EXTRA); \
	else \
		uv run vllm serve $(MODEL) \
			--host $(HOST) \
			--port $(PORT) \
			--dtype $(DTYPE) \
			--gpu-memory-utilization $(GPU_MEM) \
			--max-model-len $(MAX_LEN) \
			$(EXTRA); \
	fi

serve-bg: ## Start vLLM server in background, writing PID to .vllm.pid
	@if [ "$(MODEL)" = "/path/to/model" ]; then \
		echo "ERROR: set MODEL= to a HuggingFace ID or a local path shown by 'make models'"; exit 1; \
	fi
	@if [ -f "$(MODEL)" ]; then \
		echo "Detected local GGUF file -- using --load-format gguf --dtype auto"; \
		uv run vllm serve $(MODEL) \
			--host $(HOST) \
			--port $(PORT) \
			--load-format gguf \
			--dtype auto \
			--gpu-memory-utilization $(GPU_MEM) \
			--max-model-len $(MAX_LEN) \
			$(EXTRA) & echo $$! > .vllm.pid; \
	else \
		uv run vllm serve $(MODEL) \
			--host $(HOST) \
			--port $(PORT) \
			--dtype $(DTYPE) \
			--gpu-memory-utilization $(GPU_MEM) \
			--max-model-len $(MAX_LEN) \
			$(EXTRA) & echo $$! > .vllm.pid; \
	fi
	@echo "Started vLLM (PID $$(cat .vllm.pid)) on $(HOST):$(PORT)"

stop: ## Stop background vLLM server
	@if [ -f .vllm.pid ]; then \
		kill $$(cat .vllm.pid) && rm .vllm.pid && echo "Stopped vLLM"; \
	else \
		echo "No .vllm.pid found -- trying pkill"; \
		pkill -f "vllm serve" || echo "No vllm serve process found"; \
	fi

##@ Info

status: ## Check if vLLM server is running
	@if [ -f .vllm.pid ] && kill -0 $$(cat .vllm.pid) 2>/dev/null; then \
		echo "Running (PID $$(cat .vllm.pid)) on port $(PORT)"; \
	else \
		echo "Not running"; \
	fi

health: ## Hit the server health endpoint
	curl -s http://$(HOST):$(PORT)/health | python3 -m json.tool

models: ## List models -- running on server (if up) and available locally as GGUF
	@HOST=$(HOST) PORT=$(PORT) OLLAMA_DIR=$(OLLAMA_DIR) uv run scripts/list_models.py

chat: ## Send a test chat message (PROMPT="..." make chat)
	curl -s http://$(HOST):$(PORT)/v1/chat/completions \
		-H "Content-Type: application/json" \
		-d '{"model":"$(MODEL)","messages":[{"role":"user","content":"$(PROMPT)"}]}' \
		| python3 -m json.tool

##@ Cleanup

clean: ## Remove build artifacts and caches
	rm -rf dist build .venv __pycache__ .mypy_cache .ruff_cache .pytest_cache
	find . -name "*.pyc" -delete
	find . -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
