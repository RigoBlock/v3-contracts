// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import {ILighterInteropManager} from "./lighter/ILighterInteropManager.sol";
import {ILighterCoreEntrypoint} from "./lighter/ILighterCoreEntrypoint.sol";

/// @title IALighter - Interface for the Rigoblock Lighter adapter.
/// @dev Selector-compatible with the Lighter predeploys (rule: adapter interfaces mirror the
///  target protocol). Security-enforced parameters keep their position but have blank names.
/// @dev NAV valuation lives in EAppsLighter (getLighterBalances), not in this adapter: the
///  adapter owns Core writes, the extension owns reads/valuation. See docs/lighter/INTEGRATION.md.
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
    /// @dev Reverts UnknownMarket when the market is not in the release-time decimals table of
    ///  LighterConstants, MarketAlreadyTracked when already tracked, and InvalidMarket when the
    ///  market exists on Core but is not a perpetual. The market's decimal scales are protocol
    ///  constants and can never be caller input.
    function trackMarket(uint16 marketId) external;

    /// @notice Removes a tracked market. Only allowed when the pool has no open position on it.
    function untrackMarket(uint16 marketId) external;
}
