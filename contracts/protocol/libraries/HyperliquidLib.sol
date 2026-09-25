// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.28;

import {SafeCast} from "@openzeppelin-legacy/contracts/utils/math/SafeCast.sol";
import {PrecompileLib} from "hyper-evm-lib/PrecompileLib.sol";
import {HLConstants} from "hyper-evm-lib/common/HLConstants.sol";
import {HLConversions} from "hyper-evm-lib/common/HLConversions.sol";
import {StorageLib} from "../libraries/StorageLib.sol";
import {AppTokenBalance} from "../types/ExternalApp.sol";
import {HyperliquidData} from "../types/Applications.sol";

/// @title HyperliquidLib
/// @notice Rigoblock-specific helpers for Hyperliquid NAV and storage.
/// @custom:security-contact security@rigoblock.com
library HyperliquidLib {
    using SafeCast for uint256;
    using SafeCast for int256;

    uint256 internal constant HYPEREVM_CHAIN_ID = 999;
    uint48 internal constant _SETTLEMENT_WINDOW = 16 seconds;

    error NavLocked();

    /// @notice Returns Hyperliquid balances, adding the in-flight amount only within the same EVM block
    ///  as the recorded action. HyperCore processes EVM->Core transfers and CoreWriter actions
    ///  immediately after each EVM block is built, so the precompiles reflect them from the next EVM
    ///  block on — keeping the in-flight amount any longer would double-count.
    /// @dev Does not enforce the settlement lock: enforcement lives in assertNavUnlocked, asserted from
    /// @dev the Hyperliquid branch of EApps. See docs/hyperliquid/INTEGRATION.md.
    function getHyperliquidBalances(address account) internal view returns (AppTokenBalance[] memory balances) {
        // Perp account value is already denominated in USDC with 6 decimals (margin + unrealised pnl + funding).
        int256 perpValue = int256(
            PrecompileLib.accountMarginSummary(HLConstants.DEFAULT_PERP_DEX, account).accountValue
        );

        // Core spot USDC balance is returned in 8-decimal wei; scale it to 6-decimal EVM USDC.
        uint64 spotTotalWei = PrecompileLib.spotBalance(account, HLConstants.USDC_TOKEN_INDEX).total;
        int256 spotValue = int256(HLConversions.weiToEvm(HLConstants.USDC_TOKEN_INDEX, spotTotalWei));

        int256 totalUsdcValue = perpValue + spotValue;

        bool recentAction = _hasRecentAction();
        if (recentAction) {
            totalUsdcValue += StorageLib.hyperliquidData().inFlightAmount;
        }

        if (totalUsdcValue == 0) {
            if (recentAction || PrecompileLib.coreUserExists(account)) {
                totalUsdcValue = 1;
            } else {
                return balances;
            }
        }

        balances = new AppTokenBalance[](1);
        balances[0] = AppTokenBalance({token: HLConstants.usdc(), amount: totalUsdcValue});
    }

    function recordAction(int256 amount, bool isSpotSend) internal returns (uint64 pendingBefore) {
        HyperliquidData storage data = StorageLib.hyperliquidData();
        uint256 compositeBlock = _composeBlockNumber();
        // In-flight and pending counters expire at the next EVM block: HyperCore processes EVM->Core
        // transfers and CoreWriter actions right after each EVM block is built (same L1 block), so
        // the precompile view can already include them in the next EVM block. Full-composite
        // comparison mirrors audited HyperEVM integrations; see docs/hyperliquid/INTEGRATION.md.
        if (data.lastActionCompositeBlock != compositeBlock) {
            data.inFlightAmount = 0;
            data.pendingSpotSend = 0;
            data.lastActionCompositeBlock = compositeBlock;
        }
        data.lastActionTimestamp = uint48(block.timestamp);

        if (isSpotSend) {
            pendingBefore = data.pendingSpotSend;
            data.pendingSpotSend = pendingBefore + SafeCast.toUint64(uint256(amount));
        } else {
            data.inFlightAmount += amount.toInt128();
        }
    }

    /// @dev The full composite (L1 block number in the high bits, EVM block number in the low bits)
    ///  must match: the Core view can change at every EVM block, not only at L1 block advances.
    function _hasRecentAction() private view returns (bool) {
        uint256 lastComposite = StorageLib.hyperliquidData().lastActionCompositeBlock;
        return lastComposite != 0 && lastComposite == _composeBlockNumber();
    }

    /// @dev Composite key identifying the current EVM block and HyperCore block together.
    function _composeBlockNumber() private view returns (uint256 compositeBlockNumber) {
        compositeBlockNumber = (_l1BlockNumber() << 128) | uint128(block.number);
    }

    function _l1BlockNumber() private view returns (uint256 l1Block) {
        l1Block = uint256(PrecompileLib.l1BlockNumber());
    }

    /// @notice Reverts while NAV reads may still be stale after a Core deposit/spot-send.
    /// @dev Within the same EVM block, reads are exact for both action types: a deposit's in-flight
    /// @dev amount compensates the not-yet-visible Core credit, and a spot-send has not executed yet
    /// @dev (its destination is always the pool's own address, so it is NAV-neutral at every stage).
    /// @dev From the next EVM block on, in-flight is dropped; the precompiles normally reflect the
    /// @dev action by then (transfers are processed right after each EVM block), but delayed actions
    /// @dev and sequencing edge cases are covered by the time lock on top.
    /// @dev Asserted from the Hyperliquid branch of EApps, which every NAV write reaches.
    function assertNavUnlocked() internal view {
        HyperliquidData memory data = StorageLib.hyperliquidData();
        if (data.lastActionCompositeBlock == 0) return;
        if (data.lastActionCompositeBlock == _composeBlockNumber()) return;
        require(block.timestamp >= data.lastActionTimestamp + _SETTLEMENT_WINDOW, NavLocked());
    }
}
