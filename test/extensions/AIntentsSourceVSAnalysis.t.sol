// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Constants} from "../../contracts/test/Constants.sol";
import {RealDeploymentFixture} from "../fixtures/RealDeploymentFixture.sol";

import {ISmartPoolActions} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolActions.sol";
import {ISmartPoolState} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolState.sol";
import {IERC20} from "../../contracts/protocol/interfaces/IERC20.sol";
import {IAIntents} from "../../contracts/protocol/extensions/adapters/interfaces/IAIntents.sol";
import {IECrosschain} from "../../contracts/protocol/extensions/adapters/interfaces/IECrosschain.sol";
import {OpType, DestinationMessageParams, SourceMessageParams, Call, Instructions} from "../../contracts/protocol/types/Crosschain.sol";
import {VirtualStorageLib} from "../../contracts/protocol/libraries/VirtualStorageLib.sol";

interface IMulticallHandler {
    function handleV3AcrossMessage(address token, uint256, address, bytes memory message) external;
    function drainLeftoverTokens(address token, address payable destination) external;
}

/// @title Analyze solver fee impact on source-chain NAV via virtual supply burn.
/// @notice All tests start from totalSupply=0, VS-only pools with 100 USDC.
contract AIntentsSourceVSAnalysisTest is Test, RealDeploymentFixture {
    uint256 constant TOLERANCE_BPS = 800;
    bytes32 constant VS_SLOT = VirtualStorageLib.VIRTUAL_SUPPLY_SLOT;

    function setUp() public {
        address[] memory baseTokens = new address[](2);
        baseTokens[0] = Constants.ETH_USDC;
        baseTokens[1] = Constants.BASE_USDC;
        deployFixture(baseTokens);

        // Burn ALL fixture-minted pool tokens on Base so totalSupply = 0.
        vm.selectFork(baseForkId);
        uint256 ts = ISmartPoolState(base.pool).getPoolTokens().totalSupply;
        if (ts > 0) {
            address burner = makeAddr("burner");
            deal(base.pool, burner, ts);
            vm.prank(burner);
            ISmartPoolActions(base.pool).burn(ts, 0);
        }
        assertEq(ISmartPoolState(base.pool).getPoolTokens().totalSupply, 0, "setUp: totalSupply must be 0");

        // Receive 100 USDC cross-chain to create VS = +100e6
        _simulateReceiveOnBase(100e6);

        // Verify clean starting state
        vm.selectFork(baseForkId);
        ISmartPoolActions(base.pool).updateUnitaryValue();
        assertEq(ISmartPoolState(base.pool).getPoolTokens().totalSupply, 0, "setUp: totalSupply still 0");
        assertEq(IERC20(Constants.BASE_USDC).balanceOf(base.pool), 100e6, "setUp: pool has 100 USDC");
        int256 vs = int256(uint256(vm.load(base.pool, VS_SLOT)));
        assertEq(vs, 100e6, "setUp: VS = +100e6");
    }

    // ─── Helpers ─────────────────────────────────────────────────────

    function _buildDestInstructions(
        address token,
        address recipient,
        uint256 amount,
        address handler
    ) internal pure returns (Instructions memory) {
        Call[] memory calls = new Call[](4);
        DestinationMessageParams memory destParams =
            DestinationMessageParams({opType: OpType.Transfer, shouldUnwrapNative: false});
        calls[0] = Call({target: recipient, callData: abi.encodeCall(IECrosschain.donate, (token, 1, destParams)), value: 0});
        calls[1] = Call({target: token, callData: abi.encodeCall(IERC20.transfer, (recipient, amount)), value: 0});
        calls[2] = Call({target: handler, callData: abi.encodeCall(IMulticallHandler.drainLeftoverTokens, (token, payable(recipient))), value: 0});
        calls[3] = Call({target: recipient, callData: abi.encodeCall(IECrosschain.donate, (token, amount, destParams)), value: 0});
        return Instructions({calls: calls, fallbackRecipient: address(0)});
    }

    function _simulateReceiveOnBase(uint256 amount) internal {
        vm.selectFork(baseForkId);
        address handler = Constants.BASE_MULTICALL_HANDLER;
        deal(Constants.BASE_USDC, handler, amount);
        vm.prank(address(0xBEEF));
        IMulticallHandler(handler).handleV3AcrossMessage(
            Constants.BASE_USDC, amount, address(0xBEEF),
            abi.encode(_buildDestInstructions(Constants.BASE_USDC, base.pool, amount, handler))
        );
    }

    function _depositV3(uint256 inputAmount, uint256 outputAmount) internal {
        vm.selectFork(baseForkId);
        vm.prank(poolOwner);
        IAIntents(base.pool).depositV3(
            IAIntents.AcrossParams({
                depositor: poolOwner,
                recipient: poolOwner,
                inputToken: Constants.BASE_USDC,
                outputToken: Constants.ETH_USDC,
                inputAmount: inputAmount,
                outputAmount: outputAmount,
                destinationChainId: Constants.ETHEREUM_CHAIN_ID,
                exclusiveRelayer: address(0),
                quoteTimestamp: uint32(block.timestamp),
                fillDeadline: uint32(block.timestamp + 1 hours),
                exclusivityDeadline: 0,
                message: abi.encode(
                    SourceMessageParams({
                        opType: OpType.Transfer,
                        navTolerance: TOLERANCE_BPS,
                        shouldUnwrapOnDestination: false,
                        sourceNativeAmount: 0
                    })
                )
            })
        );
    }

    function _readVS() internal view returns (int256) {
        return int256(uint256(vm.load(base.pool, VS_SLOT)));
    }

    // ─── Tests ───────────────────────────────────────────────────────

    /// @notice 50% effective-supply burn with 1% solver fee.
    ///
    /// Starting state: totalSupply=0, VS=+100, balance=100 USDC, NAV=$1.00
    /// Transfer: inputAmount=50 (SpokePool takes 50), outputAmount=49.5 (solver fee=0.5)
    ///
    /// Expected: _handleSourceTransfer burns outputAmount/NAV = 49.5 shares from VS.
    ///   VS after   = 100 - 49.5 = 50.5
    ///   Balance     = 100 - 50   = 50
    ///   Eff. supply = 0 + 50.5   = 50.5
    ///   NAV         = 50 / 50.5  = $0.9901 (drop of ~99 bps)
    ///
    /// The solver fee ($0.50) is 50 bps of total pre-transfer assets ($100)
    /// but the NAV impact is 99 bps because it concentrates on remaining $50.
    function test_HalfSupplyBurn_1pctFee() public {
        vm.selectFork(baseForkId);

        // Pre-transfer snapshot
        uint256 navBefore = ISmartPoolState(base.pool).getPoolTokens().unitaryValue;
        int256 vsBefore = _readVS();
        uint256 balBefore = IERC20(Constants.BASE_USDC).balanceOf(base.pool);

        // Execute: 50 USDC out, solver keeps 0.5
        _depositV3(50e6, 49_500_000);

        // Post-transfer reads
        int256 vsAfter = _readVS();
        uint256 balAfter = IERC20(Constants.BASE_USDC).balanceOf(base.pool);
        ISmartPoolActions(base.pool).updateUnitaryValue();
        uint256 navAfter = ISmartPoolState(base.pool).getPoolTokens().unitaryValue;

        // Log for analysis
        console2.log("=== 50% burn, 1% fee ===");
        console2.log("  VS before / after:", uint256(vsBefore), uint256(vsAfter));
        console2.log("  Balance before / after:", balBefore, balAfter);
        console2.log("  NAV before / after:", navBefore, navAfter);

        // 1. SpokePool took exactly inputAmount
        assertEq(balBefore - balAfter, 50e6, "SpokePool takes inputAmount (50 USDC)");

        // 2. Remaining balance = 50 USDC
        assertEq(balAfter, 50e6, "Pool has 50 USDC remaining");

        // 3. VS burn = outputAmount/NAV = 49.5e6 (since NAV=$1.00 = 1e6)
        int256 vsBurned = vsBefore - vsAfter;
        assertEq(vsBurned, 49_500_000, "VS burned = outputAmount / NAV = 49.5e6");

        // 4. Remaining VS = 50.5e6 (not 50e6 — the 0.5e6 excess is the fee in shares)
        assertEq(vsAfter, 50_500_000, "VS remaining = 50.5e6 (includes 0.5e6 fee-in-shares)");

        // 5. NAV drops: 50e6 assets / 50.5e6 effective supply = 990099
        assertLt(navAfter, navBefore, "NAV decreases from solver fee");
        // 50_000_000 * 1e6 / 50_500_000 = 990099 (integer division)
        assertEq(navAfter, 990099, "NAV = 50/50.5 = $0.9901");

        // 6. Fee was 50 bps of total assets but NAV drop is ~99 bps
        uint256 navDropBps = (navBefore - navAfter) * 10000 / navBefore;
        assertEq(navDropBps, 99, "NAV drop = 99 bps (~1% of remaining, ~0.5% of total amplified 2x)");
    }

    /// @notice 100% effective-supply burn with 1% solver fee.
    ///
    /// Starting state: totalSupply=0, VS=+100, balance=100 USDC, NAV=$1.00
    /// Transfer: inputAmount=100, outputAmount=99 (fee=1 USDC)
    ///
    /// Expected: VS burn = 99/1.0 = 99. VS after = 100-99 = +1 (phantom).
    ///   Balance = 0. effectiveSupply = 1.
    ///   _updateNav: netTotalValue=0, effectiveSupply>0 => else branch => returns stored NAV.
    ///   NAV stays at $1.00 — stale, backed by $0 assets.
    function test_FullSupplyBurn_1pctFee() public {
        vm.selectFork(baseForkId);

        uint256 navBefore = ISmartPoolState(base.pool).getPoolTokens().unitaryValue;
        int256 vsBefore = _readVS();

        _depositV3(100e6, 99e6);

        int256 vsAfter = _readVS();
        uint256 balAfter = IERC20(Constants.BASE_USDC).balanceOf(base.pool);
        ISmartPoolActions(base.pool).updateUnitaryValue();
        uint256 navAfter = ISmartPoolState(base.pool).getPoolTokens().unitaryValue;

        console2.log("=== 100% burn, 1% fee ===");
        console2.log("  VS before / after:", uint256(vsBefore), uint256(vsAfter));
        console2.log("  Balance after:", balAfter);
        console2.log("  NAV before / after:", navBefore, navAfter);

        // 1. All assets left
        assertEq(balAfter, 0, "Pool is empty");

        // 2. VS burn = outputAmount/NAV = 99e6
        assertEq(vsBefore - vsAfter, 99e6, "VS burned = 99e6 (outputAmount/NAV)");

        // 3. Phantom VS = 1e6 (fee in shares, backed by $0)
        assertEq(vsAfter, 1e6, "Phantom VS = 1e6 (fee/NAV, backed by nothing)");

        // 4. NAV: netTotalValue=0, effectiveSupply=1 => stored NAV returned unchanged
        assertEq(navAfter, navBefore, "NAV unchanged (empty pool returns stored value)");
    }
}
