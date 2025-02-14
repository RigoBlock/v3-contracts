// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0 <0.9.0;

import {MixinStorage} from "../immutable/MixinStorage.sol";
import {IEOracle} from "../../extensions/adapters/interfaces/IEOracle.sol";
import {IERC20} from "../../interfaces/IERC20.sol";
import {IKyc} from "../../interfaces/IKyc.sol";
import {ISmartPoolActions} from "../../interfaces/pool/ISmartPoolActions.sol";
import {AddressSet, EnumerableSet} from "../../libraries/EnumerableSet.sol";
import {ReentrancyGuardTransient} from "../../libraries/ReentrancyGuardTransient.sol";
import {Currency, SafeTransferLib} from "../../libraries/SafeTransferLib.sol";
import {NavComponents} from "../../types/NavComponents.sol";

abstract contract MixinActions is MixinStorage, ReentrancyGuardTransient {
    using SafeTransferLib for address;
    using EnumerableSet for AddressSet;

    error BaseTokenBalance();
    error PoolAmountSmallerThanMinumum(uint16 minimumOrderDivisor);
    error PoolBurnNotEnough();
    error PoolBurnNullAmount();
    error PoolBurnOutputAmount();
    error PoolCallerNotWhitelisted();
    error PoolMinimumPeriodNotEnough();
    error PoolMintAmountIn();
    error PoolMintInvalidRecipient();
    error PoolMintOutputAmount();
    error PoolSupplyIsNullOrDust();
    error PoolTokenNotActive();

    /*
     * EXTERNAL METHODS
     */
    /// @inheritdoc ISmartPoolActions
    function mint(
        address recipient,
        uint256 amountIn,
        uint256 amountOutMin
    ) public payable override nonReentrant returns (uint256 recipientAmount) {
        require(recipient != _ZERO_ADDRESS, PoolMintInvalidRecipient());
        NavComponents memory components = _updateNav();
        address kycProvider = poolParams().kycProvider;

        // require whitelisted user if kyc is enforced
        if (!kycProvider.isAddressZero()) {
            require(IKyc(kycProvider).isWhitelistedUser(recipient), PoolCallerNotWhitelisted());
        }

        _assertBiggerThanMinimum(amountIn);

        if (components.baseToken.isAddressZero()) {
            require(msg.value == amountIn, PoolMintAmountIn());
        } else {
            components.baseToken.safeTransferFrom(msg.sender, address(this), amountIn);
        }

        bool isOnlyHolder = components.totalSupply == accounts().userAccounts[recipient].userBalance;

        if (!isOnlyHolder) {
            // apply markup
            amountIn -= (amountIn * _getSpread()) / _SPREAD_BASE;
        }

        uint256 mintedAmount = (amountIn * 10 ** components.decimals) / components.unitaryValue;
        require(mintedAmount > amountOutMin, PoolMintOutputAmount());
        poolTokens().totalSupply += mintedAmount;

        // allocate pool token transfers and log events.
        recipientAmount = _allocateMintTokens(recipient, mintedAmount);
    }

    /// @inheritdoc ISmartPoolActions
    function burn(uint256 amountIn, uint256 amountOutMin) external override nonReentrant returns (uint256 netRevenue) {
        netRevenue = _burn(amountIn, amountOutMin, _BASE_TOKEN_FLAG);
    }

    // TODO: test for potential abuse. Technically, if the token can be manipulated, a burn in base token can do just as much
    // harm as a burn in any token. Considering burn must happen after a certain period, a pool opeartor has time to sell illiquid tokens.
    // technically, this could be used for exchanging big quantities of tokens at market rate. Which is not a big deal. prob should
    // allow only if user does not have enough base tokens
    /// @inheritdoc ISmartPoolActions
    function burnForToken(
        uint256 amountIn,
        uint256 amountOutMin,
        address tokenOut
    ) external override nonReentrant returns (uint256 netRevenue) {
        // early revert if token does not have price feed, REMOVED_ADDRESS_FLAG is sentinel for token not being active.
        require(activeTokensSet().isActive(tokenOut), PoolTokenNotActive());
        netRevenue = _burn(amountIn, amountOutMin, tokenOut);
    }

    /// @inheritdoc ISmartPoolActions
    function updateUnitaryValue() external override nonReentrant {
        NavComponents memory components = _updateNav();

        // unitary value is updated only with non-dust supply
        require(components.totalSupply >= 1e2, PoolSupplyIsNullOrDust());
    }

    /*
     * PUBLIC METHODS
     */
    function decimals() public view virtual override returns (uint8);

    /*
     * INTERNAL METHODS
     */
    function _updateNav() internal virtual returns (NavComponents memory);

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
    /// @return Amount of tokens minted to the recipient.
    function _allocateMintTokens(address recipient, uint256 mintedAmount) private returns (uint256) {
        uint48 activation;

        // it is safe to use unckecked as max min period is 30 days
        unchecked {
            activation = uint48(block.timestamp) + _getMinPeriod();
        }

        uint16 transactionFee = poolParams().transactionFee;

        if (transactionFee != 0) {
            address feeCollector = _getFeeCollector();

            if (feeCollector != recipient) {
                uint256 feePool = (mintedAmount * transactionFee) / _FEE_BASE;
                mintedAmount -= feePool;

                // fee tokens are locked as well
                accounts().userAccounts[feeCollector].userBalance += uint208(feePool);
                accounts().userAccounts[feeCollector].activation = activation;
                emit Transfer(_ZERO_ADDRESS, feeCollector, feePool);
            }
        }

        accounts().userAccounts[recipient].userBalance += uint208(mintedAmount);
        accounts().userAccounts[recipient].activation = activation;
        emit Transfer(_ZERO_ADDRESS, recipient, mintedAmount);
        return mintedAmount;
    }

    function _burn(uint256 amountIn, uint256 amountOutMin, address tokenOut) private returns (uint256 netRevenue) {
        require(amountIn > 0, PoolBurnNullAmount());
        UserAccount memory userAccount = accounts().userAccounts[msg.sender];
        require(userAccount.userBalance >= amountIn, PoolBurnNotEnough());
        require(block.timestamp >= userAccount.activation, PoolMinimumPeriodNotEnough());

        // update stored pool value
        NavComponents memory components = _updateNav();

        /// @notice allocate pool token transfers and log events.
        uint256 burntAmount = _allocateBurnTokens(amountIn, userAccount.userBalance);
        bool isOnlyHolder = components.totalSupply == userAccount.userBalance;
        poolTokens().totalSupply -= burntAmount;

        if (!isOnlyHolder) {
            // apply markup
            burntAmount -= (burntAmount * _getSpread()) / _SPREAD_BASE;
        }

        // TODO: verify cases of possible underflow for small nav value
        netRevenue = (burntAmount * components.unitaryValue) / 10 ** decimals();

        address baseToken = pool().baseToken;

        // TODO: test how this could be exploited.
        if (tokenOut == _BASE_TOKEN_FLAG) {
            tokenOut = baseToken;
        } else if (tokenOut != baseToken) {
            // only allow arbitrary token redemption as a fallback in case the pool does not hold enough base currency
            uint256 baseTokenBalance = baseToken.isAddressZero() ? address(this).balance : IERC20(baseToken).balanceOf(address(this));
            require(netRevenue > baseTokenBalance, BaseTokenBalance());
            // an active token must have a price feed, hence the oracle query will always return a converted value
            netRevenue = IEOracle(address(this)).convertTokenAmount(baseToken, netRevenue, tokenOut, components.ethToBaseTokenTwap);
        }

        require(netRevenue >= amountOutMin, PoolBurnOutputAmount());

        if (tokenOut.isAddressZero()) {
            msg.sender.safeTransferNative(netRevenue);
        } else {
            tokenOut.safeTransfer(msg.sender, netRevenue);
        }
    }

    /// @notice Destroys tokens of holder.
    /// @dev Fee is paid in pool tokens, fee amount is not burnt.
    /// @param amountIn Value of tokens to be burnt.
    /// @param holderBalance The balance of the caller.
    /// @return Number of user burnt tokens.
    function _allocateBurnTokens(uint256 amountIn, uint256 holderBalance) private returns (uint256) {
        if (amountIn < holderBalance) {
            accounts().userAccounts[msg.sender].userBalance -= uint208(amountIn);
        } else {
            delete accounts().userAccounts[msg.sender];
        }

        if (poolParams().transactionFee != 0) {
            address feeCollector = _getFeeCollector();

            if (msg.sender != feeCollector) {
                uint256 feePool = (amountIn * poolParams().transactionFee) / _FEE_BASE;
                amountIn -= feePool;

                // allocate fee tokens to fee collector
                accounts().userAccounts[feeCollector].userBalance += uint208(feePool);
                accounts().userAccounts[feeCollector].activation = uint48(block.timestamp + 1);
                emit Transfer(msg.sender, feeCollector, feePool);
            }
        }

        emit Transfer(msg.sender, _ZERO_ADDRESS, amountIn);
        return amountIn;
    }

    function _assertBiggerThanMinimum(uint256 amount) private view {
        require(
            amount >= 10 ** decimals() / _MINIMUM_ORDER_DIVISOR,
            PoolAmountSmallerThanMinumum(_MINIMUM_ORDER_DIVISOR)
        );
    }
}
