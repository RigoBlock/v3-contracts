// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0 <0.9.0;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {MixinStorage} from "../immutable/MixinStorage.sol";
import {IEOracle} from "../../extensions/adapters/interfaces/IEOracle.sol";
import {IERC20} from "../../interfaces/IERC20.sol";
import {IKyc} from "../../interfaces/IKyc.sol";
import {IRigoblockV3PoolActions} from "../../interfaces/pool/IRigoblockV3PoolActions.sol";

abstract contract MixinActions is MixinStorage, ReentrancyGuardTransient {
    // TODO: check if we can unify some errors, and log info with them.
    error PoolAmountSmallerThanMinumum(uint16 minimumOrderDivisor);
    error PoolBurnNotEnough();
    error PoolBurnNullAmount();
    error PoolBurnOutputAmount();
    error PoolCallerNotWhitelisted();
    error PoolMinimumPeriodNotEnough();
    error PoolMintAmountIn();
    error PoolMintOutputAmount();
    error PoolSupplyIsNullOrDust();
    error PoolTokenNotActive();
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
    ) public payable override nonReentrant returns (uint256 recipientAmount) {
        address kycProvider = poolParams().kycProvider;

        // require whitelisted user if kyc is enforced
        if (kycProvider != _ZERO_ADDRESS) {
            require(IKyc(kycProvider).isWhitelistedUser(recipient), PoolCallerNotWhitelisted());
        }

        _assertBiggerThanMinimum(amountIn);

        if (pool().baseToken == _ZERO_ADDRESS) {
            require(msg.value == amountIn, PoolMintAmountIn());
        } else {
            _safeTransferFrom(msg.sender, address(this), amountIn);
        }

        uint256 unitaryValue = _updateNav();
        bool isOnlyHolder = poolTokens().totalSupply == accounts().userAccounts[recipient].userBalance;

        if (!isOnlyHolder) {
            // apply markup
            amountIn -= (amountIn * _getSpread()) / _SPREAD_BASE;
        }

        uint256 mintedAmount = (amountIn * 10 ** decimals()) / unitaryValue;
        require(mintedAmount > amountOutMin, PoolMintOutputAmount());
        poolTokens().totalSupply += mintedAmount;

        // allocate pool token transfers and log events.
        recipientAmount = _allocateMintTokens(recipient, mintedAmount);
    }

    /// @inheritdoc IRigoblockV3PoolActions
    function burn(uint256 amountIn, uint256 amountOutMin) external override nonReentrant returns (uint256 netRevenue) {
        netRevenue = _burn(amountIn, amountOutMin, _BASE_TOKEN_FLAG);
    }

    // TODO: test for potential abuse. Technically, if the token can be manipulated, a burn in base token can do just as much
    // harm as a burn in any token. Considering burn must happen after a certain period, a pool opeartor has time to sell illiquid tokens.
    // technically, this could be used for exchanging big quantities of tokens at market rate. Which is not a big deal. prob should
    // allow only if user does not have enough base tokens
    /// @inheritdoc IRigoblockV3PoolActions
    function burnForToken(
        uint256 amountIn,
        uint256 amountOutMin,
        address tokenOut
    ) external override nonReentrant returns (uint256 netRevenue) {
        // early revert if token does not have price feed, 0 is sentinel for token not being active. Removed token will revert later.
        // TODO: we also use type(uint256).max as flag for removed token
        require(activeTokensSet().positions[tokenOut] != 0, PoolTokenNotActive());
        netRevenue = _burn(amountIn, amountOutMin, tokenOut);
    }

    /// @inheritdoc IRigoblockV3PoolActions
    function setUnitaryValue() external override nonReentrant {
        // unitary value is updated only with non-dust supply
        require(poolTokens().totalSupply >= 1e2, PoolSupplyIsNullOrDust());
        _updateNav();
    }

    /*
     * PUBLIC METHODS
     */
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
        uint256 unitaryValue = _updateNav();

        /// @notice allocate pool token transfers and log events.
        uint256 burntAmount = _allocateBurnTokens(amountIn, userAccount.userBalance);
        bool isOnlyHolder = poolTokens().totalSupply == userAccount.userBalance;
        poolTokens().totalSupply -= burntAmount;

        if (!isOnlyHolder) {
            // apply markup
            burntAmount -= (burntAmount * _getSpread()) / _SPREAD_BASE;
        }

        // TODO: verify cases of possible underflow for small nav value
        netRevenue = (burntAmount * unitaryValue) / 10 ** decimals();

        address baseToken = pool().baseToken;

        // TODO: test how this could be exploited.
        if (tokenOut == _BASE_TOKEN_FLAG) {
            tokenOut = baseToken;
        } else if (tokenOut != baseToken) {
            // only allow arbitrary token redemption as a fallback in case the pool does not hold enough base currency
            require(netRevenue > IERC20(baseToken).balanceOf(address(this)), PoolBurnOutputAmount());
            try IEOracle(address(this)).convertTokenAmount(baseToken, netRevenue, tokenOut) returns (uint256 value) {
                netRevenue = value;
            } catch Error(string memory reason) {
                revert(reason);
            }
        }

        require(netRevenue >= amountOutMin, PoolBurnOutputAmount());

        if (tokenOut == _ZERO_ADDRESS) {
            require(address(this).balance >= netRevenue, PoolTransferFailed());
            payable(msg.sender).transfer(netRevenue);
        } else {
            _safeTransfer(tokenOut, msg.sender, netRevenue);
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

        // TODO: define from constants
        if (poolParams().transactionFee != uint256(0)) {
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

        // TODO: verify as this is inconsistent with mint, i.e. fee comes from user here, from null address in mint
        emit Transfer(msg.sender, _ZERO_ADDRESS, amountIn);
        return amountIn;
    }

    function _assertBiggerThanMinimum(uint256 amount) private view {
        require(
            amount >= 10 ** decimals() / _MINIMUM_ORDER_DIVISOR,
            PoolAmountSmallerThanMinumum(_MINIMUM_ORDER_DIVISOR)
        );
    }

    // TODO: use try/catch implementation
    function _safeTransfer(address token, address to, uint256 amount) private {
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory data) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        require(success && (data.length == 0 || abi.decode(data, (bool))), PoolTransferFailed());
    }

    // TODO: use our try/catch implementation
    function _safeTransferFrom(address from, address to, uint256 amount) private {
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory data) = pool().baseToken.call(
            abi.encodeCall(IERC20.transferFrom, (from, to, amount))
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), PoolTransferFromFailed());
    }
}
