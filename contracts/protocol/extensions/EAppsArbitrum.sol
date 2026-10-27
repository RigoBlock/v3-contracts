// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;

import {EApps} from "./EApps.sol";
import {GmxLib} from "../libraries/GmxLib.sol";
import {Applications} from "../types/Applications.sol";
import {AppTokenBalance} from "../types/ExternalApp.sol";
import {EAppsParams} from "../types/DeploymentParams.sol";

/// @title EAppsArbitrum - Arbitrum application view extension.
/// @notice EApps base plus the GMX v2 positions branch. Kept separate from the base contract so
///  chains without GMX do not pay its bytecode size, and GMX fixes do not force redeployments
///  (and version bumps) on unrelated chains.
contract EAppsArbitrum is EApps {
    /// @param params Chain-specific addresses bundled into a single struct.
    constructor(EAppsParams memory params) EApps(params) {}

    /// @dev Adds the GMX v2 positions branch; every other application is handled by the base.
    function _handleApplication(Applications appType) internal override returns (AppTokenBalance[] memory balances) {
        if (appType == Applications.GMX_V2_POSITIONS) {
            balances = GmxLib.getGmxPositionBalances(address(this));
        } else {
            balances = super._handleApplication(appType);
        }
    }
}
