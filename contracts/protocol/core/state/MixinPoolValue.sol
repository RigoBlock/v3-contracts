// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import {SafeCast} from "@openzeppelin-legacy/contracts/utils/math/SafeCast.sol";
import {MixinOwnerActions} from "../actions/MixinOwnerActions.sol";
import {IEApps} from "../../extensions/adapters/interfaces/IEApps.sol";
import {IEOracle} from "../../extensions/adapters/interfaces/IEOracle.sol";
import {IERC20} from "../../interfaces/IERC20.sol";
import {AddressSet, EnumerableSet} from "../../libraries/EnumerableSet.sol";
import {ApplicationsLib, ApplicationsSlot} from "../../libraries/ApplicationsLib.sol";
import {NavImpactLib} from "../../libraries/NavImpactLib.sol";
import {SlotDerivation} from "../../libraries/SlotDerivation.sol";
import {TransientStorage} from "../../libraries/TransientStorage.sol";
import {VirtualStorageLib} from "../../libraries/VirtualStorageLib.sol";
import {ExternalApp} from "../../types/ExternalApp.sol";
import {NavComponents} from "../../types/NavComponents.sol";

/// @title MixinPoolValue
/// @notice A contract that retrieves smart pool token balances and computes their base token value.
abstract contract MixinPoolValue is MixinOwnerActions {
    using ApplicationsLib for ApplicationsSlot;
    using EnumerableSet for AddressSet;
    using SlotDerivation for bytes32;
    using TransientStorage for address;
    using SafeCast for uint256;
    using SafeCast for int256;

    error BaseTokenPriceFeedError();

    /// @notice Uses transient storage to keep track of unique token balances.
    /// @dev With null total supply a pool will return the last stored value.
    function _updateNav() internal override returns (NavComponents memory components) {
        components.unitaryValue = poolTokens().unitaryValue;
        components.totalSupply = poolTokens().totalSupply;
        components.baseToken = pool().baseToken;
        components.decimals = pool().decimals;

        // make sure we can later convert token values in base token. Asserted before anything else to prevent potential holder burn failure.
        // Notice: the following check adds a little gas overhead, but is necessary to guarantee backwards compatibility with v3. Because all existing
        // v3 vaults have a price feed, we could move the following assertion to the following block, i.e. executing it only on the first mint.
        require(IEOracle(address(this)).hasPriceFeed(components.baseToken), BaseTokenPriceFeedError());

        // Always compute net total assets (used for cross-chain donation validation)
        int256 netValue = _computeTotalPoolValue(components.baseToken);

        if (netValue >= 0) {
            components.netTotalValue = uint256(netValue);
        } else {
            components.netTotalLiabilities = uint256(-netValue);
        }

        // first mint skips nav calculation
        if (components.unitaryValue == 0) {
            components.unitaryValue = 10 ** components.decimals;
        } else {
            int256 virtualSupply = VirtualStorageLib.getVirtualSupply();

            // revert if abs virtual supply below a minimum threshold of total supply. Also means effective supply must be non-negative.
            NavImpactLib.validateSupply(components.totalSupply, virtualSupply);
            int256 effectiveSupply = int256(components.totalSupply) + virtualSupply;

            // effective supply cannot be negative from previous assertion. Also cannot burn internally more than has been minted.
            if (effectiveSupply == 0) {
                return components;
            }

            components.totalSupply = uint256(effectiveSupply);

            if (components.netTotalValue > 0) {
                components.unitaryValue =
                    (components.netTotalValue * 10 ** components.decimals) /
                    components.totalSupply;
            } else {
                return components;
            }
        }

        // never allow storing 0 - flag for default unitary price of uninitialized pool
        if (components.unitaryValue == 0) {
            components.unitaryValue = 1;
        }

        // update storage only if different
        if (components.unitaryValue != poolTokens().unitaryValue) {
            poolTokens().unitaryValue = components.unitaryValue;
            emit NewNav(msg.sender, address(this), components.unitaryValue);
        }
    }

    /// @notice Updates the stored value with an updated one.
    /// @param baseToken The address of the base token.
    /// @return poolValue The total value of the pool in base token units.
    /// @dev Assumes the stored list contain unique elements.
    /// @dev A write method to be used in mint and burn operations.
    /// @dev Uses transient storage to keep track of unique token balances.
    function _computeTotalPoolValue(address baseToken) private returns (int256 poolValue) {
        uint256 packedApps = activeApplications().packedApplications;

        // Declare reusable variables outside loops to reduce stack depth
        address token;
        int256 amount;

        // try and get positions balances. Will revert if not successul and prevent incorrect nav calculation.
        try IEApps(address(this)).getAppTokenBalances(_getActiveApplications()) returns (ExternalApp[] memory apps) {
            // position balances can be negative, positive, or null (handled explicitly later)
            for (uint256 i = 0; i < apps.length; i++) {
                // caching for gas savings
                uint256 appTokenBalancesLength = apps[i].balances.length;

                // active positions tokens are a subset of active tokens
                for (uint256 j = 0; j < appTokenBalancesLength; j++) {
                    // push application if not active but tokens are returned from it (as with GRG staking and univ3 liquidity)
                    if (!ApplicationsLib.isActiveApplication(packedApps, uint256(apps[i].appType))) {
                        activeApplications().storeApplication(apps[i].appType);
                    }

                    // Reuse variables to minimize stack depth
                    amount = apps[i].balances[j].amount;

                    // Always add or update the balance from positions
                    if (amount != 0) {
                        token = apps[i].balances[j].token;

                        // cache balances in temporary storage
                        int256 storedBalance = token.getBalance();

                        // verify token in active tokens set, add it otherwise (relevant for pool deployed before v4)
                        if (storedBalance == 0) {
                            // will add to set only if not already stored
                            activeTokensSet().addUnique(IEOracle(address(this)), token, baseToken);
                        }

                        storedBalance += amount;
                        // store balance and make sure slot is not cleared to prevent trying to add token again
                        token.storeBalance(storedBalance != 0 ? storedBalance : int256(1));
                    }
                }
            }
        } catch Error(string memory reason) {
            // we prevent returning pool value when any of the tracked applications fails, as they are not expected to
            revert(reason);
        }

        // initialize pool value as base token balances (wallet balance plus apps balances)
        uint256 nativeAmount = msg.value;
        poolValue = _getAndClearBalance(baseToken, nativeAmount);

        // active tokens include any potentially not stored app token, like when a pool upgrades from v3 to v4
        address[] memory activeTokens = activeTokensSet().addresses;

        // caching for gas savings
        uint256 activeTokensLength = activeTokens.length;
        int256[] memory tokenAmounts = new int256[](activeTokensLength);

        // base token is not stored in activeTokens array
        for (uint256 i = 0; i < activeTokensLength; i++) {
            tokenAmounts[i] = _getAndClearBalance(activeTokens[i], nativeAmount);
        }

        if (activeTokensLength > 0) {
            poolValue += IEOracle(address(this)).convertBatchTokenAmounts(activeTokens, tokenAmounts, baseToken);
        }
    }

    /// @dev Returns 0 balance if ERC20 call fails.
    /// @param token The token address to get balance for
    /// @param nativeAmount The msg.value to subtract from ETH balance (passed to avoid multiple msg.value reads)
    function _getAndClearBalance(address token, uint256 nativeAmount) private returns (int256 value) {
        value = token.getBalance();

        // clear temporary storage if used
        if (value != 0) {
            token.storeBalance(0);
        }

        // the active tokens list contains unique addresses
        if (token == _ZERO_ADDRESS) {
            value += (address(this).balance - nativeAmount).toInt256();
        } else {
            try IERC20(token).balanceOf(address(this)) returns (uint256 _balance) {
                value += _balance.toInt256();
            } catch {
                // returns 0 balance if the ERC20 balance cannot be found
                return 0;
            }
        }
    }

    /// virtual methods
    function _getActiveApplications() internal view virtual returns (uint256);
}
