// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {AIntents} from "../../contracts/protocol/extensions/adapters/AIntents.sol";
import {ECrosschain} from "../../contracts/protocol/extensions/ECrosschain.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";
import {VirtualStorageLib} from "../../contracts/protocol/libraries/VirtualStorageLib.sol";
import {IAIntents} from "../../contracts/protocol/extensions/adapters/interfaces/IAIntents.sol";
import {IECrosschain} from "../../contracts/protocol/extensions/adapters/interfaces/IECrosschain.sol";
import {IMinimumVersion} from "../../contracts/protocol/extensions/adapters/interfaces/IMinimumVersion.sol";
import {OpType, DestinationMessageParams, SourceMessageParams} from "../../contracts/protocol/types/Crosschain.sol";

/// @title AcrossBridge - Unit tests migrated from the deprecated Across.spec.ts mocha suite
/// @notice Protocol-level behavior (real SpokePool deposits, handler fills, NAV effects) is covered
///         by the fork suites (AIntentsRealFork.t.sol, AIntentsPerformanceAttributionAnalysis.t.sol,
///         AIntentsSourceVSAnalysis.t.sol, ECrosschainFuzz.t.sol). This file covers the remaining
///         pure/unit assertions: message encoding roundtrips, access-control reverts, immutables,
///         storage slot derivation, NAV normalization math, and tolerance math.
contract AcrossBridgeTest is Test {
    uint256 internal constant BPS_BASE = 10_000;

    /*//////////////////////////////////////////////////////////////////////////
                            DEPLOYMENT / IMMUTABLES
    //////////////////////////////////////////////////////////////////////////*/

    function test_AIntents_RequiredVersion() public {
        AIntents aIntents = new AIntents(makeAddr("spokePool"));
        assertEq(IMinimumVersion(address(aIntents)).requiredVersion(), "4.1.0");
    }

    function test_AIntents_NonZeroBytecode() public {
        AIntents aIntents = new AIntents(makeAddr("spokePool"));
        assertGt(address(aIntents).code.length, 2);
    }

    function test_ECrosschain_NonZeroBytecode() public {
        ECrosschain eCrosschain = new ECrosschain();
        assertGt(address(eCrosschain).code.length, 2);
    }

    /*//////////////////////////////////////////////////////////////////////////
                          DIRECT CALL PROTECTION (AIntents)
    //////////////////////////////////////////////////////////////////////////*/

    function _acrossParams(address token) internal view returns (IAIntents.AcrossParams memory) {
        return
            IAIntents.AcrossParams({
                depositor: address(this),
                recipient: address(this),
                inputToken: token,
                outputToken: token,
                inputAmount: 1e6,
                outputAmount: 990_000,
                destinationChainId: 10,
                exclusiveRelayer: address(0),
                quoteTimestamp: uint32(block.timestamp),
                fillDeadline: uint32(block.timestamp + 3600),
                exclusivityDeadline: 0,
                message: abi.encode(
                    SourceMessageParams({
                        opType: OpType.Transfer,
                        navTolerance: 100,
                        sourceNativeAmount: 0,
                        shouldUnwrapOnDestination: false
                    })
                )
            });
    }

    function test_AIntents_DirectCallReverts() public {
        AIntents aIntents = new AIntents(makeAddr("spokePool"));
        MockERC20 token = new MockERC20("USD Coin", "USDC", 6);

        vm.expectRevert(IAIntents.DirectCallNotAllowed.selector);
        aIntents.depositV3(_acrossParams(address(token)));
    }

    function test_AIntents_DirectCallFromAnyAccountReverts() public {
        AIntents aIntents = new AIntents(makeAddr("spokePool"));
        MockERC20 token = new MockERC20("USD Coin", "USDC", 6);

        address caller = makeAddr("caller");
        vm.prank(caller);
        vm.expectRevert(IAIntents.DirectCallNotAllowed.selector);
        aIntents.depositV3(_acrossParams(address(token)));
    }

    /*//////////////////////////////////////////////////////////////////////////
                    ACCESS CONTROL (ECrosschain donation lock)
    //////////////////////////////////////////////////////////////////////////*/

    function test_ECrosschain_DonateWithoutLockRevertsForAnyCaller() public {
        ECrosschain eCrosschain = new ECrosschain();
        MockERC20 token = new MockERC20("USD Coin", "USDC", 6);

        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });

        // Test contract itself
        vm.expectRevert(abi.encodeWithSelector(IECrosschain.DonationLock.selector, false));
        IECrosschain(address(eCrosschain)).donate(address(token), 1e6, params);

        // Arbitrary user
        address user = makeAddr("user");
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IECrosschain.DonationLock.selector, false));
        IECrosschain(address(eCrosschain)).donate(address(token), 1e6, params);

        // Deployer-like privileged EOA: the lock is what gates donations, not the caller
        address deployer = makeAddr("deployer");
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IECrosschain.DonationLock.selector, false));
        IECrosschain(address(eCrosschain)).donate(address(token), 1e6, params);
    }

    /*//////////////////////////////////////////////////////////////////////////
                          DESTINATION MESSAGE ENCODING
    //////////////////////////////////////////////////////////////////////////*/

    function test_DestinationMessage_TransferModeRoundtrip() public pure {
        DestinationMessageParams memory minMsg = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });
        DestinationMessageParams memory decodedMin = abi.decode(abi.encode(minMsg), (DestinationMessageParams));
        assertEq(uint8(decodedMin.opType), uint8(OpType.Transfer));
        assertFalse(decodedMin.shouldUnwrapNative);

        DestinationMessageParams memory maxMsg = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: true
        });
        DestinationMessageParams memory decodedMax = abi.decode(abi.encode(maxMsg), (DestinationMessageParams));
        assertEq(uint8(decodedMax.opType), uint8(OpType.Transfer));
        assertTrue(decodedMax.shouldUnwrapNative);
    }

    function test_DestinationMessage_SyncModeRoundtrip() public pure {
        DestinationMessageParams memory syncMsg = DestinationMessageParams({
            opType: OpType.Sync,
            shouldUnwrapNative: true
        });
        DestinationMessageParams memory decoded = abi.decode(abi.encode(syncMsg), (DestinationMessageParams));
        assertEq(uint8(decoded.opType), uint8(OpType.Sync));
        assertTrue(decoded.shouldUnwrapNative);
    }

    function test_DestinationMessage_AllOpTypeCombinations() public pure {
        OpType[2] memory opTypes = [OpType.Transfer, OpType.Sync];
        for (uint256 i = 0; i < opTypes.length; i++) {
            for (uint256 j = 0; j < 2; j++) {
                DestinationMessageParams memory message = DestinationMessageParams({
                    opType: opTypes[i],
                    shouldUnwrapNative: j == 1
                });
                DestinationMessageParams memory decoded = abi.decode(abi.encode(message), (DestinationMessageParams));
                assertEq(uint8(decoded.opType), uint8(opTypes[i]));
                assertEq(decoded.shouldUnwrapNative, j == 1);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                            SOURCE MESSAGE ENCODING
    //////////////////////////////////////////////////////////////////////////*/

    function test_SourceMessage_TransferModeRoundtrip() public pure {
        SourceMessageParams memory message = SourceMessageParams({
            opType: OpType.Transfer,
            navTolerance: 100,
            sourceNativeAmount: 0,
            shouldUnwrapOnDestination: false
        });
        SourceMessageParams memory decoded = abi.decode(abi.encode(message), (SourceMessageParams));
        assertEq(uint8(decoded.opType), uint8(OpType.Transfer));
        assertEq(decoded.navTolerance, 100);
        assertEq(decoded.sourceNativeAmount, 0);
        assertFalse(decoded.shouldUnwrapOnDestination);
    }

    function test_SourceMessage_SyncModeWithNativeAmountRoundtrip() public pure {
        SourceMessageParams memory message = SourceMessageParams({
            opType: OpType.Sync,
            navTolerance: 200,
            sourceNativeAmount: 1 ether,
            shouldUnwrapOnDestination: true
        });
        SourceMessageParams memory decoded = abi.decode(abi.encode(message), (SourceMessageParams));
        assertEq(uint8(decoded.opType), uint8(OpType.Sync));
        assertEq(decoded.navTolerance, 200);
        assertEq(decoded.sourceNativeAmount, 1 ether);
        assertTrue(decoded.shouldUnwrapOnDestination);
    }

    function test_SourceMessage_ZeroToleranceRoundtrip() public pure {
        SourceMessageParams memory message = SourceMessageParams({
            opType: OpType.Sync,
            navTolerance: 0,
            sourceNativeAmount: 0,
            shouldUnwrapOnDestination: false
        });
        SourceMessageParams memory decoded = abi.decode(abi.encode(message), (SourceMessageParams));
        assertEq(uint8(decoded.opType), uint8(OpType.Sync));
        assertEq(decoded.navTolerance, 0);
    }

    function test_SourceMessage_AllToleranceValues() public pure {
        uint256[5] memory tolerances = [uint256(0), 50, 100, 200, 500];
        for (uint256 i = 0; i < tolerances.length; i++) {
            SourceMessageParams memory message = SourceMessageParams({
                opType: OpType.Transfer,
                navTolerance: tolerances[i],
                sourceNativeAmount: 0,
                shouldUnwrapOnDestination: false
            });
            SourceMessageParams memory decoded = abi.decode(abi.encode(message), (SourceMessageParams));
            assertEq(decoded.navTolerance, tolerances[i]);
        }
    }

    function test_SourceMessage_AllOpTypeCombinations() public pure {
        OpType[2] memory opTypes = [OpType.Transfer, OpType.Sync];
        for (uint256 i = 0; i < opTypes.length; i++) {
            SourceMessageParams memory message = SourceMessageParams({
                opType: opTypes[i],
                navTolerance: 100,
                sourceNativeAmount: 0,
                shouldUnwrapOnDestination: false
            });
            SourceMessageParams memory decoded = abi.decode(abi.encode(message), (SourceMessageParams));
            assertEq(uint8(decoded.opType), uint8(opTypes[i]));
            assertEq(decoded.navTolerance, 100);
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                              VIRTUAL SUPPLY SLOT
    //////////////////////////////////////////////////////////////////////////*/

    function test_VirtualSupplySlot_MatchesErc7201Pattern() public pure {
        bytes32 expected = bytes32(uint256(keccak256("pool.proxy.virtual.supply")) - 1);
        assertEq(VirtualStorageLib.VIRTUAL_SUPPLY_SLOT, expected);
        assertTrue(uint256(expected) != 0);
    }

    function test_VirtualSupplySlot_MatchesCanonicalValue() public pure {
        // keccak256("pool.proxy.virtual.supply") (dot notation namespace)
        assertEq(
            keccak256("pool.proxy.virtual.supply"),
            0xc1634c3ed93b1f7aa4d725c710ac3b239c1d30894404e630b60009ee34114510
        );
        // Canonical ERC-7201 slot = keccak256(namespace) - 1
        assertEq(
            VirtualStorageLib.VIRTUAL_SUPPLY_SLOT,
            0xc1634c3ed93b1f7aa4d725c710ac3b239c1d30894404e630b60009ee3411450f
        );
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  OP TYPE ENUM
    //////////////////////////////////////////////////////////////////////////*/

    function test_OpType_EnumValuesOrderingAndDistinctness() public pure {
        assertEq(uint8(OpType.Transfer), 0);
        assertEq(uint8(OpType.Sync), 1);
        assertTrue(uint8(OpType.Transfer) < uint8(OpType.Sync));
        assertTrue(uint8(OpType.Transfer) != uint8(OpType.Sync));
    }

    /*//////////////////////////////////////////////////////////////////////////
                              NAV NORMALIZATION MATH
    //////////////////////////////////////////////////////////////////////////*/

    function test_NavNormalization_Downscale() public pure {
        uint256 nav = 1 ether; // 18 decimals
        uint256 downscaled = nav / 10 ** (18 - 6);
        assertEq(downscaled, 1e6);
    }

    function test_NavNormalization_Upscale() public pure {
        uint256 nav = 1e6; // 6 decimals
        uint256 upscaled = nav * 10 ** (18 - 6);
        assertEq(upscaled, 1 ether);
    }

    function test_NavNormalization_PrecisionLossOnDownscale() public pure {
        uint256 nav = 1.123456789123456789 ether;
        uint256 downscaled = nav / 10 ** (18 - 6);
        assertEq(downscaled, 1.123456e6);
    }

    /*//////////////////////////////////////////////////////////////////////////
                               TOLERANCE MATH
    //////////////////////////////////////////////////////////////////////////*/

    function test_Tolerance_Percentages() public pure {
        assertEq((1 ether * 100) / BPS_BASE, 0.01 ether); // 1%
        assertEq((1 ether * 200) / BPS_BASE, 0.02 ether); // 2%
        assertEq((100 ether * 500) / BPS_BASE, 5 ether); // 5%
        assertEq((100 ether * 1000) / BPS_BASE, 10 ether); // 10%
        assertEq((10_000 ether * 1) / BPS_BASE, 1 ether); // 0.01%
    }

    function test_Tolerance_RangeAroundNav() public pure {
        uint256 nav = 1 ether;
        uint256 toleranceAmount = (nav * 100) / BPS_BASE;
        assertEq(nav - toleranceAmount, 0.99 ether);
        assertEq(nav + toleranceAmount, 1.01 ether);
    }

    function test_Tolerance_ScalesLinearlyWithNav() public pure {
        uint256[3] memory navs = [uint256(1 ether), 100 ether, 0.01 ether];
        for (uint256 i = 0; i < navs.length; i++) {
            uint256 toleranceAmount = (navs[i] * 100) / BPS_BASE;
            assertEq(toleranceAmount, navs[i] / 100);
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                              TOKEN FUNCTIONALITY
    //////////////////////////////////////////////////////////////////////////*/

    function test_MockERC20_MintTransferApprove() public {
        MockERC20 token = new MockERC20("USD Coin", "USDC", 6);
        address user = makeAddr("user");
        address spender = makeAddr("spender");

        token.mint(address(this), 100e6);
        assertEq(token.balanceOf(address(this)), 100e6);

        token.transfer(user, 10e6);
        assertEq(token.balanceOf(user), 10e6);

        token.approve(spender, 50e6);
        assertEq(token.allowance(address(this), spender), 50e6);
    }
}
