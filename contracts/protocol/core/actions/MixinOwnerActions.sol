// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0 <0.9.0;

import {MixinActions} from "./MixinActions.sol";
import {IEApps} from "../../extensions/adapters/interfaces/IEApps.sol";
import {IERC20} from "../../interfaces/IERC20.sol";
import {ISmartPoolOwnerActions} from "../../interfaces/v4/pool/ISmartPoolOwnerActions.sol";
import {ApplicationsLib, ApplicationsSlot} from "../../libraries/ApplicationsLib.sol";
import {EnumerableSet, AddressSet} from "../../libraries/EnumerableSet.sol";
import {ExternalApp} from "../../types/ExternalApp.sol";

abstract contract MixinOwnerActions is MixinActions {
    using ApplicationsLib for ApplicationsSlot;
    using EnumerableSet for AddressSet;

    error PoolCallerIsNotOwner();
    error PoolFeeBiggerThanMax(uint16 maxFee);
    error PoolInputIsNotContract();
    error OwnerActionInputIsSameAsCurrent();
    error PoolLockupPeriodInvalid(uint48 minimum, uint48 maximum);
    error PoolNullOwnerInput();
    error PoolSpreadInvalid(uint16 maxSpread);

    modifier onlyOwner() {
        require(msg.sender == pool().owner, PoolCallerIsNotOwner());
        _;
    }

    /// @inheritdoc ISmartPoolOwnerActions
    function changeFeeCollector(address feeCollector) external override onlyOwner {
        require(feeCollector != poolParams().feeCollector, OwnerActionInputIsSameAsCurrent());
        poolParams().feeCollector = feeCollector;
        emit NewCollector(msg.sender, address(this), feeCollector);
    }

    /// @inheritdoc ISmartPoolOwnerActions
    /// @dev Minimum period is always at least 10 to prevent flash txs.
    function changeMinPeriod(uint48 minPeriod) external override onlyOwner {
        require(
            minPeriod >= _MIN_LOCKUP && minPeriod <= _MAX_LOCKUP,
            PoolLockupPeriodInvalid(_MIN_LOCKUP, _MAX_LOCKUP)
        );
        require(minPeriod != poolParams().minPeriod, OwnerActionInputIsSameAsCurrent());
        poolParams().minPeriod = minPeriod;
        emit MinimumPeriodChanged(address(this), minPeriod);
    }

    /// @inheritdoc ISmartPoolOwnerActions
    function changeSpread(uint16 newSpread) external override onlyOwner {
        // 0 value is sentinel for uninitialized spread, returning _MAX_SPREAD
        require(newSpread > 0 && newSpread <= _MAX_SPREAD, PoolSpreadInvalid(_MAX_SPREAD));
        require(newSpread != poolParams().spread, OwnerActionInputIsSameAsCurrent());
        poolParams().spread = newSpread;
        emit SpreadChanged(address(this), newSpread);
    }

    function purgeInactiveTokensAndApps() external override onlyOwner {
        // retrieve the list and mapping of stored tokens
        AddressSet storage set = activeTokensSet();
        ApplicationsSlot storage appsBitmap = activeApplications();
        uint256 packedApps = appsBitmap.packedApplications;
        ExternalApp[] memory activeApps;

        try IEApps(address(this)).getAppTokenBalances(packedApps) returns (ExternalApp[] memory apps) {
            for (uint256 i = 0; i < apps.length; i++) {
                if (
                    apps[i].balances.length == 0 &&
                    ApplicationsLib.isActiveApplication(packedApps, uint256(apps[i].appType))
                ) {
                    appsBitmap.removeApplication(apps[i].appType);
                }
            }
            activeApps = apps;
        } catch Error(string memory reason) {
            // do not allow removing tokens if the apps do not return their tokens correctly
            revert(reason);
        }

        // base token is never pushed to active list for gas savings, we can safely remove any unactive token
        address[] memory activeTokens = set.addresses;
        uint256 activeTokenBalance;

        for (uint256 i = 0; i < activeTokens.length; i++) {
            bool inApp;

            // skip removal if a token is active in an application
            for (uint256 j = 0; j < activeApps.length; j++) {
                for (uint256 k = 0; k < activeApps[j].balances.length; k++) {
                    if (activeApps[j].balances[k].token == activeTokens[i]) {
                        inApp = true;
                        break; // Exit k loop
                    }
                }
                if (inApp) {
                    break; // Exit j loop if token found in any app
                }
            }

            if (!inApp) {
                if (activeTokens[i] == _ZERO_ADDRESS) {
                    activeTokenBalance = address(this).balance;
                } else {
                    activeTokenBalance = IERC20(activeTokens[i]).balanceOf(address(this));
                }

                if (activeTokenBalance <= 1) {
                    set.remove(activeTokens[i]);
                }
            }
        }
    }

    /// @inheritdoc ISmartPoolOwnerActions
    function setKycProvider(address kycProvider) external override onlyOwner {
        // a pool can decide to remove the user whitelist requirement at any time
        if (kycProvider != address(0)) {
            require(_isContract(kycProvider), PoolInputIsNotContract());
        }
        require(kycProvider != poolParams().kycProvider, OwnerActionInputIsSameAsCurrent());
        poolParams().kycProvider = kycProvider;
        emit KycProviderSet(address(this), kycProvider);
    }

    /// @inheritdoc ISmartPoolOwnerActions
    function setTransactionFee(uint16 transactionFee) external override onlyOwner {
        require(transactionFee <= _MAX_TRANSACTION_FEE, PoolFeeBiggerThanMax(_MAX_TRANSACTION_FEE)); //fee cannot be higher than 1%
        require(transactionFee != poolParams().transactionFee, OwnerActionInputIsSameAsCurrent());
        poolParams().transactionFee = transactionFee;
        emit NewFee(msg.sender, address(this), transactionFee);
    }

    /// @inheritdoc ISmartPoolOwnerActions
    function setOwner(address newOwner) public override onlyOwner {
        require(newOwner != _ZERO_ADDRESS, PoolNullOwnerInput());
        require(newOwner != pool().owner, OwnerActionInputIsSameAsCurrent());
        address oldOwner = pool().owner;
        pool().owner = newOwner;
        emit NewOwner(oldOwner, newOwner);
    }

    function _isContract(address target) private view returns (bool) {
        return target.code.length > 0;
    }
}
