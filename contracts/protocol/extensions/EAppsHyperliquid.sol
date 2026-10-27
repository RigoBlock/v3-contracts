// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;

import {EApps} from "./EApps.sol";
import {HyperliquidLib} from "../libraries/HyperliquidLib.sol";
import {TransientStorage} from "../libraries/TransientStorage.sol";
import {Applications} from "../types/Applications.sol";
import {AppTokenBalance} from "../types/ExternalApp.sol";
import {EAppsParams} from "../types/DeploymentParams.sol";

/// @title EAppsHyperliquid - HyperEVM application view extension.
/// @notice EApps base plus the Hyperliquid perps branch. Kept separate from the base contract so
///  other chains do not pay its bytecode size, and Hyperliquid fixes do not force redeployments
///  (and version bumps) on unrelated chains.
contract EAppsHyperliquid is EApps {
    /// @param params Chain-specific addresses bundled into a single struct.
    constructor(EAppsParams memory params) EApps(params) {}

    /// @dev Adds the Hyperliquid branch; every other application is handled by the base.
    ///  Hyperliquid-specific settlement lock: reverts with NavLocked while a Core deposit/spot-send
    ///  may still leave NAV reads stale. updateUnitaryValue (and crosschain donate, which routes
    ///  through it) is explicitly exempt via the transient flag; see docs/hyperliquid/INTEGRATION.md.
    function _handleApplication(Applications appType) internal override returns (AppTokenBalance[] memory balances) {
        if (appType == Applications.HYPERLIQUID) {
            if (!TransientStorage.getNavLockExempt()) {
                HyperliquidLib.assertNavUnlocked();
            }
            balances = HyperliquidLib.getHyperliquidBalances(address(this));
        } else {
            balances = super._handleApplication(appType);
        }
    }
}
