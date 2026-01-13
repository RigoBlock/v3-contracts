// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {IEAcrossHandler} from "../../extensions/adapters/interfaces/IEAcrossHandler.sol";
import {IERC20} from "../../interfaces/IERC20.sol";
import {CrosschainLib} from "../../libraries/CrosschainLib.sol";
import {ReentrancyGuardTransient} from "../../libraries/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "../../libraries/SafeTransferLib.sol";
import {DestinationMessageParams, OpType} from "../../types/Crosschain.sol";

// TODO: check if should move TransferEscrow our of the extensions folder, as it's not an extension
/// @title TransferEscrow - Escrow contract for Transfer and Sync operation refunds
/// @notice Manages refunds from failed Transfer/Sync operations with NAV-neutral donations
/// @dev Combined escrow contract that handles both receive() and claimRefund() functionality
contract TransferEscrow is ReentrancyGuardTransient {
    using SafeTransferLib for address;

    /// @notice Emitted when tokens are donated back to the pool
    event TokensDonated(address indexed token, uint256 amount);

    /// @notice The pool this escrow is associated with
    address public immutable pool;

    error InvalidAmount();
    error InvalidPool();
    error UnsupportedToken();

    constructor(address _pool) {
        require(_pool.code.length > 0, InvalidPool()); // pool must be a smart contract
        pool = _pool;
    }

    /// @notice Receives native currency
    receive() external payable {}

    /// @notice Allows anyone to claim refund tokens and send them to the pool
    /// @dev Only allows Across-whitelisted tokens + native currency to prevent unauthorized token activation.
    ///      This protects against:
    ///      1. Expired native deposits refunded as WETH (auto-activates WETH if it has price feed)
    ///      2. Gas griefing by filling max token slots (128 tokens)
    ///      3. NAV calculation gas increases from too many active tokens
    /// @param token The token address to claim (address(0) for native)
    function refundVault(address token) external nonReentrant {
        // Only allow native currency or Across-whitelisted tokens
        // Native (address(0)) is always safe as it's the pool's base token or already active
        // WETH and stablecoins must be on Across whitelist to prevent unauthorized activation
        require(token == address(0) || CrosschainLib.isAllowedCrosschainToken(token), UnsupportedToken());

        uint256 balance;

        if (token == address(0)) {
            balance = address(this).balance;
        } else {
            balance = IERC20(token).balanceOf(address(this));
        }

        require(balance > 0, InvalidAmount());

        DestinationMessageParams memory params;
        params.opType = OpType.Transfer;

        // Store balance before transfer
        IEAcrossHandler(pool).donate(token, 1, params);

        // Transfer tokens to pool
        if (token == address(0)) {
            pool.safeTransferNative(balance);
        } else {
            token.safeTransfer(pool, balance);
        }

        // Process donation with actual balance
        IEAcrossHandler(pool).donate(token, balance, params);

        emit TokensDonated(token, balance);
    }
}
