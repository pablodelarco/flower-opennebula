# Flower-OpenNebula Appliance Build Driver
#
# Usage:
#   make all                 # Build both images
#   make flower-superlink    # Build SuperLink only
#   make flower-supernode    # Build SuperNode only
#   make clean               # Remove build artifacts
#
# Prerequisites:
#   - Packer >= 1.9 with QEMU plugin
#   - QEMU/KVM
#   - one-apps repo at ONE_APPS_DIR (default: ../one-apps)
#   - Base image at INPUT_DIR/ubuntu2204.qcow2

SHELL := /bin/bash

# Directories
INPUT_DIR   ?= $(CURDIR)/images
OUTPUT_DIR  ?= $(CURDIR)/export
ONE_APPS_DIR ?= $(CURDIR)/../one-apps

# Packer flags
PACKER_FLAGS ?=
HEADLESS     ?= true

# Appliance list
APPLIANCES := flower-superlink flower-supernode

.PHONY: all clean validate $(APPLIANCES)

all: $(APPLIANCES)

# ---------- SuperLink ----------
flower-superlink: $(OUTPUT_DIR)/flower-superlink.qcow2

$(OUTPUT_DIR)/flower-superlink.qcow2: superlink/appliance.sh packer/superlink/superlink.pkr.hcl
	@echo "==> Building Flower SuperLink image..."
	@mkdir -p $(OUTPUT_DIR)
	cd packer/superlink && \
	packer init . && \
	packer build \
		-var "input_dir=$(INPUT_DIR)" \
		-var "output_dir=$(OUTPUT_DIR)" \
		-var "one_apps_dir=$(ONE_APPS_DIR)" \
		-var "headless=$(HEADLESS)" \
		$(PACKER_FLAGS) \
		.
	@echo "==> SuperLink image: $(OUTPUT_DIR)/flower-superlink.qcow2"

# ---------- SuperNode ----------
flower-supernode: $(OUTPUT_DIR)/flower-supernode.qcow2

$(OUTPUT_DIR)/flower-supernode.qcow2: supernode/appliance.sh packer/supernode/supernode.pkr.hcl
	@echo "==> Building Flower SuperNode image..."
	@mkdir -p $(OUTPUT_DIR)
	cd packer/supernode && \
	packer init . && \
	packer build \
		-var "input_dir=$(INPUT_DIR)" \
		-var "output_dir=$(OUTPUT_DIR)" \
		-var "one_apps_dir=$(ONE_APPS_DIR)" \
		-var "headless=$(HEADLESS)" \
		$(PACKER_FLAGS) \
		.
	@echo "==> SuperNode image: $(OUTPUT_DIR)/flower-supernode.qcow2"

# ---------- Validation ----------
validate:
	@echo "==> Validating shell scripts..."
	bash -n superlink/appliance.sh
	bash -n supernode/appliance.sh
	bash -n packer/scripts/81-configure-ssh.sh
	bash -n packer/scripts/82-configure-context.sh
	@echo "==> Validating Packer templates..."
	cd packer/superlink && packer validate -syntax-only .
	cd packer/supernode && packer validate -syntax-only .
	@echo "==> All validations passed."

# ---------- Clean ----------
clean:
	rm -rf $(OUTPUT_DIR)
	rm -f packer/superlink/flower-superlink-context.iso
	rm -rf packer/superlink/context/
	rm -f packer/supernode/flower-supernode-context.iso
	rm -rf packer/supernode/context/
	@echo "==> Build artifacts cleaned."
