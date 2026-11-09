#!/usr/bin/env bash
# ==============================================================================
# SpecterEngine Base Sepolia Deployment Automation
# Target: Base Sepolia (OP Stack Rollup, Chain ID 84532, ~200ms block cadence)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$ROOT_DIR/.env"
OUTPUT_DIR="$ROOT_DIR/deployments"

mkdir -p "$OUTPUT_DIR"

# Source environment variables if .env exists
if [ -f "$ENV_FILE" ]; then
    echo "Loading environment variables from $ENV_FILE..."
    # shellcheck disable=SC1090
    source "$ENV_FILE"
fi

# Validation & Defaults
BASE_SEPOLIA_RPC="${BASE_SEPOLIA_RPC_HTTP:-https://sepolia.base.org}"
DEPLOYER_KEY="${DEPLOYER_PRIVATE_KEY:-}"
SENTINEL_SIGNER="${SENTINEL_SIGNER_ADDRESS:-}"
REACTIVE_RELAYER="${REACTIVE_RELAYER_ADDRESS:-0x0000000000000000000000000000000000000000}"

if [ -z "$DEPLOYER_KEY" ]; then
    echo "ERROR: DEPLOYER_PRIVATE_KEY is not defined in environment or .env."
    exit 1
fi

if [ -z "$SENTINEL_SIGNER" ]; then
    echo "ERROR: SENTINEL_SIGNER_ADDRESS is required to initialize Airlock Receiver."
    exit 1
fi

echo "================================================================================"
echo "          SPECTERENGINE: BASE SEPOLIA DEPLOYMENT PIPELINE                       "
echo "================================================================================"
echo "Target RPC           : $BASE_SEPOLIA_RPC"
echo "Target Chain ID      : 84532 (Base Sepolia)"
echo "Sentinel Signer      : $SENTINEL_SIGNER"
echo "Reactive Relayer     : $REACTIVE_RELAYER"
echo "================================================================================"

cd "$ROOT_DIR"

# 1. Compile Contracts
echo ""
echo "[Step 1/3] Compiling Solidity smart contracts with Foundry..."
forge build --sizes

# 2. Deploy SpecterAirlockReceiver.sol
echo ""
echo "[Step 2/3] Deploying SpecterAirlockReceiver to Base Sepolia..."
AIRLOCK_OUTPUT=$(forge create contracts/base/SpecterAirlockReceiver.sol:SpecterAirlockReceiver \
    --rpc-url "$BASE_SEPOLIA_RPC" \
    --private-key "$DEPLOYER_KEY" \
    --constructor-args "$REACTIVE_RELAYER" "$SENTINEL_SIGNER" \
    --json)

AIRLOCK_ADDRESS=$(echo "$AIRLOCK_OUTPUT" | grep -o '"deployedTo":"[^"]*' | cut -d'"' -f4)
AIRLOCK_TX_HASH=$(echo "$AIRLOCK_OUTPUT" | grep -o '"transactionHash":"[^"]*' | cut -d'"' -f4)

echo ">>> SpecterAirlockReceiver deployed at: $AIRLOCK_ADDRESS"
echo ">>> Deployment Tx: $AIRLOCK_TX_HASH"

# 3. Deploy MockDeFiPool.sol (Initial reserves: 100 ETH, 300,000 USDC)
echo ""
echo "[Step 3/3] Deploying MockDeFiPool connected to Airlock Receiver..."
TOKEN0="0x1111111111111111111111111111111111111111"
TOKEN1="0x2222222222222222222222222222222222222222"
INIT_RES0="100000000000000000000"       # 100 ETH (18 decimals)
INIT_RES1="300000000000000000000000"   # 300,000 USDC (18 decimals)

POOL_OUTPUT=$(forge create contracts/base/MockDeFiPool.sol:MockDeFiPool \
    --rpc-url "$BASE_SEPOLIA_RPC" \
    --private-key "$DEPLOYER_KEY" \
    --constructor-args "$TOKEN0" "$TOKEN1" "$INIT_RES0" "$INIT_RES1" "$AIRLOCK_ADDRESS" \
    --json)

POOL_ADDRESS=$(echo "$POOL_OUTPUT" | grep -o '"deployedTo":"[^"]*' | cut -d'"' -f4)
POOL_TX_HASH=$(echo "$POOL_OUTPUT" | grep -o '"transactionHash":"[^"]*' | cut -d'"' -f4)

echo ">>> MockDeFiPool deployed at: $POOL_ADDRESS"
echo ">>> Deployment Tx: $POOL_TX_HASH"

# Export Deployments to JSON
DEPLOYMENT_RECORD="$OUTPUT_DIR/base_sepolia.json"
cat <<EOF > "$DEPLOYMENT_RECORD"
{
  "network": "Base Sepolia",
  "chainId": 84532,
  "deployedAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "contracts": {
    "SpecterAirlockReceiver": {
      "address": "$AIRLOCK_ADDRESS",
      "transactionHash": "$AIRLOCK_TX_HASH",
      "sentinelSigner": "$SENTINEL_SIGNER",
      "reactiveRelayer": "$REACTIVE_RELAYER"
    },
    "MockDeFiPool": {
      "address": "$POOL_ADDRESS",
      "transactionHash": "$POOL_TX_HASH",
      "airlockReceiver": "$AIRLOCK_ADDRESS",
      "initialReserve0": "$INIT_RES0",
      "initialReserve1": "$INIT_RES1"
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
echo "SPECTER_AIRLOCK_RECEIVER_ADDRESS=$AIRLOCK_ADDRESS"
echo "MOCK_DEFI_POOL_ADDRESS=$POOL_ADDRESS"
echo "================================================================================"
