// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import {ILighterInteropManager} from "./lighter/ILighterInteropManager.sol";
import {ILighterCoreEntrypoint} from "./lighter/ILighterCoreEntrypoint.sol";
import {AppTokenBalance} from "../../../types/ExternalApp.sol";

/// @title IALighter - Interface for the Rigoblock Lighter adapter.
/// @dev Selector-compatible with the Lighter predeploys (rule: adapter interfaces mirror the
///  target protocol). Security-enforced parameters keep their position but have blank names.
interface IALighter is ILighterInteropManager, ILighterCoreEntrypoint {
    event Deposited(uint256 amount);
    event Withdrawn(uint256 amount);
    event OrderSent(uint64 indexed reqId);
    event MarketTracked(uint16 indexed marketId);
    event MarketUntracked(uint16 indexed marketId);

    error DirectCallNotAllowed();
    error NotLighterEVM();
    error InvalidAmount();
    error InvalidAsset();
    error InvalidRoute();
    error InvalidRecipient();
    error InvalidMarket();
    error MaxTrackedMarketsReached();
    error PositionNotClosed();
    error AccountNotActivated();

    /// @notice Tracks a perp market for NAV valuation. Callable only by the pool owner
    ///  (enforced by MixinFallback's delegatecall routing).
    /// @param sizeDecimals The market's size_decimals from LighterCore's orderBookDetails API.
    /// @param priceDecimals The market's price_decimals from LighterCore's orderBookDetails API.
    function trackMarket(uint16 marketId, uint8 sizeDecimals, uint8 priceDecimals) external;

    /// @notice Removes a tracked market. Only allowed when the pool has no open position on it.
    function untrackMarket(uint16 marketId) external;

    /// @notice Returns the given pool's Lighter balances valued in USDC (6 decimals).
    /// @param pool The pool whose LighterCore account is valued (also the EApps storage holder).
    /// @dev Executed under staticcall: the EApps/ENavView NAV branches call this selector on the
    ///  pool, whose fallback routes it here read-only (non-owner caller). The adapter cannot read
    ///  pool storage, so it pulls the tracked markets and in-flight accounting from
    ///  EApps.getLighterTrackedMarkets. This keeps LighterLib out of the size-constrained
    ///  extensions; see docs/lighter/INTEGRATION.md ("NAV routing").
    function getLighterBalances(address pool) external view returns (AppTokenBalance[] memory balances);
}
