// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISpecterAirlock} from "../interfaces/ISpecterAirlock.sol";

interface IFlashBorrower {
    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external returns (bytes32);
}

/**
 * @title MockDeFiPool
 * @notice Production-grade simulated automated market maker and flash-lending vault deployed on Base Sepolia.
 * Emits low-latency telemetry (ThreatTriggerEvent) upon micro-deviations, liquidity shocks, or anomalous slippage.
 * Integrated with the SpecterAirlock circuit breaker to enforce instant state isolation.
 */
contract MockDeFiPool {
    bytes32 public constant FLASH_LOAN_CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");
    uint256 public constant BPS_DIVISOR = 10_000;
    uint256 public constant PRECISION = 1e18;

    address public owner;
    address public airlockReceiver;

    address public token0;
    address public token1;

    uint256 public reserve0;
    uint256 public reserve1;

    uint256 public nominalReserve0;
    uint256 public nominalReserve1;

    // Detection thresholds (in basis points: 500 = 5%)
    uint256 public threatThresholdBps;
    uint256 public slippageThresholdBps;

    // Flash loan fee (e.g., 9 bps = 0.09%)
    uint256 public flashLoanFeeBps;

    event ThreatTriggerEvent(
        address indexed pool,
        address indexed initiator,
        uint256 reserveDeltaBps,
        uint256 slippageVelocity,
        uint256 blockTimestamp
    );

    event LiquidityDeposited(address indexed provider, uint256 amount0, uint256 amount1);
    event LiquidityWithdrawn(address indexed provider, uint256 amount0, uint256 amount1);
    event SwapExecuted(
        address indexed sender,
        address indexed tokenIn,
        uint256 amountIn,
        uint256 amountOut,
        address indexed to
    );
    event FlashLoanExecuted(
        address indexed borrower,
        address indexed token,
        uint256 amount,
        uint256 fee
    );
    event NominalReservesCalibrated(uint256 nominal0, uint256 nominal1);
    event AirlockReceiverUpdated(address indexed oldReceiver, address indexed newReceiver);
    event ThreatThresholdsUpdated(uint256 newReserveDeltaBps, uint256 newSlippageThresholdBps);

    error PoolQuarantined(address pool, uint256 timestamp);
    error UnauthorizedCaller(address caller);
    error InsufficientLiquidity();
    error InsufficientOutputAmount();
    error InvalidToken();
    error FlashLoanFailed();
    error InvalidReserves();

    modifier onlyOwner() {
        if (msg.sender != owner) revert UnauthorizedCaller(msg.sender);
        _;
    }

    modifier whenNotQuarantined() {
        if (airlockReceiver != address(0)) {
            if (ISpecterAirlock(airlockReceiver).isQuarantined(address(this))) {
                revert PoolQuarantined(address(this), block.timestamp);
            }
        }
        _;
    }

    constructor(
        address _token0,
        address _token1,
        uint256 _initialReserve0,
        uint256 _initialReserve1,
        address _airlockReceiver
    ) {
        owner = msg.sender;
        token0 = _token0 == address(0) ? address(0x1111111111111111111111111111111111111111) : _token0;
        token1 = _token1 == address(0) ? address(0x2222222222222222222222222222222222222222) : _token1;

        reserve0 = _initialReserve0;
        reserve1 = _initialReserve1;
        nominalReserve0 = _initialReserve0;
        nominalReserve1 = _initialReserve1;

        airlockReceiver = _airlockReceiver;

        threatThresholdBps = 500;       // 5.0% deviation triggers warning/telemetry
        slippageThresholdBps = 800;     // 8.0% slippage spike triggers warning/telemetry
        flashLoanFeeBps = 9;            // 0.09% fee
    }

    receive() external payable {
        reserve0 += msg.value;
    }

    /**
     * @notice Deposit liquidity into the pool.
     */
    function deposit(uint256 amount0, uint256 amount1) external payable whenNotQuarantined {
        if (msg.value > 0) {
            amount0 = msg.value;
        }
        reserve0 += amount0;
        reserve1 += amount1;

        emit LiquidityDeposited(msg.sender, amount0, amount1);
    }

    /**
     * @notice Calibrates the baseline nominal reserves against which deviations are evaluated.
     */
    function calibrateNominalReserves(uint256 newNominal0, uint256 newNominal1) external onlyOwner {
        if (newNominal0 == 0 || newNominal1 == 0) revert InvalidReserves();
        nominalReserve0 = newNominal0;
        nominalReserve1 = newNominal1;
        emit NominalReservesCalibrated(newNominal0, newNominal1);
    }

    /**
     * @notice Internal helper to compute constant product swap output.
     */
    function _calculateAmountOut(
        uint256 amountIn,
        uint256 resIn,
        uint256 resOut
    ) internal pure returns (uint256) {
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * resOut;
        uint256 denominator = (resIn * 1000) + amountInWithFee;
        return numerator / denominator;
    }

    /**
     * @notice Internal helper to evaluate anomaly telemetry metrics without stack pressure.
     */
    function _evaluateMetrics(
        uint256 resIn,
        uint256 resOut,
        uint256 nominalIn,
        uint256 amountIn,
        uint256 amountOut
    ) internal pure returns (uint256 reserveDeltaBps, uint256 slippageVelocity) {
        uint256 idealSpotPrice = (resOut * PRECISION) / resIn;
        uint256 effectivePrice = (amountOut * PRECISION) / amountIn;

        uint256 newResIn = resIn + amountIn;
        uint256 deltaR = newResIn > nominalIn ? newResIn - nominalIn : nominalIn - newResIn;
        reserveDeltaBps = (deltaR * BPS_DIVISOR) / nominalIn;

        uint256 slippageBps = 0;
        if (idealSpotPrice > effectivePrice) {
            slippageBps = ((idealSpotPrice - effectivePrice) * BPS_DIVISOR) / idealSpotPrice;
        }
        slippageVelocity = slippageBps * 10;
    }

    /**
     * @notice Executes constant-product token swap with real-time anomaly telemetry emission.
     */
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 minAmountOut,
        address tokenIn,
        address to
    ) external whenNotQuarantined returns (uint256 amountOut) {
        if (amountIn == 0) revert InsufficientLiquidity();
        bool isZeroForOne = (tokenIn == token0);
        if (!isZeroForOne && tokenIn != token1) revert InvalidToken();

        uint256 resIn = isZeroForOne ? reserve0 : reserve1;
        uint256 resOut = isZeroForOne ? reserve1 : reserve0;
        uint256 nominalIn = isZeroForOne ? nominalReserve0 : nominalReserve1;

        if (resIn == 0 || resOut == 0) revert InsufficientLiquidity();

        amountOut = _calculateAmountOut(amountIn, resIn, resOut);
        if (amountOut < minAmountOut) revert InsufficientOutputAmount();
        if (amountOut >= resOut) revert InsufficientLiquidity();

        (uint256 reserveDeltaBps, uint256 slippageVelocity) = _evaluateMetrics(
            resIn,
            resOut,
            nominalIn,
            amountIn,
            amountOut
        );

        if (isZeroForOne) {
            reserve0 += amountIn;
            reserve1 -= amountOut;
        } else {
            reserve1 += amountIn;
            reserve0 -= amountOut;
        }

        if (reserveDeltaBps >= threatThresholdBps || slippageVelocity >= (slippageThresholdBps * 10)) {
            emit ThreatTriggerEvent(
                address(this),
                msg.sender,
                reserveDeltaBps,
                slippageVelocity,
                block.timestamp
            );
        }

        emit SwapExecuted(msg.sender, tokenIn, amountIn, amountOut, to);
    }

    /**
     * @notice Flash loan borrowing primitive allowing instant capital access.
     * Evaluates reserve displacement and emits ThreatTriggerEvent if significant drain occurs.
     */
    function flashBorrow(
        address token,
        uint256 amount,
        bytes calldata data
    ) external whenNotQuarantined returns (bool) {
        bool isToken0 = (token == token0);
        if (!isToken0 && token != token1) revert InvalidToken();

        uint256 currentReserve = isToken0 ? reserve0 : reserve1;
        uint256 nominalReserve = isToken0 ? nominalReserve0 : nominalReserve1;

        if (amount == 0 || amount > currentReserve) revert InsufficientLiquidity();

        uint256 fee = (amount * flashLoanFeeBps) / BPS_DIVISOR;

        // Measure drain delta
        uint256 drainDeltaBps = (amount * BPS_DIVISOR) / nominalReserve;

        if (drainDeltaBps >= threatThresholdBps) {
            emit ThreatTriggerEvent(
                address(this),
                msg.sender,
                drainDeltaBps,
                drainDeltaBps * 15,
                block.timestamp
            );
        }

        if (isToken0) {
            reserve0 -= amount;
        } else {
            reserve1 -= amount;
        }

        if (data.length > 0) {
            bytes32 callbackResult = IFlashBorrower(msg.sender).onFlashLoan(
                msg.sender,
                token,
                amount,
                fee,
                data
            );
            if (callbackResult != FLASH_LOAN_CALLBACK_SUCCESS) revert FlashLoanFailed();
        }

        if (isToken0) {
            reserve0 += amount + fee;
        } else {
            reserve1 += amount + fee;
        }

        emit FlashLoanExecuted(msg.sender, token, amount, fee);
        return true;
    }

    // --- Governance & Operational Controls ---

    function setAirlockReceiver(address _newReceiver) external onlyOwner {
        address old = airlockReceiver;
        airlockReceiver = _newReceiver;
        emit AirlockReceiverUpdated(old, _newReceiver);
    }

    function setThreatThresholds(uint256 _newReserveDeltaBps, uint256 _newSlippageThresholdBps) external onlyOwner {
        threatThresholdBps = _newReserveDeltaBps;
        slippageThresholdBps = _newSlippageThresholdBps;
        emit ThreatThresholdsUpdated(_newReserveDeltaBps, _newSlippageThresholdBps);
    }

    function getReserves() external view returns (uint256 _reserve0, uint256 _reserve1) {
        return (reserve0, reserve1);
    }

    function getNominalReserves() external view returns (uint256 _nominal0, uint256 _nominal1) {
        return (nominalReserve0, nominalReserve1);
    }
}
