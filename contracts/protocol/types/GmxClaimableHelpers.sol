// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.28;

import {IGmxDataStore} from "../../utils/exchanges/gmx/IGmxSynthetics.sol";
import {GmxCallbackLib} from "../libraries/GmxCallbackLib.sol";
import {GmxConstants} from "./GmxConstants.sol";

/// @title GmxClaimableHelpers
/// @notice Shared view helpers for reading GMX claimable funding and collateral
///  amounts from the DataStore. Used by both NAV (`GmxLib`) and the adapter
///  (`GmxAdapterLib`) without pulling adapter code into NAV extensions.
library GmxClaimableHelpers {
    /// @notice Returns the claimable funding amount for `(market, token, account)`.
    function getClaimableFundingAmount(address market, address token, address account) internal view returns (uint256) {
        return
            IGmxDataStore(GmxConstants._GMX_DATA_STORE).getUint(
                keccak256(abi.encode(GmxCallbackLib.CLAIMABLE_FUNDING_AMOUNT_KEY, market, token, account))
            );
    }

    /// @notice Returns the claimable collateral amount for a recorded collateral key.
    function getClaimableCollateralAmount(
        bytes32 amountKey,
        GmxCallbackLib.ClaimableCollateralInfo memory info,
        address account
    ) internal view returns (uint256 claimableAmount_) {
        IGmxDataStore ds = IGmxDataStore(GmxConstants._GMX_DATA_STORE);
        uint256 amount = ds.getUint(amountKey);
        if (amount == 0) return 0;

        bytes32 factorTimeKey = keccak256(
            abi.encode(GmxCallbackLib.CLAIMABLE_COLLATERAL_FACTOR_KEY, info.market, info.token, info.timeKey)
        );
        bytes32 factorKey = keccak256(
            abi.encode(GmxCallbackLib.CLAIMABLE_COLLATERAL_FACTOR_KEY, info.market, info.token, info.timeKey, account)
        );
        bytes32 reductionKey = keccak256(
            abi.encode(
                GmxCallbackLib.CLAIMABLE_COLLATERAL_REDUCTION_FACTOR_KEY,
                info.market,
                info.token,
                info.timeKey,
                account
            )
        );
        bytes32 claimedKey = keccak256(
            abi.encode(GmxCallbackLib.CLAIMED_COLLATERAL_AMOUNT_KEY, info.market, info.token, info.timeKey, account)
        );

        uint256 factor = ds.getUint(factorTimeKey);
        uint256 factorForAccount = ds.getUint(factorKey);
        if (factorForAccount > factor) factor = factorForAccount;

        uint256 reduction = ds.getUint(reductionKey);
        if (factor == 0 && reduction == 0) {
            uint256 divisor = ds.getUint(GmxCallbackLib.CLAIMABLE_COLLATERAL_TIME_DIVISOR_KEY);
            uint256 maturityTime = info.timeKey * divisor;
            // If GMX changes the time divisor after the key is recorded, maturityTime can
            // move past block.timestamp. Treat it as not-yet-matured rather than reverting.
            uint256 timeDiff = block.timestamp > maturityTime ? block.timestamp - maturityTime : 0;
            if (timeDiff > ds.getUint(GmxCallbackLib.CLAIMABLE_COLLATERAL_DELAY_KEY)) {
                factor = GmxConstants._FLOAT_PRECISION;
            }
        }

        factor = factor > reduction ? factor - reduction : 0;

        uint256 adjusted = (amount * factor) / GmxConstants._FLOAT_PRECISION;
        uint256 claimed = ds.getUint(claimedKey);
        claimableAmount_ = adjusted > claimed ? adjusted - claimed : 0;
    }
}
