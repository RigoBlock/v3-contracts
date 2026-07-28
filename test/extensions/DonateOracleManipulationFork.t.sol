// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Constants} from "../../contracts/test/Constants.sol";
import {RealDeploymentFixture} from "../fixtures/RealDeploymentFixture.sol";

import {ISmartPoolActions} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolActions.sol";
import {ISmartPoolState} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolState.sol";
import {SafeTransferLib} from "../../contracts/protocol/libraries/SafeTransferLib.sol";
import {IECrosschain} from "../../contracts/protocol/extensions/adapters/interfaces/IECrosschain.sol";
import {IEOracle} from "../../contracts/protocol/extensions/adapters/interfaces/IEOracle.sol";
import {OpType, DestinationMessageParams} from "../../contracts/protocol/types/Crosschain.sol";
import {VirtualStorageLib} from "../../contracts/protocol/libraries/VirtualStorageLib.sol";
import {IOracle} from "../../contracts/protocol/interfaces/IOracle.sol";
import {NetAssetsValue} from "../../contracts/protocol/types/NavComponents.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @title DonateOracleManipulationForkTest
/// @notice Fork test that verifies BackGeoOracle price manipulation between the two donate
///         phases cannot create phantom virtual supply.
/// @dev Uses the real Ethereum deployment and mocks oracle.observe() to simulate realistic
///      non-base-token price moves. Any non-base-token price change is caught by the NAV
///      integrity check before any virtual supply can be minted.
contract DonateOracleManipulationForkTest is Test, RealDeploymentFixture {
    using SafeTransferLib for address;

    /// @notice Approximate tick change for a 10% price move (log_{1.0001}(1.1) ≈ 953 ticks).
    int24 internal constant TICK_CHANGE = 1000;

    function setUp() public {
        address[] memory baseTokens = new address[](1);
        // Use WETH as base so we can manipulate the USDC oracle (cardinality 125) as the
        // non-base asset held by the pool.
        baseTokens[0] = Constants.ETH_WETH;
        deployFixture(baseTokens);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            ORACLE MOCK HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    function _getSecondsAgos(uint16 cardinality) private view returns (uint32[] memory secondsAgos) {
        uint16 blockTime = block.chainid == 1 ? 8 : 1;
        // Match EOracle.sol: N observations span at most (N - 1) * blockTime seconds.
        uint32 maxSecondsAgos = cardinality > 1 ? uint32(uint16(cardinality - 1) * blockTime) : 1;
        secondsAgos = new uint32[](2);
        secondsAgos[0] = maxSecondsAgos > 300 ? 300 : maxSecondsAgos;
        secondsAgos[1] = 0;
    }

    /// @notice Build vm.mockCall parameters for oracle.observe() that shift the TWAP by
    ///         `tickChange` ticks for the ETH/token pool used by EOracle.
    function _getOracleMockParams(
        address token,
        int24 tickChange
    ) private view returns (address mockTarget, bytes memory mockCalldata, bytes memory mockReturnData) {
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: 0,
            tickSpacing: TickMath.MAX_TICK_SPACING,
            hooks: IHooks(Constants.ORACLE)
        });

        IOracle.ObservationState memory state = IOracle(Constants.ORACLE).getState(poolKey);
        require(state.cardinality > 0, "Oracle pool not initialized");

        uint32[] memory secondsAgos = _getSecondsAgos(state.cardinality);

        (int48[] memory origTickCumulatives, uint144[] memory liquidity) = IOracle(Constants.ORACLE).observe(
            poolKey,
            secondsAgos
        );

        int56 origDelta = int56(origTickCumulatives[1]) - int56(origTickCumulatives[0]);
        int56 timeDelta = int56(uint56(secondsAgos[0]));
        int24 origTwap = int24(origDelta / timeDelta);
        int24 newTwap = origTwap + tickChange;

        int56 newDelta = int56(newTwap) * timeDelta;
        int48[] memory mockedTickCumulatives = new int48[](2);
        mockedTickCumulatives[0] = int48(int56(origTickCumulatives[1]) - newDelta);
        mockedTickCumulatives[1] = origTickCumulatives[1];

        mockTarget = Constants.ORACLE;
        mockCalldata = abi.encodeWithSelector(IOracle.observe.selector, poolKey, secondsAgos);
        mockReturnData = abi.encode(mockedTickCumulatives, liquidity);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            TESTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice A legitimate WETH donation on a WETH-base pool that also holds a non-base token
    ///         succeeds and creates virtual supply backed by the transferred assets.
    function test_OracleManipulation_LegitimateDonation_Succeeds() public {
        vm.selectFork(mainnetForkId);
        address pool = pool();
        bytes32 vsSlot = VirtualStorageLib.VIRTUAL_SUPPLY_SLOT;

        // Add USDC to the pool via a Sync donation so the pool holds a non-base asset
        // without creating virtual supply.
        uint256 usdcAmount = 10_000e6;
        deal(Constants.ETH_USDC, address(this), usdcAmount);

        IECrosschain(pool).donate(
            Constants.ETH_USDC,
            1,
            DestinationMessageParams({opType: OpType.Sync, shouldUnwrapNative: false})
        );
        Constants.ETH_USDC.safeTransfer(pool, usdcAmount);
        IECrosschain(pool).donate(
            Constants.ETH_USDC,
            usdcAmount,
            DestinationMessageParams({opType: OpType.Sync, shouldUnwrapNative: false})
        );

        int256 vsBefore = int256(uint256(vm.load(pool, vsSlot)));

        // Now donate WETH (the base token) in Transfer mode.
        uint256 donationAmount = 10 ether;
        deal(Constants.ETH_WETH, address(this), donationAmount);

        uint256 navBefore = ISmartPoolState(pool).getPoolTokens().unitaryValue;

        IECrosschain(pool).donate(
            Constants.ETH_WETH,
            1,
            DestinationMessageParams({opType: OpType.Transfer, shouldUnwrapNative: false})
        );
        Constants.ETH_WETH.safeTransfer(pool, donationAmount);
        IECrosschain(pool).donate(
            Constants.ETH_WETH,
            donationAmount,
            DestinationMessageParams({opType: OpType.Transfer, shouldUnwrapNative: false})
        );

        int256 vsAfter = int256(uint256(vm.load(pool, vsSlot)));
        assertGt(vsAfter - vsBefore, 0, "Transfer donation should create positive virtual supply");

        uint256 navAfter = ISmartPoolState(pool).getPoolTokens().unitaryValue;
        assertGe(navAfter, navBefore, "Legitimate donation must not decrease NAV per share");
    }

    /// @dev Common helper for oracle-manipulation tests. Pre-loads the pool with USDC via Sync,
    ///      starts a WETH Transfer donation, mocks the USDC oracle by `tickChange` ticks,
    ///      and asserts that phase 2 reverts with NavManipulationDetected.
    function _runOracleManipulationTest(int24 tickChange) private {
        vm.selectFork(mainnetForkId);
        address pool = pool();

        // Pre-load the pool with USDC via a Sync donation (no virtual supply).
        uint256 usdcAmount = 10_000e6;
        deal(Constants.ETH_USDC, address(this), usdcAmount);

        IECrosschain(pool).donate(
            Constants.ETH_USDC,
            1,
            DestinationMessageParams({opType: OpType.Sync, shouldUnwrapNative: false})
        );
        Constants.ETH_USDC.safeTransfer(pool, usdcAmount);
        IECrosschain(pool).donate(
            Constants.ETH_USDC,
            usdcAmount,
            DestinationMessageParams({opType: OpType.Sync, shouldUnwrapNative: false})
        );

        int256 vsBefore = int256(uint256(vm.load(pool, VirtualStorageLib.VIRTUAL_SUPPLY_SLOT)));

        // Capture the asset snapshot that phase 1 will store in transient storage.
        NetAssetsValue memory snapshot = ISmartPoolActions(pool).updateUnitaryValue();

        // Start a WETH donation phase 1 (uses the real oracle).
        IECrosschain(pool).donate(
            Constants.ETH_WETH,
            1,
            DestinationMessageParams({opType: OpType.Transfer, shouldUnwrapNative: false})
        );

        // Capture the unmocked conversion before installing the mock, so we can prove the mock
        // actually changes the TWAP used by EOracle.
        int256 originalConversion = IEOracle(pool).convertTokenAmount(Constants.ETH_USDC, 1e6, Constants.ETH_WETH);

        // Mock the USDC oracle.
        (address mockTarget, bytes memory mockCalldata, bytes memory mockReturnData) = _getOracleMockParams(
            Constants.ETH_USDC,
            tickChange
        );
        vm.mockCall(mockTarget, mockCalldata, mockReturnData);

        // Verify the mock actually affects the EOracle conversion path. The mocked tick changes the
        // ETH/USDC pool price. Because convertTokenAmount(USDC, 1e6, WETH) returns WETH per USDC,
        // a positive tick change (USDC per ETH increases) means each USDC is worth less WETH, while a
        // negative tick change means each USDC is worth more WETH.
        int256 mockedConversion = IEOracle(pool).convertTokenAmount(Constants.ETH_USDC, 1e6, Constants.ETH_WETH);
        assertNotEq(mockedConversion, originalConversion, "Mocked oracle should change USDC conversion");
        if (tickChange > 0) {
            assertLt(mockedConversion, originalConversion, "Positive tick change should decrease WETH per USDC");
        } else {
            assertGt(mockedConversion, originalConversion, "Negative tick change should increase WETH per USDC");
        }

        // Transfer the WETH expected by the donation.
        uint256 donationAmount = 10 ether;
        deal(Constants.ETH_WETH, address(this), donationAmount);
        Constants.ETH_WETH.safeTransfer(pool, donationAmount);

        // Compute the NAV that _validateNavIntegrity will compare against expectedAssets. It uses
        // the mocked oracle, so it diverges from the snapshot + donationAmount equality.
        NetAssetsValue memory currentNav = ISmartPoolActions(pool).updateUnitaryValue();
        uint256 expectedAssets = snapshot.netTotalValue + donationAmount;

        // amountDelta equals donationAmount, so CallerTransferAmount passes and the revert
        // must come from the NAV integrity check.
        vm.expectRevert(
            abi.encodeWithSelector(
                IECrosschain.NavManipulationDetected.selector,
                expectedAssets,
                currentNav.netTotalValue
            )
        );
        IECrosschain(pool).donate(
            Constants.ETH_WETH,
            donationAmount,
            DestinationMessageParams({opType: OpType.Transfer, shouldUnwrapNative: false})
        );

        vm.clearMockedCalls();

        int256 vsAfter = int256(uint256(vm.load(pool, VirtualStorageLib.VIRTUAL_SUPPLY_SLOT)));
        assertEq(vsAfter, vsBefore, "No virtual supply should be created on reverted donation");
    }

    /// @notice A BackGeoOracle price increase of the non-base asset (USDC) between the two donate
    ///         phases triggers NavManipulationDetected and prevents any virtual-supply minting.
    function test_OracleManipulation_USDCPriceIncreaseBetweenPhases_Reverts() public {
        _runOracleManipulationTest(TICK_CHANGE);
    }

    /// @notice A BackGeoOracle price decrease of the non-base asset (USDC) between the two donate
    ///         phases also triggers NavManipulationDetected and prevents any virtual-supply minting.
    function test_OracleManipulation_USDCPriceDecreaseBetweenPhases_Reverts() public {
        _runOracleManipulationTest(-TICK_CHANGE);
    }

    /*//////////////////////////////////////////////////////////////////////////
                        DONATED-TOKEN ORACLE MANIPULATION
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Common helper for donated-token oracle manipulation. Pre-loads the pool with USDC via a
    ///      Sync donation so USDC is already an active asset, then starts a USDC Transfer donation and
    ///      manipulates the USDC oracle between the two phases. The NAV integrity check must revert
    ///      because the storedAssets snapshot used the old price while the final NAV uses the new one.
    function _runDonatedTokenOracleManipulationTest(int24 tickChange) private {
        vm.selectFork(mainnetForkId);
        address pool = pool();

        // Pre-load the pool with USDC via a Sync donation so USDC is active in the NAV snapshot.
        uint256 usdcAmount = 10_000e6;
        deal(Constants.ETH_USDC, address(this), usdcAmount);

        IECrosschain(pool).donate(
            Constants.ETH_USDC,
            1,
            DestinationMessageParams({opType: OpType.Sync, shouldUnwrapNative: false})
        );
        Constants.ETH_USDC.safeTransfer(pool, usdcAmount);
        IECrosschain(pool).donate(
            Constants.ETH_USDC,
            usdcAmount,
            DestinationMessageParams({opType: OpType.Sync, shouldUnwrapNative: false})
        );

        int256 vsBefore = int256(uint256(vm.load(pool, VirtualStorageLib.VIRTUAL_SUPPLY_SLOT)));

        // Capture the asset snapshot that phase 1 will store in transient storage.
        NetAssetsValue memory snapshot = ISmartPoolActions(pool).updateUnitaryValue();

        // Start a USDC Transfer donation phase 1 (uses the real oracle).
        IECrosschain(pool).donate(
            Constants.ETH_USDC,
            1,
            DestinationMessageParams({opType: OpType.Transfer, shouldUnwrapNative: false})
        );

        // Capture the unmocked conversion before installing the mock, so we can prove the mock
        // actually changes the TWAP used by EOracle.
        int256 originalConversion = IEOracle(pool).convertTokenAmount(Constants.ETH_USDC, 1e6, Constants.ETH_WETH);

        // Mock the USDC oracle.
        (address mockTarget, bytes memory mockCalldata, bytes memory mockReturnData) = _getOracleMockParams(
            Constants.ETH_USDC,
            tickChange
        );
        vm.mockCall(mockTarget, mockCalldata, mockReturnData);

        // Verify the mock actually affects the EOracle conversion path. The mocked tick changes the
        // ETH/USDC pool price. Because convertTokenAmount(USDC, 1e6, WETH) returns WETH per USDC,
        // a positive tick change (USDC per ETH increases) means each USDC is worth less WETH, while a
        // negative tick change means each USDC is worth more WETH.
        int256 mockedConversion = IEOracle(pool).convertTokenAmount(Constants.ETH_USDC, 1e6, Constants.ETH_WETH);
        assertNotEq(mockedConversion, originalConversion, "Mocked oracle should change USDC conversion");
        if (tickChange > 0) {
            assertLt(mockedConversion, originalConversion, "Positive tick change should decrease WETH per USDC");
        } else {
            assertGt(mockedConversion, originalConversion, "Negative tick change should increase WETH per USDC");
        }

        // Transfer the USDC expected by the donation.
        uint256 donationAmount = 10_000e6;
        deal(Constants.ETH_USDC, address(this), donationAmount);
        Constants.ETH_USDC.safeTransfer(pool, donationAmount);

        // Compute the NAV that _validateNavIntegrity will compare against expectedAssets. It uses
        // the mocked oracle, so it diverges from the snapshot + donationAmount equality.
        NetAssetsValue memory currentNav = ISmartPoolActions(pool).updateUnitaryValue();
        uint256 expectedAssets = snapshot.netTotalValue +
            uint256(IEOracle(pool).convertTokenAmount(Constants.ETH_USDC, int256(donationAmount), Constants.ETH_WETH));

        // amountDelta equals donationAmount, so CallerTransferAmount passes and the revert
        // must come from the NAV integrity check.
        vm.expectRevert(
            abi.encodeWithSelector(
                IECrosschain.NavManipulationDetected.selector,
                expectedAssets,
                currentNav.netTotalValue
            )
        );
        IECrosschain(pool).donate(
            Constants.ETH_USDC,
            donationAmount,
            DestinationMessageParams({opType: OpType.Transfer, shouldUnwrapNative: false})
        );

        vm.clearMockedCalls();

        int256 vsAfter = int256(uint256(vm.load(pool, VirtualStorageLib.VIRTUAL_SUPPLY_SLOT)));
        assertEq(vsAfter, vsBefore, "No virtual supply should be created on reverted donation");
    }

    /// @notice A BackGeoOracle price increase of the donated token (USDC) between the two donate
    ///         phases triggers NavManipulationDetected and prevents any virtual-supply minting.
    function test_OracleManipulation_DonatedTokenPriceIncreaseBetweenPhases_Reverts() public {
        _runDonatedTokenOracleManipulationTest(TICK_CHANGE);
    }

    /// @notice A BackGeoOracle price decrease of the donated token (USDC) between the two donate
    ///         phases also triggers NavManipulationDetected and prevents any virtual-supply minting.
    function test_OracleManipulation_DonatedTokenPriceDecreaseBetweenPhases_Reverts() public {
        _runDonatedTokenOracleManipulationTest(-TICK_CHANGE);
    }
}
