// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IReactive, ISubscriptionService} from "../interfaces/IReactive.sol";
import {IPayer} from "../interfaces/IPayer.sol";
import {ISpecterAirlock} from "../interfaces/ISpecterAirlock.sol";

/**
 * @title SpecterReactiveCore
 * @notice Consensus & Ingestion Layer running on Reactive Omni (CometBFT, 1.0s blocks).
 * Subscribes to micro-deviation telemetry from Base Sepolia (Chain ID 84532), validates
 * threats against sliding thresholds, deduplicates events via a bounded hash ring,
 * and emits cross-chain callbacks to quarantine vulnerable pools with instant finality.
 */
contract SpecterReactiveCore is IReactive, IPayer {
    uint256 public constant BASE_SEPOLIA_CHAIN_ID = 84532;

    // keccak256("ThreatTriggerEvent(address,address,uint256,uint256,uint256)")
    uint256 public constant THREAT_TRIGGER_TOPIC_0 = 0x6e9f0d1109ff621e285fc524258957863bf10a37e58a7413a96677f48523a6c2;

    // Reactive subscription wildcard for unconstrained topics
    uint256 public constant REACTIVE_IGNORE = 0xa65f96fc951c3fa459f6b7047a46049b35bc81273e70f84148618781fa0478b2;

    // Bounded hash ring for duplicate suppression
    uint256 public constant HASH_RING_CAPACITY = 64;
    bytes32[HASH_RING_CAPACITY] public eventHashRing;
    uint256 public ringPointer;

    address public owner;
    address public subscriptionService;
    address public monitoredPool;
    address public targetAirlockReceiver;

    uint64 public callbackGasLimit;
    uint256 public defaultQuarantineDuration;
    uint256 public minThreatScoreThreshold; // 8800 = 88.00%
    uint256 public duplicateSuppressionWindow; // in seconds

    // Rate-limiting and duplicate tracking
    mapping(bytes32 => uint256) public recentIncidentTimestamps;
    mapping(address => uint256) public poolLastQuarantined;

    // IPayer state tracking
    uint256 private _payerBalance;
    mapping(address => uint256) private _debts;

    event SubscribedToPool(address indexed pool, uint256 chainId);
    event ThreatValidated(bytes32 indexed incidentHash, address indexed pool, uint256 riskScore);
    event ThreatSuppressed(bytes32 indexed incidentHash, string reason);
    event ConfigurationUpdated(address monitoredPool, address targetAirlockReceiver);

    error UnauthorizedCaller(address caller);
    error InvalidConfiguration();
    error InsufficientPayerBalance(uint256 requested, uint256 available);
    error SubscriptionFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert UnauthorizedCaller(msg.sender);
        _;
    }

    constructor(
        address _subscriptionService,
        address _monitoredPool,
        address _targetAirlockReceiver
    ) payable {
        owner = msg.sender;
        subscriptionService = _subscriptionService;
        monitoredPool = _monitoredPool;
        targetAirlockReceiver = _targetAirlockReceiver;

        callbackGasLimit = 350_000;
        defaultQuarantineDuration = 3600; // 1 hour quarantine window
        minThreatScoreThreshold = 8800;   // 88.00% anomaly threshold
        duplicateSuppressionWindow = 60;  // 60-second duplicate suppression window

        if (msg.value > 0) {
            _payerBalance += msg.value;
            emit FundsDeposited(msg.sender, msg.value);
        }

        // Initialize subscription if service address is active
        if (_subscriptionService != address(0) && _monitoredPool != address(0)) {
            ISubscriptionService(_subscriptionService).subscribe(
                BASE_SEPOLIA_CHAIN_ID,
                _monitoredPool,
                THREAT_TRIGGER_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
            emit SubscribedToPool(_monitoredPool, BASE_SEPOLIA_CHAIN_ID);
        }
    }

    receive() external payable {
        _payerBalance += msg.value;
        emit FundsDeposited(msg.sender, msg.value);
    }

    /**
     * @notice Reactive Network execution callback hook.
     * Invoked deterministically by CometBFT consensus engine upon matching subscribed logs.
     */
    function react(
        uint256 chain_id,
        address _contract,
        uint256 topic_0,
        uint256 topic_1,
        uint256 topic_2,
        uint256 /* topic_3 */,
        bytes calldata data,
        uint256 /* block_number */,
        uint256 /* op_code */
    ) external override {
        // Enforce origin network and topic validation
        if (chain_id != BASE_SEPOLIA_CHAIN_ID) return;
        if (_contract != monitoredPool) return;
        if (topic_0 != THREAT_TRIGGER_TOPIC_0) return;

        // Unpack indexed parameters
        address pool = address(uint160(topic_1));
        address initiator = address(uint160(topic_2));

        // Low-level ABI unpacking of data payload
        (uint256 reserveDeltaBps, uint256 slippageVelocity, uint256 blockTimestamp) = abi.decode(
            data,
            (uint256, uint256, uint256)
        );

        // Compute unique incident fingerprint
        bytes32 incidentHash = keccak256(
            abi.encodePacked(
                pool,
                initiator,
                reserveDeltaBps,
                slippageVelocity,
                blockTimestamp
            )
        );

        // Internal Hash Ring rate-limiting and duplicate suppression
        if (_isDuplicateOrSuppressed(incidentHash, pool)) {
            emit ThreatSuppressed(incidentHash, "DUPLICATE_OR_RATE_LIMITED");
            return;
        }

        // Record incident in hash ring
        _recordIncident(incidentHash, pool);

        // Compute composite threat score: (alpha * deltaR) + (beta * slippage) + base baseline
        // Scaled to basis points (0 to 10,000)
        uint256 riskScore = _computeCompositeThreatScore(reserveDeltaBps, slippageVelocity);

        // Filter false alarms below detection threshold
        if (riskScore < minThreatScoreThreshold) {
            emit ThreatSuppressed(incidentHash, "BELOW_THREAT_THRESHOLD");
            return;
        }

        emit ThreatValidated(incidentHash, pool, riskScore);

        // Dispatch cross-chain callback to quarantine pool on Base Sepolia
        bytes memory payload = abi.encodeWithSelector(
            ISpecterAirlock.quarantinePool.selector,
            pool,
            defaultQuarantineDuration,
            abi.encode(incidentHash, riskScore, blockTimestamp)
        );

        emit Callback(
            BASE_SEPOLIA_CHAIN_ID,
            targetAirlockReceiver,
            callbackGasLimit,
            payload
        );
    }

    // --- Threat Assessment & Hash Ring Primitives ---

    function _computeCompositeThreatScore(uint256 reserveDeltaBps, uint256 slippageVelocity)
        internal
        pure
        returns (uint256)
    {
        // Weight vectors: alpha = 0.45, beta = 0.35, gamma = 0.20
        // Scaled components (inputs are in BPS)
        uint256 componentReserve = (reserveDeltaBps * 45) / 100;
        uint256 componentSlippage = (slippageVelocity * 35) / 1000;
        uint256 componentMempoolUrgency = 2000; // Baseline priority weight (20%)

        uint256 total = componentReserve + componentSlippage + componentMempoolUrgency;
        if (total > 10_000) total = 10_000;
        return total;
    }

    function _isDuplicateOrSuppressed(bytes32 incidentHash, address pool) internal view returns (bool) {
        // Suppression check 1: Exact incident hash cooldown
        if (recentIncidentTimestamps[incidentHash] != 0) {
            if (block.timestamp < recentIncidentTimestamps[incidentHash] + duplicateSuppressionWindow) {
                return true;
            }
        }

        // Suppression check 2: Pool quarantine rate limit (prevent spamming airlock receiver)
        if (poolLastQuarantined[pool] != 0) {
            if (block.timestamp < poolLastQuarantined[pool] + 30) {
                return true;
            }
        }

        return false;
    }

    function _recordIncident(bytes32 incidentHash, address pool) internal {
        // Overwrite oldest slot in bounded hash ring
        bytes32 oldHash = eventHashRing[ringPointer];
        if (oldHash != bytes32(0)) {
            delete recentIncidentTimestamps[oldHash];
        }

        eventHashRing[ringPointer] = incidentHash;
        ringPointer = (ringPointer + 1) % HASH_RING_CAPACITY;

        recentIncidentTimestamps[incidentHash] = block.timestamp;
        poolLastQuarantined[pool] = block.timestamp;
    }

    // --- IPayer Debt & Balance Settlement Implementation ---

    function pay(uint256 amount) external override {
        if (_payerBalance < amount) revert InsufficientPayerBalance(amount, _payerBalance);
        _payerBalance -= amount;
        emit DebtCovered(msg.sender, amount);
    }

    function coverDebt() external override {
        uint256 debt = _debts[address(this)];
        if (debt > 0) {
            if (_payerBalance < debt) revert InsufficientPayerBalance(debt, _payerBalance);
            _payerBalance -= debt;
            _debts[address(this)] = 0;
            emit DebtCovered(address(this), debt);
        }
    }

    function getDebt(address account) external view override returns (uint256) {
        return _debts[account];
    }

    function deposit() external payable override {
        _payerBalance += msg.value;
        emit FundsDeposited(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external override onlyOwner {
        if (_payerBalance < amount) revert InsufficientPayerBalance(amount, _payerBalance);
        _payerBalance -= amount;
        payable(owner).transfer(amount);
        emit FundsWithdrawn(address(this), owner, amount);
    }

    function balance() external view override returns (uint256) {
        return _payerBalance;
    }

    // --- Configuration & Maintenance ---

    function updateTargets(address _monitoredPool, address _targetAirlockReceiver) external onlyOwner {
        monitoredPool = _monitoredPool;
        targetAirlockReceiver = _targetAirlockReceiver;

        if (subscriptionService != address(0) && _monitoredPool != address(0)) {
            ISubscriptionService(subscriptionService).subscribe(
                BASE_SEPOLIA_CHAIN_ID,
                _monitoredPool,
                THREAT_TRIGGER_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }

        emit ConfigurationUpdated(_monitoredPool, _targetAirlockReceiver);
    }

    function setOperationalParameters(
        uint64 _callbackGasLimit,
        uint256 _defaultQuarantineDuration,
        uint256 _minThreatScoreThreshold,
        uint256 _duplicateSuppressionWindow
    ) external onlyOwner {
        callbackGasLimit = _callbackGasLimit;
        defaultQuarantineDuration = _defaultQuarantineDuration;
        minThreatScoreThreshold = _minThreatScoreThreshold;
        duplicateSuppressionWindow = _duplicateSuppressionWindow;
    }
}
