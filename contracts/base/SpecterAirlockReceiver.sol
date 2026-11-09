// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISpecterAirlock} from "../interfaces/ISpecterAirlock.sol";

/**
 * @title SpecterAirlockReceiver
 * @notice Dedicated emergency execution receiver and circuit breaker on Base Sepolia.
 * 
 * DESIGN CONSTRAINTS:
 * 1. TIMING PRIMITIVE: Uses block.timestamp exclusively for state resets, intervals, and cooldown logic.
 *    block.number is strictly avoided due to Base Sepolia's ~200ms block cadence.
 * 2. DUAL ACCESS CONTROL:
 *    a) Trusted Reactive Relayer address with payload validation.
 *    b) EIP-712 ECDSA signed threat attestation from off-chain Sentinel engine.
 * 3. STATE ISOLATION: Instant atomic quarantine of compromised pool contract.
 */
contract SpecterAirlockReceiver is ISpecterAirlock {
    bytes32 public constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    bytes32 public constant THREAT_ATTESTATION_TYPEHASH = keccak256(
        "ThreatAttestation(address pool,uint256 riskScore,uint256 nonce,uint256 deadline)"
    );

    bytes32 public constant NAME_HASH = keccak256(bytes("SpecterEngineSentinel"));
    bytes32 public constant VERSION_HASH = keccak256(bytes("1.0.0"));

    // Minimum risk score threshold (88.00% = 8800 bps)
    uint256 public constant MIN_RISK_SCORE = 8800;

    address public owner;
    address public reactiveRelayer;
    address public sentinelSigner;

    // Pool quarantine state
    mapping(address => QuarantineRecord) public quarantineRecords;

    // Anti-replay registries
    mapping(uint256 => bool) public usedNonces;
    mapping(bytes32 => bool) public executedIncidents;

    error UnauthorizedAccess(address caller);
    error InvalidSignature();
    error SignatureExpired(uint256 deadline, uint256 currentTimestamp);
    error NonceAlreadyUsed(uint256 nonce);
    error IncidentAlreadyProcessed(bytes32 incidentHash);
    error RiskScoreBelowThreshold(uint256 score, uint256 minScore);
    error InvalidAddress();
    error InvalidDuration();

    modifier onlyOwner() {
        if (msg.sender != owner) revert UnauthorizedAccess(msg.sender);
        _;
    }

    constructor(
        address _reactiveRelayer,
        address _sentinelSigner
    ) {
        owner = msg.sender;
        reactiveRelayer = _reactiveRelayer;
        sentinelSigner = _sentinelSigner;
    }

    /**
     * @notice Computes EIP-712 domain separator dynamically to handle cross-chain forks safely.
     */
    function domainSeparator() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                NAME_HASH,
                VERSION_HASH,
                block.chainid,
                address(this)
            )
        );
    }

    /**
     * @notice Atomic quarantine entrypoint.
     * Accessible via Vector A (Reactive Relayer) or Vector B (Dual-authorized Sentinel EIP-712 proof).
     * @param poolAddress Target pool contract address to quarantine.
     * @param quarantineDuration Cooldown duration in seconds (computed with block.timestamp).
     * @param proof Relayer packet or EIP-712 signature payload.
     */
    function quarantinePool(
        address poolAddress,
        uint256 quarantineDuration,
        bytes calldata proof
    ) external override {
        if (poolAddress == address(0)) revert InvalidAddress();
        if (quarantineDuration == 0) revert InvalidDuration();

        uint256 riskScore;
        bytes32 incidentHash;
        address triggerSource;

        if (msg.sender == reactiveRelayer) {
            // Vector A: Direct Reactive Relayer invocation
            triggerSource = reactiveRelayer;
            (incidentHash, riskScore) = _verifyReactivePayload(poolAddress, proof);
        } else {
            // Vector B: Dual-authorized ECDSA signed payload from off-chain Sentinel engine
            triggerSource = sentinelSigner;
            (incidentHash, riskScore) = _verifySentinelProof(poolAddress, proof);
        }

        // Apply atomic quarantine state
        uint256 expiresAt = block.timestamp + quarantineDuration;

        quarantineRecords[poolAddress] = QuarantineRecord({
            isQuarantined: true,
            quarantinedUntil: expiresAt,
            quarantinedAt: block.timestamp,
            triggerSource: triggerSource,
            riskScore: riskScore,
            incidentHash: incidentHash
        });

        emit AirlockEngaged(
            poolAddress,
            triggerSource,
            quarantineDuration,
            expiresAt,
            riskScore,
            incidentHash
        );
    }

    /**
     * @notice Lifts quarantine for a pool after security audit and review.
     */
    function liftQuarantine(address poolAddress) external override onlyOwner {
        if (poolAddress == address(0)) revert InvalidAddress();

        quarantineRecords[poolAddress].isQuarantined = false;
        quarantineRecords[poolAddress].quarantinedUntil = block.timestamp;

        emit AirlockDisengaged(poolAddress, msg.sender, block.timestamp);
    }

    /**
     * @notice Checks if a pool is actively quarantined.
     * Enforces strict block.timestamp expiration check.
     */
    function isQuarantined(address poolAddress) external view override returns (bool) {
        QuarantineRecord memory record = quarantineRecords[poolAddress];
        return (record.isQuarantined && block.timestamp < record.quarantinedUntil);
    }

    /**
     * @notice Returns comprehensive quarantine details for telemetry queries.
     */
    function getQuarantineDetails(address poolAddress)
        external
        view
        override
        returns (
            bool quarantined,
            uint256 untilTimestamp,
            address triggerSource,
            uint256 riskScore,
            bytes32 incidentHash
        )
    {
        QuarantineRecord memory record = quarantineRecords[poolAddress];
        bool active = record.isQuarantined && block.timestamp < record.quarantinedUntil;
        return (
            active,
            record.quarantinedUntil,
            record.triggerSource,
            record.riskScore,
            record.incidentHash
        );
    }

    // --- Internal Proof Verifiers ---

    function _verifyReactivePayload(address poolAddress, bytes calldata proof)
        internal
        returns (bytes32 incidentHash, uint256 riskScore)
    {
        uint256 originTimestamp;
        (incidentHash, riskScore, originTimestamp) = abi.decode(proof, (bytes32, uint256, uint256));

        if (executedIncidents[incidentHash]) revert IncidentAlreadyProcessed(incidentHash);
        executedIncidents[incidentHash] = true;

        if (riskScore < MIN_RISK_SCORE) revert RiskScoreBelowThreshold(riskScore, MIN_RISK_SCORE);

        return (incidentHash, riskScore);
    }

    function _verifySentinelProof(address poolAddress, bytes calldata proof)
        internal
        returns (bytes32 incidentHash, uint256 riskScore)
    {
        uint256 nonce;
        uint256 deadline;
        bytes memory signature;

        (riskScore, nonce, deadline, signature) = abi.decode(
            proof,
            (uint256, uint256, uint256, bytes)
        );

        if (block.timestamp > deadline) revert SignatureExpired(deadline, block.timestamp);
        if (usedNonces[nonce]) revert NonceAlreadyUsed(nonce);
        if (riskScore < MIN_RISK_SCORE) revert RiskScoreBelowThreshold(riskScore, MIN_RISK_SCORE);

        usedNonces[nonce] = true;

        // Compute EIP-712 struct hash
        bytes32 structHash = keccak256(
            abi.encode(
                THREAT_ATTESTATION_TYPEHASH,
                poolAddress,
                riskScore,
                nonce,
                deadline
            )
        );

        // Compute full EIP-712 digest
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", domainSeparator(), structHash)
        );

        address recovered = _recoverSigner(digest, signature);
        if (recovered != sentinelSigner || sentinelSigner == address(0)) revert InvalidSignature();

        incidentHash = structHash;
        executedIncidents[incidentHash] = true;

        return (incidentHash, riskScore);
    }

    /**
     * @notice High-assurance, zero-dependency ECDSA recovery with malleability mitigation.
     */
    function _recoverSigner(bytes32 digest, bytes memory signature) internal pure returns (address) {
        if (signature.length != 65) return address(0);

        bytes32 r;
        bytes32 s;
        uint8 v;

        assembly {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }

        // EIP-2 malleability check for s-value
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D5761797A63000E5604C0FF3BA5E54D) {
            return address(0);
        }

        if (v < 27) {
            v += 27;
        }

        if (v != 27 && v != 28) {
            return address(0);
        }

        return ecrecover(digest, v, r, s);
    }

    // --- Admin Configuration ---

    function setReactiveRelayer(address _newRelayer) external onlyOwner {
        if (_newRelayer == address(0)) revert InvalidAddress();
        address old = reactiveRelayer;
        reactiveRelayer = _newRelayer;
        emit ReactiveRelayerUpdated(old, _newRelayer);
    }

    function setSentinelSigner(address _newSigner) external onlyOwner {
        if (_newSigner == address(0)) revert InvalidAddress();
        address old = sentinelSigner;
        sentinelSigner = _newSigner;
        emit SentinelSignerUpdated(old, _newSigner);
    }
}
