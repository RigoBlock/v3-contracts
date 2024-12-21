// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0 <0.9.0;

import "./MixinActions.sol";

abstract contract MixinOwnerActions is MixinActions {
    PoolSpreadInvalid(uint16 maxSpread);
    PoolLockupPeriodInvalid(uint48 minimum, uint48 maximum);

    modifier onlyOwner() {
        require(msg.sender == pool().owner, "POOL_CALLER_IS_NOT_OWNER_ERROR");
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

    // TODO: move to types
    struct AppTokenBalance {
        address token;
        int128 amount;
    }

    struct App {
        AppTokenBalance[] balances;
        uint256 appType; // converted to uint to facilitate supporting new apps
    }

    struct IdleToken {
        address token;
        uint256 originalIndex;
    }

    // TODO: check if want to keep here, in case it's clear this won't need frequent upgrade, or to an extension
    // TODO: make minimal method, so can keep here and change extensions in case, as we want to provide logic in core.
    /// @notice Allows clearing storage from idle tokens. This method also removes any potential duplicates.
    /// @dev This is the only endpoint that has access to removing a token from the active tokens tuple.
    function purgeInactiveTokensAndApps() external /*override*/ onlyOwner {
        // TODO: this method must read from storage slot, without addition of default tokens in between, verify
        AddressSet[] storage set = activeTokensSet();
        AppTokenBalance[] memory appTokens;
        uint256 activeApps = applications().packedApplications;
        try IEApps(address(this)).getAppTokenBalances(applications().packedApplications) returns (App[] memory apps) {
            for (uint i = 0; i < apps.length; i++) {
                // all supported apps are returned, non active with empty tuple. We do not update storage unless the
                // specific app is stored as active
                if (apps[i].balances.length == 0 && ApplicationsLib.isActiveApplication(uint256(apps[i].appType))) {
                    // as this uses applications library, check if want to move to extension, or the library is fine
                    // as we won't be update to upgrade the library without causing implementation bytecode to change
                    ApplicationsLib.removeApplication(apps[i].appType);
                }
            }
        } catch Error(string memory reason) {
            // do not allow removing tokens if the apps do not return their tokens correctly
            revert reason;
        }

        IdleToken[] memory idleTokens = new IdleToken[](set.activeTokens);

        for (uint i = 0; i < set.activeTokens.length; i++) {
            bool isPositiveBalance;
            if (set.activeTokens[i] == address(0) || set.activeTokens[i] == pool().baseToken) {
                // do not remove chain currency or base token for gas optimizations
                continue;
            } else {
                try IERC20(set.activeTokens[i]).balanceOf(address(this)) returns (uint256 _balance) {
                    isPositiveBalance = _balance > 1;
                } catch {
                    continue;
                }
            }

            if (!isPositiveBalance) {
                bool isActiveAppToken;
                for (i = 0; i < app.length)
                for (uint j = 0; j < appTokens.length; j++) {
                    // remove a null balance token only if not used in an app
                    if (set.activeTokens(j) == appTokens(j).token) {
                        isActiveAppToken = true;
                        break;
                    } else {
                        continue;
                    }
                }

                if (!isActiveAppToken) {
                    set.remove(set.activeTokens(j));
                }
            }
        }
    }

    /// @inheritdoc IRigoblockV3PoolOwnerActions
    // TODO: we can add storage mapping as canonical whitelist, with a flag for canonical list
    // TODO: remove ability to set custom kyc provider, as it is not a demanded feature and there is no
    // guarantee kyc provider will use same interface. We could instead develop a userWhitelist extension
    // to support known kyc providers in the future
    function setKycProvider(address kycProvider) external override onlyOwner {
        require(_isContract(kycProvider), "POOL_INPUT_NOT_CONTRACT_ERROR");
        poolParams().kycProvider = kycProvider;
        emit KycProviderSet(address(this), kycProvider);
    }

    /// @inheritdoc IRigoblockV3PoolOwnerActions
    function setTransactionFee(uint16 transactionFee) external override onlyOwner {
        require(transactionFee <= _MAX_TRANSACTION_FEE, "POOL_FEE_HIGHER_THAN_ONE_PERCENT_ERROR"); //fee cannot be higher than 1%
        poolParams().transactionFee = transactionFee;
        emit NewFee(msg.sender, address(this), transactionFee);
    }

    /// @inheritdoc IRigoblockV3PoolOwnerActions
    function setOwner(address newOwner) public override onlyOwner {
        require(newOwner != address(0), "POOL_NULL_OWNER_INPUT_ERROR");
        address oldOwner = pool().owner;
        pool().owner = newOwner;
        emit NewOwner(oldOwner, newOwner);
    }

    function totalSupply() public view virtual override returns (uint256);

    function decimals() public view virtual override returns (uint8);

    function _getUnitaryValue() internal view virtual override returns (uint256);

    function _isContract(address target) private view returns (bool) {
        return target.code.length > 0;
    }
}
