// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;

import {EApps} from "./EApps.sol";
import {LighterLib} from "../libraries/LighterLib.sol";
import {TransientStorage} from "../libraries/TransientStorage.sol";
import {Applications} from "../types/Applications.sol";
import {AppTokenBalance} from "../types/ExternalApp.sol";
import {EAppsParams} from "../types/DeploymentParams.sol";

/// @title EAppsLighter - LighterEVM application view extension.
/// @notice EApps base plus the Lighter perps branch. Kept separate from the base contract so
///  other chains do not pay its bytecode size, and Lighter fixes do not force redeployments
///  (and version bumps) on unrelated chains.
/// @notice Owns the Lighter NAV valuation: ALighter handles Core writes, this extension reads
///  Core state through READ_CORE and values the pool's account over its tracked markets.
///  See docs/lighter/INTEGRATION.md.
contract EAppsLighter is EApps {
    /// @param params Chain-specific addresses bundled into a single struct.
    constructor(EAppsParams memory params) EApps(params) {}

    /// @dev Adds the Lighter branch; every other application is handled by the base. Pending
    ///  transfers never lock (the in-flight amount values them exactly); a settled transfer locks
    ///  NAV-dependent flows until the owner attests the EVM-side leg landed (syncTransfer) —
    ///  same exempt-flag mechanism as Hyperliquid, status-driven instead of time-driven.
    function _handleApplication(Applications appType) internal override returns (AppTokenBalance[] memory balances) {
        if (appType == Applications.LIGHTER_PERPS) {
            if (!TransientStorage.getNavLockExempt()) {
                LighterLib.assertNavUnlocked();
            }
            balances = LighterLib.getLighterBalances(address(this));
        } else {
            balances = super._handleApplication(appType);
        }
    }
}
