// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {UnitTestFixture} from "../fixtures/UnitTestFixture.sol";
import {Constants} from "../../contracts/test/Constants.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";
import {IEOracle} from "../../contracts/protocol/extensions/adapters/interfaces/IEOracle.sol";
import {ISmartPoolOwnerActions} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolOwnerActions.sol";
import {IRigoblockPoolProxyFactory} from "../../contracts/protocol/interfaces/IRigoblockPoolProxyFactory.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {EnumerableSet} from "../../contracts/protocol/libraries/EnumerableSet.sol";

/// @title EOracleCardinalityTest - Regression tests for the cardinality-1 oracle guard.
/// @notice A BackGeoOracle feed with only one observation cannot compute a meaningful TWAP.
///         `EOracle.hasPriceFeed()` must reject cardinality-1 feeds so they cannot be added
///         to a pool's active token set and cannot be priced on the NAV path.
contract EOracleCardinalityTest is Test, UnitTestFixture {
    address internal token;
    address internal poolProxy;

    function setUp() public {
        deployFixture();

        // Deploy a mock token at a deterministic address for the oracle pool key.
        token = makeAddr("testToken");
        deployCodeTo("out/MockERC20.sol/MockERC20.json", abi.encode("Test Token", "TEST", 18), token);

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
}
