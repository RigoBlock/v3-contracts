// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0 <0.9.0;

import {MixinActions} from "./MixinActions.sol";
import {IEApps} from "../../extensions/adapters/interfaces/IEApps.sol";
import {IERC20} from "../../interfaces/IERC20.sol";
import {IRigoblockV3PoolOwnerActions} from "../../interfaces/pool/IRigoblockV3PoolOwnerActions.sol";
import {ApplicationsLib, ApplicationsSlot} from "../../libraries/ApplicationsLib.sol";
import {EnumerableSet, AddressSet} from "../../libraries/EnumerableSet.sol";
import {ExternalApp} from "../../types/ExternalApp.sol";

abstract contract MixinOwnerActions is MixinActions {
    using ApplicationsLib for ApplicationsSlot;
    using EnumerableSet for AddressSet;

    error PoolCallerIsNotOwner();
    error PoolFeeBiggerThanMax(uint16 maxFee);
    error PoolInputIsNotContract();
    error PoolLockupPeriodInvalid(uint48 minimum, uint48 maximum);
    error PoolNullOwnerInput();
    error PoolSpreadInvalid(uint16 maxSpread);

    modifier onlyOwner() {
        require(msg.sender == pool().owner, PoolCallerIsNotOwner());
        _;
    }

    /// @inheritdoc IRigoblockV3PoolOwnerActions
    function changeFeeCollector(address feeCollector) external override onlyOwner {
        poolParams().feeCollector = feeCollector;
        emit NewCollector(msg.sender, address(this), feeCollector);
    }

    /// @inheritdoc IRigoblockV3PoolOwnerActions
    function changeMinPeriod(uint48 minPeriod) external override onlyOwner {
        /// @notice minimum period is always at least 1 to prevent flash txs.
        require(
            minPeriod >= _MIN_LOCKUP && minPeriod <= _MAX_LOCKUP,
            PoolLockupPeriodInvalid(_MIN_LOCKUP, _MAX_LOCKUP)
        );
        poolParams().minPeriod = minPeriod;
        emit MinimumPeriodChanged(address(this), minPeriod);
    }

    /// @inheritdoc IRigoblockV3PoolOwnerActions
    function changeSpread(uint16 newSpread) external override onlyOwner {
        // 0 value is sentinel for uninitialized spread, returning _MAX_SPREAD
        require(newSpread > 0 && newSpread <= _MAX_SPREAD, PoolSpreadInvalid(_MAX_SPREAD));
        poolParams().spread = newSpread;
        emit SpreadChanged(address(this), newSpread);
    }

    function purgeInactiveTokensAndApps() external override onlyOwner {
        // retrieve the list and mapping of stored tokens
        AddressSet storage set = activeTokensSet();
        ApplicationsSlot storage appsBitmap = applications();
        uint256 packedApps = appsBitmap.packedApplications;
        ExternalApp[] memory activeApps;
        // TODO: test we get the correct balances, as fallback delegatecalls to extension in this case
        try IEApps(address(this)).getAppTokenBalances(packedApps) returns (ExternalApp[] memory apps) {
            for (uint256 i = 0; i < apps.length; i++) {
                activeApps = apps;

                // update storage if the specific app is stored as active
                if (
                    apps[i].balances.length == 0 &&
                    ApplicationsLib.isActiveApplication(packedApps, uint256(apps[i].appType))
                ) {
                    appsBitmap.removeApplication(apps[i].appType);
                }
            }
        } catch Error(string memory reason) {
            // do not allow removing tokens if the apps do not return their tokens correctly
            revert(reason);
        }

        bool foundInApp;

        // base token is never pushed to active list for gas savings, we can safely remove any unactive token
        for (uint256 i = 0; i < set.addresses.length; i++) {
            // skip removal if a token is active in an application
            for (uint256 j = 0; j < activeApps.length; j++) {
                for (uint256 k = 0; k < activeApps[i].balances.length; k++) {
                    if (activeApps[j].balances[k].token == set.addresses[i]) {
                        foundInApp = true;
                        break; // Exit k loop
                    }
                }
                if (foundInApp) {
                    break; // Exit j loop if token found in any app
                }
            }

            if (!foundInApp) {
                try IERC20(set.addresses[i]).balanceOf(address(this)) returns (uint256 _balance) {
                    if (_balance <= 1) {
                        set.remove(set.addresses[i]);
                    }
                } catch {
                    continue;
                }
            } else {
                foundInApp = false;
            }
        }
    }

    /// @inheritdoc IRigoblockV3PoolOwnerActions
    function setKycProvider(address kycProvider) external override onlyOwner {
        require(_isContract(kycProvider), PoolInputIsNotContract());
        poolParams().kycProvider = kycProvider;
        emit KycProviderSet(address(this), kycProvider);
    }

    /// @inheritdoc IRigoblockV3PoolOwnerActions
    function setTransactionFee(uint16 transactionFee) external override onlyOwner {
        require(transactionFee <= _MAX_TRANSACTION_FEE, PoolFeeBiggerThanMax(_MAX_TRANSACTION_FEE)); //fee cannot be higher than 1%
        poolParams().transactionFee = transactionFee;
        emit NewFee(msg.sender, address(this), transactionFee);
    }

    /// @inheritdoc IRigoblockV3PoolOwnerActions
    function setOwner(address newOwner) public override onlyOwner {
        require(newOwner != _ZERO_ADDRESS, PoolNullOwnerInput());
        address oldOwner = pool().owner;
        pool().owner = newOwner;
        emit NewOwner(oldOwner, newOwner);
    }

    function _isContract(address target) private view returns (bool) {
        return target.code.length > 0;
    }
}
