// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import {ICoreWriter} from "hyper-evm-lib/interfaces/ICoreWriter.sol";
import {ICoreDepositWallet} from "hyper-evm-lib/interfaces/ICoreDepositWallet.sol";

/// @title IAHyperliquid - Interface for the Rigoblock Hyperliquid adapter.
/// @notice Exposes the canonical Hyperliquid CoreWriter and CoreDepositWallet interfaces.
/// @dev Runs via delegatecall in the pool context. Non-owner write access is blocked by MixinFallback.
interface IAHyperliquid is ICoreWriter, ICoreDepositWallet {
    // =========================================================================
    // Errors
    // =========================================================================

    error DirectCallNotAllowed();
    error NotHyperEVM();
    error InvalidAmount();
    error InvalidDex();
    error InvalidActionData();
    error UnsupportedAction(uint24 actionId);
    error AccountNotActivated();
    error InsufficientBridgeReserve();
}
