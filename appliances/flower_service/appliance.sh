#!/usr/bin/env bash

# ---------------------------------------------------------------------------- #
# Copyright 2024-2026, OpenNebula Project, OpenNebula Systems                   #
#                                                                              #
# Licensed under the Apache License, Version 2.0 (the "License"); you may      #
# not use this file except in compliance with the License. You may obtain      #
# a copy of the License at                                                     #
#                                                                              #
# http://www.apache.org/licenses/LICENSE-2.0                                   #
#                                                                              #
# Unless required by applicable law or agreed to in writing, software          #
# distributed under the License is distributed on an "AS IS" BASIS,            #
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.     #
# See the License for the specific language governing permissions and          #
# limitations under the License.                                               #
# ---------------------------------------------------------------------------- #

# Flower FL - OneFlow service wrapper.
#
# This directory packages the marketplace YAMLs for the Flower Federated
# Learning OneFlow service: the SERVICE_TEMPLATE plus the SuperLink and
# SuperNode VMTEMPLATEs. No image is built from this directory -- the actual
# appliance logic lives in the per-image appliances that this service composes:
#   - appliances/flower_superlink  (flwr/superlink coordinator)
#   - appliances/flower_supernode  (flwr training client)
# The lifecycle hooks below are intentional no-ops so this file conforms to the
# one-apps service interface without altering the composed images.

ONE_SERVICE_NAME='Service Flower FL - Federated Learning'
ONE_SERVICE_VERSION='1.31.0'
ONE_SERVICE_BUILD=$(date +%s)
ONE_SERVICE_SHORT_DESCRIPTION='OneFlow service composing Flower SuperLink + SuperNode for federated learning'
ONE_SERVICE_DESCRIPTION=$(cat <<'EOF'
Flower Federated Learning OneFlow service. Deploys a SuperLink coordinator and
one or more SuperNode training clients that auto-discover the SuperLink via
OneGate over TLS. The appliance logic is provided by the flower_superlink and
flower_supernode images; this wrapper only carries the marketplace
SERVICE_TEMPLATE and VMTEMPLATE definitions.
EOF
)
ONE_SERVICE_RECONFIGURABLE=true

service_install()   { :; }
service_configure() { :; }
service_bootstrap() { :; }
service_cleanup()   { :; }
