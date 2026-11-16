// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;

import {EApps} from "./EApps.sol";
import {LighterLib} from "../libraries/LighterLib.sol";
import {StorageLib} from "../libraries/StorageLib.sol";
import {TransientStorage} from "../libraries/TransientStorage.sol";
import {Applications, LighterSlot, LighterViewData} from "../types/Applications.sol";
import {AppTokenBalance} from "../types/ExternalApp.sol";
import {EAppsParams} from "../types/DeploymentParams.sol";
import {IEAppsLighter} from "./adapters/interfaces/IEAppsLighter.sol";

/// @title EAppsLighter - LighterEVM application view extension.
/// @notice EApps base plus the Lighter perps branch. Kept separate from the base contract so
///  other chains do not pay its bytecode size, and Lighter fixes do not force redeployments
///  (and version bumps) on unrelated chains.
/// @notice Owns the Lighter NAV valuation: ALighter handles Core writes, this extension reads
///  Core state through READ_CORE and values the pool's account over its tracked markets.
contract EAppsLighter is EApps, IEAppsLighter {
    /// @param params Chain-specific addresses bundled into a single struct.
    constructor(EAppsParams memory params) EApps(params) {}

    /// @inheritdoc IEAppsLighter
    function getLighterTrackedMarkets() external view override returns (LighterViewData memory viewData) {
        LighterSlot storage slot = StorageLib.lighterSlot();
        viewData.marketIds = slot.trackedMarkets;
        viewData.inFlightAmount = slot.data.inFlightAmount;
        viewData.lastReqId = slot.data.lastReqId;
        viewData.usdcSnapshotAtSettle = slot.data.usdcSnapshotAtSettle;
    }

    /// @dev Valuation runs before the lock so a landed leg clears the record and unlocks in the
    ///  same evaluation; a settled transfer with the leg still in transit reverts here.
    function _handleApplication(Applications appType) internal override returns (AppTokenBalance[] memory balances) {
        if (appType == Applications.LIGHTER_PERPS) {
            balances = LighterLib.getLighterBalances(address(this));
            if (!TransientStorage.getNavLockExempt()) {
                LighterLib.assertNavUnlocked();
            }
        } else {
            balances = super._handleApplication(appType);
        }
    }
}
