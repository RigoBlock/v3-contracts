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

    /// @notice Returns the signed net Hyperliquid account value as a single USDC balance.
    /// @dev Aggregates core perp margin and spot USDC balance in HyperCore wei units first, then
    ///  converts the signed net amount to EVM decimals once.
    function getHyperliquidBalances(address account) internal view returns (AppTokenBalance[] memory balances) {
        int256 totalRawWei = int256(
            PrecompileLib.accountMarginSummary(HLConstants.DEFAULT_PERP_DEX, account).accountValue
        ) + int256(uint256(PrecompileLib.spotBalance(account, HLConstants.USDC_TOKEN_INDEX).total));

        int256 totalUsdcValue = _weiToEvmSigned(HLConstants.USDC_TOKEN_INDEX, totalRawWei);

        bool recentAction = hasRecentAction();
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

    function _weiToEvmSigned(uint64 token, int256 amountWei) private view returns (int256) {
        if (amountWei == 0) return 0;

        bool isNegative = amountWei < 0;
        uint256 absWei = isNegative ? uint256(-amountWei) : uint256(amountWei);
        int256 evmAmount = SafeCast.toInt256(HLConversions.weiToEvm(token, absWei.toUint64()));

        return isNegative ? -evmAmount : evmAmount;
    }

    function hasRecentAction() private view returns (bool) {
        uint256 lastCompositeBlock = StorageLib.hyperliquidData().lastActionCompositeBlock;
        return lastCompositeBlock != 0 && lastCompositeBlock == _compositeBlockNumber();
    }

    function ensureBlockFresh() private {
        HyperliquidData storage data = StorageLib.hyperliquidData();
        uint256 compositeBlock = _compositeBlockNumber();
        if (data.lastActionCompositeBlock != compositeBlock) {
            data.inFlightAmount = 0;
            data.pendingSpotSend = 0;
            data.lastActionCompositeBlock = compositeBlock;
        }
    }

    /// @dev Returns a composite block number keyed to HyperCore's L1 block and the EVM block.
    function _compositeBlockNumber() private view returns (uint256 compositeBlockNumber) {
        compositeBlockNumber = (uint256(PrecompileLib.l1BlockNumber()) << 128) | uint128(block.number);
    }

    function recordAction(int256 amount) internal {
        ensureBlockFresh();
        StorageLib.hyperliquidData().inFlightAmount += amount.toInt128();
    }

    function recordSpotSend(uint64 amount) internal returns (uint64 pendingSpotSend) {
        ensureBlockFresh();
        HyperliquidData storage data = StorageLib.hyperliquidData();
        pendingSpotSend = data.pendingSpotSend;
        data.pendingSpotSend = pendingSpotSend + amount;
    }
}
