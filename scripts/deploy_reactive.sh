#!/usr/bin/env bash
# ==============================================================================
# SpecterEngine Reactive Omni Deployment Automation
# Target: Reactive Omni Kopli Testnet (CometBFT Consensus, Chain ID 5318008, 1.0s blocks)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$ROOT_DIR/.env"
OUTPUT_DIR="$ROOT_DIR/deployments"

mkdir -p "$OUTPUT_DIR"

if [ -f "$ENV_FILE" ]; then
    echo "Loading environment variables from $ENV_FILE..."
    # shellcheck disable=SC1090
    source "$ENV_FILE"
fi

REACTIVE_RPC="${REACTIVE_RPC_HTTP:-https://kopli-rpc.reactive.network}"
DEPLOYER_KEY="${DEPLOYER_PRIVATE_KEY:-}"
MONITORED_POOL="${MOCK_DEFI_POOL_ADDRESS:-}"
AIRLOCK_RECEIVER="${SPECTER_AIRLOCK_RECEIVER_ADDRESS:-}"
# Reactive Network official Subscription System contract address
SUBSCRIPTION_SERVICE="${REACTIVE_SUBSCRIPTION_SERVICE_ADDRESS:-0x0000000000000000000000000000000000FFFFFF}"

if [ -z "$DEPLOYER_KEY" ]; then
    echo "ERROR: DEPLOYER_PRIVATE_KEY is not defined in environment or .env."
    exit 1
fi

if [ -z "$MONITORED_POOL" ] || [ "$MONITORED_POOL" = "0x0000000000000000000000000000000000000000" ]; then
    echo "ERROR: MOCK_DEFI_POOL_ADDRESS must be set from the Base Sepolia deployment."
    exit 1
fi

if [ -z "$AIRLOCK_RECEIVER" ] || [ "$AIRLOCK_RECEIVER" = "0x0000000000000000000000000000000000000000" ]; then
    echo "ERROR: SPECTER_AIRLOCK_RECEIVER_ADDRESS must be set from the Base Sepolia deployment."
    exit 1
fi

echo "================================================================================"
echo "          SPECTERENGINE: REACTIVE OMNI DEPLOYMENT PIPELINE                      "
echo "================================================================================"
echo "Target RPC           : $REACTIVE_RPC"
echo "Target Chain ID      : 5318008 (Reactive Kopli Testnet)"
echo "Subscription Service : $SUBSCRIPTION_SERVICE"
echo "Monitored Base Pool  : $MONITORED_POOL (Chain ID: 84532)"
echo "Target Airlock Rx    : $AIRLOCK_RECEIVER (Chain ID: 84532)"
echo "Initial Gas Funding  : 0.1 REACT (for IPayer callback execution solvency)"
echo "================================================================================"

cd "$ROOT_DIR"

# 1. Compile Contracts
echo ""
echo "[Step 1/2] Compiling Reactive contracts with Foundry..."
forge build --sizes

# 2. Deploy SpecterReactiveCore.sol with initial REACT deposit
echo ""
echo "[Step 2/2] Deploying SpecterReactiveCore to Reactive Omni..."
REACTIVE_OUTPUT=$(forge create contracts/reactive/SpecterReactiveCore.sol:SpecterReactiveCore \
    --rpc-url "$REACTIVE_RPC" \
    --private-key "$DEPLOYER_KEY" \
    --value 0.1ether \
    --constructor-args "$SUBSCRIPTION_SERVICE" "$MONITORED_POOL" "$AIRLOCK_RECEIVER" \
    --json)

REACTIVE_ADDRESS=$(echo "$REACTIVE_OUTPUT" | grep -o '"deployedTo":"[^"]*' | cut -d'"' -f4)
REACTIVE_TX_HASH=$(echo "$REACTIVE_OUTPUT" | grep -o '"transactionHash":"[^"]*' | cut -d'"' -f4)

echo ">>> SpecterReactiveCore deployed at: $REACTIVE_ADDRESS"
echo ">>> Deployment Tx: $REACTIVE_TX_HASH"

# Export Deployments to JSON
DEPLOYMENT_RECORD="$OUTPUT_DIR/reactive_omni.json"
cat <<EOF > "$DEPLOYMENT_RECORD"
{
  "network": "Reactive Omni Kopli Testnet",
  "chainId": 5318008,
  "deployedAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "contracts": {
    "SpecterReactiveCore": {
      "address": "$REACTIVE_ADDRESS",
      "transactionHash": "$REACTIVE_TX_HASH",
      "monitoredPool": "$MONITORED_POOL",
      "originChainId": 84532,
      "targetAirlockReceiver": "$AIRLOCK_RECEIVER",
      "subscriptionService": "$SUBSCRIPTION_SERVICE",
      "prefundedBalance": "0.1 REACT"
    }
  }
}
EOF

echo ""
echo "================================================================================"
echo "DEPLOYMENT COMPLETE!"
echo "Deployment manifest written to: $DEPLOYMENT_RECORD"
echo ""
echo "Update your .env file with:"
echo "SPECTER_REACTIVE_CORE_ADDRESS=$REACTIVE_ADDRESS"
echo "================================================================================"
