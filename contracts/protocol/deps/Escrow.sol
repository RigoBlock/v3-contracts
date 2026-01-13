// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {IEAcrossHandler} from "../extensions/adapters/interfaces/IEAcrossHandler.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {CrosschainLib} from "../libraries/CrosschainLib.sol";
import {ReentrancyGuardTransient} from "../libraries/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";
import {DestinationMessageParams, OpType} from "../types/Crosschain.sol";

/// @title Escrow - Generic escrow for cross-chain operation refunds (Transfer and Sync)
/// @notice Manages refunds from failed Transfer/Sync operations with NAV-neutral donations
/// @dev Deployed per pool per OpType via CREATE2 for deterministic addressing
contract Escrow is ReentrancyGuardTransient {
    using SafeTransferLib for address;

    /// @notice Emitted when tokens are donated back to the pool
    event TokensDonated(address indexed token, uint256 amount);

    /// @notice The pool this escrow is associated with
    address public immutable pool;

    /// @notice The operation type this escrow handles (Transfer or Sync)
    OpType public immutable opType;

    error InvalidAmount();
    error InvalidPool();
    error UnsupportedToken();

    constructor(address _pool, OpType _opType) {
        require(_pool.code.length > 0, InvalidPool()); // pool must be a smart contract
        pool = _pool;
        opType = _opType;
    }

    /// @notice Allows anyone to claim refund tokens and send them to the pool
    /// @dev Only allows Across-whitelisted tokens to prevent unauthorized token activation.
    ///      This protects against:
    ///      1. Gas griefing by filling max token slots (128 tokens)
    ///      2. NAV calculation gas increases from too many active tokens
    ///      3. Unauthorized token activation via donations
    ///      Note: Native ETH is not supported because EAcrossHandler.donate() rejects it.
    ///            Across refunds expired deposits in the original token (WETH/USDC/USDT), not native ETH.
    /// @param token The token address to claim
    function refundVault(address token) external nonReentrant {
        // Only allow Across-whitelisted tokens (EAcrossHandler will reject native ETH anyway)
        require(CrosschainLib.isAllowedCrosschainToken(token), UnsupportedToken());

        uint256 balance;

        if (token == address(0)) {
            balance = address(this).balance;
        } else {
            balance = IERC20(token).balanceOf(address(this));
        }

        require(balance > 0, InvalidAmount());

        DestinationMessageParams memory params;
        params.opType = opType; // Use escrow's configured OpType (Transfer or Sync)

        // Store balance before transfer
        IEAcrossHandler(pool).donate(token, 1, params);

        // Transfer tokens to pool (only ERC20 supported)
        token.safeTransfer(pool, balance);

        // Process donation with actual balance
        IEAcrossHandler(pool).donate(token, balance, params);

        emit TokensDonated(token, balance);
    }
}
