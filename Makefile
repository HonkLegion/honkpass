# Every target runs scripts/make.fish. Values reach Fish through the environment.
# macOS Make 3.81 does not support .SHELLFLAGS.
SHELL := /opt/homebrew/bin/fish --no-config
.DEFAULT_GOAL := build
.NOTPARALLEL:

export CONFIGURATION ?= Debug
export DERIVED_DATA ?= .build/xcode

export NAME ?=
export DELAY ?=
export APPEARANCE ?=
export OFFLINE ?=
export MAKE_PROGRESS
export NO_COLOR
export DISTRIBUTION_DIR ?= .build/distribution
export NOTARY_PROFILE ?= bckp-notary
export NOTES_FILE ?=
export RELEASE_TAG ?=

TARGETS := help build run test smoke prepare-sdk server server-https server-stop server-reset reference reference-session screenshot \
	screenshot-bitwarden \
	reference-source design-kit public-suffixes compare two-step-code sandbox sandbox-server guard guard-off \
	check test-progress archive notarize licenses check-licenses source-archive public-source test-publication update-package upload-update test-updates
.PHONY: $(TARGETS)

$(TARGETS):
	@$(SHELL) scripts/make.fish $@
