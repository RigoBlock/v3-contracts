// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import {ILighterInteropManager} from "./lighter/ILighterInteropManager.sol";
import {ILighterCoreEntrypoint} from "./lighter/ILighterCoreEntrypoint.sol";

/// @title IALighter - Interface for the Rigoblock Lighter adapter.
/// @dev Selector-compatible with the Lighter predeploys (rule: adapter interfaces mirror the
///  target protocol). Security-enforced parameters keep their position but have blank names.
/// @dev NAV valuation lives in EAppsLighter (internal LIGHTER_PERPS branch), not in this adapter:
///  the adapter owns Core writes, the extension owns reads/valuation. Markets are tracked
///  automatically on createOrder. Stale tracked entries are pruned by an operator-gated
///  evaluation: the operator calls pool.getAppTokenBalances(1 << uint256(Applications.LIGHTER_PERPS))
///  directly — NAV-evaluating transactions (updateUnitaryValue, mint/burn, purge) do not prune,
///  as they reach the extension via an external self-call and msg.sender is the pool itself.
///  See "Pruning tracked markets" in docs/lighter/INTEGRATION.md.
interface IALighter is ILighterInteropManager, ILighterCoreEntrypoint {
    event Deposited(uint256 amount);
    event Withdrawn(uint256 amount);
    event OrderSent(uint64 indexed reqId);

    error DirectCallNotAllowed();
    error NotLighterEVM();
    error InvalidAmount();
    error InvalidAsset();
    error InvalidRoute();
    error InvalidRecipient();
    error InvalidMarket();
    error AccountNotActivated();
}
