// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {UnitTestFixture} from "../fixtures/UnitTestFixture.sol";
import {Constants} from "../../contracts/test/Constants.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";
import {EOracle} from "../../contracts/protocol/extensions/EOracle.sol";
import {IEOracle} from "../../contracts/protocol/extensions/adapters/interfaces/IEOracle.sol";
import {ISmartPoolOwnerActions} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolOwnerActions.sol";
import {IRigoblockPoolProxyFactory} from "../../contracts/protocol/interfaces/IRigoblockPoolProxyFactory.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {EnumerableSet} from "../../contracts/protocol/libraries/EnumerableSet.sol";

/// @title EOracleCardinalityTest - Regression tests for EOracle conversion and cardinality guards.
/// @notice A BackGeoOracle feed with only one observation cannot compute a meaningful TWAP.
///         `EOracle.hasPriceFeed()` must reject cardinality-1 feeds so they cannot be added
///         to a pool's active token set and cannot be priced on the NAV path.
///         Also covers the sqrtPriceX96^2 overflow fix for extreme TWAP ticks.
contract EOracleCardinalityTest is Test, UnitTestFixture {
    using PoolIdLibrary for PoolKey;

    address internal token;
    address internal poolProxy;

    /// @dev HyperEVM-like EOracle: no BackGeoOracle is deployed, so the oracle hook address is zero.
    ///      Only identity conversions are possible on such a deployment (USDC numeraire pools).
    EOracle internal noOracleEOracle;
    address internal usdc;

    function setUp() public {
        deployFixture();

        // Deploy a mock token at a deterministic address for the oracle pool key.
        token = makeAddr("testToken");
        deployCodeTo("out/MockERC20.sol/MockERC20.json", abi.encode("Test Token", "TEST", 18), token);

        usdc = makeAddr("usdc");
        noOracleEOracle = new EOracle(address(0), deployment.wrappedNative);

        (poolProxy, ) = IRigoblockPoolProxyFactory(deployment.factory).createPool("test pool", "TEST", address(0));
    }

    function _poolKey(address _token) private view returns (PoolKey memory) {
        return
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(_token),
                fee: 0,
                tickSpacing: TickMath.MAX_TICK_SPACING,
                hooks: IHooks(address(deployment.mockOracle))
            });
    }

    /// @notice A freshly-initialized oracle has cardinality 2 and should be accepted.
    function test_CardinalityTwo_HasPriceFeed() public {
        deployment.mockOracle.initializeObservations(_poolKey(token));
        assertTrue(IEOracle(extensions.eOracle).hasPriceFeed(token));
    }

    /// @notice The minimum usable cardinality (2) must produce a valid TWAP without reverting.
    ///         The mock's second observation has prevTick = 200, so after warping forward the
    ///         1-second TWAP returned by EOracle equals 200.
    function test_CardinalityTwo_GetTwapSucceeds() public {
        deployment.mockOracle.initializeObservations(_poolKey(token));
        vm.warp(block.timestamp + 100);
        assertEq(IEOracle(extensions.eOracle).getTwap(token), int24(200));
    }

    /// @notice A cardinality-1 oracle must be rejected by hasPriceFeed.
    function test_CardinalityOne_HasPriceFeedFalse() public {
        PoolKey memory key = _poolKey(token);
        deployment.mockOracle.initializeObservations(key);
        deployment.mockOracle.setState(key, 0, 1, 1);

        assertFalse(IEOracle(extensions.eOracle).hasPriceFeed(token));
    }

    /// @notice Because hasPriceFeed rejects cardinality-1 feeds, a pool owner cannot add
    ///         such a token as an acceptable mint token. addUnique reverts with the
    ///         TokenPriceFeedDoesNotExist error.
    function test_CardinalityOne_CannotAddAcceptableMintToken() public {
        PoolKey memory key = _poolKey(token);
        deployment.mockOracle.initializeObservations(key);
        deployment.mockOracle.setState(key, 0, 1, 1);

        vm.expectRevert(abi.encodeWithSelector(EnumerableSet.TokenPriceFeedDoesNotExist.selector, token));
        ISmartPoolOwnerActions(poolProxy).setAcceptableMintToken(token, true);
    }

    /// @notice Helper to initialize a constant-TWAP oracle feed and warp forward so getTwap returns `tick`.
    function _initOracleTick(int24 tick) private {
        deployment.mockOracle.initializeObservationsWithTick(_poolKey(token), tick);
        vm.warp(block.timestamp + 100);
    }

    /// @notice Ticks <= 443,636 are safe even with the old square-then-divide math.
    function test_ConvertTokenAmount_BoundaryTick_Succeeds() public {
        _initOracleTick(int24(443_636));
        int256 converted = IEOracle(extensions.eOracle).convertTokenAmount(address(0), 1e18, token);
        assertGt(converted, 0);
    }

    /// @notice Tick 443,637 is the first tick where sqrtPriceX96 > 2^128 and squaring overflows uint256.
    /// @dev Before the fix this reverted with panic 0x11; after the fix it returns a positive amount.
    function test_ConvertTokenAmount_OverflowBoundaryTick_Succeeds() public {
        _initOracleTick(int24(443_637));
        int256 converted = IEOracle(extensions.eOracle).convertTokenAmount(address(0), 1e18, token);
        assertGt(converted, 0);
    }

    /// @notice Realistic memecoin-like positive tick (PEPE vs ETH) well past the overflow boundary.
    function test_ConvertTokenAmount_HighPositiveTick_Succeeds() public {
        _initOracleTick(int24(500_000));
        int256 converted = IEOracle(extensions.eOracle).convertTokenAmount(address(0), 1e18, token);
        assertGt(converted, 0);
    }

    /// @notice Symmetric negative-conversion-tick path: token -> ETH with a very expensive token.
    function test_ConvertTokenAmount_HighNegativeConversionTick_Succeeds() public {
        _initOracleTick(int24(-500_000));
        int256 converted = IEOracle(extensions.eOracle).convertTokenAmount(token, 1e18, address(0));
        assertGt(converted, 0);
    }

    /// @notice Regression: an identity conversion (token == targetToken) must never consult the
    ///         oracle. On HyperEVM no BackGeoOracle is deployed (oracle hook = address(0)), so an
    ///         eager getTwap(targetToken) reverts and bricked cross-chain donate finalization for
    ///         USDC-denominated pools.
    function test_ConvertTokenAmount_IdentityWithoutOracle_Succeeds() public {
        int256 amount = 123_456e6;
        assertEq(noOracleEOracle.convertTokenAmount(usdc, amount, usdc), amount);

        // also holds for the wrapped native token identity
        int256 nativeAmount = 1e18;
        assertEq(
            noOracleEOracle.convertTokenAmount(deployment.wrappedNative, nativeAmount, deployment.wrappedNative),
            nativeAmount
        );
    }

    /// @notice A zero amount must return 0 without consulting the oracle, even for a
    ///         non-identity target token that has no price feed.
    function test_ConvertTokenAmount_ZeroAmountWithoutOracle_Succeeds() public {
        assertEq(noOracleEOracle.convertTokenAmount(usdc, 0, token), 0);
    }

    /// @notice Regression: a batch consisting only of identity conversions must not compute the
    ///         target TWAP. Before the lazy-TWAP fix, convertBatchTokenAmounts([usdc], [x], usdc)
    ///         eagerly called getTwap(usdc) and reverted on oracle-less deployments (HyperEVM).
    function test_ConvertBatchTokenAmounts_IdentityOnlyWithoutOracle_Succeeds() public {
        address[] memory tokens = new address[](3);
        tokens[0] = usdc;
        tokens[1] = usdc;
        tokens[2] = usdc;
        int256[] memory amounts = new int256[](3);
        amounts[0] = 100e6;
        amounts[1] = 0; // zero-amount element must also skip the oracle
        amounts[2] = 250e6;

        assertEq(noOracleEOracle.convertBatchTokenAmounts(tokens, amounts, usdc), 350e6);
    }

    /// @notice The target TWAP must be computed lazily: a batch whose elements are all identity
    ///         conversions must succeed even when the target token has no initialized feed.
    function test_ConvertBatchTokenAmounts_IdentityOnlyTokenWithoutFeed_Succeeds() public {
        // `token` has no initialized observations, so getTwap(token) would revert.
        assertFalse(IEOracle(extensions.eOracle).hasPriceFeed(token));

        address[] memory tokens = new address[](1);
        tokens[0] = token;
        int256[] memory amounts = new int256[](1);
        amounts[0] = 7e18;

        assertEq(IEOracle(extensions.eOracle).convertBatchTokenAmounts(tokens, amounts, token), 7e18);
    }

    /// @notice A batch mixing a real conversion and an identity element must convert only the
    ///         non-identity element, using the same TWAP as a single conversion.
    function test_ConvertBatchTokenAmounts_MixedIdentityAndConversion_Succeeds() public {
        _initOracleTick(int24(200));

        address[] memory tokens = new address[](2);
        tokens[0] = address(0);
        tokens[1] = token;
        int256[] memory amounts = new int256[](2);
        amounts[0] = 1e18;
        amounts[1] = 5e17;

        int256 total = IEOracle(extensions.eOracle).convertBatchTokenAmounts(tokens, amounts, token);
        int256 single = IEOracle(extensions.eOracle).convertTokenAmount(address(0), 1e18, token);
        assertEq(total, single + 5e17);
    }

    /// @notice Non-identity conversions still require a live feed: on an oracle-less deployment
    ///         they must revert rather than return a bogus value.
    function test_ConvertTokenAmount_NonIdentityWithoutOracle_Reverts() public {
        try noOracleEOracle.convertTokenAmount(usdc, 1e6, token) {
            revert("non-identity conversion should revert without oracle");
        } catch {
            // expected: no oracle deployed
        }
    }

    // -------------------------------------------------------------------------
    // Regression: uint16 overflow panic in _getSecondsAgos at high cardinality on mainnet
    // -------------------------------------------------------------------------

    /// @notice Initialize a constant-tick-200 feed, raise its cardinality via setState, and plant a
    ///         valid observation at the last index so the mock's observe() (which iterates up to
    ///         cardinality) resolves both TWAP queries to consistent cumulatives instead of an
    ///         uninitialized zero observation. Warps so that secondsAgo = 300 targets the first
    ///         observation (tickCumulative 0) and secondsAgo = 0 interpolates 300 seconds at tick
    ///         200 from the planted observation, i.e. TWAP = (60000 - 0) / 300 = 200.
    function _initHighCardinalityOracle(uint16 cardinality) private {
        PoolKey memory key = _poolKey(token);
        uint32 t0 = uint32(block.timestamp);
        deployment.mockOracle.initializeObservationsWithTick(key, 200);
        deployment.mockOracle.setState(key, cardinality - 1, cardinality, cardinality);

        // plant Observation{blockTimestamp: t0, prevTick: 200, tickCumulative: 0, initialized: true}
        // at observations[poolId][cardinality - 1] (first storage variable of MockOracle, slot 0;
        // the fixed-size array element sits at keccak256(poolId . 0) + index)
        bytes32 baseSlot = keccak256(abi.encode(key.toId(), uint256(0)));
        bytes32 obsSlot = bytes32(uint256(baseSlot) + uint256(cardinality - 1));
        uint256 word = (uint256(1) << 248) | (uint256(uint24(200)) << 32) | uint256(t0);
        vm.store(address(deployment.mockOracle), obsSlot, bytes32(word));

        vm.warp(t0 + 300);
    }

    /// @notice Boundary that always worked: cardinality 8192 on mainnet (blockTime 8) gives
    ///         (8192 - 1) * 8 = 65528, which still fits uint16. getTwap must return the
    ///         constant-200 TWAP.
    function test_Cardinality8192Mainnet_GetTwapSucceeds() public {
        vm.chainId(1);
        _initHighCardinalityOracle(8192);
        assertEq(IEOracle(extensions.eOracle).getTwap(token), int24(200));
    }

    /// @notice Regression: at cardinality 8193 on mainnet, the old formula
    ///         uint16((8193 - 1) * 8) = uint16(65536) overflowed and panicked with 0x11 inside
    ///         getTwap, bricking NAV updates for every pool holding the token. After the fix
    ///         getTwap returns the same TWAP as the low-cardinality case.
    function test_Cardinality8193Mainnet_GetTwapSucceeds() public {
        vm.chainId(1);
        _initHighCardinalityOracle(8193);
        assertEq(IEOracle(extensions.eOracle).getTwap(token), int24(200));
    }

    /// @notice Max uint16 cardinality 65535 on mainnet: (65535 - 1) * 8 = 524272. This case was
    ///         never exercised before the fix and panicked with 0x11.
    function test_CardinalityMaxMainnet_GetTwapSucceeds() public {
        vm.chainId(1);
        _initHighCardinalityOracle(65535);
        assertEq(IEOracle(extensions.eOracle).getTwap(token), int24(200));
    }

    /// @notice The NAV conversion path must also succeed at cardinality 8193 on mainnet (it
    ///         panicked with 0x11 before the fix).
    function test_Cardinality8193Mainnet_ConvertTokenAmountSucceeds() public {
        vm.chainId(1);
        _initHighCardinalityOracle(8193);
        int256 converted = IEOracle(extensions.eOracle).convertTokenAmount(address(0), 1e18, token);
        assertGt(converted, 0);
    }

    /// @notice secondsAgos capping: both cardinality 8192 and 8193 exceed the 300-second cap on
    ///         mainnet, so both must return the identical TWAP.
    function test_Cardinality8192vs8193Mainnet_SameTwap() public {
        vm.chainId(1);
        _initHighCardinalityOracle(8192);
        int24 twap8192 = IEOracle(extensions.eOracle).getTwap(token);
        _initHighCardinalityOracle(8193);
        int24 twap8193 = IEOracle(extensions.eOracle).getTwap(token);
        assertEq(twap8192, int24(200));
        assertEq(twap8192, twap8193);
    }
}
