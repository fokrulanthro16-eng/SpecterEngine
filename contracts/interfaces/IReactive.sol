// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

/**
 * @title IReactive
 * @notice Complete unabridged official interface for Reactive Network smart contracts.
 * Reactive contracts execute on Reactive Omni (CometBFT consensus) and handle real-time cross-chain events.
 */
interface IReactive {
    /**
     * @notice Emitted to request a cross-chain execution callback on a destination chain.
     * @param chain_id The destination EVM chain ID (e.g., 84532 for Base Sepolia).
     * @param _contract The destination contract address.
     * @param gas_limit The execution gas limit on the destination chain.
     * @param payload The ABI-encoded calldata for the destination execution.
     */
    event Callback(
        uint256 indexed chain_id,
        address indexed _contract,
        uint64 indexed gas_limit,
        bytes payload
    );

    /**
     * @notice Reactive event entrypoint invoked deterministically by the Reactive VM when a subscribed event matches.
     * @param chain_id Origin chain ID where the event occurred.
     * @param _contract Address of the contract emitting the log.
     * @param topic_0 Primary topic (event signature keccak256 hash).
     * @param topic_1 First indexed parameter (if present, zero otherwise).
     * @param topic_2 Second indexed parameter (if present, zero otherwise).
     * @param topic_3 Third indexed parameter (if present, zero otherwise).
     * @param data Non-indexed ABI-encoded log data.
     * @param block_number Block height on origin chain.
     * @param op_code Reactive execution opcode flags.
     */
    function react(
        uint256 chain_id,
        address _contract,
        uint256 topic_0,
        uint256 topic_1,
        uint256 topic_2,
        uint256 topic_3,
        bytes calldata data,
        uint256 block_number,
        uint256 op_code
    ) external;
}

/**
 * @title ISubscriptionService
 * @notice Reactive Network system contract interface for dynamic cross-chain event subscriptions.
 */
interface ISubscriptionService {
    function subscribe(
        uint256 chain_id,
        address _contract,
        uint256 topic_0,
        uint256 topic_1,
        uint256 topic_2,
        uint256 topic_3
    ) external;

    function unsubscribe(
        uint256 chain_id,
        address _contract,
        uint256 topic_0,
        uint256 topic_1,
        uint256 topic_2,
        uint256 topic_3
    ) external;
}
