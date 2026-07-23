#!/bin/bash
# e2e: run the composite action via act (docker) against the mock API/OIDC on the host.
set -e
cd "$(dirname "$0")/.."

node test/mock-api.js &
MOCK=$!
trap 'kill $MOCK 2>/dev/null' EXIT
sleep 0.5

act push -W test/workflow.yml --network bridge --container-options "--add-host=host.docker.internal:host-gateway" \
  --env ACTIONS_ID_TOKEN_REQUEST_URL='http://host.docker.internal:8787/oidc?api-version=2' \
  --env ACTIONS_ID_TOKEN_REQUEST_TOKEN='req-token'

echo "e2e pass"
