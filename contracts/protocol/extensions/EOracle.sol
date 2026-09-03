// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {SafeCast} from "@openzeppelin-legacy/contracts/utils/math/SafeCast.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IEOracle} from "./adapters/interfaces/IEOracle.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {HyperliquidLib} from "../libraries/HyperliquidLib.sol";
import {HLConstants} from "hyper-evm-lib/common/HLConstants.sol";

contract EOracle is IEOracle {
    using TickMath for int24;
    using SafeCast for uint256;

    address private constant _ZERO_ADDRESS = address(0);
    uint256 private constant Q96 = 2 ** 96;
    int24 private constant _TWAP_UNSET = type(int24).max;

    address private immutable _wrappedNative;
    IOracle private immutable _oracle;

    constructor(address oracleHookAddress, address wrappedNative) {
        _wrappedNative = wrappedNative;
        _oracle = IOracle(oracleHookAddress);
    }

    /// @inheritdoc IEOracle
    function convertBatchTokenAmounts(
        address[] calldata tokens,
        int256[] calldata amounts,
        address targetToken
    ) external view returns (int256 totalConvertedAmount) {
        totalConvertedAmount = _convertTokenAmounts(tokens, amounts, targetToken);
    }

    /// @inheritdoc IEOracle
    function convertTokenAmount(
        address token,
        int256 amount,
        address targetToken
    ) external view override returns (int256 convertedAmount) {
        address[] memory tokens = new address[](1);
        int256[] memory amounts = new int256[](1);
        tokens[0] = token;
        amounts[0] = amount;
        convertedAmount = _convertTokenAmounts(tokens, amounts, targetToken);
    }

    function _convertTokenAmounts(
        address[] memory tokens,
        int256[] memory amounts,
        address targetToken
    ) private view returns (int256 total) {
        if (targetToken == _wrappedNative) targetToken = _ZERO_ADDRESS;

        int24 nativeToTargetTwap = _TWAP_UNSET;
        int256 amount;
        address token;

        for (uint256 i = 0; i < tokens.length; i++) {
            amount = amounts[i];
            token = tokens[i];

            // early return when oracle call is not needed
            if (amount == 0 || token == targetToken) {
                total += amount;
                continue;
            }

            if (nativeToTargetTwap == _TWAP_UNSET) {
                nativeToTargetTwap = targetToken == _ZERO_ADDRESS ? int24(0) : getTwap(targetToken);
            }

            if (token == _wrappedNative) token = _ZERO_ADDRESS;

            uint256 absAmount = uint256(amount >= 0 ? amount : -amount);
            int24 conversionTick;
            if (token == _ZERO_ADDRESS) {
                conversionTick = nativeToTargetTwap;
            } else if (targetToken == _ZERO_ADDRESS) {
                conversionTick = -getTwap(token);
            } else {
                conversionTick = -(getTwap(token) - nativeToTargetTwap);
                if (conversionTick < TickMath.MIN_TICK || conversionTick > TickMath.MAX_TICK) {
                    continue;
                }
            }

            uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(conversionTick);
            // Compute price using FullMath.mulDiv to avoid the intermediate sqrtPriceX96^2 overflow for tick > 443,636
            uint256 priceX96 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), Q96);
            uint256 tokenAmount = FullMath.mulDiv(absAmount, priceX96, Q96);
            total += amount >= 0 ? tokenAmount.toInt256() : -tokenAmount.toInt256();
        }
    }

    /// @inheritdoc IEOracle
    function hasPriceFeed(address token) external view returns (bool) {
        // On HyperEVM there is no BackGeoOracle / Uniswap V4 deployment.
        // USDC is Hyperliquid's collateral and numeraire, so it is the only token treated as having a feed.
        if (block.chainid == HyperliquidLib.HYPEREVM_CHAIN_ID) {
            return token == HLConstants.usdc();
        }
        if (token == _ZERO_ADDRESS || token == _wrappedNative) {
            return true;
        }
        // cardinality > 1 means the oracle pool has at least two observations.
        (, IOracle.ObservationState memory state) = _getPool(_ZERO_ADDRESS, token, _oracle);
        return state.cardinality > 1;
    }

    /// @inheritdoc IEOracle
    function getTwap(address token) public view override returns (int24 twap) {
        PoolKey memory key;
        IOracle.ObservationState memory state;

        if (token == _ZERO_ADDRESS || token == _wrappedNative) {
            // tick = 0 implies price of 1
            return 0;
        } else {
            (key, state) = _getPool(_ZERO_ADDRESS, token, _oracle);

            // get twap from oracle
            uint32[] memory secondsAgos = _getSecondsAgos(state.cardinality);
            (int48[] memory tickCumulatives, ) = _oracle.observe(key, secondsAgos);
            return int24((tickCumulatives[1] - tickCumulatives[0]) / int56(int32(secondsAgos[0])));
        }
    }

    function _getPool(
        address token0,
        address token1,
        IOracle oracle
    ) private view returns (PoolKey memory key, IOracle.ObservationState memory state) {
        key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 0,
            tickSpacing: TickMath.MAX_TICK_SPACING,
            hooks: IHooks(address(oracle))
        });
        state = oracle.getState(key);
    }

    function _getSecondsAgos(uint16 cardinality) private view returns (uint32[] memory secondsAgos) {
        // blocktime cannot be lower than 8 seconds on Ethereum, 1 seconds on any other chain
        uint16 blockTime = block.chainid == 1 ? 8 : 1;
        uint32 maxSecondsAgos = uint32(uint16(cardinality - 1) * blockTime);
        secondsAgos = new uint32[](2);
        secondsAgos[0] = maxSecondsAgos > 300 ? 300 : maxSecondsAgos;
        secondsAgos[1] = 0;
    }
}
