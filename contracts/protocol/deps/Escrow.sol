// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {IECrosschain} from "../extensions/adapters/interfaces/IECrosschain.sol";
import {IERC20} from "../interfaces/IERC20.sol";
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
    /// @dev Token validation is delegated to ECrosschain.donate() which checks:
    ///      1. Token is in the cross-chain whitelist (prevents unauthorized activation)
    ///      2. Token is not native ETH (address(0))
    ///      This approach ensures:
    ///      - Single source of truth for token validation (ECrosschain, which is upgradeable)
    ///      - No risk of tokens getting stuck if whitelist changes
    ///      - Escrow remains simple and forward-compatible
    /// @param token The token address to claim
    function refundVault(address token) external nonReentrant {
        // Validate token is not native ETH (ECrosschain.donate will reject it anyway,
        // but we fail early to save gas on the transfer attempt)
        require(token != address(0), UnsupportedToken());

        // Get token balance
        uint256 balance = IERC20(token).balanceOf(address(this));

        require(balance > 0, InvalidAmount());

        // isImpactingNav will make Sync behave like Transfer on EAcross
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: opType,
            shouldUnwrapNative: false
        });

        // Store balance before transfer
        IECrosschain(pool).donate(token, 1, params);

        // Transfer tokens to pool (only ERC20 supported)
        token.safeTransfer(pool, balance);

        // Process donation with actual balance
        IECrosschain(pool).donate(token, balance, params);

        emit TokensDonated(token, balance);
    }
}
