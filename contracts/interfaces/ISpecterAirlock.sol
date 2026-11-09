// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ISpecterAirlock
 * @notice Interface for SpecterAirlockReceiver circuit breaker on Base Sepolia.
 */
interface ISpecterAirlock {
    enum AirlockState {
        Active,
        Quarantined,
        Cooldown
    }

    struct QuarantineRecord {
        bool isQuarantined;
        uint256 quarantinedUntil;
        uint256 quarantinedAt;
        address triggerSource;
        uint256 riskScore;
        bytes32 incidentHash;
    }

    event AirlockEngaged(
        address indexed pool,
        address indexed triggerSource,
        uint256 quarantineDuration,
        uint256 expiresAt,
        uint256 riskScore,
        bytes32 incidentHash
    );

    event AirlockDisengaged(
        address indexed pool,
        address indexed caller,
        uint256 timestamp
    );

    event SentinelSignerUpdated(address indexed oldSigner, address indexed newSigner);
    event ReactiveRelayerUpdated(address indexed oldRelayer, address indexed newRelayer);

    /**
     * @notice Quarantines a pool atomically based on verified cross-chain reactive callback or EIP-712 proof.
     * @param poolAddress Target pool contract address to quarantine.
     * @param quarantineDuration Duration in seconds the quarantine remains active.
     * @param proof Cryptographic proof or encoded reactive payload.
     */
    function quarantinePool(
        address poolAddress,
        uint256 quarantineDuration,
        bytes calldata proof
    ) external;

    /**
     * @notice Lifts quarantine after security post-mortem or cooldown expiration.
     * @param poolAddress The pool to restore to active state.
     */
    function liftQuarantine(address poolAddress) external;

    /**
     * @notice Checks whether a pool is actively quarantined.
     * @param poolAddress Pool address to query.
     * @return True if pool is quarantined and quarantine has not expired.
     */
    function isQuarantined(address poolAddress) external view returns (bool);

    /**
     * @notice Returns comprehensive quarantine state metadata for a pool.
     */
    function getQuarantineDetails(address poolAddress)
        external
        view
        returns (
            bool quarantined,
            uint256 untilTimestamp,
            address triggerSource,
            uint256 riskScore,
            bytes32 incidentHash
        );
}
