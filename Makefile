# Build and development helpers for wrq.

SHELL := /bin/sh

RUBY ?= ruby
RAKE ?= $(RUBY) -S rake
PREFIX ?= $(HOME)/.local

SCRIPT := wrq.rb
LIB_SOURCES := $(shell find lib -type f -name '*.rb' -print 2>/dev/null)
RUBY_SOURCES := $(SCRIPT) $(LIB_SOURCES)

SPINEL ?= spinel
SPINEL_FLAGS ?= -O s
NATIVE := dist/wrq
NATIVE_C := dist/wrq.c

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show available targets
	@echo "wrq - a local-first research paper library"
	@echo
	@echo "Available targets:"
	@awk 'BEGIN { FS = ":.*## " } /^[a-zA-Z0-9_.-]+:.*## / { printf "  %-16s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

.PHONY: test
test: ## Run lint, unit tests, shell specs, and optional native checks
	$(RAKE) test

.PHONY: lint
lint: ## Syntax-check all Ruby sources
	$(RAKE) lint

.PHONY: unit
unit: ## Run Minitest
	$(RAKE) unit

.PHONY: spec
spec: ## Run MRI shell acceptance specs
	$(RAKE) spec

.PHONY: gem
gem: ## Build the wrq-cli gem
	gem build wrq.gemspec

.PHONY: install
install: ## Install beneath PREFIX (default: ~/.local)
	install -d "$(PREFIX)/bin" "$(PREFIX)/libexec/wrq"
	install -m 755 "$(SCRIPT)" "$(PREFIX)/libexec/wrq/wrq.rb"
	rm -rf "$(PREFIX)/libexec/wrq/lib"
	cp -R lib "$(PREFIX)/libexec/wrq/lib"
	ln -sfn "../libexec/wrq/wrq.rb" "$(PREFIX)/bin/wrq"
	@echo "Installed $(PREFIX)/bin/wrq"

.PHONY: uninstall
uninstall: ## Remove files installed by this Makefile
	rm -f "$(PREFIX)/bin/wrq"
	rm -rf "$(PREFIX)/libexec/wrq"

.PHONY: native
native: $(NATIVE_C) $(NATIVE) ## Emit C and build the Spinel native executable

$(NATIVE_C): $(RUBY_SOURCES)
	mkdir -p dist
	$(SPINEL) $(SPINEL_FLAGS) -c "$(SCRIPT)" -o "$@"

$(NATIVE): $(RUBY_SOURCES)
	mkdir -p dist
	$(SPINEL) $(SPINEL_FLAGS) "$(SCRIPT)" -o "$@"

.PHONY: native-test
native-test: native ## Run shell specs against the native executable
	bash spec/tests/wrq_runner.sh "$(NATIVE)"

.PHONY: native-compare
native-compare: native ## Compare normalized MRI and native behavior
	bash spec/tests/wrq_runner_and_compare.sh "./$(SCRIPT)" "$(NATIVE)"

.PHONY: clean
clean: ## Remove generated local artifacts
	rm -rf dist pkg
	rm -f wrq-cli-*.gem
