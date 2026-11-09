"""
SpecterEngine Sentinel Configuration Module
Centralized, type-safe settings loaded from environment variables and defaults.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional
from dotenv import load_dotenv

# Automatically load .env if present
env_path = Path(__file__).resolve().parent.parent / ".env"
load_dotenv(dotenv_path=env_path)


@dataclass(frozen=True)
class NetworkConfig:
    name: str
    chain_id: int
    rpc_http: str
    rpc_ws: str
    block_cadence_ms: int


@dataclass(frozen=True)
class SpecterConfig:
    # Base Sepolia Network (OP Stack, ~200ms blocks)
    base_sepolia: NetworkConfig = field(
        default_factory=lambda: NetworkConfig(
            name="Base Sepolia",
            chain_id=int(os.getenv("BASE_SEPOLIA_CHAIN_ID", "84532")),
            rpc_http=os.getenv("BASE_SEPOLIA_RPC_HTTP", "https://sepolia.base.org"),
            rpc_ws=os.getenv("BASE_SEPOLIA_RPC_WS", "wss://base-sepolia-rpc.publicnode.com"),
            block_cadence_ms=200,
        )
    )

    # Reactive Omni Testnet (CometBFT, 1.0s blocks)
    reactive_omni: NetworkConfig = field(
        default_factory=lambda: NetworkConfig(
            name="Reactive Omni Kopli",
            chain_id=int(os.getenv("REACTIVE_CHAIN_ID", "5318008")),
            rpc_http=os.getenv("REACTIVE_RPC_HTTP", "https://kopli-rpc.reactive.network"),
            rpc_ws=os.getenv("REACTIVE_RPC_WS", "wss://kopli-rpc.reactive.network/websocket"),
            block_cadence_ms=1000,
        )
    )

    # Contract Deployments
    mock_defi_pool_address: str = field(
        default_factory=lambda: os.getenv(
            "MOCK_DEFI_POOL_ADDRESS", "0x0000000000000000000000000000000000000000"
        )
    )
    specter_airlock_receiver_address: str = field(
        default_factory=lambda: os.getenv(
            "SPECTER_AIRLOCK_RECEIVER_ADDRESS", "0x0000000000000000000000000000000000000000"
        )
    )
    specter_reactive_core_address: str = field(
        default_factory=lambda: os.getenv(
            "SPECTER_REACTIVE_CORE_ADDRESS", "0x0000000000000000000000000000000000000000"
        )
    )
    reactive_relayer_address: str = field(
        default_factory=lambda: os.getenv(
            "REACTIVE_RELAYER_ADDRESS", "0x0000000000000000000000000000000000000000"
        )
    )

    # Cryptographic Credentials
    sentinel_private_key: str = field(
        default_factory=lambda: os.getenv(
            "SENTINEL_PRIVATE_KEY",
            "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",  # Anvil key 0 default
        )
    )
    deployer_private_key: str = field(
        default_factory=lambda: os.getenv(
            "DEPLOYER_PRIVATE_KEY",
            "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
        )
    )

    # Algorithmic Scoring Parameters
    alpha_reserve: float = 0.45
    beta_slippage: float = 0.35
    gamma_priority_gas: float = 0.20
    threat_threshold: float = 0.88
    sliding_window_depth: int = 50
    quarantine_duration_sec: int = 3600  # 1 hour

    # EIP-712 Domain Metadata
    eip712_name: str = "SpecterEngineSentinel"
    eip712_version: str = "1.0.0"

    # ONNX Model Path
    onnx_model_path: Path = field(
        default_factory=lambda: Path(__file__).resolve().parent / "specter_anomaly_model.onnx"
    )


# Singleton instance
CONFIG = SpecterConfig()
