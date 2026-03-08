// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0 <0.9.0;

/// @title IA0xRouter - Interface for the 0x swap aggregator adapter.
/// @notice Allows Rigoblock smart pools to execute swaps via the 0x AllowanceHolder and Settler contracts.
/// @author Gabriele Rigo - <gab@rigoblock.com>
interface IA0xRouter {
    /// @notice Thrown when a call is made directly to the adapter instead of via delegatecall.
    error DirectCallNotAllowed();

    /// @notice Thrown when the swap recipient is not the smart pool.
    error RecipientNotSmartPool();

    /// @notice Thrown when the target is not a genuine 0x Settler instance.
    error CounterfeitSettler(address target);

    /// @notice Thrown when the Settler calldata has an unsupported function selector.
    error UnsupportedSettlerFunction();

    /// @notice Thrown when the Settler calldata is too short to decode.
    error InvalidSettlerCalldata();

    /// @notice Thrown when the pool does not hold enough native balance.
    error InsufficientNativeBalance();

    /// @notice Thrown when a settler action is not in the adapter's allowlist.
    /// @dev Only whitelisted DEX swap actions are permitted.
    /// @param actionSelector The 4-byte selector of the rejected action.
    error ActionNotAllowed(bytes4 actionSelector);

    /// @notice Thrown when operator is not the same address as target.
    /// @dev AllowanceHolder stores the ephemeral allowance under `operator`. If operator differs
    ///  from the genuine Settler (target), a malicious operator contract could consume the
    ///  ephemeral allowance and drain pool tokens to an arbitrary address.
    error OperatorMustEqualTarget();

    /// @notice Thrown when a TRANSFER_FROM action's recipient is not the Settler itself.
    /// @dev Allowing an arbitrary recipient would let the pool owner drain funds.
    /// @param recipient The decoded recipient address that failed the check.
    error TransferFromRecipientNotSettler(address recipient);

    /// @notice Execute a swap via the 0x AllowanceHolder contract.
    /// @dev The calldata is forwarded unmodified to AllowanceHolder after validation.
    /// @param operator The address authorized to consume the ephemeral allowance. Must equal `target`.
    /// @param token The sell token address.
    /// @param amount The sell token amount.
    /// @param target The 0x Settler contract address that will execute the swap.
    /// @param data The Settler.execute() calldata containing swap instructions.
    /// @return result The return data from AllowanceHolder.exec.
    function exec(
        address operator,
        address token,
        uint256 amount,
        address payable target,
        bytes calldata data
    ) external payable returns (bytes memory result);
}
