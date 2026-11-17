# vm2lxc: lint and test entry points.
#   make lint   shellcheck over the entry script, lib/ and the test stubs
#   make test   bats unit tests (fixtures only, no Proxmox host needed)
#   make check  both

SHELL := /bin/bash

SH_FILES := vm2lxc $(wildcard lib/*.sh) $(wildcard tests/stubs/*.sh)

.PHONY: lint test check

lint:
	shellcheck -x $(SH_FILES)

test:
	bats --recursive tests

check: lint test
