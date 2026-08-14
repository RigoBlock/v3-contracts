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
/// @dev Uses hyper-evm-lib for precompile calls, chain constants, decimal conversions,
///  and CoreWriter abstractions. This library only contains logic that is specific to
///  the Rigoblock integration: storage access, in-flight tracking, and NAV aggregation.
/// @custom:security-contact security@rigoblock.com
library HyperliquidLib {
    using SafeCast for uint256;
    using SafeCast for int256;

    /// @dev HyperEVM chain id.
    uint256 internal constant HYPEREVM_CHAIN_ID = 999;

    /// @dev Number of blocks over which a recorded action is considered "recent".
    ///  A value of 0 means the in-flight adjustment is applied only in the same block as the action.
    uint256 private constant _ACTION_BLOCK_WINDOW = 0;

    /// @notice Returns the signed net Hyperliquid account value as a single USDC balance.
    /// @dev Aggregates core perp margin and spot USDC balance in HyperCore wei units first, then
    ///  converts the signed net amount to EVM decimals once. This avoids rounding inconsistencies
    ///  that can occur when converting negative perp and non-negative spot balances separately.
    ///  The net value is returned as-is; if it is exactly zero with no recent action, an empty
    ///  array is returned so the application can be purged. If it is exactly zero with a recent
    ///  action, a 1-wei dust balance is returned to keep the application alive during the
    ///  one-block HyperCore settlement gap.
    function getHyperliquidBalances(address account) internal view returns (AppTokenBalance[] memory balances) {
        // Sum perp and spot balances in HyperCore 8-decimal wei units before converting.
        int256 totalRawWei = int256(
            PrecompileLib.accountMarginSummary(HLConstants.DEFAULT_PERP_DEX, account).accountValue
        ) + int256(uint256(PrecompileLib.spotBalance(account, HLConstants.USDC_TOKEN_INDEX).total));

        int256 totalUsdcValue = _weiToEvmSigned(HLConstants.USDC_TOKEN_INDEX, totalRawWei);

        // Add the in-flight adjustment (already in EVM 6-decimal USDC) and apply the dust guard
        // only when the net is exactly zero.
        bool recentAction = hasRecentAction();
        if (recentAction) {
            totalUsdcValue += StorageLib.hyperliquidData().inFlightAmount;
            if (totalUsdcValue == 0) {
                totalUsdcValue = 1;
            }
        }

        if (totalUsdcValue == 0 && !recentAction) {
            return balances;
        }

        balances = new AppTokenBalance[](1);
        balances[0] = AppTokenBalance({token: HLConstants.usdc(), amount: totalUsdcValue});
    }

    /// @dev Converts a signed HyperCore wei amount to EVM decimals, preserving the sign.
    function _weiToEvmSigned(uint64 token, int256 amountWei) private view returns (int256) {
        if (amountWei == 0) return 0;

        bool isNegative = amountWei < 0;
        uint256 absWei = isNegative ? uint256(-amountWei) : uint256(amountWei);
        int256 evmAmount = SafeCast.toInt256(HLConversions.weiToEvm(token, absWei.toUint64()));

        return isNegative ? -evmAmount : evmAmount;
    }

    /// @notice Returns true if a Hyperliquid action was recorded within the last `_ACTION_BLOCK_WINDOW` blocks.
    function hasRecentAction() private view returns (bool) {
        uint256 lastBlock = StorageLib.hyperliquidData().lastActionBlock;
        return lastBlock != 0 && block.number <= lastBlock + _ACTION_BLOCK_WINDOW;
    }

    /// @notice Records the current block number and an in-flight amount for a Hyperliquid action.
    /// @dev Must be called by `AHyperliquid` on every state-affecting action. Positive `amount`
    ///  is added to NAV (deposits); negative `amount` is subtracted (withdrawals) during the
    ///  one-block HyperCore settlement gap. `amount` is cast to `int128`; in-flight USDC amounts
    ///  are always well below the `int128` range.
    function recordAction(int256 amount) internal {
        HyperliquidData storage data = StorageLib.hyperliquidData();
        if (data.lastActionBlock != block.number) {
            data.inFlightAmount = 0;
        }
        data.lastActionBlock = block.number.toUint128();
        data.inFlightAmount += amount.toInt128();
    }
}
