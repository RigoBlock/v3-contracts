// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {IECrosschain} from "../extensions/adapters/interfaces/IECrosschain.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {ReentrancyGuardTransient} from "../libraries/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";
import {DestinationMessageParams, OpType} from "../types/Crosschain.sol";

/// @title Escrow - Generic escrow for cross-chain operation refunds (Transfer and Sync)
/// @notice Manages refunds to pool via escrow, like across expired deposits.
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

    /// @dev The passed pool must be a Rigoblock pool, i.e. implement `donate` with unlock.
    constructor(address _pool, OpType _opType) {
        require(_pool.code.length > 0, InvalidPool()); // pool must be a smart contract
        pool = _pool;
        opType = _opType;
    }

    /// @notice Allows anyone to send owned to the target Rigoblock pool.
    /// @param token The token address to claim.
    function refundVault(address token) external nonReentrant {
        require(token != address(0), UnsupportedToken());
        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance > 0, InvalidAmount());

        DestinationMessageParams memory params = DestinationMessageParams({opType: opType, shouldUnwrapNative: false});

        // unlock and execute transfer flow
        IECrosschain(pool).donate(token, 1, params);
        token.safeTransfer(pool, balance);
        IECrosschain(pool).donate(token, balance, params);
        emit TokensDonated(token, balance);
    }
}
