"""
SpecterEngine EIP-712 Cryptographic Signer & Attestation Module
Constructs, signs, and validates EIP-712 ThreatAttestation structures.
"""

from __future__ import annotations

from typing import Tuple, Dict, Any
from eth_account import Account
from eth_account.messages import encode_typed_data
from eth_abi import encode
from eth_utils import keccak, to_checksum_address

from config import CONFIG


THREAT_ATTESTATION_TYPE = [
    {"name": "pool", "type": "address"},
    {"name": "riskScore", "type": "uint256"},
    {"name": "nonce", "type": "uint256"},
    {"name": "deadline", "type": "uint256"},
]

EIP712_DOMAIN_TYPE = [
    {"name": "name", "type": "string"},
    {"name": "version", "type": "string"},
    {"name": "chainId", "type": "uint256"},
    {"name": "verifyingContract", "type": "address"},
]


def build_eip712_domain(
    verifying_contract: str | None = None,
    chain_id: int | None = None
) -> Dict[str, Any]:
    """
    Constructs standard EIP-712 domain structure.
    """
    contract_addr = verifying_contract or CONFIG.specter_airlock_receiver_address
    cid = chain_id or CONFIG.base_sepolia.chain_id

    return {
        "name": CONFIG.eip712_name,
        "version": CONFIG.eip712_version,
        "chainId": cid,
        "verifyingContract": to_checksum_address(contract_addr),
    }


def build_message_types() -> Dict[str, Any]:
    """
    Returns EIP-712 type definition schema.
    """
    return {
        "ThreatAttestation": THREAT_ATTESTATION_TYPE,
    }


def sign_attestation(
    pool_address: str,
    risk_score: int,
    nonce: int,
    deadline: int,
    private_key: str,
    verifying_contract: str | None = None,
    chain_id: int | None = None
) -> Tuple[int, str, str, bytes]:
    """
    Signs a ThreatAttestation EIP-712 structured data message.

    Returns:
        (v, r_hex, s_hex, signature_bytes)
    """
    domain = build_eip712_domain(verifying_contract, chain_id)
    message_types = build_message_types()

    message_data = {
        "pool": to_checksum_address(pool_address),
        "riskScore": int(risk_score),
        "nonce": int(nonce),
        "deadline": int(deadline),
    }

    signable_msg = encode_typed_data(
        domain_data=domain,
        message_types=message_types,
        message_data=message_data
    )

    account = Account.from_key(private_key)
    signed = account.sign_message(signable_msg)

    v = signed.v
    r_hex = hex(signed.r)
    s_hex = hex(signed.s)
    sig_bytes = bytes(signed.signature)

    return v, r_hex, s_hex, sig_bytes


def verify_attestation(
    pool_address: str,
    risk_score: int,
    nonce: int,
    deadline: int,
    signature_bytes: bytes,
    expected_signer: str,
    verifying_contract: str | None = None,
    chain_id: int | None = None
) -> bool:
    """
    Validates EIP-712 signature against expected signer address.
    """
    domain = build_eip712_domain(verifying_contract, chain_id)
    message_types = build_message_types()

    message_data = {
        "pool": to_checksum_address(pool_address),
        "riskScore": int(risk_score),
        "nonce": int(nonce),
        "deadline": int(deadline),
    }

    signable_msg = encode_typed_data(
        domain_data=domain,
        message_types=message_types,
        message_data=message_data
    )

    recovered = Account.recover_message(signable_msg, signature=signature_bytes)
    return recovered.lower() == expected_signer.lower()


def encode_calldata_proof(
    risk_score: int,
    nonce: int,
    deadline: int,
    signature_bytes: bytes
) -> bytes:
    """
    Encodes proof bytes for SpecterAirlockReceiver.quarantinePool(address,uint256,bytes calldata).
    ABI layout: (uint256 riskScore, uint256 nonce, uint256 deadline, bytes signature)
    """
    return encode(
        ["uint256", "uint256", "uint256", "bytes"],
        [int(risk_score), int(nonce), int(deadline), signature_bytes]
    )
