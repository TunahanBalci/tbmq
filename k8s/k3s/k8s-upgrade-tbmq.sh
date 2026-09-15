#!/bin/bash
#
# Copyright © 2016-2026 The Thingsboard Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/k8s-common.sh"

check_cluster

if kube get statefulset tbmq >/dev/null 2>&1 || [ -n "$(kube get pods -l app=tbmq -o name)" ]; then
  fail "TBMQ is still deployed. Run ./k8s-delete-tbmq.sh before upgrading the database."
fi

run_db_setup UPGRADE_TB

log "TBMQ upgrade finished. Run ./k8s-deploy-tbmq.sh to start the new TBMQ version."
