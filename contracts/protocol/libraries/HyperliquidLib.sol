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
    uint48 internal constant _SETTLEMENT_WINDOW = 128 seconds;

    error NavLocked();

    function getHyperliquidBalances(address account) internal view returns (AppTokenBalance[] memory balances) {
        _assertNavUnlocked();
        return getHyperliquidBalancesUnsafe(account);
    }

    /// @notice Unsafe variant of `getHyperliquidBalances` that does not check the settlement lock.
    /// @dev Designed to inspect nav offchain even during temporary potential hyperEvm state lags.
    function getHyperliquidBalancesUnsafe(address account) internal view returns (AppTokenBalance[] memory balances) {
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
        uint256 compositeBlock = _compositeBlockNumber();
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

    function _hasRecentAction() private view returns (bool) {
        uint256 lastCompositeBlock = StorageLib.hyperliquidData().lastActionCompositeBlock;
        return lastCompositeBlock != 0 && lastCompositeBlock == _compositeBlockNumber();
    }

    /// @dev Returns a composite block number keyed to HyperCore's L1 block and the EVM block.
    function _compositeBlockNumber() private view returns (uint256 compositeBlockNumber) {
        compositeBlockNumber = (uint256(PrecompileLib.l1BlockNumber()) << 128) | uint128(block.number);
    }

    function _assertNavUnlocked() private view {
        uint48 unlockAt = StorageLib.hyperliquidData().lastActionTimestamp;
        if (unlockAt != 0) {
            require(block.timestamp >= unlockAt + _SETTLEMENT_WINDOW, NavLocked());
        }
    }
}
