// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import {ICoreWriter} from "hyper-evm-lib/interfaces/ICoreWriter.sol";
import {ICoreDepositWallet} from "hyper-evm-lib/interfaces/ICoreDepositWallet.sol";

/// @title IAHyperliquid - Interface for the Rigoblock Hyperliquid adapter.
interface IAHyperliquid is ICoreWriter, ICoreDepositWallet {
    event ActionSent(uint24 indexed actionId);

    error DirectCallNotAllowed();
    error NotHyperEVM();
    error InvalidAmount();
    error InvalidDex();
    error InvalidActionData();
    error UnsupportedAction(uint24 actionId);
    error AccountNotActivated();
    error InsufficientBridgeReserve();
}
