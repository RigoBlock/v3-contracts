// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0 <0.9.0;

import {AppTokenBalance} from "../../../types/ExternalApp.sol";
import {IEApps} from "./IEApps.sol";

/// @title IEAppsLighter - LighterEVM application view extension interface.
/// @notice Extends IEApps with the Lighter perps NAV view, deployed as EAppsLighter on
///  LighterEVM (chain 19529). See docs/lighter/INTEGRATION.md.
interface IEAppsLighter is IEApps {
    /// @notice Returns the pool's Lighter balances valued in USDC (6 decimals).
    /// @dev Runs in pool context (delegatecall): reads the pool's Lighter slot and values the
    ///  Core account (shared collateral + tracked-market positions) from READ_CORE. Never
    ///  reverts on Core-side absence: a missing account or position contributes zero.
    function getLighterBalances() external view returns (AppTokenBalance[] memory balances);
}
