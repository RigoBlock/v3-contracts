// SPDX-License-Identifier: Apache 2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import {SafeCast} from "@openzeppelin-legacy/contracts/utils/math/SafeCast.sol";
import {MixinStorage} from "../immutable/MixinStorage.sol";
import {IEOracle} from "../../extensions/adapters/interfaces/IEOracle.sol";
import {IERC20} from "../../interfaces/IERC20.sol";
import {IKyc} from "../../interfaces/IKyc.sol";
import {ISmartPoolActions} from "../../interfaces/v4/pool/ISmartPoolActions.sol";
import {AddressSet, EnumerableSet} from "../../libraries/EnumerableSet.sol";
import {ReentrancyGuardTransient} from "../../libraries/ReentrancyGuardTransient.sol";
import {Currency, SafeTransferLib} from "../../libraries/SafeTransferLib.sol";
import {NavComponents} from "../../types/NavComponents.sol";

abstract contract MixinActions is MixinStorage, ReentrancyGuardTransient {
    using SafeTransferLib for address;
    using EnumerableSet for AddressSet;
    using SafeCast for uint256;

    error BaseTokenBalance();
    error PoolAmountSmallerThanMinimum(uint16 minimumOrderDivisor);
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
    error InvalidOperator();
    error PoolMintTokenNotActive();

    /*
     * EXTERNAL METHODS
     */
    /// @inheritdoc ISmartPoolActions
    function mint(
        address recipient,
        uint256 amountIn,
        uint256 amountOutMin
    ) external payable override nonReentrant returns (uint256 recipientAmount) {
        recipientAmount = _mint(recipient, amountIn, amountOutMin, _BASE_TOKEN_FLAG);
    }

    /// @inheritdoc ISmartPoolActions
    function mintWithToken(
        address recipient,
        uint256 amountIn,
        uint256 amountOutMin,
        address tokenIn
    ) external payable override nonReentrant returns (uint256 recipientAmount) {
        // early revert if token does not have price feed, REMOVED_ADDRESS_FLAG is sentinel for token not being active.
        require(acceptedTokensSet().isActive(tokenIn), PoolMintTokenNotActive());

        recipientAmount = _mint(recipient, amountIn, amountOutMin, tokenIn);
    }

    /// @inheritdoc ISmartPoolActions
    function burn(uint256 amountIn, uint256 amountOutMin) external override nonReentrant returns (uint256 netRevenue) {
        netRevenue = _burn(amountIn, amountOutMin, _BASE_TOKEN_FLAG);
    }

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

    /// @inheritdoc ISmartPoolActions
    function setOperator(address operator, bool approved) external override returns (bool) {
        operators().isApproved[msg.sender][operator] = approved;

        emit OperatorSet(msg.sender, operator, approved);

        return true;
    }

    error DonateTransferFromFailer();

    // TODO: by integrating it as EIntents, we could remove the transferFrom on donate, or the donate entirely?
    /// @inheritdoc ISmartPoolActions
    function donate(address token, uint256 amount) external payable override {
        // as the method is not restricted, we prevent nav inflation via a rogue token.
        require(isOwnedToken(token), TokenIsNotOwned());
    
        if (amount == 0) {
            return; // null amount is flag for rebalance check
        } else if (amount == 1) {
            // amount == 1 is flag for caller token balance
            amount = IERC20(token).balanceOf(msg.sender);
        }

        // TODO: what if donation is made in nativeCurrency?
        try IERC20(token).transferFrom(msg.sender, amount) {
            address baseToken = pool().baseToken;
            int256 convertedAmount = IEOracle(address(this)).convertTokenAmount(token, amount.toInt256(), baseToken);
            // TODO: simply define baseTokenVirtualBalance int256 in a library
            virtualBalances[baseToken] -= IEOracle(address(this)).convertTokenAmount(token, amount.toInt256(), baseToken);
        } catch {
            revert DonateTransferFromFailer();
        }
    }

    /*
     * PUBLIC METHODS
     */
    function decimals() public view virtual override returns (uint8);
    function isOperator(address holder, address operator) public view virtual returns (bool approved);

    /*
     * INTERNAL METHODS
     */
    function _updateNav() internal virtual returns (NavComponents memory);

    function _getFeeCollector() internal view virtual returns (address);

    function _getMinPeriod() internal view virtual returns (uint48);

    /// @dev Returns the spread, or _MAX_SPREAD if not set
    function _getSpread() internal view virtual returns (uint16);

    function _getTokenJar() internal view virtual returns (address);

    /*
     * PRIVATE METHODS
     */
    function _mint(
        address recipient,
        uint256 amountIn,
        uint256 amountOutMin,
        address tokenIn
    ) private returns (uint256) {
        require(recipient != _ZERO_ADDRESS, PoolMintInvalidRecipient());
        require(msg.sender == recipient || isOperator(recipient, msg.sender), InvalidOperator());
        NavComponents memory components = _updateNav();
        address kycProvider = poolParams().kycProvider;

        // require whitelisted user if kyc is enforced
        if (!kycProvider.isAddressZero()) {
            require(IKyc(kycProvider).isWhitelistedUser(recipient), PoolCallerNotWhitelisted());
        }

        _assertBiggerThanMinimum(amountIn);
        uint256 spread = (amountIn * _getSpread()) / _SPREAD_BASE;

        if (tokenIn == _BASE_TOKEN_FLAG) {
            tokenIn = components.baseToken;
        }

        if (tokenIn.isAddressZero()) {
            require(msg.value == amountIn, PoolMintAmountIn());
            _getTokenJar().safeTransferNative(spread);
        } else {
            tokenIn.safeTransferFrom(msg.sender, address(this), amountIn);
            tokenIn.safeTransfer(_getTokenJar(), spread);
        }

        amountIn -= spread;

        if (tokenIn != components.baseToken) {
            // convert the tokenIn amount into base token amount BEFORE calculating mintedAmount
            amountIn = uint256(
                IEOracle(address(this)).convertTokenAmount(tokenIn, amountIn.toInt256(), components.baseToken)
            );
        }

        uint256 mintedAmount = (amountIn * 10 ** components.decimals) / components.unitaryValue;
        poolTokens().totalSupply += mintedAmount;

        // allocate pool token transfers and log events.
        uint256 recipientAmount = _allocateMintTokens(recipient, mintedAmount);
        require(recipientAmount >= amountOutMin, PoolMintOutputAmount());
        return recipientAmount;
    }

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
        poolTokens().totalSupply -= burntAmount;

        netRevenue = (burntAmount * components.unitaryValue) / 10 ** decimals();

        address baseToken = pool().baseToken;

        if (tokenOut == _BASE_TOKEN_FLAG) {
            tokenOut = baseToken;
        } else if (tokenOut != baseToken) {
            // only allow arbitrary token redemption as a fallback in case the pool does not hold enough base currency
            uint256 baseTokenBalance = baseToken.isAddressZero()
                ? address(this).balance
                : IERC20(baseToken).balanceOf(address(this));
            require(netRevenue > baseTokenBalance, BaseTokenBalance());

            // an active token must have a price feed, hence the oracle query will always return a converted value
            netRevenue = uint256(
                IEOracle(address(this)).convertTokenAmount(baseToken, netRevenue.toInt256(), tokenOut)
            );
        }

        uint256 spread = (netRevenue * _getSpread()) / _SPREAD_BASE;
        netRevenue -= spread;

        require(netRevenue >= amountOutMin, PoolBurnOutputAmount());

        if (tokenOut.isAddressZero()) {
            msg.sender.safeTransferNative(netRevenue);
            _getTokenJar().safeTransferNative(spread);
        } else {
            tokenOut.safeTransfer(msg.sender, netRevenue);
            tokenOut.safeTransfer(_getTokenJar(), spread);
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
            PoolAmountSmallerThanMinimum(_MINIMUM_ORDER_DIVISOR)
        );
    }
}
