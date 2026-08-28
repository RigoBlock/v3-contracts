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

    /// @notice NAV-sensitive reads/writes are deferred for this long after a Hyperliquid deposit or
    ///  spot-send withdrawal, because HyperCore reader precompiles can lag behind EVM state.
    /// @dev 128 seconds covers at least two full big-block cadences (60s each) plus a small margin.
    uint48 internal constant _SETTLEMENT_WINDOW = 128 seconds;

    error NavLocked();

    /// @notice Returns the signed net Hyperliquid account value as a single USDC balance.
    /// @dev Aggregates core perp margin and spot USDC balance in HyperCore wei units first, then
    ///  converts the signed net amount to EVM decimals once. Reverts with `NavLocked()` during the
    ///  settlement window so that no NAV estimate can use a stale HyperCore snapshot. This function
    ///  is only invoked from the Hyperliquid application branch, so the caller has already
    ///  established that the Hyperliquid app is active.
    function getHyperliquidBalances(address account) internal view returns (AppTokenBalance[] memory balances) {
        _assertNavUnlocked();
        return getHyperliquidBalancesUnsafe(account);
    }

    /// @notice Unsafe variant of `getHyperliquidBalances` that does not check the settlement lock.
    /// @dev Used only by off-chain view extensions (`ENavView`) so the nav shield can read a
    ///  potentially stale NAV and enforce its own policy. On-chain NAV writes must use the locked
    ///  `getHyperliquidBalances`.
    function getHyperliquidBalancesUnsafe(address account) internal view returns (AppTokenBalance[] memory balances) {
        int256 totalRawWei = int256(
            PrecompileLib.accountMarginSummary(HLConstants.DEFAULT_PERP_DEX, account).accountValue
        ) + int256(uint256(PrecompileLib.spotBalance(account, HLConstants.USDC_TOKEN_INDEX).total));

        int256 totalUsdcValue = _weiToEvmSigned(HLConstants.USDC_TOKEN_INDEX, totalRawWei);

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

    /// @notice Records a Hyperliquid action and arms the settlement lock.
    /// @param amount Signed deposit/withdrawal amount (EVM USDC) when `isSpotSend` is false; unsigned
    ///  spot-send amount (Core wei) when `isSpotSend` is true.
    /// @param isSpotSend True for `SPOT_SEND` withdrawals, false for deposits and zero-stamp calls.
    /// @return pendingBefore The cumulative spot-send amount already recorded in the same composite
    ///  block (only meaningful when `isSpotSend` is true).
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

    function _weiToEvmSigned(uint64 token, int256 amountWei) private view returns (int256) {
        if (amountWei == 0) return 0;

        bool isNegative = amountWei < 0;
        uint256 absWei = isNegative ? uint256(-amountWei) : uint256(amountWei);
        int256 evmAmount = SafeCast.toInt256(HLConversions.weiToEvm(token, absWei.toUint64()));

        return isNegative ? -evmAmount : evmAmount;
    }

    function _hasRecentAction() private view returns (bool) {
        uint256 lastCompositeBlock = StorageLib.hyperliquidData().lastActionCompositeBlock;
        return lastCompositeBlock != 0 && lastCompositeBlock == _compositeBlockNumber();
    }

    /// @dev Returns a composite block number keyed to HyperCore's L1 block and the EVM block.
    function _compositeBlockNumber() private view returns (uint256 compositeBlockNumber) {
        compositeBlockNumber = (uint256(PrecompileLib.l1BlockNumber()) << 128) | uint128(block.number);
    }

    /// @notice Reverts if the Hyperliquid settlement window is still open.
    /// @dev This is a private helper used only by `getHyperliquidBalances`. The caller has already
    ///  routed here because the Hyperliquid application is active, so no bitmap check is needed.
    function _assertNavUnlocked() private view {
        uint48 unlockAt = StorageLib.hyperliquidData().lastActionTimestamp;
        if (unlockAt != 0) {
            require(block.timestamp >= unlockAt + _SETTLEMENT_WINDOW, NavLocked());
        }
    }
}
