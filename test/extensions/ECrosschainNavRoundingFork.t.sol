// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Constants} from "../../contracts/test/Constants.sol";
import {RealDeploymentFixture} from "../fixtures/RealDeploymentFixture.sol";
import {IERC20} from "../../contracts/protocol/interfaces/IERC20.sol";
import {ISmartPoolActions} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolActions.sol";
import {IECrosschain} from "../../contracts/protocol/extensions/adapters/interfaces/IECrosschain.sol";
import {IEOracle} from "../../contracts/protocol/extensions/adapters/interfaces/IEOracle.sol";
import {OpType, DestinationMessageParams} from "../../contracts/protocol/types/Crosschain.sol";
import {VirtualStorageLib} from "../../contracts/protocol/libraries/VirtualStorageLib.sol";

/// @title ECrosschainNavRoundingForkTest
/// @notice Regression for the production NavManipulationDetected incident (BSC vault, block 120895984):
///         the exact-equality NAV check reverted legitimate donations whenever the oracle's
///         fixed-point floor rounding misaligned between the snapshot conversion (dust and donated
///         delta converted separately) and the fresh single-pass NAV conversion (combined balance) -
///         a deterministic gap of exactly 1 wei.
/// @dev Uses the local (fixed) ECrosschain deployment from RealDeploymentFixture against the real
///      mainnet BackGeoOracle. The misaligning amount is found at runtime with local math
///      (convertTokenAmount(2^96) returns priceX96 exactly, so floor(a * p) == mulmod-style
///      mulDiv can be computed off-chain), so the test does not depend on a pinned price.
contract ECrosschainNavRoundingForkTest is Test, RealDeploymentFixture {
    function setUp() public {
        // WETH-base pool: USDC donations take the oracle-converted (non-base) branch,
        // the production shape of the incident (18-dec base token receiving a stablecoin).
        address[] memory baseTokens = new address[](1);
        baseTokens[0] = Constants.ETH_WETH;
        deployFixture(baseTokens);
        vm.selectFork(mainnetForkId);
    }

    /// @notice Finds a dust adjustment and donation amount where the two groupings of the oracle
    ///         conversion diverge: convert(dust) + convert(x) < convert(dust + x).
    /// @dev Computed locally from a single oracle call: convertTokenAmount(token, 2^96) returns
    ///      priceX96 exactly, so floor(a * p) = (a * priceX96) / 2^96 and only the fractional
    ///      remainders (via mulmod) decide whether the two groupings differ. The dust adjustment
    ///      widens its fraction into [0.75, 0.95] so a small candidate triggers the gap.
    function _findMisaligningAmount(
        address pool,
        address token,
        address baseToken,
        uint256 dust
    ) internal view returns (uint256 adj, uint256 donation) {
        uint256 q96 = uint256(1) << 96;
        uint256 priceX96 = uint256(IEOracle(pool).convertTokenAmount(token, int256(q96), baseToken));

        for (uint256 candidate = 0; candidate < 10_000; candidate++) {
            uint256 frac = mulmod(dust + candidate, priceX96, q96);
            if (frac >= (q96 * 3) / 4 && frac <= (q96 * 95) / 100) {
                adj = candidate;
                break;
            }
        }
        dust += adj;

        // The gap fires iff frac(dust * p) + frac(x * p) >= 1, i.e. frac(x * p) >= q96 - dustFrac.
        // The amount is kept large (>= 1000 USDC) so Transfer mode mints a non-zero virtual supply.
        uint256 need = q96 - mulmod(dust, priceX96, q96); // in (0.05, 0.25] * q96
        for (uint256 candidate = 1_000_000_000; candidate <= 1_000_100_000; candidate++) {
            if (mulmod(candidate, priceX96, q96) >= need) {
                return (adj, candidate);
            }
        }
        revert("no misaligning amount found for the oracle price");
    }

    /// @dev Activates USDC on the WETH-base pool leaving an active dust balance, then donates a
    ///      scanned misaligning amount. Pre-fix the finalize donate reverted with
    ///      NavManipulationDetected(expected, expected + 1); post-fix it succeeds.
    function _roundingBoundDonate(OpType opType) internal {
        address pool = pool();
        address baseToken = Constants.ETH_WETH;
        DestinationMessageParams memory params = DestinationMessageParams({opType: opType, shouldUnwrapNative: false});

        // 1. Activate USDC with a first Sync donation, leaving an active dust balance.
        uint256 activation = 10_000e6;
        deal(Constants.ETH_USDC, address(this), activation);
        IECrosschain(pool).donate(Constants.ETH_USDC, 1, params);
        IERC20(Constants.ETH_USDC).transfer(pool, activation);
        IECrosschain(pool).donate(Constants.ETH_USDC, activation, params);

        uint256 dust = IERC20(Constants.ETH_USDC).balanceOf(pool);
        assertGt(dust, 0, "USDC dust must remain after activation");
        uint256 donation;

        // 2. Scan (locally) for a dust adjustment and donation that trigger the 1-wei floor-sum
        //    gap at the current TWAP, sanity-check the operands on the real oracle, and assert on
        //    the exact operands donate compares internally: fresh NAV exceeds snapshot +
        //    convert(delta) by exactly 1 wei - the precise state at which the pre-fix
        //    exact-equality check reverted. Block-scoped to keep the stack shallow.
        {
            (uint256 adj, uint256 candidate) = _findMisaligningAmount(pool, Constants.ETH_USDC, baseToken, dust);
            donation = candidate;
            if (adj > 0) {
                deal(Constants.ETH_USDC, address(this), adj);
                IERC20(Constants.ETH_USDC).transfer(pool, adj);
                dust += adj;
            }
            uint256 dustValue = uint256(IEOracle(pool).convertTokenAmount(Constants.ETH_USDC, int256(dust), baseToken));
            uint256 donationValue = uint256(
                IEOracle(pool).convertTokenAmount(Constants.ETH_USDC, int256(donation), baseToken)
            );
            uint256 combinedValue = uint256(
                IEOracle(pool).convertTokenAmount(Constants.ETH_USDC, int256(dust + donation), baseToken)
            );
            assertEq(dustValue + donationValue + 1, combinedValue, "engineered gap must be exactly 1 wei");

            uint256 navAtLock = ISmartPoolActions(pool).updateUnitaryValue().netTotalValue;
            IECrosschain(pool).donate(Constants.ETH_USDC, 1, params); // lock
            deal(Constants.ETH_USDC, address(this), donation);
            IERC20(Constants.ETH_USDC).transfer(pool, donation);
            uint256 expectedAssets = navAtLock + donationValue;
            uint256 actualNav = ISmartPoolActions(pool).updateUnitaryValue().netTotalValue;
            assertEq(actualNav, expectedAssets + 1, "fresh NAV must exceed snapshot + convert(delta) by exactly 1 wei");
        }

        // 3. Finalize: must succeed after the fix (pre-fix: NavManipulationDetected at this state).
        int256 vsBefore = int256(uint256(vm.load(pool, VirtualStorageLib.VIRTUAL_SUPPLY_SLOT)));
        IECrosschain(pool).donate(Constants.ETH_USDC, donation, params);

        int256 vsAfter = int256(uint256(vm.load(pool, VirtualStorageLib.VIRTUAL_SUPPLY_SLOT)));
        if (opType == OpType.Transfer) {
            assertGt(vsAfter, vsBefore, "Transfer mode must mint virtual supply");
        } else {
            assertEq(vsAfter, vsBefore, "Sync mode must not modify virtual supply");
        }
        assertEq(IERC20(Constants.ETH_USDC).balanceOf(pool), dust + donation, "pool must hold the full donation");
    }

    function test_NavRounding_SyncMode_DustyUsdcDonate_Succeeds() public {
        _roundingBoundDonate(OpType.Sync);
    }

    function test_NavRounding_TransferMode_DustyUsdcDonate_Succeeds() public {
        _roundingBoundDonate(OpType.Transfer);
    }

    /// @notice The 1-wei rounding bound must not weaken the manipulation check: draining the base
    ///         token between the lock and the finalize donate still reverts with NavManipulationDetected.
    function test_NavRounding_RealManipulation_StillReverts() public {
        address pool = pool();
        address baseToken = Constants.ETH_WETH;
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Sync,
            shouldUnwrapNative: false
        });

        // Activate USDC so the pool holds a non-base asset.
        uint256 activation = 10_000e6;
        deal(Constants.ETH_USDC, address(this), activation);
        IECrosschain(pool).donate(Constants.ETH_USDC, 1, params);
        IERC20(Constants.ETH_USDC).transfer(pool, activation);
        IECrosschain(pool).donate(Constants.ETH_USDC, activation, params);

        // Lock, deliver the claimed donation, then drain the pool's base token (WETH) in between.
        uint256 donation = 100e6;
        IECrosschain(pool).donate(Constants.ETH_USDC, 1, params); // lock
        // The snapshot NAV equals a fresh read at unchanged state (same block, same TWAP).
        uint256 storedAssets = ISmartPoolActions(pool).updateUnitaryValue().netTotalValue;
        deal(Constants.ETH_USDC, address(this), donation);
        IERC20(Constants.ETH_USDC).transfer(pool, donation);
        vm.prank(pool);
        IERC20(Constants.ETH_WETH).transfer(address(this), 1e18);

        // The fresh NAV inside donate is deterministic and equals a read at unchanged state.
        uint256 expectedAssets = storedAssets +
            uint256(IEOracle(pool).convertTokenAmount(Constants.ETH_USDC, int256(donation), baseToken));
        uint256 actualNav = ISmartPoolActions(pool).updateUnitaryValue().netTotalValue;
        assertEq(expectedAssets - actualNav, 1e18, "gap must equal the drained 1 WETH");

        vm.expectRevert(
            abi.encodeWithSelector(IECrosschain.NavManipulationDetected.selector, expectedAssets, actualNav)
        );
        IECrosschain(pool).donate(Constants.ETH_USDC, donation, params);
    }
}
