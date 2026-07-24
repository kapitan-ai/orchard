.PHONY: help setup setup-elixir setup-native setup-openspec dev dev-controller dev-node-agent openspec validate-product-version format compile credo dialyzer test cover check-elixir

MIX_BOOTSTRAP_ERL_AFLAGS = -ssl protocol_version \"['tlsv1.2']\"

help:
	@printf '%s\n' \
	  'Orchard command targets:' \
	  '  make setup          Install pinned repo dependencies' \
	  '  make dev            Run source dev in the foreground' \
	  '  make dev-controller Run source-dev controller host' \
	  '  make dev-node-agent Run source-dev node-agent host' \
	  '  make openspec       Run pinned OpenSpec validation' \
	  '  make validate-product-version Validate Product Version consistency' \
	  '  make format         Run Elixir formatter' \
	  '  make test           Run default test suite' \
	  '  make check-elixir   Run full Elixir quality workflow'

setup: setup-elixir setup-native setup-openspec

setup-elixir:
	mise trust
	mise install
	ERL_AFLAGS="$(MIX_BOOTSTRAP_ERL_AFLAGS)" mise exec -- mix local.hex --if-missing --force
	ERL_AFLAGS="$(MIX_BOOTSTRAP_ERL_AFLAGS)" mise exec -- mix local.rebar --if-missing --force
	ERL_AFLAGS="$(MIX_BOOTSTRAP_ERL_AFLAGS)" mise exec -- mix deps.get

setup-native:
	mise exec -- uv sync --directory native/orchard_tokenizer
	mise exec -- uv sync --directory native/orchard_worker_mlx

setup-openspec:
	mise exec -- npm ci --ignore-scripts

dev:
	mise exec -- bin/dev

dev-controller:
	mise exec -- bin/dev-controller

dev-node-agent:
	mise exec -- bin/dev-node-agent

openspec:
	OPENSPEC_TELEMETRY=0 mise exec -- npm run openspec -- validate --all --strict --no-interactive

validate-product-version:
	mise exec -- elixir scripts/validate-product-version.exs

format:
	mise exec -- mix format

compile:
	mise exec -- mix compile --warnings-as-errors

credo:
	mise exec -- mix credo --strict

dialyzer:
	mise exec -- mix dialyzer

test:
	mise exec -- mix test

cover:
	mise exec -- mix test --cover

check-elixir: format compile credo dialyzer test cover
