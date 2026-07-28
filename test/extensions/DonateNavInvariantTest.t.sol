// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {UnitTestFixture} from "../fixtures/UnitTestFixture.sol";
import {Constants} from "../../contracts/test/Constants.sol";
import {CrosschainLib} from "../../contracts/protocol/libraries/CrosschainLib.sol";
import {StorageLib} from "../../contracts/protocol/libraries/StorageLib.sol";
import {VirtualStorageLib} from "../../contracts/protocol/libraries/VirtualStorageLib.sol";
import {IERC20} from "../../contracts/protocol/interfaces/IERC20.sol";
import {IWETH9} from "../../contracts/protocol/interfaces/IWETH9.sol";
import {ECrosschain} from "../../contracts/protocol/extensions/ECrosschain.sol";
import {MixinFallback} from "../../contracts/protocol/core/sys/MixinFallback.sol";
import {IECrosschain} from "../../contracts/protocol/extensions/adapters/interfaces/IECrosschain.sol";
import {IEOracle} from "../../contracts/protocol/extensions/adapters/interfaces/IEOracle.sol";
import {IRigoblockPoolProxyFactory} from "../../contracts/protocol/interfaces/IRigoblockPoolProxyFactory.sol";
import {ISmartPoolActions} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolActions.sol";
import {ISmartPoolImmutable} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolImmutable.sol";
import {ISmartPoolOwnerActions} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolOwnerActions.sol";
import {ISmartPoolState} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolState.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {OpType, DestinationMessageParams} from "../../contracts/protocol/types/Crosschain.sol";
import {NetAssetsValue} from "../../contracts/protocol/types/NavComponents.sol";

/// @title DonateNavInvariantTest - Tests for the donation NAV-per-share invariant.
/// @notice These tests verify that an interleaved share-issuing operation between the two
///         phases of `ECrosschain.donate()` cannot decrease the per-share NAV (`unitaryValue`).
///         The defensive invariant catches unbacked virtual-supply writes without enumerating
///         every possible mutating operation.
contract DonateNavInvariantTest is Test, UnitTestFixture {
    address usdc = Constants.ETH_USDC;
    address weth = Constants.ETH_WETH;

    address usdcBasePool;
    address ethBasePool;

    address holder = makeAddr("holder");
    address interleaver = makeAddr("interleaver");

    function setUp() public {
        deployFixture();

        // Deploy mocks at the real mainnet addresses so CrosschainLib.isAllowedCrosschainToken
        // recognizes them when we switch to chainId 1.
        deployCodeTo("out/MockERC20.sol/MockERC20.0.8.28.json", abi.encode("USD Coin", "USDC", 6), usdc);
        deployCodeTo("out/WETH9.sol/WETH9.json", "", weth);

        // A pool whose base token is a bridgeable token (USDC) - used to exercise the interleaved-mint path.
        (usdcBasePool, ) = IRigoblockPoolProxyFactory(deployment.factory).createPool("usdc pool", "USDC", usdc);

        // A pool whose base token is not a bridgeable token (ETH) - the configuration of the
        // largest existing smart pools, which is not exposed to the bridgeable-token interleave path.
        (ethBasePool, ) = IRigoblockPoolProxyFactory(deployment.factory).createPool("eth pool", "ETH", address(0));
    }

    function _initOracle(address token) private {
        deployment.mockOracle.initializeObservations(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(token),
                fee: 0,
                tickSpacing: TickMath.MAX_TICK_SPACING,
                hooks: IHooks(address(deployment.mockOracle))
            })
        );
        vm.warp(block.timestamp + 100);
    }

    function _mintUsdcPool(address recipient, uint256 amount) private {
        MockERC20(usdc).mint(recipient, amount);
        vm.prank(recipient);
        MockERC20(usdc).approve(usdcBasePool, amount);
        vm.prank(recipient);
        ISmartPoolActions(usdcBasePool).mint(recipient, amount, 0);
    }

    function _mintEthPool(address recipient, uint256 amount) private {
        vm.deal(recipient, amount);
        vm.prank(recipient);
        ISmartPoolActions(ethBasePool).mint{value: amount}(recipient, amount, 0);
    }

    /// @dev Computes the per-share NAV that ECrosschain._validateNavIntegrity will observe after
    ///      `amount` of `token` is added as virtual supply. Mirrors the contract's accounting so
    ///      the tests can assert the full revert data with `vm.expectRevert`.
    function _navAfterVirtualSupplyWrite(
        address pool,
        address token,
        uint256 amount,
        uint256 storedNav
    ) private returns (uint256) {
        NetAssetsValue memory nav = ISmartPoolActions(pool).updateUnitaryValue();
        uint256 totalSupply = ISmartPoolState(pool).getPoolTokens().totalSupply;
        address baseToken = ISmartPoolState(pool).getPool().baseToken;
        uint8 decimals = ISmartPoolState(pool).getPool().decimals;
        uint256 amountValueInBase = uint256(IEOracle(pool).convertTokenAmount(token, int256(amount), baseToken));
        uint256 vsAdded = (amountValueInBase * (10 ** decimals)) / storedNav;
        return (nav.netTotalValue * (10 ** decimals)) / (totalSupply + vsAdded);
    }

    /*//////////////////////////////////////////////////////////////////////////
                              NAV-PER-SHARE INVARIANT SCENARIOS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice An interleaved mint in a bridgeable-base-token pool must revert because NAV per share decreases.
    function test_Donate_InterleavedMint_DecreasesNavPerShare_Reverts() public {
        _initOracle(usdc);
        vm.chainId(1);

        // Give an existing holder real shares backed by USDC.
        _mintUsdcPool(holder, 1_000_000e6);

        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });

        // Capture the NAV that phase 1 will store in transient storage. Use the freshly
        // computed value because `getPoolTokens().unitaryValue` returns the cached stored NAV.
        uint256 storedNav = ISmartPoolActions(usdcBasePool).updateUnitaryValue().unitaryValue;

        // Phase 1: lock and snapshot NAV/assets.
        IECrosschain(usdcBasePool).donate(usdc, 1, params);

        // An interleaved mint of the same token (USDC) is performed between the two phases.
        _mintUsdcPool(interleaver, 1_000_000e6);

        // The minted deposit (net of spread) satisfies the balance-delta check, but the donation
        // then writes unbacked virtual supply on top of the minted shares, lowering NAV per share.
        uint256 balanceAfterMint = MockERC20(usdc).balanceOf(usdcBasePool);
        uint256 amountDelta = balanceAfterMint - 1_000_000e6;

        // Phase 2 must revert with NavDecreased because the interleaved mint lowers NAV per share.
        uint256 currentNav = _navAfterVirtualSupplyWrite(usdcBasePool, usdc, amountDelta, storedNav);
        vm.expectRevert(abi.encodeWithSelector(IECrosschain.NavDecreased.selector, storedNav, currentNav));
        IECrosschain(usdcBasePool).donate(usdc, amountDelta, params);

        vm.chainId(31337);
    }

    /// @notice Explicit regression test for the submitted WETH/ETH PoC configuration.
    /// @dev The scenario uses an ETH-base pool, WETH as the interleaved mint/donation token,
    ///      and oracle price 1 WETH = 1 ETH. The phase-2 donation must revert with NavDecreased
    ///      because writing unbacked virtual supply on top of the freshly minted real shares lowers NAV per share.
    function test_Donate_WethEthInterleavedMint_Reverts() public {
        _initOracle(weth);
        vm.chainId(1);

        // The interleaved path requires the pool owner to have accepted WETH for minting.
        ISmartPoolOwnerActions(ethBasePool).setAcceptableMintToken(weth, true);

        // Holder establishes real shares backed by ETH so a meaningful NAV exists.
        _mintEthPool(holder, 1000 ether);

        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });

        uint256 storedNav = ISmartPoolActions(ethBasePool).updateUnitaryValue().unitaryValue;

        // Phase 1: lock the (initially zero) WETH balance.
        IECrosschain(ethBasePool).donate(weth, 1, params);

        // An interleaved WETH mint is performed between the two donation phases.
        uint256 d = 10 ether; // 1% of holder ETH
        vm.deal(interleaver, d);
        vm.prank(interleaver);
        IWETH9(weth).deposit{value: d}();
        vm.prank(interleaver);
        IWETH9(weth).approve(ethBasePool, d);
        vm.prank(interleaver);
        ISmartPoolActions(ethBasePool).mintWithToken(interleaver, d, 0, weth);

        uint256 amountDelta = IWETH9(weth).balanceOf(ethBasePool);

        // Phase 2 must revert because unbacked virtual supply would deflate NAV per share.
        uint256 currentNav = _navAfterVirtualSupplyWrite(ethBasePool, weth, amountDelta, storedNav);
        vm.expectRevert(abi.encodeWithSelector(IECrosschain.NavDecreased.selector, storedNav, currentNav));
        IECrosschain(ethBasePool).donate(weth, amountDelta, params);

        vm.chainId(31337);
    }

    /// @notice The legitimate donation flow (no interleaved mint/burn) still works and does not
    ///         decrease NAV per share.
    function test_Donate_LegitimateTransfer_SucceedsAndKeepsNav() public {
        _initOracle(usdc);
        vm.chainId(1);

        _mintUsdcPool(holder, 1_000_000e6);

        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });

        uint256 navBefore = ISmartPoolState(usdcBasePool).getPoolTokens().unitaryValue;
        uint256 donationAmount = 500_000e6;

        int256 vsBefore = int256(uint256(vm.load(usdcBasePool, VirtualStorageLib.VIRTUAL_SUPPLY_SLOT)));

        IECrosschain(usdcBasePool).donate(usdc, 1, params);
        MockERC20(usdc).mint(usdcBasePool, donationAmount);
        IECrosschain(usdcBasePool).donate(usdc, donationAmount, params);

        int256 vsAfter = int256(uint256(vm.load(usdcBasePool, VirtualStorageLib.VIRTUAL_SUPPLY_SLOT)));
        assertGt(vsAfter - vsBefore, 0, "Legitimate donation should create positive virtual supply");

        uint256 navAfter = ISmartPoolState(usdcBasePool).getPoolTokens().unitaryValue;
        assertGe(navAfter, navBefore, "Transfer donation must not decrease NAV per share");

        vm.chainId(31337);
    }

    /// @notice Sync mode adds assets without virtual supply, so NAV per share must increase.
    function test_Donate_LegitimateSync_SucceedsAndIncreasesNav() public {
        _initOracle(usdc);
        vm.chainId(1);

        _mintUsdcPool(holder, 1_000_000e6);

        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Sync,
            shouldUnwrapNative: false
        });

        uint256 navBefore = ISmartPoolState(usdcBasePool).getPoolTokens().unitaryValue;
        uint256 donationAmount = 500_000e6;

        int256 vsBefore = int256(uint256(vm.load(usdcBasePool, VirtualStorageLib.VIRTUAL_SUPPLY_SLOT)));

        IECrosschain(usdcBasePool).donate(usdc, 1, params);
        MockERC20(usdc).mint(usdcBasePool, donationAmount);
        IECrosschain(usdcBasePool).donate(usdc, donationAmount, params);

        int256 vsAfter = int256(uint256(vm.load(usdcBasePool, VirtualStorageLib.VIRTUAL_SUPPLY_SLOT)));
        assertEq(vsAfter - vsBefore, 0, "Sync donation must not create virtual supply");

        uint256 navAfter = ISmartPoolState(usdcBasePool).getPoolTokens().unitaryValue;
        assertGt(navAfter, navBefore, "Sync donation must increase NAV per share");

        vm.chainId(31337);
    }

    /*//////////////////////////////////////////////////////////////////////////
                         NON-BRIDGEABLE BASE TOKEN (ETH) POOL
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Native currency (`address(0)`) is not a whitelisted cross-chain donation token.
    ///         The extension defers that check to phase 2, so phase 1 succeeds even for `address(0)`.
    ///         To exercise the phase-2 rejection we simulate a native ETH donation arriving between
    ///         the two calls and assert it is rejected at the `CrosschainLib.isAllowedCrosschainToken`
    ///         check, not at an early phase-1 guard.
    function test_Donate_NativeOnEthBase_Reverts() public {
        vm.chainId(1);

        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });

        // Phase 1: lock the donation state and snapshot the current native balance.
        IECrosschain(ethBasePool).donate(address(0), 1, params);

        // Simulate a native ETH donation arriving between the two calls.
        vm.deal(ethBasePool, address(ethBasePool).balance + 1 ether);

        // Phase 2: even though the pool's native balance increased, address(0) is not a whitelisted
        // cross-chain token, so the call reverts at the whitelist check.
        vm.expectRevert(CrosschainLib.UnsupportedCrossChainToken.selector);
        IECrosschain(ethBasePool).donate(address(0), 1 ether, params);

        vm.chainId(31337);
    }

    /// @notice A WETH donation attempt on an ETH-base pool reverts because the interleaver can only
    ///         mint ETH (the base token), which does not affect the WETH balance used for the
    ///         donation delta.
    function test_Donate_WethOnEthBase_InterleavedEthMint_Reverts() public {
        _initOracle(usdc); // oracle is needed for non-base-token activation
        _initOracle(weth);
        vm.chainId(1);

        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });

        IECrosschain(ethBasePool).donate(weth, 1, params);
        _mintEthPool(interleaver, 1 ether);

        // The interleaved ETH mint leaves the WETH balance unchanged, so amountDelta is zero
        // and the donation reverts at the amountDelta >= amount check.
        vm.expectRevert(ECrosschain.CallerTransferAmount.selector);
        IECrosschain(ethBasePool).donate(weth, 1 ether, params);

        vm.chainId(31337);
    }

    /// @notice Even with a pre-existing WETH balance, an interleaved ETH mint does not increase
    ///         the WETH balance, so the donation finalize reverts before reaching NAV validation.
    function test_Donate_WethOnEthBase_InterleavedEthMintWithBalance_Reverts() public {
        _initOracle(usdc);
        _initOracle(weth);
        vm.chainId(1);

        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });

        // Capture the asset snapshot that phase 1 will store.
        NetAssetsValue memory snapshot = ISmartPoolActions(ethBasePool).updateUnitaryValue();

        IECrosschain(ethBasePool).donate(weth, 1, params);

        // Give the pool some WETH (simulating an actual WETH transfer).
        vm.deal(address(this), 1 ether);
        IWETH9(weth).deposit{value: 1 ether}();
        IWETH9(weth).transfer(ethBasePool, 1 ether);

        // Interleave an ETH mint. ETH increases total assets but does not change the WETH balance,
        // so the asset-equality check in phase 2 reverts.
        _mintEthPool(interleaver, 1 ether);

        // Phase 2 must revert with NavManipulationDetected because the interleaved ETH mint added
        // assets that the WETH balance-delta did not account for.
        uint256 expectedAssets = snapshot.netTotalValue +
            uint256(IEOracle(ethBasePool).convertTokenAmount(weth, int256(1 ether), address(0)));
        // The `actualNav` argument is the NAV after the donation activates WETH and writes virtual
        // supply, so it cannot be derived from an external `updateUnitaryValue()` call. The value
        // below is deterministic for this fixed test setup (determined empirically from the revert).
        uint256 actualNav = 1_979_199_653_440_576_965;
        vm.expectRevert(
            abi.encodeWithSelector(IECrosschain.NavManipulationDetected.selector, expectedAssets, actualNav)
        );
        IECrosschain(ethBasePool).donate(weth, 1 ether, params);

        vm.chainId(31337);
    }

    /*//////////////////////////////////////////////////////////////////////////
                              REAL DEPLOYED TEST POOL
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Sanity check on the real multi-chain test pool: its base token is not a bridgeable
    ///         cross-chain token, and the pool has been upgraded to the implementation that routes
    ///         `donate()` through ECrosschain. A native donation still reverts at the whitelist check.
    /// @dev This test reverts when MAINNET_RPC_URL is not available, so it never passes silently.
    function test_Donate_RealTestPool_BaseTokenNotBridgeable() public {
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string(""));
        require(bytes(rpcUrl).length > 0, "MAINNET_RPC_URL not set");

        vm.createSelectFork(rpcUrl, Constants.MAINNET_BLOCK);

        address pool = Constants.TEST_POOL;
        address baseToken = ISmartPoolState(pool).getPool().baseToken;

        assertFalse(
            CrosschainLib.isAllowedCrosschainToken(baseToken),
            "Test pool base token must not be a bridgeable cross-chain token"
        );

        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });

        // Phase 1: initialize the donation state. This succeeds because the whitelist check is
        // deferred to phase 2.
        IECrosschain(pool).donate(address(0), 1, params);

        // Simulate a native ETH donation arriving between the two calls.
        vm.deal(pool, address(pool).balance + 1 ether);

        // Phase 2: native currency is not a whitelisted cross-chain token, so the call reverts
        // at the whitelist check rather than reaching any virtual-supply write.
        vm.expectRevert(CrosschainLib.UnsupportedCrossChainToken.selector);
        IECrosschain(pool).donate(address(0), 1 ether, params);
    }

    /*//////////////////////////////////////////////////////////////////////////
                         WETH UNWRAP (NATIVE DELIVERY) FLOW
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice WETH donations with `shouldUnwrapNative=true` convert the received WETH to ETH.
    ///         The donation succeeds and does not decrease NAV per share.
    /// @dev The fixture's pool reports `deployment.wrappedNative` as wrappedNative, which is not
    ///      a CrosschainLib-whitelisted token. We mock `wrappedNative()` to the mainnet WETH address
    ///      so the unit test can exercise the unwrap branch.
    function test_Donate_WethUnwrap_Succeeds() public {
        _initOracle(weth);
        vm.chainId(1);

        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: true
        });

        // Make the pool believe its wrapped native is mainnet WETH.
        vm.mockCall(ethBasePool, abi.encodeWithSelector(ISmartPoolImmutable.wrappedNative.selector), abi.encode(weth));

        uint256 navBefore = ISmartPoolState(ethBasePool).getPoolTokens().unitaryValue;
        uint256 donationAmount = 2 ether;

        int256 vsBefore = int256(uint256(vm.load(ethBasePool, VirtualStorageLib.VIRTUAL_SUPPLY_SLOT)));

        // Phase 1: lock WETH balance.
        IECrosschain(ethBasePool).donate(weth, 1, params);

        // Phase 2: send WETH, which gets unwrapped to ETH before validation.
        vm.deal(address(this), donationAmount);
        IWETH9(weth).deposit{value: donationAmount}();
        IWETH9(weth).transfer(ethBasePool, donationAmount);

        IECrosschain(ethBasePool).donate(weth, donationAmount, params);

        // ETH balance increased by the donation, WETH was withdrawn.
        assertEq(ethBasePool.balance, donationAmount, "ETH balance should equal donation amount");

        int256 vsAfter = int256(uint256(vm.load(ethBasePool, VirtualStorageLib.VIRTUAL_SUPPLY_SLOT)));
        assertGt(vsAfter - vsBefore, 0, "Unwrapped donation should create positive virtual supply");

        uint256 navAfter = ISmartPoolState(ethBasePool).getPoolTokens().unitaryValue;
        assertGe(navAfter, navBefore, "Unwrap donation must not decrease NAV per share");

        vm.chainId(31337);
    }

    /*//////////////////////////////////////////////////////////////////////////
                         BURN INTERLEAVING SAFETY CHECK
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Interleaving a burn of a different token cannot inflate NAV: the asset equality
    ///         check fails because the burn removes assets that the donation did not account for.
    function test_Donate_InterleavedBurnOfDifferentToken_Reverts() public {
        _initOracle(usdc);
        _initOracle(weth);
        vm.chainId(1);

        // Set up a WETH-base pool so the interleaver can burn WETH while donating USDC.
        (address wethBasePool, ) = IRigoblockPoolProxyFactory(deployment.factory).createPool(
            "weth base pool",
            "WETHB",
            weth
        );

        // Mint WETH shares to the interleaver.
        vm.deal(interleaver, 10 ether);
        vm.prank(interleaver);
        IWETH9(weth).deposit{value: 10 ether}();
        vm.prank(interleaver);
        IWETH9(weth).approve(wethBasePool, 10 ether);
        vm.prank(interleaver);
        ISmartPoolActions(wethBasePool).mint(interleaver, 10 ether, 0);

        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });

        // Capture the asset snapshot that phase 1 will store in transient storage.
        NetAssetsValue memory snapshot = ISmartPoolActions(wethBasePool).updateUnitaryValue();

        // Phase 1 on USDC donation.
        IECrosschain(wethBasePool).donate(usdc, 1, params);

        // The interleaver burns WETH in between. This removes assets but does not touch the USDC balance.
        // Advance time past the mint lockup to allow burning.
        vm.warp(block.timestamp + 31 days);
        vm.prank(interleaver);
        ISmartPoolActions(wethBasePool).burn(1 ether, 0);

        // Phase 2: the missing WETH value makes the asset equality check fail.
        MockERC20(usdc).mint(wethBasePool, 100_000e6);

        // Phase 2 must revert with NavManipulationDetected because the interleaved burn removed
        // assets that the donation did not account for.
        uint256 expectedAssets = snapshot.netTotalValue +
            uint256(IEOracle(wethBasePool).convertTokenAmount(usdc, int256(100_000e6), weth));
        // The `actualNav` argument is the NAV after the donation activates USDC and writes virtual
        // supply, so it cannot be derived from an external `updateUnitaryValue()` call. The value
        // below is deterministic for this fixed test setup (determined empirically from the revert).
        uint256 actualNav = 8_990_000_100_000_000_000;
        vm.expectRevert(
            abi.encodeWithSelector(IECrosschain.NavManipulationDetected.selector, expectedAssets, actualNav)
        );
        IECrosschain(wethBasePool).donate(usdc, 100_000e6, params);

        vm.chainId(31337);
    }

    /// @notice When a same-token burn is interleaved, the phase-2 donation cannot use the gross
    ///         transferred amount as the `amount` parameter. The `amount` is bounded by the net
    ///         balance increase (`amountDelta`), which equals gross transfer minus the burn payout.
    ///         Therefore any NAV impact is bounded by the net donation, not the gross one.
    function test_Donate_InterleavedBurn_GrossAmountCannotExceedNetBalanceIncrease() public {
        _initOracle(usdc);
        vm.chainId(1);

        _mintUsdcPool(holder, 1_000_000e6);
        _mintUsdcPool(interleaver, 500_000e6);

        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });

        uint256 balanceBefore = MockERC20(usdc).balanceOf(usdcBasePool);
        uint256 totalSupplyBefore = ISmartPoolState(usdcBasePool).getPoolTokens().totalSupply;
        int256 vsBefore = int256(uint256(vm.load(usdcBasePool, VirtualStorageLib.VIRTUAL_SUPPLY_SLOT)));

        // Phase 1: lock and snapshot.
        IECrosschain(usdcBasePool).donate(usdc, 1, params);

        // The interleaver burns 100k shares. The pool pays out 100k USDC, so totalSupply and balance drop.
        uint256 burnAmount = 100_000e6;
        vm.warp(block.timestamp + 31 days);
        vm.prank(interleaver);
        ISmartPoolActions(usdcBasePool).burn(burnAmount, 0);

        // The interleaver returns exactly the burned amount: gross transfer = 100k, net to pool = 0.
        MockERC20(usdc).mint(interleaver, burnAmount);
        vm.prank(interleaver);
        MockERC20(usdc).transfer(usdcBasePool, burnAmount);

        uint256 amountDelta = MockERC20(usdc).balanceOf(usdcBasePool) - balanceBefore;
        assertEq(amountDelta, 0, "Net balance increase should be zero after returning the burn payout");

        // A phase-2 call pretending the gross 100k transfer is a donation must revert,
        // because the net balance increase is 0.
        vm.expectRevert(ECrosschain.CallerTransferAmount.selector);
        IECrosschain(usdcBasePool).donate(usdc, burnAmount, params);

        // Total supply was reduced by the burn, and no donation virtual supply was created.
        uint256 totalSupplyAfter = ISmartPoolState(usdcBasePool).getPoolTokens().totalSupply;
        assertEq(totalSupplyAfter, totalSupplyBefore - burnAmount, "Burn should reduce total supply");

        int256 vsAfter = int256(uint256(vm.load(usdcBasePool, VirtualStorageLib.VIRTUAL_SUPPLY_SLOT)));
        assertEq(vsAfter - vsBefore, 0, "No virtual supply should be created when net donation is zero");

        vm.chainId(31337);
    }

    /// @notice Even when a same-token burn is interleaved and the interleaver returns more than the
    ///         burned amount, the phase-2 donation is bounded by the net balance increase.
    ///         Virtual supply and any NAV impact derive from the net donation (100 in the user's
    ///         example), not from the gross transfer (200).
    function test_Donate_InterleavedBurn_NavImpactBoundedByNetDonation() public {
        _initOracle(usdc);
        vm.chainId(1);

        _mintUsdcPool(holder, 1_000_000e6);
        _mintUsdcPool(interleaver, 500_000e6);

        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });

        uint256 balanceBefore = MockERC20(usdc).balanceOf(usdcBasePool);
        uint256 totalSupplyBefore = ISmartPoolState(usdcBasePool).getPoolTokens().totalSupply;
        uint256 navBefore = ISmartPoolState(usdcBasePool).getPoolTokens().unitaryValue;
        int256 vsBefore = int256(uint256(vm.load(usdcBasePool, VirtualStorageLib.VIRTUAL_SUPPLY_SLOT)));

        // Phase 1: lock and snapshot.
        IECrosschain(usdcBasePool).donate(usdc, 1, params);

        // Interleave a burn of 100k shares (the "100" in the user's example).
        uint256 burnAmount = 100_000e6;
        vm.warp(block.timestamp + 31 days);
        vm.prank(interleaver);
        ISmartPoolActions(usdcBasePool).burn(burnAmount, 0);

        uint256 navAfterBurn = ISmartPoolState(usdcBasePool).getPoolTokens().unitaryValue;
        uint256 totalSupplyAfterBurn = ISmartPoolState(usdcBasePool).getPoolTokens().totalSupply;

        // Interleaver returns 200k (the "gross 200"): 100k replaces the burn payout, 100k is the net
        // donation to the pool. amountDelta is therefore 100k.
        uint256 grossTransfer = 200_000e6;
        uint256 netDonation = grossTransfer - burnAmount;
        MockERC20(usdc).mint(interleaver, grossTransfer);
        vm.prank(interleaver);
        MockERC20(usdc).transfer(usdcBasePool, grossTransfer);

        uint256 amountDelta = MockERC20(usdc).balanceOf(usdcBasePool) - balanceBefore;
        assertEq(amountDelta, netDonation, "Net balance increase must equal gross transfer minus burn payout");

        // A phase-2 call with amount = gross transfer (200k) must revert because amountDelta is only 100k.
        vm.expectRevert(ECrosschain.CallerTransferAmount.selector);
        IECrosschain(usdcBasePool).donate(usdc, grossTransfer, params);

        // Phase 2 with amount = net donation (100k) succeeds.
        IECrosschain(usdcBasePool).donate(usdc, netDonation, params);

        int256 vsAfter = int256(uint256(vm.load(usdcBasePool, VirtualStorageLib.VIRTUAL_SUPPLY_SLOT)));
        assertGt(vsAfter - vsBefore, 0, "Net donation should create positive virtual supply");

        // The virtual supply corresponds to the net donation, not the gross transfer.
        uint256 expectedVs = (netDonation * 10 ** 6) / navBefore;
        assertApproxEqAbs(uint256(vsAfter - vsBefore), expectedVs, 1e6, "VS must derive from net donation only");

        uint256 totalSupplyAfter = ISmartPoolState(usdcBasePool).getPoolTokens().totalSupply;
        assertEq(totalSupplyAfter, totalSupplyBefore - burnAmount, "Burn should reduce total supply");

        // The donation part is NAV-neutral: it adds netDonation assets and netDonation virtual supply.
        // Any NAV change is bounded by the net donation value over the post-burn supply; the gross
        // transfer does not inflate NAV beyond that.
        uint256 navAfter = ISmartPoolState(usdcBasePool).getPoolTokens().unitaryValue;
        uint256 maxDonationNavImpact = (netDonation * 10 ** 6) / totalSupplyAfterBurn;
        assertLe(
            navAfter - navAfterBurn,
            maxDonationNavImpact + 1e6, // tolerate 1 unit of rounding
            "NAV impact must be bounded by net donation / post-burn supply, not gross transfer"
        );

        vm.chainId(31337);
    }

    /// @notice Even when a same-token burn is forced between the two donation phases
    ///         (and enough tokens are transferred to make phase 2 succeed), NAV per share cannot be
    ///         deflated. The only new virtual supply is the one implied by the real net donation.
    function test_Donate_InterleavedBurn_RealDonationDoesNotDeflateNav() public {
        _initOracle(usdc);
        vm.chainId(1);

        // Establish real shares for both the holder and the interleaver.
        _mintUsdcPool(holder, 1_000_000e6);
        _mintUsdcPool(interleaver, 500_000e6);

        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });

        uint256 navBefore = ISmartPoolState(usdcBasePool).getPoolTokens().unitaryValue;
        uint256 totalSupplyBefore = ISmartPoolState(usdcBasePool).getPoolTokens().totalSupply;
        uint256 balanceBefore = MockERC20(usdc).balanceOf(usdcBasePool);
        int256 vsBefore = int256(uint256(vm.load(usdcBasePool, VirtualStorageLib.VIRTUAL_SUPPLY_SLOT)));

        // Phase 1: lock and snapshot.
        IECrosschain(usdcBasePool).donate(usdc, 1, params);

        // Interleave a burn of the base token. This reduces both assets and total supply.
        uint256 burnAmount = 100_000e6;
        vm.warp(block.timestamp + 31 days);
        vm.prank(interleaver);
        ISmartPoolActions(usdcBasePool).burn(burnAmount, 0);

        // Capture NAV immediately after the burn but before the interleaver returns the funds.
        // This isolates the donation's own NAV impact from the burn's spread impact.
        uint256 navAfterBurn = ISmartPoolState(usdcBasePool).getPoolTokens().unitaryValue;
        uint256 totalSupplyAfterBurn = ISmartPoolState(usdcBasePool).getPoolTokens().totalSupply;

        // Interleaver returns the burned value plus a real donation so phase 2 does not revert.
        uint256 realDonation = 50_000e6;
        uint256 transferBack = burnAmount + realDonation;
        MockERC20(usdc).mint(interleaver, transferBack);
        vm.prank(interleaver);
        MockERC20(usdc).transfer(usdcBasePool, transferBack);

        uint256 balanceAfter = MockERC20(usdc).balanceOf(usdcBasePool);

        // Phase 2 must succeed, but it cannot create unbacked virtual supply that would deflate NAV.
        uint256 amountDelta = balanceAfter - balanceBefore;
        IECrosschain(usdcBasePool).donate(usdc, amountDelta, params);

        int256 vsAfter = int256(uint256(vm.load(usdcBasePool, VirtualStorageLib.VIRTUAL_SUPPLY_SLOT)));
        assertGt(vsAfter - vsBefore, 0, "Real donation should create positive virtual supply");

        uint256 navAfter = ISmartPoolState(usdcBasePool).getPoolTokens().unitaryValue;
        assertGe(navAfter, navBefore, "Burn interleave must not decrease NAV per share");

        uint256 totalSupplyAfter = ISmartPoolState(usdcBasePool).getPoolTokens().totalSupply;
        assertEq(totalSupplyAfter, totalSupplyBefore - burnAmount, "Burn should reduce total supply");

        // The virtual-supply delta corresponds to the real donation amount, not to the burn.
        uint256 expectedVs = (realDonation * 10 ** 6) / navBefore;
        assertApproxEqAbs(uint256(vsAfter - vsBefore), expectedVs, 1e6, "VS must derive from real donation only");

        // The donation's own NAV impact is bounded by the real net donation value divided by
        // the post-burn supply. It cannot be inflated beyond that, because the only new shares
        // created correspond to the real donation.
        uint256 maxDonationNavIncrease = (realDonation * 10 ** 6) / totalSupplyAfterBurn;
        assertLe(
            navAfter - navAfterBurn,
            maxDonationNavIncrease + 1e6, // tolerate 1 unit of rounding
            "Donation NAV impact must be bounded by real net donation value"
        );

        vm.chainId(31337);
    }

    /// @notice Extreme burn interleave: burning ~90% of supply and returning 110% of initial value
    ///         creates a hybrid Transfer/Sync effect but never unbacked supply.
    /// @dev Initial pool: interleaver≈90 USDC, holder=10 USDC, NAV≈1.0. Interleaver burns their whole balance,
    ///      returns 110 USDC, then finalizes a Transfer donation with amount=10. amountDelta = the net donation.
    function test_Donate_InterleavedBurn_LargeBurnHybrid_NavBacked() public {
        _initOracle(usdc);
        vm.chainId(1);

        uint256 holderDeposit = 10_000_000; // 10 USDC
        uint256 interleaverDeposit = 90_000_000; // 90 USDC

        // Holder and interleaver each contribute so the interleaver ends up with ~90% of shares.
        _mintUsdcPool(holder, holderDeposit);
        _mintUsdcPool(interleaver, interleaverDeposit);

        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });

        uint256 balanceBefore = MockERC20(usdc).balanceOf(usdcBasePool);
        uint256 totalSupplyBefore = ISmartPoolState(usdcBasePool).getPoolTokens().totalSupply;
        uint256 navBefore = ISmartPoolState(usdcBasePool).getPoolTokens().unitaryValue;
        int256 vsBefore = int256(uint256(vm.load(usdcBasePool, VirtualStorageLib.VIRTUAL_SUPPLY_SLOT)));

        // Interleaver's full pool-token balance should be ~90% of total supply.
        uint256 interleaverBalanceBeforeBurn = IERC20(usdcBasePool).balanceOf(interleaver);
        assertGt(
            (interleaverBalanceBeforeBurn * 100) / totalSupplyBefore,
            85,
            "Interleaver should hold ~90% of total supply before burn"
        );

        // Phase 1: lock and snapshot.
        IECrosschain(usdcBasePool).donate(usdc, 1, params);

        // Interleaver burns ~90% of supply. The pool pays out USDC, so totalSupply and balance drop.
        vm.warp(block.timestamp + 31 days);
        vm.prank(interleaver);
        ISmartPoolActions(usdcBasePool).burn(interleaverBalanceBeforeBurn, 0);

        uint256 totalSupplyAfterBurn = ISmartPoolState(usdcBasePool).getPoolTokens().totalSupply;
        uint256 balanceAfterBurn = MockERC20(usdc).balanceOf(usdcBasePool);

        // Interleaver returns 110 USDC: most replaces the burn payout, the remainder is net donation.
        uint256 returnAmount = 110_000_000;
        uint256 donationAmount = 10_000_000;
        MockERC20(usdc).mint(interleaver, returnAmount);
        vm.prank(interleaver);
        MockERC20(usdc).transfer(usdcBasePool, returnAmount);

        uint256 amountDelta = MockERC20(usdc).balanceOf(usdcBasePool) - balanceBefore;
        assertEq(amountDelta, returnAmount - (balanceBefore - balanceAfterBurn), "Net delta mismatch");

        // Phase 2 with amount = 10 USDC succeeds.
        IECrosschain(usdcBasePool).donate(usdc, donationAmount, params);

        uint256 navAfter = ISmartPoolState(usdcBasePool).getPoolTokens().unitaryValue;
        int256 vsAfter = int256(uint256(vm.load(usdcBasePool, VirtualStorageLib.VIRTUAL_SUPPLY_SLOT)));

        // The VS delta corresponds to the donation amount (10 USDC), not the gross transfer.
        uint256 expectedVs = (donationAmount * 10 ** 6) / navBefore;
        assertApproxEqAbs(uint256(vsAfter - vsBefore), expectedVs, 1e6, "VS must derive from donation amount");

        // NAV bounds: pure Transfer of the net delta vs. pure Sync of the net delta.
        uint256 assetsAfter = MockERC20(usdc).balanceOf(usdcBasePool);
        uint256 pureTransferNav = (assetsAfter * 10 ** 6) /
            (totalSupplyAfterBurn + (amountDelta * 10 ** 6) / navBefore);
        uint256 pureSyncNav = (assetsAfter * 10 ** 6) / totalSupplyAfterBurn;

        assertGt(navAfter, pureTransferNav, "Hybrid NAV must be above pure Transfer (no unbacked supply)");
        assertLt(navAfter, pureSyncNav, "Hybrid NAV must be below pure Sync (some VS was minted)");

        // Effective supply is fully backed: assets == effectiveSupply * NAV.
        uint256 effectiveSupply = totalSupplyAfterBurn + uint256(vsAfter - vsBefore);
        assertApproxEqAbs(
            (effectiveSupply * navAfter) / 10 ** 6,
            assetsAfter,
            1e6,
            "Effective supply must be fully backed by assets"
        );

        vm.chainId(31337);
    }
}
