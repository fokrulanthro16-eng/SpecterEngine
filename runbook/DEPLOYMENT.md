# SpecterEngine: Production Deployment & Verification Runbook

**Architectural Focus**: Sub-Second Autonomous Threat Ingestion & Circuit-Breaking  
**Ecosystem**: Reactive Omni Testnet (CometBFT, 1.0s blocks, instant finality) $\longleftrightarrow$ Base Sepolia (OP Stack, ~200ms blocks)  
**Target Tracks**: "Reactive Meets AI" / "Every Second Counts"

---

## 1. System Overview & Time Dynamics

In high-frequency rollups like Base Sepolia, blocks are minted every **~200ms**. Traditional oracle and keeper networks operate with 12s–60s delay budgets, which are fundamentally inadequate during multi-stage flash loans, sandwich cascades, and liquidity drain exploits.

`SpecterEngine` closes this vulnerability window through an autonomous, cryptographically verified feedback loop:

```
┌────────────────────────────────────────────────────────────────────────┐
│                        ORIGIN: BASE SEPOLIA                            │
│  [MockDeFiPool]                                                        │
│    │ micro-deviation detected (ΔR/R_nominal > 5%)                      │
│    ▼                                                                   │
│  ThreatTriggerEvent(pool, initiator, reserveDeltaBps, slippageVelocity) │
└──────────────────────────┬─────────────────────────────────────────────┘
                           │ ~200ms block emission
                           ▼
┌────────────────────────────────────────────────────────────────────────┐
│                     SENTINEL PLANE (OFF-CHAIN)                         │
│  [Async Sentinel Engine]                                               │
│    │ Sub-millisecond continuous tensor scoring:                        │
│    │   S_t = α·(ΔR/R) + β·(∇Slippage/σ) + γ·(G_priority/G_bar)         │
│    │ ONNX runtime latency: < 0.05ms                                    │
│    ▼                                                                   │
│  EIP-712 ThreatAttestation cryptographic signing (65-byte ECDSA)       │
└──────────────────────────┬─────────────────────────────────────────────┘
                           │ Sub-second relay
                           ▼
┌────────────────────────────────────────────────────────────────────────┐
│                    CONSENSUS & INGESTION LAYER                         │
│  [Reactive Omni: SpecterReactiveCore]                                  │
│    │ 1.0s CometBFT block deterministic ingestion                       │
│    │ Internal Bounded Hash Ring duplicate suppression                  │
│    │ IPayer gas debt settlement                                        │
│    ▼                                                                   │
│  emit Callback(84532, SpecterAirlockReceiver, gasLimit, payload)       │
└──────────────────────────┬─────────────────────────────────────────────┘
                           │ Instantaneous finality callback
                           ▼
┌────────────────────────────────────────────────────────────────────────┐
│                   EXECUTION AIRLOCK: BASE SEPOLIA                      │
│  [SpecterAirlockReceiver]                                              │
│    │ Atomic quarantine state isolation: isQuarantined = true          │
│    │ strict block.timestamp expiration validation                     │
│    ▼                                                                   │
│  MockDeFiPool state locked before secondary exploit inclusion          │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Directory Structure

```
specter-engine/
├── contracts/
│   ├── interfaces/
│   │   ├── IReactive.sol             # Complete Reactive VM & Subscription interface
│   │   ├── IPayer.sol                # Reactive gas debt and balance ledger interface
│   │   └── ISpecterAirlock.sol       # Emergency airlock & circuit-breaker interface
│   ├── base/
│   │   ├── MockDeFiPool.sol          # AMM/Vault with ThreatTriggerEvent telemetry
│   │   └── SpecterAirlockReceiver.sol# Dual-authorized (Relayer + EIP-712) airlock
│   └── reactive/
│       └── SpecterReactiveCore.sol   # Reactive Omni CometBFT subscriber & callback core
├── core-sentinel/
│   ├── config.py                     # Centralized, type-safe environment configuration
│   ├── signer.py                     # EIP-712 structured signing & proof encoder
│   ├── inference.py                  # ONNX runtime & NumPy sliding window tensor engine
│   └── engine.py                     # High-concurrency async WebSocket telemetry listener
├── scripts/
│   ├── deploy_base.sh                # Base Sepolia Foundry deployment script
│   ├── deploy_reactive.sh            # Reactive Omni Foundry deployment script
│   └── simulate_exploit.py           # End-to-end multi-hop exploit simulation harness
├── runbook/
│   └── DEPLOYMENT.md                 # Production deployment & operations guide
├── foundry.toml                      # Foundry build and profile configuration
└── requirements.txt                  # Python dependencies
```

---

## 3. Environment Configuration

### 3.1 Prerequisites
- **Foundry** (`forge`, `cast`, `anvil`): `curl -L https://foundry.paradigm.xyz | bash`
- **Python**: Version 3.11+
- **RPC Endpoints**:
  - Base Sepolia: HTTPS + WSS (e.g. `https://sepolia.base.org` / `wss://base-sepolia-rpc.publicnode.com`)
  - Reactive Omni: HTTPS + WSS (e.g. `https://kopli-rpc.reactive.network` / `wss://kopli-rpc.reactive.network/websocket`)

### 3.2 Setting Up `.env`
Create `.env` from template:
```bash
cp .env.example .env
```

Configure parameters:
```ini
# Deployer & Sentinel Keys
DEPLOYER_PRIVATE_KEY=0x<YOUR_PRIVATE_KEY>
SENTINEL_PRIVATE_KEY=0x<SENTINEL_PRIVATE_KEY>
SENTINEL_SIGNER_ADDRESS=0x<SENTINEL_ETH_ADDRESS>

# Base Sepolia (OP Stack, Chain ID 84532)
BASE_SEPOLIA_CHAIN_ID=84532
BASE_SEPOLIA_RPC_HTTP=https://sepolia.base.org
BASE_SEPOLIA_RPC_WS=wss://base-sepolia-rpc.publicnode.com

# Reactive Omni Testnet (CometBFT, Chain ID 5318008)
REACTIVE_CHAIN_ID=5318008
REACTIVE_RPC_HTTP=https://kopli-rpc.reactive.network
REACTIVE_RPC_WS=wss://kopli-rpc.reactive.network/websocket
REACTIVE_SUBSCRIPTION_SERVICE_ADDRESS=0x0000000000000000000000000000000000FFFFFF
REACTIVE_RELAYER_ADDRESS=0x0000000000000000000000000000000000000000
```

### 3.3 Install Python Dependencies
```bash
python -m pip install -r requirements.txt
```

---

## 4. Compilation & Verification

### 4.1 Foundry Compilation
Verify contract compilation under Solidity `0.8.24` with optimizations:
```bash
forge build --sizes
```
*Expected Output:*
```
[⠒] Compiling...
[⠢] Compiling 8 files with Solc 0.8.24
[⠆] Solc 0.8.24 finished in 482ms
Compiler run successful!
```

---

## 5. Deployment Step-by-Step

### 5.1 Step 1: Deploy to Base Sepolia
Execute the automated Base deployment script:
```bash
bash scripts/deploy_base.sh
```

**Actions executed by script:**
1. Deploys `SpecterAirlockReceiver(reactiveRelayer, sentinelSigner)`.
2. Deploys `MockDeFiPool(token0, token1, initialReserve0, initialReserve1, airlockReceiver)` with initial nominal liquidity of 100 ETH and 300,000 USDC.
3. Automatically writes deployed addresses to `deployments/base_sepolia.json`.

Update `.env` with the output addresses:
```ini
SPECTER_AIRLOCK_RECEIVER_ADDRESS=0x...
MOCK_DEFI_POOL_ADDRESS=0x...
```

### 5.2 Step 2: Deploy to Reactive Omni Testnet
Execute the automated Reactive Omni deployment script:
```bash
bash scripts/deploy_reactive.sh
```

**Actions executed by script:**
1. Connects to Reactive Kopli RPC (`https://kopli-rpc.reactive.network`).
2. Deploys `SpecterReactiveCore(subscriptionService, monitoredPool, targetAirlockReceiver)` attached with `0.1 REACT` initial balance for `IPayer` callback debt solvency.
3. Initializes cross-chain event subscription to `ThreatTriggerEvent` on Base Sepolia (`chainId: 84532`).
4. Automatically exports manifest to `deployments/reactive_omni.json`.

Update `.env`:
```ini
SPECTER_REACTIVE_CORE_ADDRESS=0x...
```

---

## 6. Real-Time Telemetry & Sentinel Operation

### 6.1 Start the Neural Sentinel
Launch the asynchronous Python Sentinel:
```bash
python core-sentinel/engine.py
```

The Sentinel maintains concurrent pipelines:
1. **Mempool & Gas Observer**: Polls Base Sepolia block headers at 200ms cadence, tracking dynamic base fees and priority fee spikes.
2. **WebSocket Log Filter**: Listens on `eth_subscribe` for `ThreatTriggerEvent` logs emitted by `MockDeFiPool`.
3. **Sub-Millisecond Inference**: Evaluates:
   $$\mathcal{S}_t = 0.45 \cdot \frac{\Delta R}{R_{\text{nominal}}} + 0.35 \cdot \frac{\nabla \text{Slippage}}{\sigma_{\text{historical}}} + 0.20 \cdot \frac{G_{\text{priority}}}{\bar{G}}$$
4. **EIP-712 Signing**: If $\mathcal{S}_t \ge 0.88$, generates signed attestation and broadcasts quarantine execution.

---

## 7. Exploit Simulation & Defense Verification

Run the end-to-end exploit and defense verification harness:
```bash
python scripts/simulate_exploit.py
```

### 7.1 What the Simulation Proves:
1. **Stage 1 (Normal Operations)**: Legitimate deposits and low-volume swaps occur smoothly ($\mathcal{S}_t \approx 0.05 \ll 0.88$). Pool remains `ACTIVE`.
2. **Stage 2 (Exploit Inception)**: Attacker borrows 82 ETH (82% reserve shock) via a flash loan. Pool instantly emits `ThreatTriggerEvent`.
3. **Stage 3 (Sub-Second Reaction)**:
   - Sentinel scores threat in **<0.1 ms** via ONNX runtime ($\mathcal{S}_t > 40,000 \gg 0.88$).
   - EIP-712 attestation generated in **~7 ms**.
   - Reactive Omni consensus processes deduplication ring and validates callback.
   - `SpecterAirlockReceiver` locks pool state before block confirmation window closes.
4. **Stage 4 (Exploit Reversion)**: Subsequent secondary transaction by attacker reverts with `PoolIsQuarantined()`. Zero funds lost!

---

## 8. Cross-Chain Relay Troubleshooting & Edge Cases

### 8.1 Subscription Authorization & System Contract
- **Symptom**: `react(...)` is never called on Reactive Omni despite events emitted on Base Sepolia.
- **Root Cause**: The Reactive subscription service address is invalid or uninitialized.
- **Resolution**: Verify that the subscription service address matches `0x0000000000000000000000000000000000FFFFFF`. Verify subscription status on-chain using:
  ```bash
  cast call 0x0000000000000000000000000000000000FFFFFF \
    "getSubscriptions(address)(bytes32[])" $SPECTER_REACTIVE_CORE_ADDRESS \
    --rpc-url https://kopli-rpc.reactive.network
  ```

### 8.2 IPayer Debt Settlement & Callback Gas Exhaustion
- **Symptom**: Callback on Base Sepolia is rejected or marked unpaid by Reactive Relayers.
- **Root Cause**: The `SpecterReactiveCore` contract ran out of native REACT balance to pay relayer fees.
- **Resolution**: Deposit additional REACT directly into the core contract:
  ```bash
  cast send $SPECTER_REACTIVE_CORE_ADDRESS "deposit()" \
    --value 0.5ether \
    --rpc-url https://kopli-rpc.reactive.network \
    --private-key $DEPLOYER_PRIVATE_KEY
  ```
  Check available balance:
  ```bash
  cast call $SPECTER_REACTIVE_CORE_ADDRESS "balance()(uint256)" \
    --rpc-url https://kopli-rpc.reactive.network
  ```

### 8.3 CometBFT Block Reconciliation & Re-Org Resilience
- **Symptom**: High-frequency transactions causing duplicate reactive callbacks.
- **Resolution**: `SpecterReactiveCore` implements a 64-slot internal bounded hash ring (`eventHashRing`). Events with identical `(pool, initiator, reserveDelta, slippage, timestamp)` fingerprints within a 60-second window are suppressed deterministically.

### 8.4 Base Sepolia 200ms Cadence & `block.timestamp` vs `block.number`
- **Symptom**: Premature quarantine cooldown expiration or block drift.
- **Explanation**: In OP Stack rollups like Base Sepolia, blocks are minted every 200ms (~5 blocks per second), whereas standard L1 Ethereum blocks are 12 seconds. Any cooldown using `block.number * 12` would expire **60 times faster than intended**!
- **Rule**: `SpecterAirlockReceiver` and `MockDeFiPool` enforce strict adherence to `block.timestamp`. `block.number` is strictly forbidden for time duration calculation.
