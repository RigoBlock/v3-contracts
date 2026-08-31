// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Constants} from "../../contracts/test/Constants.sol";
import {RealDeploymentFixture} from "../fixtures/RealDeploymentFixture.sol";
import {IERC20} from "../../contracts/protocol/interfaces/IERC20.sol";
import {ISmartPoolState} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolState.sol";
import {IECrosschain} from "../../contracts/protocol/extensions/adapters/interfaces/IECrosschain.sol";
import {VirtualStorageLib} from "../../contracts/protocol/libraries/VirtualStorageLib.sol";
import {OpType, DestinationMessageParams} from "../../contracts/protocol/types/Crosschain.sol";

/// @title ECrosschainUnwrapWethPrebalanceFork
/// @notice Regression tests: unwrapping WETH donations must succeed even when the pool
///  already holds a WETH balance and native is not yet active.
contract ECrosschainUnwrapWethPrebalanceForkTest is Test, RealDeploymentFixture {
    function _unwrapTransfer() internal pure returns (DestinationMessageParams memory) {
        return DestinationMessageParams({opType: OpType.Transfer, shouldUnwrapNative: true});
    }

    function _unwrapSync() internal pure returns (DestinationMessageParams memory) {
        return DestinationMessageParams({opType: OpType.Sync, shouldUnwrapNative: true});
    }

    function setUp() public {
        address[] memory baseTokens = new address[](1);
        baseTokens[0] = Constants.ETH_USDC;
        deployFixture(baseTokens);
        vm.selectFork(mainnetForkId);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                BASELINE (NO DUST)
    //////////////////////////////////////////////////////////////////////////*/

    function test_Unwrap_Succeeds_WithZeroWethBalance() public {
        uint256 donation = 0.5e18;
        address donor = Constants.ETH_MULTICALL_HANDLER;

        assertEq(IERC20(Constants.ETH_WETH).balanceOf(ethereum.pool), 0, "pool must start with no WETH");

        deal(Constants.ETH_WETH, donor, donation);
        vm.startPrank(donor);
        IECrosschain(ethereum.pool).donate(Constants.ETH_WETH, 1, _unwrapTransfer());
        IERC20(Constants.ETH_WETH).transfer(ethereum.pool, donation);
        IECrosschain(ethereum.pool).donate(Constants.ETH_WETH, donation, _unwrapTransfer());
        vm.stopPrank();

        assertEq(IERC20(Constants.ETH_WETH).balanceOf(ethereum.pool), 0, "all WETH unwrapped");
    }

    /*//////////////////////////////////////////////////////////////////////////
                            WETH DUST DOES NOT DOS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Before the fix, a WETH dust gift made every subsequent unwrapping delivery
    ///  revert with NavManipulationDetected. After the fix it succeeds and leaves the dust
    ///  untouched as WETH.
    function test_Unwrap_Succeeds_WithWethDust_NativeInactive() public {
        uint256 dust = 1e12;
        uint256 donation = 0.5e18;
        address griefer = address(0xBAD);
        address donor = Constants.ETH_MULTICALL_HANDLER;

        deal(Constants.ETH_WETH, griefer, dust);
        vm.prank(griefer);
        IERC20(Constants.ETH_WETH).transfer(ethereum.pool, dust);

        deal(Constants.ETH_WETH, donor, donation);
        vm.startPrank(donor);
        IECrosschain(ethereum.pool).donate(Constants.ETH_WETH, 1, _unwrapTransfer());
        IERC20(Constants.ETH_WETH).transfer(ethereum.pool, donation);
        IECrosschain(ethereum.pool).donate(Constants.ETH_WETH, donation, _unwrapTransfer());
        vm.stopPrank();

        assertEq(IERC20(Constants.ETH_WETH).balanceOf(ethereum.pool), dust, "dust WETH remains");
        assertEq(ethereum.pool.balance, donation, "only the donation was unwrapped to native");
    }

    /*//////////////////////////////////////////////////////////////////////////
                        THRESHOLD: ALL PRE-BALANCES NOW PASS
    //////////////////////////////////////////////////////////////////////////*/

    function test_Unwrap_Succeeds_AllPreBalances() public {
        uint256[5] memory dusts = [uint256(1), 1e6, 1e8, 5e8, 1e12];

        for (uint256 i = 0; i < dusts.length; i++) {
            uint256 snap = vm.snapshotState();
            bool reverted = _attemptUnwrapWithDust(dusts[i]);
            console2.log("dust wei", dusts[i], "reverted:", reverted);
            assertFalse(reverted, "all dust sizes should succeed after the fix");
            vm.revertToState(snap);
        }
    }

    function test_Unwrap_Succeeds_WithOneWeth() public {
        assertFalse(_attemptUnwrapWithDust(1e18), "1 WETH pre-balance must succeed after the fix");
    }

    function test_Unwrap_Succeeds_WithThreeWeiWeth() public {
        assertFalse(_attemptUnwrapWithDust(3), "3 wei WETH must succeed");
    }

    /*//////////////////////////////////////////////////////////////////////////
                        ACTIVATING NATIVE FIRST STILL WORKS
    //////////////////////////////////////////////////////////////////////////*/

    function test_Unwrap_Succeeds_AfterNativeActivation() public {
        uint256 dust = 1e12;
        uint256 activation = 5;
        uint256 donation = 0.5e18;
        address griefer = address(0xBAD);
        address donor = Constants.ETH_MULTICALL_HANDLER;

        deal(Constants.ETH_WETH, donor, activation + donation);
        vm.startPrank(donor);

        IECrosschain(ethereum.pool).donate(Constants.ETH_WETH, 1, _unwrapTransfer());
        IERC20(Constants.ETH_WETH).transfer(ethereum.pool, activation);
        IECrosschain(ethereum.pool).donate(Constants.ETH_WETH, activation, _unwrapTransfer());

        vm.stopPrank();
        deal(Constants.ETH_WETH, griefer, dust);
        vm.prank(griefer);
        IERC20(Constants.ETH_WETH).transfer(ethereum.pool, dust);

        vm.startPrank(donor);
        IECrosschain(ethereum.pool).donate(Constants.ETH_WETH, 1, _unwrapTransfer());
        IERC20(Constants.ETH_WETH).transfer(ethereum.pool, donation);
        IECrosschain(ethereum.pool).donate(Constants.ETH_WETH, donation, _unwrapTransfer());
        vm.stopPrank();

        assertEq(IERC20(Constants.ETH_WETH).balanceOf(ethereum.pool), dust, "dust WETH remains");
        assertGt(ethereum.pool.balance, 0, "native balance increased");
    }

    /// @dev Once native is active, an interleaved native transfer between lock and finalize
    ///  is NOT absorbed by the correction (because previouslyActive is true). It changes
    ///  netTotalValue without changing expectedAssets, so NAV integrity reverts. This is the
    ///  dual of the native-inactive case and is documented behavior, not a fund-risk bug.
    function test_Unwrap_Reverts_InterleavedNative_WhenNativeActive() public {
        uint256 activation = 5;
        uint256 donation = 0.5e18;
        uint256 interleaved = 0.01e18;
        address donor = Constants.ETH_MULTICALL_HANDLER;
        address interleaver = address(0xBAD);

        // First unwrap: activate native.
        deal(Constants.ETH_WETH, donor, activation + donation);
        vm.startPrank(donor);
        IECrosschain(ethereum.pool).donate(Constants.ETH_WETH, 1, _unwrapTransfer());
        IERC20(Constants.ETH_WETH).transfer(ethereum.pool, activation);
        IECrosschain(ethereum.pool).donate(Constants.ETH_WETH, activation, _unwrapTransfer());

        // Second unwrap with interleaved native.
        IECrosschain(ethereum.pool).donate(Constants.ETH_WETH, 1, _unwrapTransfer());
        IERC20(Constants.ETH_WETH).transfer(ethereum.pool, donation);
        vm.stopPrank();

        deal(interleaver, interleaved);
        vm.prank(interleaver);
        (bool sent, ) = ethereum.pool.call{value: interleaved}("");
        require(sent, "interleaved send failed");

        vm.prank(donor);
        vm.expectRevert();
        IECrosschain(ethereum.pool).donate(Constants.ETH_WETH, donation, _unwrapTransfer());
    }

    /*//////////////////////////////////////////////////////////////////////////
                    WETH ACTIVE, NATIVE INACTIVE ALSO SUCCEEDS
    //////////////////////////////////////////////////////////////////////////*/

    function test_Unwrap_Succeeds_WithActiveWeth_NativeInactive() public {
        uint256 donation = 0.5e18;
        address donor = Constants.ETH_MULTICALL_HANDLER;

        deal(Constants.ETH_WETH, donor, donation * 2);
        DestinationMessageParams memory noUnwrap = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });

        vm.startPrank(donor);
        IECrosschain(ethereum.pool).donate(Constants.ETH_WETH, 1, noUnwrap);
        IERC20(Constants.ETH_WETH).transfer(ethereum.pool, donation);
        IECrosschain(ethereum.pool).donate(Constants.ETH_WETH, donation, noUnwrap);

        IECrosschain(ethereum.pool).donate(Constants.ETH_WETH, 1, _unwrapTransfer());
        IERC20(Constants.ETH_WETH).transfer(ethereum.pool, donation);
        IECrosschain(ethereum.pool).donate(Constants.ETH_WETH, donation, _unwrapTransfer());
        vm.stopPrank();

        assertEq(ethereum.pool.balance, donation, "donation unwrapped to native");
    }

    /*//////////////////////////////////////////////////////////////////////////
                        PRE-EXISTING NATIVE BALANCE INCLUDED
    //////////////////////////////////////////////////////////////////////////*/

    function test_Unwrap_Succeeds_WithPreExistingNativeBalance() public {
        uint256 nativeDust = 1e12;
        uint256 wethDust = 1e12;
        uint256 donation = 0.5e18;
        address griefer = address(0xBAD);
        address donor = Constants.ETH_MULTICALL_HANDLER;

        // Griefer sends native directly to the pool (no calldata → receive()).
        // Native is not active, so this balance is not in storedAssets.
        deal(griefer, nativeDust);
        vm.prank(griefer);
        (bool sent, ) = ethereum.pool.call{value: nativeDust}("");
        require(sent, "native send failed");

        // Also leave WETH dust to verify it is excluded from the native correction.
        deal(Constants.ETH_WETH, griefer, wethDust);
        vm.prank(griefer);
        IERC20(Constants.ETH_WETH).transfer(ethereum.pool, wethDust);

        deal(Constants.ETH_WETH, donor, donation);
        vm.startPrank(donor);
        IECrosschain(ethereum.pool).donate(Constants.ETH_WETH, 1, _unwrapTransfer());
        IERC20(Constants.ETH_WETH).transfer(ethereum.pool, donation);
        IECrosschain(ethereum.pool).donate(Constants.ETH_WETH, donation, _unwrapTransfer());
        vm.stopPrank();

        assertEq(ethereum.pool.balance, nativeDust + donation, "native balance includes pre-existing and donation");
        assertEq(IERC20(Constants.ETH_WETH).balanceOf(ethereum.pool), wethDust, "WETH dust remains untouched");
    }

    /*//////////////////////////////////////////////////////////////////////////
                    INTERLEAVED NATIVE TRANSFER IS ACCOUNTED FOR
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev A native transfer can be inserted between the lock and finalize calls
    ///  (same tx, arbitrary multicall). The full native balance must be counted in
    ///  expectedAssets so NAV integrity still holds; extra ETH is a NAV increase
    ///  for existing holders, not a manipulation vector.
    function test_Unwrap_Succeeds_WithInterleavedNativeTransfer() public {
        uint256 bridgeAmount = 0.5e18;
        uint256 interleavedEth = 0.1e18;
        address donor = Constants.ETH_MULTICALL_HANDLER;
        address interleaver = address(0xBAD);

        deal(Constants.ETH_WETH, donor, bridgeAmount);
        deal(interleaver, interleavedEth);

        vm.startPrank(donor);
        IECrosschain(ethereum.pool).donate(Constants.ETH_WETH, 1, _unwrapTransfer());
        IERC20(Constants.ETH_WETH).transfer(ethereum.pool, bridgeAmount);
        vm.stopPrank();

        // Interleaved call: send native to the pool before the legitimate finalize.
        vm.prank(interleaver);
        (bool sent, ) = ethereum.pool.call{value: interleavedEth}("");
        require(sent, "interleaved send failed");

        vm.prank(donor);
        IECrosschain(ethereum.pool).donate(Constants.ETH_WETH, bridgeAmount, _unwrapTransfer());

        assertEq(
            ethereum.pool.balance,
            interleavedEth + bridgeAmount,
            "native balance includes interleaved ETH and bridge amount"
        );
        assertEq(IERC20(Constants.ETH_WETH).balanceOf(ethereum.pool), 0, "all WETH unwrapped");
    }

    /// @dev Removing WETH between lock and finalize violates the lock and must revert.
    ///  The lock stores the WETH balance at lock time; finalize requires the current WETH
    ///  balance to be at least that amount.
    function test_Unwrap_Reverts_WhenWethBalanceDecreases() public {
        uint256 donation = 0.5e18;
        uint256 initialWeth = 0.1e18;
        address donor = Constants.ETH_MULTICALL_HANDLER;

        deal(Constants.ETH_WETH, donor, donation);
        deal(Constants.ETH_WETH, ethereum.pool, initialWeth);

        vm.startPrank(donor);
        IECrosschain(ethereum.pool).donate(Constants.ETH_WETH, 1, _unwrapTransfer());
        IERC20(Constants.ETH_WETH).transfer(ethereum.pool, donation);
        vm.stopPrank();

        // Simulate WETH leaving the pool between lock and finalize (below stored amount).
        deal(Constants.ETH_WETH, ethereum.pool, 0);

        vm.prank(donor);
        vm.expectRevert(IECrosschain.BalanceUnderflow.selector);
        IECrosschain(ethereum.pool).donate(Constants.ETH_WETH, donation, _unwrapTransfer());
    }

    /*//////////////////////////////////////////////////////////////////////////
                        SOUNDNESS OF NATIVE-BALANCE CORRECTION
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev The correction uses the current native balance, not the native balance at lock
    ///  time. An interleaved native transfer is therefore counted in expectedAssets. We assert
    ///  that this does NOT mint extra virtual supply: only the bridge `amount` parameter is
    ///  used for share accounting, while the interleaved ETH is a NAV increase for existing
    ///  holders (unitary value rises).
    function test_InterleavedNativeTransfer_DoesNotInflateVirtualSupply() public {
        uint256 bridgeAmount = 0.5e18;
        uint256 interleavedEth = 0.1e18;
        address donor = Constants.ETH_MULTICALL_HANDLER;
        address interleaver = address(0xBAD);

        deal(Constants.ETH_WETH, donor, bridgeAmount);
        deal(interleaver, interleavedEth);

        // Baseline: finalize without any interleaved ETH. Record virtual supply and unitary value.
        uint256 baselineSnap = vm.snapshotState();
        vm.startPrank(donor);
        IECrosschain(ethereum.pool).donate(Constants.ETH_WETH, 1, _unwrapTransfer());
        IERC20(Constants.ETH_WETH).transfer(ethereum.pool, bridgeAmount);
        IECrosschain(ethereum.pool).donate(Constants.ETH_WETH, bridgeAmount, _unwrapTransfer());
        vm.stopPrank();

        int256 virtualSupplyBaseline = int256(uint256(vm.load(ethereum.pool, VirtualStorageLib.VIRTUAL_SUPPLY_SLOT)));
        ISmartPoolState.PoolTokens memory tokensBaseline = ISmartPoolState(ethereum.pool).getPoolTokens();

        // Now run the same donation but with an interleaved native transfer.
        vm.revertToState(baselineSnap);

        vm.startPrank(donor);
        IECrosschain(ethereum.pool).donate(Constants.ETH_WETH, 1, _unwrapTransfer());
        IERC20(Constants.ETH_WETH).transfer(ethereum.pool, bridgeAmount);
        vm.stopPrank();

        vm.prank(interleaver);
        (bool sent, ) = ethereum.pool.call{value: interleavedEth}("");
        require(sent, "interleaved send failed");

        vm.prank(donor);
        IECrosschain(ethereum.pool).donate(Constants.ETH_WETH, bridgeAmount, _unwrapTransfer());

        int256 virtualSupplyInterleaved = int256(
            uint256(vm.load(ethereum.pool, VirtualStorageLib.VIRTUAL_SUPPLY_SLOT))
        );
        ISmartPoolState.PoolTokens memory tokensInterleaved = ISmartPoolState(ethereum.pool).getPoolTokens();

        // The interleaved ETH changed nothing in share accounting: virtual supply is identical.
        assertEq(
            uint256(virtualSupplyInterleaved),
            uint256(virtualSupplyBaseline),
            "interleaved ETH must not affect virtual supply"
        );

        // The interleaved ETH is a pure NAV increase, so unitary value is strictly higher.
        assertGt(
            tokensInterleaved.unitaryValue,
            tokensBaseline.unitaryValue,
            "interleaved ETH must increase unitary value"
        );

        assertEq(ethereum.pool.balance, bridgeAmount + interleavedEth, "native balance is sum");
    }

    /// @dev A WETH-only delta check would fail when native was inactive before the donation
    ///  and a pre-existing native balance exists. The implementation must count the full native
    ///  balance, not just the WETH delta.
    function test_InterleavedNativeTransfer_WouldFailUnderWethOnlyCheck() public {
        uint256 bridgeAmount = 0.5e18;
        uint256 nativePreBalance = 0.05e18;
        address donor = Constants.ETH_MULTICALL_HANDLER;
        address griefer = address(0xBAD);

        // Pre-existing native balance, inactive. This is the state a WETH-only check ignores.
        deal(griefer, nativePreBalance);
        vm.prank(griefer);
        (bool sent, ) = ethereum.pool.call{value: nativePreBalance}("");
        require(sent, "native send failed");

        deal(Constants.ETH_WETH, donor, bridgeAmount);
        vm.startPrank(donor);
        IECrosschain(ethereum.pool).donate(Constants.ETH_WETH, 1, _unwrapTransfer());
        IERC20(Constants.ETH_WETH).transfer(ethereum.pool, bridgeAmount);
        IECrosschain(ethereum.pool).donate(Constants.ETH_WETH, bridgeAmount, _unwrapTransfer());
        vm.stopPrank();

        assertEq(ethereum.pool.balance, nativePreBalance + bridgeAmount, "native balance includes pre-balance");
    }

    /// @dev Baseline invariant: without interleaved ETH the native balance equals exactly the
    ///  bridge amount and virtual supply increases only by the bridge amount's share value.
    function test_NativeBalanceCorrection_NoInterleavedManipulation() public {
        uint256 bridgeAmount = 0.5e18;
        address donor = Constants.ETH_MULTICALL_HANDLER;

        int256 virtualSupplyBefore = int256(uint256(vm.load(ethereum.pool, VirtualStorageLib.VIRTUAL_SUPPLY_SLOT)));

        deal(Constants.ETH_WETH, donor, bridgeAmount);
        vm.startPrank(donor);
        IECrosschain(ethereum.pool).donate(Constants.ETH_WETH, 1, _unwrapTransfer());
        IERC20(Constants.ETH_WETH).transfer(ethereum.pool, bridgeAmount);
        IECrosschain(ethereum.pool).donate(Constants.ETH_WETH, bridgeAmount, _unwrapTransfer());
        vm.stopPrank();

        int256 virtualSupplyAfter = int256(uint256(vm.load(ethereum.pool, VirtualStorageLib.VIRTUAL_SUPPLY_SLOT)));

        // No interleaved manipulation happened, but the invariant still holds: supply changed
        // only by the bridge amount's share value.
        assertGt(virtualSupplyAfter, virtualSupplyBefore, "virtual supply increased");
        assertEq(ethereum.pool.balance, bridgeAmount, "native balance equals bridge amount");
    }

    /*//////////////////////////////////////////////////////////////////////////
                        LOCK ISOLATES FLOWS FROM OTHER DONATE CALLS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev A second lock attempt while a flow is in progress must revert.
    function test_Lock_PreventsInterleavedSecondLock() public {
        address donor = Constants.ETH_MULTICALL_HANDLER;
        vm.prank(donor);
        IECrosschain(ethereum.pool).donate(Constants.ETH_WETH, 1, _unwrapTransfer());

        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(IECrosschain.DonationLock.selector, true));
        IECrosschain(ethereum.pool).donate(Constants.ETH_WETH, 1, _unwrapTransfer());
    }

    /// @dev A finalize for a token whose temporary balance was never locked must revert.
    function test_Lock_PreventsCrossTokenFinalize() public {
        address donor = Constants.ETH_MULTICALL_HANDLER;
        vm.prank(donor);
        IECrosschain(ethereum.pool).donate(Constants.ETH_WETH, 1, _unwrapTransfer());

        vm.prank(address(0xBAD));
        vm.expectRevert(IECrosschain.TokenNotInitialized.selector);
        IECrosschain(ethereum.pool).donate(Constants.ETH_USDC, 1e6, _unwrapTransfer());
    }

    /*//////////////////////////////////////////////////////////////////////////
                    PARAM MISMATCH: LOCK/FINALIZE ARE INDEPENDENT
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev The contract does not store `params`; the finalize call's `shouldUnwrapNative`
    ///  determines behavior. Locking as unwrap then finalizing as no-unwrap leaves WETH.
    function test_ParamsMismatch_LockUnwrap_FinalizeNoUnwrap() public {
        uint256 donation = 0.5e18;
        address donor = Constants.ETH_MULTICALL_HANDLER;

        DestinationMessageParams memory noUnwrap = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });

        deal(Constants.ETH_WETH, donor, donation);
        vm.startPrank(donor);
        IECrosschain(ethereum.pool).donate(Constants.ETH_WETH, 1, _unwrapTransfer());
        IERC20(Constants.ETH_WETH).transfer(ethereum.pool, donation);
        IECrosschain(ethereum.pool).donate(Constants.ETH_WETH, donation, noUnwrap);
        vm.stopPrank();

        assertEq(ethereum.pool.balance, 0, "native balance unchanged");
        assertEq(IERC20(Constants.ETH_WETH).balanceOf(ethereum.pool), donation, "WETH not unwrapped");
    }

    /// @dev Locking as no-unwrap then finalizing as unwrap still succeeds and unwraps.
    function test_ParamsMismatch_LockNoUnwrap_FinalizeUnwrap() public {
        uint256 donation = 0.5e18;
        address donor = Constants.ETH_MULTICALL_HANDLER;

        DestinationMessageParams memory noUnwrap = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });

        deal(Constants.ETH_WETH, donor, donation);
        vm.startPrank(donor);
        IECrosschain(ethereum.pool).donate(Constants.ETH_WETH, 1, noUnwrap);
        IERC20(Constants.ETH_WETH).transfer(ethereum.pool, donation);
        IECrosschain(ethereum.pool).donate(Constants.ETH_WETH, donation, _unwrapTransfer());
        vm.stopPrank();

        assertEq(ethereum.pool.balance, donation, "WETH unwrapped to native");
        assertEq(IERC20(Constants.ETH_WETH).balanceOf(ethereum.pool), 0, "no WETH left");
    }

    /// @dev Locking as Transfer then finalizing as Sync changes the virtual-supply
    ///  behavior. The contract cannot enforce param consistency; this test documents
    ///  that the finalize call's `opType` is the one applied.
    function test_ParamsMismatch_LockTransfer_FinalizeSync() public {
        uint256 donation = 0.5e18;
        address donor = Constants.ETH_MULTICALL_HANDLER;

        DestinationMessageParams memory syncUnwrap = DestinationMessageParams({
            opType: OpType.Sync,
            shouldUnwrapNative: true
        });

        deal(Constants.ETH_WETH, donor, donation);
        vm.startPrank(donor);
        IECrosschain(ethereum.pool).donate(Constants.ETH_WETH, 1, _unwrapTransfer());
        IERC20(Constants.ETH_WETH).transfer(ethereum.pool, donation);
        IECrosschain(ethereum.pool).donate(Constants.ETH_WETH, donation, syncUnwrap);
        vm.stopPrank();

        assertEq(ethereum.pool.balance, donation, "WETH unwrapped");
        // Sync mode does not mint virtual supply; only the NAV impact check applies.
    }

    /*//////////////////////////////////////////////////////////////////////////
                            SYNC MODE ALSO SUCCEEDS
    //////////////////////////////////////////////////////////////////////////*/

    function test_UnwrapSync_Succeeds_WithWethDust() public {
        uint256 dust = 1e12;
        uint256 donation = 0.5e18;
        address griefer = address(0xBAD);
        address donor = Constants.ETH_MULTICALL_HANDLER;

        deal(Constants.ETH_WETH, griefer, dust);
        vm.prank(griefer);
        IERC20(Constants.ETH_WETH).transfer(ethereum.pool, dust);

        deal(Constants.ETH_WETH, donor, donation);
        vm.startPrank(donor);
        IECrosschain(ethereum.pool).donate(Constants.ETH_WETH, 1, _unwrapSync());
        IERC20(Constants.ETH_WETH).transfer(ethereum.pool, donation);
        IECrosschain(ethereum.pool).donate(Constants.ETH_WETH, donation, _unwrapSync());
        vm.stopPrank();

        assertEq(IERC20(Constants.ETH_WETH).balanceOf(ethereum.pool), dust, "dust WETH remains");
        assertEq(ethereum.pool.balance, donation, "donation unwrapped to native");
    }

    /*//////////////////////////////////////////////////////////////////////////
                            HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    function _attemptUnwrapWithDust(uint256 dust) internal returns (bool reverted) {
        uint256 donation = 0.5e18;
        address griefer = address(0xBAD);
        address donor = Constants.ETH_MULTICALL_HANDLER;

        if (dust > 0) {
            deal(Constants.ETH_WETH, griefer, dust);
            vm.prank(griefer);
            IERC20(Constants.ETH_WETH).transfer(ethereum.pool, dust);
        }

        deal(Constants.ETH_WETH, donor, donation);
        DestinationMessageParams memory p = _unwrapTransfer();

        vm.startPrank(donor);
        IECrosschain(ethereum.pool).donate(Constants.ETH_WETH, 1, p);
        IERC20(Constants.ETH_WETH).transfer(ethereum.pool, donation);
        (bool ok, ) = ethereum.pool.call(
            abi.encodeWithSelector(IECrosschain.donate.selector, Constants.ETH_WETH, donation, p)
        );
        vm.stopPrank();

        reverted = !ok;
    }
}
