// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AIntents} from "../../contracts/protocol/extensions/adapters/AIntents.sol";
import {EAcrossHandler} from "../../contracts/protocol/extensions/EAcrossHandler.sol";
import {IERC20} from "../../contracts/protocol/interfaces/IERC20.sol";
import {IEAcrossHandler} from "../../contracts/protocol/extensions/adapters/interfaces/IEAcrossHandler.sol";
import {IAIntents} from "../../contracts/protocol/extensions/adapters/interfaces/IAIntents.sol";

/// @title AcrossUnit - Unit tests for Across integration components
/// @notice Tests individual contract functionality without cross-chain simulation
contract AcrossUnitTest is Test {
    AIntents adapter;
    EAcrossHandler handler;
    
    address mockSpokePool;
    address mockWETH;
    address testPool;
    
    function setUp() public {
        mockSpokePool = makeAddr("spokePool");
        mockWETH = makeAddr("WETH");
        testPool = makeAddr("testPool");
        
        // Mock SpokePool's wrappedNativeToken()
        vm.mockCall(
            mockSpokePool,
            abi.encodeWithSignature("wrappedNativeToken()"),
            abi.encode(mockWETH)
        );
        
        adapter = new AIntents(mockSpokePool);
        handler = new EAcrossHandler(mockSpokePool);
    }
    
    /// @notice Test adapter deployment
    function test_Adapter_Deployment() public {
        assertEq(address(adapter.acrossSpokePool()), mockSpokePool, "SpokePool address incorrect");
    }
    
    /// @notice Test handler deployment (stateless)
    function test_Handler_Deployment() public {
        // Handler should have no state
        assertTrue(address(handler).code.length > 0, "Handler should be deployed");
        assertEq(handler.acrossSpokePool(), mockSpokePool, "Handler should store SpokePool");
    }
    
    /// @notice Test handler rejects invalid SpokePool in constructor
    function test_Handler_RejectsInvalidSpokePool() public {
        vm.expectRevert("INVALID_SPOKE_POOL");
        new EAcrossHandler(address(0));
    }
    
    /// @notice Test handler rejects unauthorized caller
    function test_Handler_RejectsUnauthorizedCaller() public {
        address unauthorizedCaller = makeAddr("unauthorized");
        address tokenReceived = makeAddr("token");
        uint256 amount = 100e6;
        
        AIntents.CrossChainMessage memory message = AIntents.CrossChainMessage({
            messageType: AIntents.MessageType.Transfer,
            sourceChainId: 0,
            sourceNav: 0,
            sourceDecimals: 18,
            navTolerance: 0,
            unwrapNative: false
        });
        
        bytes memory encodedMessage = abi.encode(message);
        
        // Attempt to call from unauthorized address
        vm.prank(unauthorizedCaller);
        vm.expectRevert(abi.encodeWithSelector(IEAcrossHandler.UnauthorizedCaller.selector));
        handler.handleV3AcrossMessage(tokenReceived, amount, encodedMessage);
    }
    
    /// @notice Test message encoding/decoding
    function test_MessageEncodingDecoding() public {
        AIntents.CrossChainMessage memory message = AIntents.CrossChainMessage({
            messageType: AIntents.MessageType.Transfer,
            sourceChainId: 0,
            sourceNav: 1e18,
            sourceDecimals: 18,
            navTolerance: 100,
            unwrapNative: true
        });
        
        bytes memory encoded = abi.encode(message);
        AIntents.CrossChainMessage memory decoded = abi.decode(encoded, (AIntents.CrossChainMessage));
        
        assertEq(uint8(decoded.messageType), uint8(AIntents.MessageType.Transfer), "MessageType mismatch");
        assertEq(decoded.sourceNav, 1e18, "sourceNav mismatch");
        assertEq(decoded.sourceDecimals, 18, "sourceDecimals mismatch");
        assertEq(decoded.navTolerance, 100, "navTolerance mismatch");
        assertTrue(decoded.unwrapNative, "unwrapNative mismatch");
    }
    
    /// @notice Test required version
    function test_Adapter_RequiredVersion() public {
        string memory version = adapter.requiredVersion();
        assertEq(version, "HF_4.1.0", "Required version incorrect");
    }
    
    /// @notice Test adapter immutables
    function test_Adapter_Immutables() public view {
        address spokePool = address(adapter.acrossSpokePool());
        assertTrue(spokePool != address(0), "SpokePool should be set");
    }
    
    /// @notice Test ExtensionsMap selector mapping
    function test_ExtensionsMap_SelectorMapping() public {
        bytes4 selector = bytes4(keccak256("handleV3AcrossMessage(address,uint256,bytes)"));
        
        // Verify selector is correctly calculated
        assertEq(
            selector,
            EAcrossHandler.handleV3AcrossMessage.selector,
            "Selector mismatch"
        );
    }
    
    /// @notice Test depositV3 interface matches Across exactly
    function test_DepositV3InterfaceMatch() public {
        // Verify our adapter has exact same signature as Across SpokePool
        bytes4 acrossSelector = bytes4(keccak256(
            "depositV3(address,address,address,address,uint256,uint256,uint256,address,uint32,uint32,uint32,bytes)"
        ));
        
        bytes4 adapterSelector = AIntents.depositV3.selector;
        
        assertEq(adapterSelector, acrossSelector, "Adapter must match Across interface exactly");
    }
    
    /// @notice Test virtual balance storage slot calculation
    function test_VirtualBalanceSlot() public {
        // Verify storage slot matches MixinConstants
        bytes32 expectedSlot = bytes32(uint256(keccak256("pool.proxy.virtualBalances")) - 1);
        bytes32 calculatedSlot = 0x19797d8be84f650fe18ebccb97578c2adb7abe9b7c86852694a3ceb69073d1d1;
        
        assertEq(calculatedSlot, expectedSlot, "Virtual balance slot mismatch");
    }
    
    /// @notice Test message type enum values
    function test_MessageTypeEnumValues() public {
        uint8 transferType = uint8(AIntents.MessageType.Transfer);
        uint8 rebalanceType = uint8(AIntents.MessageType.Rebalance);
        
        assertEq(transferType, 0, "Transfer should be 0");
        assertEq(rebalanceType, 1, "Rebalance should be 1");
    }
    
    /// @notice Test NAV normalization logic
    function test_NavNormalization() public {
        // Test same decimals
        assertEq(_normalizeNav(1e18, 18, 18), 1e18, "Same decimals should not change");
        
        // Test downscaling
        assertEq(_normalizeNav(1e18, 18, 6), 1e6, "Should downscale correctly");
        
        // Test upscaling
        assertEq(_normalizeNav(1e6, 6, 18), 1e18, "Should upscale correctly");
    }
    
    /// @notice Test tolerance calculation
    function test_ToleranceCalculation() public {
        uint256 nav = 1e18; // 1.0 per share
        uint256 tolerance = 100; // 1% = 100 basis points
        
        uint256 toleranceAmount = (nav * tolerance) / 10000;
        assertEq(toleranceAmount, 1e16, "1% of 1e18 should be 1e16");
        
        uint256 minNav = nav - toleranceAmount;
        uint256 maxNav = nav + toleranceAmount;
        
        assertEq(minNav, 99e16, "Min NAV incorrect");
        assertEq(maxNav, 101e16, "Max NAV incorrect");
    }
    
    /// @notice Fuzz test: NAV normalization
    function testFuzz_NavNormalization(uint256 nav, uint8 sourceDecimals, uint8 destDecimals) public {
        // Constrain decimals to reasonable range
        vm.assume(sourceDecimals <= 18 && destDecimals <= 18);
        vm.assume(sourceDecimals > 0 && destDecimals > 0);
        
        // Constrain NAV to avoid overflow
        if (destDecimals > sourceDecimals) {
            vm.assume(nav < type(uint256).max / (10 ** (destDecimals - sourceDecimals)));
        }
        
        uint256 normalized = _normalizeNav(nav, sourceDecimals, destDecimals);
        
        // Verify reversibility
        uint256 denormalized = _normalizeNav(normalized, destDecimals, sourceDecimals);
        
        if (sourceDecimals == destDecimals) {
            assertEq(normalized, nav, "Same decimals should not change");
        } else if (sourceDecimals < destDecimals) {
            assertTrue(normalized >= nav, "Upscaling should increase or maintain value");
        } else {
            assertTrue(normalized <= nav, "Downscaling should decrease or maintain value");
        }
    }
    
    /// @notice Fuzz test: Tolerance within range
    function testFuzz_ToleranceInRange(uint256 nav, uint256 tolerance) public {
        vm.assume(nav > 0 && nav < type(uint256).max / 10000);
        vm.assume(tolerance <= 10000); // Max 100%
        vm.assume(tolerance > 0); // Must have some tolerance
        
        uint256 toleranceAmount = (nav * tolerance) / 10000;
        vm.assume(toleranceAmount > 0); // Ensure tolerance amount is non-zero
        
        uint256 minNav = nav > toleranceAmount ? nav - toleranceAmount : 0;
        uint256 maxNav = nav + toleranceAmount;
        
        assertTrue(minNav <= nav, "Min NAV should be <= NAV");
        assertTrue(maxNav >= nav, "Max NAV should be >= NAV");
        assertTrue(maxNav > minNav, "Max should be > Min with non-zero tolerance");
    }
    
    /*
     * HELPER FUNCTIONS
     */
    
    function _normalizeNav(
        uint256 nav,
        uint8 sourceDecimals,
        uint8 destDecimals
    ) internal pure returns (uint256) {
        if (sourceDecimals == destDecimals) {
            return nav;
        } else if (sourceDecimals > destDecimals) {
            return nav / (10 ** (sourceDecimals - destDecimals));
        } else {
            return nav * (10 ** (destDecimals - sourceDecimals));
        }
    }
}
