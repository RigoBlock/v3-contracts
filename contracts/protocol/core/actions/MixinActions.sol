// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0 <0.9.0;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import "../immutable/MixinStorage.sol";
import "../../interfaces/IKyc.sol";

// TODO: check at what level of hierarchy the implementation should inherit ReentrancyGuardTransient
abstract contract MixinActions is MixinStorage, ReentrancyGuardTransient {
    error PoolTransferFailed();
    error PoolTransferFromFailed();

    /*
     * EXTERNAL METHODS
     */
    /// @inheritdoc IRigoblockV3PoolActions
    function mint(
        address recipient,
        uint256 amountIn,
        uint256 amountOutMin
    ) public payable override nonReentrant() returns (uint256 recipientAmount) {
        address kycProvider = poolParams().kycProvider;

        // require whitelisted user if kyc is enforced
        if (kycProvider != address(0)) {
            require(IKyc(kycProvider).isWhitelistedUser(recipient), "POOL_CALLER_NOT_WHITELISTED_ERROR");
        }

        _assertBiggerThanMinimum(amountIn);

        if (pool().baseToken == address(0)) {
            require(msg.value == amountIn, "POOL_MINT_AMOUNTIN_ERROR,");
        } else {
            _safeTransferFrom(msg.sender, address(this), amountIn);
        }

        // TODO: verify if we should add base token to active assets, which may save some gas on nav estimate.

        // TODO: verify what happens with null total supply
        // update stored pool value
        uint256 unitaryValue = _updateNav();

        bool isOnlyHolder = poolTokens().totalSupply == balanceOf(msg.sender);

        if (!isOnlyHolder) {
            // apply markup
            amountIn -= (amountIn * _getSpread()) / _SPREAD_BASE;
        }

        uint256 mintedAmount = (amountIn * 10**decimals()) / unitaryValue;
        require(mintedAmount > amountOutMin, "POOL_MINT_OUTPUT_AMOUNT_ERROR");
        poolTokens().totalSupply += mintedAmount;

        /// @notice allocate pool token transfers and log events.
        recipientAmount = _allocateMintTokens(recipient, mintedAmount);
    }

    /// @inheritdoc IRigoblockV3PoolActions
    function burn(uint256 amountIn, uint256 amountOutMin) external override nonReentrant() returns (uint256 netRevenue) {
        netRevenue = _burn(amountIn, amountOutMin, tokenOut);
    }

    // TODO: test for potential abuse. Technically, if the token can be manipulated, a burn in base token can do just as much
    // harm as a burn in any token. Considering burn must happen after a certain period, a pool opeartor has time to sell illiquid tokens.
    // technically, this could be used for exchanging big quantities of tokens at market rate. Which is not a big deal. prob should
    // allow only if user does not have enough base tokens
    function burnForToken(uint256 amountIn, uint256 amountOutMin, address tokenOut)
        external
        /*override*/
        nonReentrant()
        returns (uint256 netRevenue)
    {
        // early revert if token does not have price feed, 0 is sentinel for token not being in portfolio
        require(getTrackedTokens().positions[tokenOut] != 0);
        netRevenue = _burn(amountIn, amountOutMin, tokenOut);
    }

    /// @inheritdoc IRigoblockV3PoolActions
    function setUnitaryValue() external override nonReentrant() {
        // unitary value can be updated only after first mint
        require(poolTokens().totalSupply > 1e2, "POOL_SUPPLY_NULL_ERROR");

        poolTokens().unitaryValue = unitaryValue;
        emit NewNav(msg.sender, address(this), unitaryValue);
    }

    /*
     * PUBLIC METHODS
     */
    function balanceOf(address who) external view returns (uint256);
    function decimals() public view virtual override returns (uint8);

    /*
     * INTERNAL METHODS
     */
    function _updateNav() internal virtual returns (uint256 unitaryValue);

    function _getFeeCollector() internal view virtual returns (address);

    function _getMinPeriod() internal view virtual returns (uint48);

    /// @dev Returns the spread, or _MAX_SPREAD if not set
    function _getSpread() internal view virtual returns (uint16);

    /*
     * PRIVATE METHODS
     */
    /// @notice Allocates tokens to recipient. Fee tokens are locked too.
    /// @dev Each new mint on same recipient sets new activation on all owned tokens.
    /// @param recipient Address of the recipient.
    /// @param mintedAmount Value of issued tokens.
    /// @return recipientAmount Number of new tokens issued to recipient.
    function _allocateMintTokens(address recipient, uint256 mintedAmount) private returns (uint256 recipientAmount) {
        recipientAmount = mintedAmount;
        Accounts storage accounts = accounts();
        uint208 recipientBalance = accounts.userAccounts[recipient].userBalance;
        uint48 activation;
        // it is safe to use unckecked as max min period is 30 days
        unchecked {
            activation = uint48(block.timestamp) + _getMinPeriod();
        }
        uint16 transactionFee = poolParams().transactionFee;

        if (transactionFee != 0) {
            address feeCollector = _getFeeCollector();

            if (feeCollector == recipient) {
                // it is safe to use unckecked as recipientAmount requires user holding enough base tokens.
                unchecked {
                    recipientBalance += uint208(recipientAmount);
                }
            } else {
                uint208 feeCollectorBalance = accounts.userAccounts[feeCollector].userBalance;
                uint256 feePool = (mintedAmount * transactionFee) / _FEE_BASE;
                recipientAmount -= feePool;
                unchecked {
                    feeCollectorBalance += uint208(feePool);
                    recipientBalance += uint208(recipientAmount);
                }
                //fee tokens are locked as well
                accounts.userAccounts[feeCollector] = UserAccount({
                    userBalance: feeCollectorBalance,
                    activation: activation
                });
                emit Transfer(address(0), feeCollector, feePool);
            }
        } else {
            unchecked {
                recipientBalance += uint208(recipientAmount);
            }
        }

        accounts.userAccounts[recipient] = UserAccount({userBalance: recipientBalance, activation: activation});
        emit Transfer(address(0), recipient, recipientAmount);
    }

    function _burn(uint256 amountIn, uint256 amountOutMin, address tokenOut) private returns (uint256 netRevenue) {
        require(amountIn > 0, "POOL_BURN_NULL_AMOUNT_ERROR");
        UserAccount memory userAccount = accounts().userAccounts[msg.sender];
        require(userAccount.userBalance >= amountIn, "POOL_BURN_NOT_ENOUGH_ERROR");
        require(block.timestamp >= userAccount.activation, "POOL_MINIMUM_PERIOD_NOT_ENOUGH_ERROR");

        // update stored pool value
        // TODO: could implement some form of caching, like take the value valid up until 5 minutes
        uint256 unitaryValue = _updateNav();

        /// @notice allocate pool token transfers and log events.
        uint256 burntAmount = _allocateBurnTokens(amountIn);
        bool isOnlyHolder = poolTokens().totalSupply == balanceOf(msg.sender);
        poolTokens().totalSupply -= burntAmount;

        if (!isOnlyHolder) {
            // apply markup
            burntAmount -= (burntAmount * _getSpread()) / _SPREAD_BASE;
        }

        // TODO: verify cases of possible underflow for small nav value
        netRevenue = (burntAmount * unitaryValue) / 10**decimals();

        address baseToken = pool().baseToken;

        // TODO: test how this could be exploited
        if (tokenOut != baseToken) {
            // only allow arbitrary token redemption as a fallback in case the pool does not hold enough base currency
            require(netRevenue > IERC20(baseToken).balanceOf(address(this)));
            try IEOracle(address(this)).convertTokenAmount(baseToken, netRevenue, tokenOut) returns (uint256 value) {
                netRevenue = value;
            } catch Error(string memory reason) {
                revert reason;
            }
        }

        require(netRevenue >= amountOutMin, "POOL_BURN_OUTPUT_AMOUNT_ERROR");

        if (tokenOut == address(0)) {
            payable(msg.sender).transfer(netRevenue);
        } else {
            _safeTransfer(tokenOut, msg.sender, netRevenue);
        }
    }

    /// @notice Destroys tokens of holder.
    /// @dev Fee is paid in pool tokens.
    /// @param amountIn Value of tokens to be burnt.
    /// @return burntAmount Number of net burnt tokens.
    function _allocateBurnTokens(uint256 amountIn) private returns (uint256 burntAmount) {
        burntAmount = amountIn;
        Accounts storage accounts = accounts();
        uint208 holderBalance = accounts.userAccounts[msg.sender].userBalance;

        if (poolParams().transactionFee != uint256(0)) {
            address feeCollector = _getFeeCollector();

            if (msg.sender == feeCollector) {
                holderBalance -= uint208(burntAmount);
            } else {
                uint256 feePool = (amountIn * poolParams().transactionFee) / _FEE_BASE;
                burntAmount -= feePool;
                holderBalance -= uint208(burntAmount);

                // allocate fee tokens to fee collector
                uint208 feeCollectorBalance = accounts.userAccounts[feeCollector].userBalance;
                uint48 activation;
                unchecked {
                    feeCollectorBalance += uint208(feePool);
                    activation = uint48(block.timestamp + 1);
                }
                accounts.userAccounts[feeCollector] = UserAccount({
                    userBalance: feeCollectorBalance,
                    activation: uint48(block.timestamp + 1)
                });
                emit Transfer(msg.sender, feeCollector, feePool);
            }
        } else {
            holderBalance -= uint208(burntAmount);
        }

        // clear storage is user account has sold all held tokens
        if (holderBalance == 0) {
            delete accounts.userAccounts[msg.sender];
        } else {
            accounts.userAccounts[msg.sender].userBalance = holderBalance;
        }

        emit Transfer(msg.sender, address(0), burntAmount);
    }

    function _assertBiggerThanMinimum(uint256 amount) private view {
        require(amount >= 10**decimals() / _MINIMUM_ORDER_DIVISOR, "POOL_AMOUNT_SMALLER_THAN_MINIMUM_ERROR");
    }

    // TODO: use try/catch implementation
    function _safeTransfer(address token, address to, uint256 amount) private {
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(_TRANSFER_SELECTOR, to, amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), PoolTransferFailed());
    }

    // TODO: use our try/catch implementation
    function _safeTransferFrom(
        address from,
        address to,
        uint256 amount
    ) private {
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory data) = pool().baseToken.call(
            abi.encodeWithSelector(_TRANSFER_FROM_SELECTOR, from, to, amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), PoolTransferFromFailed());
    }
}
