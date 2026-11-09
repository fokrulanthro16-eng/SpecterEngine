// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

/**
 * @title IPayer
 * @notice Complete unabridged official interface for Reactive Network gas and debt settlement.
 * Contracts that trigger cross-chain callbacks must manage and settle gas debt on Reactive Omni.
 */
interface IPayer {
    /**
     * @notice Emitted when outstanding debt is settled.
     * @param payer The address paying down the debt.
     * @param amount The debt amount covered in native REACT.
     */
    event DebtCovered(address indexed payer, uint256 amount);

    /**
     * @notice Emitted when funds are deposited into the payer balance.
     * @param payer The depositor.
     * @param amount Amount of native REACT deposited.
     */
    event FundsDeposited(address indexed payer, uint256 amount);

    /**
     * @notice Emitted when funds are withdrawn from payer balance.
     * @param payer Payer withdrawing funds.
     * @param recipient Target address receiving funds.
     * @param amount Amount withdrawn.
     */
    event FundsWithdrawn(address indexed payer, address indexed recipient, uint256 amount);

    /**
     * @notice Pay specified amount to the network for execution services.
     * @param amount The amount to pay.
     */
    function pay(uint256 amount) external;

    /**
     * @notice Covers all accrued debt for the contract using available balance.
     */
    function coverDebt() external;

    /**
     * @notice Returns the outstanding debt accrued by an account.
     * @param account Target address.
     * @return Current debt in wei.
     */
    function getDebt(address account) external view returns (uint256);

    /**
     * @notice Deposit native tokens to maintain active execution solvency.
     */
    function deposit() external payable;

    /**
     * @notice Withdraw excess funds not encumbered by outstanding debt.
     * @param amount Amount to withdraw.
     */
    function withdraw(uint256 amount) external;

    /**
     * @notice Returns the contract's available balance in the payer ledger.
     * @return Available balance.
     */
    function balance() external view returns (uint256);
}
