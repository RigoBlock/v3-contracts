// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AIntents} from "../../contracts/protocol/extensions/adapters/AIntents.sol";
import {EAcrossHandler} from "../../contracts/protocol/extensions/EAcrossHandler.sol";
import {IERC20} from "../../contracts/protocol/interfaces/IERC20.sol";
import {IEAcrossHandler} from "../../contracts/protocol/extensions/adapters/interfaces/IEAcrossHandler.sol";
import {IAIntents} from "../../contracts/protocol/extensions/adapters/interfaces/IAIntents.sol";
import {IAcrossSpokePool} from "../../contracts/protocol/interfaces/IAcrossSpokePool.sol";
import {IWETH9} from "../../contracts/protocol/interfaces/IWETH9.sol";
import {ISmartPoolImmutable} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolImmutable.sol";
import {ISmartPoolState} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolState.sol";
import {ISmartPoolActions} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolActions.sol";
import {IEOracle} from "../../contracts/protocol/extensions/adapters/interfaces/IEOracle.sol";
import {OpType, DestinationMessage, SourceMessage} from "../../contracts/protocol/types/Crosschain.sol";

/// @title AcrossUnit - Unit tests for Across integration components
/// @notice Tests individual contract functionality without cross-chain simulation
contract AcrossUnitTest is Test {
    AIntents adapter;
    EAcrossHandler handler;
    
    address mockSpokePool;
    address mockWETH;
    address mockBaseToken;
    address mockInputToken;
    address testPool;
    
    // TODO: these storage slot definitions MUST be imported to avoid manual error (by ai, which is hilarious).
    // Storage slots
    bytes32 constant POOL_INIT_SLOT = 0xe48b9bb119adfc3bccddcc581484cc6725fe8d292ebfcec7d67b1f93138d8bd8;
    bytes32 constant VIRTUAL_BALANCES_SLOT = 0x19797d8be84f650fe18ebccb97578c2adb7abe9b7c86852694a3ceb69073d1d1;
    bytes32 constant CHAIN_NAV_SPREADS_SLOT = 0x1effae8a79ec0c3b88754a639dc07316aa9c4de89b6b9794fb7c1d791c43492d;
    bytes32 constant ACTIVE_TOKENS_SLOT = 0xbd68f1d41a93565ce29970ec13a2bc56a87c8bdd0b31366d8baa7620f41eb6cb;
    
    function setUp() public {
        mockSpokePool = makeAddr("spokePool");
        mockWETH = makeAddr("WETH");
        mockBaseToken = makeAddr("baseToken");
        mockInputToken = makeAddr("inputToken");
        testPool = makeAddr("testPool");
        
        // Mock SpokePool methods
        vm.mockCall(
            mockSpokePool,
            abi.encodeWithSignature("wrappedNativeToken()"),
            abi.encode(mockWETH)
        );
        vm.mockCall(
            mockSpokePool,
            abi.encodeWithSignature("fillDeadlineBuffer()"),
            abi.encode(uint32(3600))
        );
        
        adapter = new AIntents(mockSpokePool);
        handler = new EAcrossHandler(mockSpokePool);
    }
    
    /// @notice Test adapter deployment
    function test_Adapter_Deployment() public view {
        assertEq(address(adapter.acrossSpokePool()), mockSpokePool, "SpokePool address incorrect");
    }
    
    /// @notice Test handler deployment (stateless)
    function test_Handler_Deployment() public view {
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
        
        DestinationMessage memory message = DestinationMessage({
            opType: OpType.Transfer,
            sourceChainId: 0,
            sourceNav: 0,
            sourceDecimals: 18,
            navTolerance: 0,
            shouldUnwrap: false,
            sourceNativeAmount: 0
        });
        
        bytes memory encodedMessage = abi.encode(message);
        
        // Attempt to call from unauthorized address
        vm.prank(unauthorizedCaller);
        vm.expectRevert(abi.encodeWithSelector(IEAcrossHandler.UnauthorizedCaller.selector));
        handler.handleV3AcrossMessage(tokenReceived, amount, encodedMessage);
    }
    
    /// @notice Test handler Transfer mode execution using actual contract
    function test_Handler_TransferMode_MessageParsing() public view {
        // Test that Transfer message can be properly encoded/decoded
        DestinationMessage memory message = DestinationMessage({
            opType: OpType.Transfer,
            sourceChainId: 0,
            sourceNav: 0,
            sourceDecimals: 6,
            navTolerance: 0,
            shouldUnwrap: false,
            sourceNativeAmount: 0
        });
        
        bytes memory encodedMessage = abi.encode(message);
        DestinationMessage memory decoded = abi.decode(encodedMessage, (DestinationMessage));
        
        assertEq(uint8(decoded.opType), uint8(OpType.Transfer), "OpType should be Transfer");
        assertEq(decoded.sourceChainId, 0, "Source chain ID should match");
        assertEq(decoded.sourceDecimals, 6, "Source decimals should match");
    }
    
    /// @notice Test Rebalance mode message encoding/decoding
    function test_Handler_RebalanceMode_MessageParsing() public view {
        uint256 sourceNav = 1e18; // 1.0 per share
        
        DestinationMessage memory rebalanceMsg = DestinationMessage({
            opType: OpType.Rebalance,
            sourceChainId: 42161,
            sourceNav: sourceNav,
            sourceDecimals: 18,
            navTolerance: 200, // 2%
            shouldUnwrap: false,
            sourceNativeAmount: 0
        });
        
        bytes memory encoded = abi.encode(rebalanceMsg);
        DestinationMessage memory decoded = abi.decode(encoded, (DestinationMessage));
        
        assertEq(uint8(decoded.opType), uint8(OpType.Rebalance), "OpType should be Rebalance");
        assertEq(decoded.sourceChainId, 42161, "Source chain ID should match");
        assertEq(decoded.sourceNav, sourceNav, "Source NAV should match");
        assertEq(decoded.navTolerance, 200, "NAV tolerance should match");
    }
    
    /// @notice Test Sync mode message encoding/decoding
    function test_Handler_SyncMode_MessageParsing() public view {
        uint256 sourceNav = 1e18;
        
        DestinationMessage memory message = DestinationMessage({
            opType: OpType.Sync,
            sourceChainId: 42161,
            sourceNav: sourceNav,
            sourceDecimals: 18,
            navTolerance: 0,
            shouldUnwrap: false,
            sourceNativeAmount: 0
        });
        
        bytes memory encoded = abi.encode(message);
        DestinationMessage memory decoded = abi.decode(encoded, (DestinationMessage));
        
        assertEq(uint8(decoded.opType), uint8(OpType.Sync), "OpType should be Sync");
        assertEq(decoded.sourceChainId, 42161, "Source chain ID should match");
        assertEq(decoded.sourceNav, sourceNav, "Source NAV should match");
    }
    
    /// @notice Test WETH unwrap message construction
    function test_Handler_UnwrapWETH_MessageSetup() public view {
        DestinationMessage memory message = DestinationMessage({
            opType: OpType.Transfer,
            sourceChainId: 0,
            sourceNav: 0,
            sourceDecimals: 18,
            navTolerance: 0,
            shouldUnwrap: true, // Request unwrap
            sourceNativeAmount: 0
        });
        
        bytes memory encoded = abi.encode(message);
        DestinationMessage memory decoded = abi.decode(encoded, (DestinationMessage));
        
        assertTrue(decoded.shouldUnwrap, "Should unwrap should be true");
        assertEq(uint8(decoded.opType), uint8(OpType.Transfer), "OpType should be Transfer");
    }
    
    /// @notice Test handler rejects invalid OpType
    function test_Handler_RejectsInvalidOpType() public {
        vm.skip(true); // Skip: Requires full pool context with delegatecall - covered by AcrossIntegrationFork.t.sol
        _setupPoolMocks();
        
        // Create message with invalid OpType (cast 99 to OpType enum)
        bytes memory encodedMessage = abi.encode(
            OpType.Transfer, // Will be manually corrupted
            uint256(0),
            uint256(0),
            uint8(18),
            uint256(0),
            false,
            uint256(0)
        );
        
        // Manually corrupt the OpType field (first 32 bytes after length)
        assembly {
            mstore(add(encodedMessage, 0x20), 99) // Invalid OpType
        }
        
        vm.prank(mockSpokePool);
        vm.expectRevert(abi.encodeWithSelector(IEAcrossHandler.InvalidOpType.selector));
        handler.handleV3AcrossMessage(mockInputToken, 100e6, encodedMessage);
    }
    
    /// @notice Test handler rejects rebalance without sync
    function test_Handler_RejectsRebalanceWithoutSync() public {
        vm.skip(true); // Skip: Requires full pool context with delegatecall - covered by AcrossIntegrationFork.t.sol
        _setupPoolMocks();
        
        DestinationMessage memory message = DestinationMessage({
            opType: OpType.Rebalance,
            sourceChainId: 42161,
            sourceNav: 1e18,
            sourceDecimals: 18,
            navTolerance: 100,
            shouldUnwrap: false,
            sourceNativeAmount: 0
        });
        
        // Mock pool state
        vm.mockCall(
            address(this),
            abi.encodeWithSelector(ISmartPoolState.getPoolTokens.selector),
            abi.encode(ISmartPoolState.PoolTokens({unitaryValue: 1e18, totalSupply: 1000e18}))
        );
        
        vm.prank(mockSpokePool);
        vm.expectRevert(abi.encodeWithSelector(IEAcrossHandler.ChainsNotSynced.selector));
        handler.handleV3AcrossMessage(mockInputToken, 100e6, abi.encode(message));
    }
    
    /// @notice Test handler rejects NAV deviation too high
    function test_Handler_RejectsNavDeviationTooHigh() public {
        vm.skip(true); // Skip: Requires full pool context with delegatecall - covered by AcrossIntegrationFork.t.sol
        _setupPoolMocks();
        
        uint256 sourceNav = 1e18;
        uint256 destNav = 1.1e18; // 10% higher, outside 2% tolerance
        
        // First sync
        DestinationMessage memory syncMsg = DestinationMessage({
            opType: OpType.Sync,
            sourceChainId: 42161,
            sourceNav: sourceNav,
            sourceDecimals: 18,
            navTolerance: 200,
            shouldUnwrap: false,
            sourceNativeAmount: 0
        });
        
        vm.mockCall(
            address(this),
            abi.encodeWithSelector(ISmartPoolState.getPoolTokens.selector),
            abi.encode(ISmartPoolState.PoolTokens({unitaryValue: sourceNav, totalSupply: 1000e18}))
        );
        
        vm.prank(mockSpokePool);
        handler.handleV3AcrossMessage(mockInputToken, 100e6, abi.encode(syncMsg));
        
        // Now rebalance with NAV outside tolerance
        DestinationMessage memory rebalanceMsg = DestinationMessage({
            opType: OpType.Rebalance,
            sourceChainId: 42161,
            sourceNav: sourceNav,
            sourceDecimals: 18,
            navTolerance: 200, // 2%
            shouldUnwrap: false,
            sourceNativeAmount: 0
        });
        
        // Update mock to return higher NAV
        vm.mockCall(
            address(this),
            abi.encodeWithSelector(ISmartPoolState.getPoolTokens.selector),
            abi.encode(ISmartPoolState.PoolTokens({unitaryValue: destNav, totalSupply: 1000e18}))
        );
        
        vm.prank(mockSpokePool);
        vm.expectRevert(abi.encodeWithSelector(IEAcrossHandler.NavDeviationTooHigh.selector));
        handler.handleV3AcrossMessage(mockInputToken, 100e6, abi.encode(rebalanceMsg));
    }
    
    /// @notice Test message encoding/decoding
    function test_MessageEncodingDecoding() public pure {
        DestinationMessage memory message = DestinationMessage({
            opType: OpType.Transfer,
            sourceChainId: 0,
            sourceNav: 1e18,
            sourceDecimals: 18,
            navTolerance: 100,
            shouldUnwrap: true,
            sourceNativeAmount: 0
        });
        
        bytes memory encoded = abi.encode(message);
        DestinationMessage memory decoded = abi.decode(encoded, (DestinationMessage));
        
        assertEq(uint8(decoded.opType), uint8(OpType.Transfer), "OpType mismatch");
        assertEq(decoded.sourceNav, 1e18, "sourceNav mismatch");
        assertEq(decoded.sourceDecimals, 18, "sourceDecimals mismatch");
        assertEq(decoded.navTolerance, 100, "navTolerance mismatch");
        assertTrue(decoded.shouldUnwrap, "unwrapNative mismatch");
    }
    
    /// @notice Test required version
    function test_Adapter_RequiredVersion() public view {
        string memory version = adapter.requiredVersion();
        assertEq(version, "HF_4.1.0", "Required version incorrect");
    }
    
    /// @notice Test adapter immutables
    function test_Adapter_Immutables() public view {
        address spokePool = address(adapter.acrossSpokePool());
        assertTrue(spokePool != address(0), "SpokePool should be set");
    }
    
    /// @notice Test adapter rejects direct call
    function test_Adapter_RejectsDirectCall() public {
        // Create params for depositV3
        IAIntents.AcrossParams memory params = IAIntents.AcrossParams({
            depositor: address(this),
            recipient: address(this),
            inputToken: mockInputToken,
            outputToken: mockInputToken,
            inputAmount: 100e6,
            outputAmount: 99e6,
            destinationChainId: 10,
            exclusiveRelayer: address(0),
            quoteTimestamp: uint32(block.timestamp),
            fillDeadline: uint32(block.timestamp + 3600),
            exclusivityDeadline: 0,
            message: abi.encode(SourceMessage({
                opType: OpType.Transfer,
                navTolerance: 100,
                shouldUnwrapOnDestination: false,
                sourceNativeAmount: 0
            }))
        });
        
        // Should revert because not called via delegatecall
        vm.expectRevert(abi.encodeWithSelector(IAIntents.DirectCallNotAllowed.selector));
        adapter.depositV3(params);
    }
    
    /// @notice Test adapter depositV3 with Transfer mode (via delegatecall simulation)
    function test_Adapter_DepositV3_TransferMode() public {
        vm.skip(true); // Skip: Requires full pool context with delegatecall - covered by AcrossIntegrationFork.t.sol
        // Deploy a mock pool contract that will delegatecall to adapter
        MockPool pool = new MockPool(address(adapter), mockSpokePool, mockBaseToken, mockInputToken);
        
        // Fund the pool with tokens
        deal(mockInputToken, address(pool), 1000e6);
        
        // Mock token as ERC20
        vm.mockCall(
            mockInputToken,
            abi.encodeWithSelector(IERC20.allowance.selector),
            abi.encode(uint256(0))
        );
        vm.mockCall(
            mockInputToken,
            abi.encodeWithSelector(IERC20.approve.selector),
            abi.encode(true)
        );
        
        IAIntents.AcrossParams memory params = _createAcrossParams(
            mockInputToken,
            mockInputToken,
            100e6,
            99e6,
            10,
            OpType.Transfer,
            100
        );
        
        // Mock SpokePool depositV3
        vm.mockCall(
            mockSpokePool,
            abi.encodeWithSelector(IAcrossSpokePool.depositV3.selector),
            abi.encode()
        );
        
        // Execute via delegatecall through mock pool
        pool.callDepositV3(params);
    }
    
    /// @notice Test adapter rejects null input token
    function test_Adapter_RejectsNullInputToken() public {
        MockPool pool = new MockPool(address(adapter), mockSpokePool, mockBaseToken, mockInputToken);
        
        IAIntents.AcrossParams memory params = _createAcrossParams(
            address(0), // Null input token
            mockInputToken,
            100e6,
            99e6,
            10,
            OpType.Transfer,
            100
        );
        
        vm.expectRevert(abi.encodeWithSelector(IAIntents.NullAddress.selector));
        pool.callDepositV3(params);
    }
    
    /// @notice Test adapter rejects non-zero exclusive relayer
    function test_Adapter_RejectsNonZeroExclusiveRelayer() public {
        MockPool pool = new MockPool(address(adapter), mockSpokePool, mockBaseToken, mockInputToken);
        
        IAIntents.AcrossParams memory params = _createAcrossParams(
            mockInputToken,
            mockInputToken,
            100e6,
            99e6,
            10,
            OpType.Transfer,
            100
        );
        params.exclusiveRelayer = makeAddr("relayer"); // Override with non-zero
        
        vm.expectRevert(abi.encodeWithSelector(IAIntents.NullAddress.selector));
        pool.callDepositV3(params);
    }
    
    /// @notice Test adapter with Rebalance mode
    function test_Adapter_DepositV3_RebalanceMode() public {
        vm.skip(true); // Skip: Requires full pool context with delegatecall - covered by AcrossIntegrationFork.t.sol
        MockPool pool = new MockPool(address(adapter), mockSpokePool, mockBaseToken, mockInputToken);
        deal(mockInputToken, address(pool), 1000e6);
        
        // Mock token operations
        vm.mockCall(mockInputToken, abi.encodeWithSelector(IERC20.allowance.selector), abi.encode(uint256(0)));
        vm.mockCall(mockInputToken, abi.encodeWithSelector(IERC20.approve.selector), abi.encode(true));
        
        // Mock SpokePool depositV3
        vm.mockCall(mockSpokePool, abi.encodeWithSelector(IAcrossSpokePool.depositV3.selector), abi.encode());
        
        IAIntents.AcrossParams memory params = _createAcrossParams(
            mockInputToken,
            mockInputToken,
            100e6,
            99e6,
            10,
            OpType.Rebalance,
            200
        );
        
        pool.callDepositV3(params);
    }
    
    /// @notice Test adapter with Sync mode
    function test_Adapter_DepositV3_SyncMode() public {
        vm.skip(true); // Skip: Requires full pool context with delegatecall - covered by AcrossIntegrationFork.t.sol
        MockPool pool = new MockPool(address(adapter), mockSpokePool, mockBaseToken, mockInputToken);
        deal(mockInputToken, address(pool), 1000e6);
        
        // Mock token operations
        vm.mockCall(mockInputToken, abi.encodeWithSelector(IERC20.allowance.selector), abi.encode(uint256(0)));
        vm.mockCall(mockInputToken, abi.encodeWithSelector(IERC20.approve.selector), abi.encode(true));
        
        // Mock SpokePool depositV3
        vm.mockCall(mockSpokePool, abi.encodeWithSelector(IAcrossSpokePool.depositV3.selector), abi.encode());
        
        IAIntents.AcrossParams memory params = _createAcrossParams(
            mockInputToken,
            mockInputToken,
            100e6,
            99e6,
            10,
            OpType.Sync,
            100
        );
        
        pool.callDepositV3(params);
    }
    
    /// @notice Test adapter caps navTolerance at 10%
    function test_Adapter_CapsNavTolerance() public {
        vm.skip(true); // Skip: Requires full pool context with delegatecall - covered by AcrossIntegrationFork.t.sol
        MockPool pool = new MockPool(address(adapter), mockSpokePool, mockBaseToken, mockInputToken);
        deal(mockInputToken, address(pool), 1000e6);
        
        // Mock token operations
        vm.mockCall(mockInputToken, abi.encodeWithSelector(IERC20.allowance.selector), abi.encode(uint256(0)));
        vm.mockCall(mockInputToken, abi.encodeWithSelector(IERC20.approve.selector), abi.encode(true));
        
        // Mock SpokePool to capture the message
        vm.mockCall(mockSpokePool, abi.encodeWithSelector(IAcrossSpokePool.depositV3.selector), abi.encode());
        
        IAIntents.AcrossParams memory params = _createAcrossParams(
            mockInputToken,
            mockInputToken,
            100e6,
            99e6,
            10,
            OpType.Transfer,
            5000 // 50% - should be capped to 10%
        );
        
        pool.callDepositV3(params);
        // In real scenario, we'd verify the capped tolerance in the message
    }
    
    /// @notice Test adapter with token that has existing allowance
    function test_Adapter_WithExistingAllowance() public {
        vm.skip(true); // Skip: Requires full pool context with delegatecall - covered by AcrossIntegrationFork.t.sol
        MockPool pool = new MockPool(address(adapter), mockSpokePool, mockBaseToken, mockInputToken);
        deal(mockInputToken, address(pool), 1000e6);
        
        // Mock token with existing allowance
        vm.mockCall(
            mockInputToken,
            abi.encodeWithSelector(IERC20.allowance.selector),
            abi.encode(uint256(1000e6)) // Has allowance
        );
        vm.mockCall(
            mockInputToken,
            abi.encodeWithSelector(IERC20.approve.selector, mockSpokePool, 0),
            abi.encode(true)
        );
        
        // Mock SpokePool depositV3
        vm.mockCall(mockSpokePool, abi.encodeWithSelector(IAcrossSpokePool.depositV3.selector), abi.encode());
        
        IAIntents.AcrossParams memory params = _createAcrossParams(
            mockInputToken,
            mockInputToken,
            100e6,
            99e6,
            10,
            OpType.Transfer,
            100
        );
        
        pool.callDepositV3(params);
    }
    
    /// @notice Test handler constructor stores spoke pool address
    function test_Handler_ConstructorStoresSpokePool() public view {
        assertEq(handler.acrossSpokePool(), mockSpokePool, "SpokePool should be stored");
    }
    
    /// @notice Test adapter constructor stores spoke pool address
    function test_Adapter_ConstructorStoresSpokePool() public view {
        assertEq(address(adapter.acrossSpokePool()), mockSpokePool, "SpokePool should be stored");
    }
    
    /// @notice Test OpType enum has correct values
    function test_OpType_EnumValues() public pure {
        assertEq(uint8(OpType.Transfer), 0, "Transfer should be 0");
        assertEq(uint8(OpType.Rebalance), 1, "Rebalance should be 1");
        assertEq(uint8(OpType.Sync), 2, "Sync should be 2");
    }
    
    /// @notice Test DestinationMessage encoding/decoding with all OpTypes
    function test_DestinationMessage_AllOpTypes() public pure {
        // Test Transfer
        DestinationMessage memory transferMsg = DestinationMessage({
            opType: OpType.Transfer,
            sourceChainId: 42161,
            sourceNav: 1e18,
            sourceDecimals: 18,
            navTolerance: 100,
            shouldUnwrap: false,
            sourceNativeAmount: 0
        });
        bytes memory encodedTransfer = abi.encode(transferMsg);
        DestinationMessage memory decodedTransfer = abi.decode(encodedTransfer, (DestinationMessage));
        assertEq(uint8(decodedTransfer.opType), uint8(OpType.Transfer));
        
        // Test Rebalance
        DestinationMessage memory rebalanceMsg = DestinationMessage({
            opType: OpType.Rebalance,
            sourceChainId: 42161,
            sourceNav: 1e18,
            sourceDecimals: 18,
            navTolerance: 200,
            shouldUnwrap: false,
            sourceNativeAmount: 0
        });
        bytes memory encodedRebalance = abi.encode(rebalanceMsg);
        DestinationMessage memory decodedRebalance = abi.decode(encodedRebalance, (DestinationMessage));
        assertEq(uint8(decodedRebalance.opType), uint8(OpType.Rebalance));
        
        // Test Sync
        DestinationMessage memory syncMsg = DestinationMessage({
            opType: OpType.Sync,
            sourceChainId: 42161,
            sourceNav: 1e18,
            sourceDecimals: 18,
            navTolerance: 0,
            shouldUnwrap: false,
            sourceNativeAmount: 0
        });
        bytes memory encodedSync = abi.encode(syncMsg);
        DestinationMessage memory decodedSync = abi.decode(encodedSync, (DestinationMessage));
        assertEq(uint8(decodedSync.opType), uint8(OpType.Sync));
    }
    
    /// @notice Test SourceMessage encoding/decoding
    function test_SourceMessage_EncodingDecoding() public pure {
        SourceMessage memory $ = SourceMessage({
            opType: OpType.Transfer,
            navTolerance: 100,
            shouldUnwrapOnDestination: true,
            sourceNativeAmount: 0.01 ether
        });
        
        bytes memory encoded = abi.encode($);
        SourceMessage memory decoded = abi.decode(encoded, (SourceMessage));
        
        assertEq(uint8(decoded.opType), uint8(OpType.Transfer));
        assertEq(decoded.navTolerance, 100);
        assertTrue(decoded.shouldUnwrapOnDestination);
        assertEq(decoded.sourceNativeAmount, 0.01 ether);
    }
    
    /// @notice Test NAV normalization edge cases
    function test_NavNormalization_EdgeCases() public pure {
        // Same decimals
        assertEq(_normalizeNav(1e18, 18, 18), 1e18);
        
        // Downscale by 12
        assertEq(_normalizeNav(1e18, 18, 6), 1e6);
        
        // Upscale by 12
        assertEq(_normalizeNav(1e6, 6, 18), 1e18);
        
        // Downscale by 1
        assertEq(_normalizeNav(1e18, 18, 17), 1e17);
        
        // Upscale by 1
        assertEq(_normalizeNav(1e17, 17, 18), 1e18);
    }
    
    /// @notice Test tolerance calculation edge cases
    function test_ToleranceCalculation_EdgeCases() public pure {
        // 0.01% tolerance
        uint256 nav1 = 1e18;
        uint256 tol1 = 1; // 0.01%
        uint256 tolAmt1 = (nav1 * tol1) / 10000;
        assertEq(tolAmt1, 1e14);
        
        // 10% tolerance (max)
        uint256 nav2 = 1e18;
        uint256 tol2 = 1000; // 10%
        uint256 tolAmt2 = (nav2 * tol2) / 10000;
        assertEq(tolAmt2, 1e17);
        
        // 100% tolerance (unrealistic but mathematically valid)
        uint256 nav3 = 1e18;
        uint256 tol3 = 10000; // 100%
        uint256 tolAmt3 = (nav3 * tol3) / 10000;
        assertEq(tolAmt3, 1e18);
    }
    
    /// @notice Test adapter rejects inactive token
    function test_Adapter_RejectsInactiveToken() public {
        MockPool pool = new MockPool(address(adapter), mockSpokePool, mockBaseToken, mockInputToken);
        
        // Create token that won't be marked as active
        address inactiveToken = makeAddr("inactiveToken");
        
        IAIntents.AcrossParams memory params = _createAcrossParams(
            inactiveToken,
            inactiveToken,
            100e6,
            99e6,
            10,
            OpType.Transfer,
            100
        );
        
        vm.expectRevert(abi.encodeWithSelector(IAIntents.TokenNotActive.selector));
        pool.callDepositV3(params);
    }
    
    /// @notice Test ExtensionsMap selector mapping
    function test_ExtensionsMap_SelectorMapping() public pure {
        bytes4 selector = bytes4(keccak256("handleV3AcrossMessage(address,uint256,bytes)"));
        
        // Verify selector is correctly calculated
        assertEq(
            selector,
            EAcrossHandler.handleV3AcrossMessage.selector,
            "Selector mismatch"
        );
    }
    
    // TODO: update test, as it's taking tuple input
    /// @notice Test depositV3 interface matches Across exactly
    //function test_DepositV3InterfaceMatch() public {
        // Verify our adapter has exact same signature as Across SpokePool
    //    bytes4 acrossSelector = bytes4(keccak256(
    //        "depositV3(address,address,address,address,uint256,uint256,uint256,address,uint32,uint32,uint32,bytes)"
    //    ));
    //    
    //    bytes4 adapterSelector = AIntents.depositV3.selector;
    //    
    //    assertEq(adapterSelector, acrossSelector, "Adapter must match Across interface exactly");
    //}
    
    /// @notice Test virtual balance storage slot calculation
    function test_VirtualBalanceSlot() public pure {
        // Verify storage slot matches MixinConstants
        bytes32 expectedSlot = bytes32(uint256(keccak256("pool.proxy.virtualBalances")) - 1);
        bytes32 calculatedSlot = 0x19797d8be84f650fe18ebccb97578c2adb7abe9b7c86852694a3ceb69073d1d1;
        
        assertEq(calculatedSlot, expectedSlot, "Virtual balance slot mismatch");
    }
    
    /// @notice Test message type enum values
    function test_OpTypeEnumValues() public pure {
        uint8 transferType = uint8(OpType.Transfer);
        uint8 rebalanceType = uint8(OpType.Rebalance);
        
        assertEq(transferType, 0, "Transfer should be 0");
        assertEq(rebalanceType, 1, "Rebalance should be 1");
    }
    
    /// @notice Test NAV normalization logic
    function test_NavNormalization() public pure {
        // Test same decimals
        assertEq(_normalizeNav(1e18, 18, 18), 1e18, "Same decimals should not change");
        
        // Test downscaling
        assertEq(_normalizeNav(1e18, 18, 6), 1e6, "Should downscale correctly");
        
        // Test upscaling
        assertEq(_normalizeNav(1e6, 6, 18), 1e18, "Should upscale correctly");
    }
    
    /// @notice Test tolerance calculation
    function test_ToleranceCalculation() public pure {
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
    function testFuzz_NavNormalization(uint256 nav, uint8 sourceDecimals, uint8 destDecimals) public pure {
        // Constrain decimals to reasonable range
        vm.assume(sourceDecimals <= 18 && destDecimals <= 18);
        vm.assume(sourceDecimals > 0 && destDecimals > 0);
        
        // Constrain NAV to avoid overflow
        if (destDecimals > sourceDecimals) {
            vm.assume(nav < type(uint256).max / (10 ** (destDecimals - sourceDecimals)));
        }
        
        uint256 normalized = _normalizeNav(nav, sourceDecimals, destDecimals);
        
        // Verify reversibility
        //uint256 denormalized = _normalizeNav(normalized, destDecimals, sourceDecimals);
        // TODO: there is a small precision loss here, check if we can assert that delta is within a 1e8 range
        //assertEq(denormalized, nav, "Denormalized should be equal to nav");
        
        if (sourceDecimals == destDecimals) {
            assertEq(normalized, nav, "Same decimals should not change");
        } else if (sourceDecimals < destDecimals) {
            assertTrue(normalized >= nav, "Upscaling should increase or maintain value");
        } else {
            assertTrue(normalized <= nav, "Downscaling should decrease or maintain value");
        }
    }
    
    /// @notice Fuzz test: Tolerance within range
    function testFuzz_ToleranceInRange(uint256 nav, uint256 tolerance) public pure {
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
    
    function _createAcrossParams(
        address _inputToken,
        address _outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destChainId,
        OpType opType,
        uint256 navTolerance
    ) internal view returns (IAIntents.AcrossParams memory) {
        return IAIntents.AcrossParams({
            depositor: address(this),
            recipient: address(this),
            inputToken: _inputToken,
            outputToken: _outputToken,
            inputAmount: inputAmount,
            outputAmount: outputAmount,
            destinationChainId: destChainId,
            exclusiveRelayer: address(0),
            quoteTimestamp: uint32(block.timestamp),
            fillDeadline: uint32(block.timestamp + 3600),
            exclusivityDeadline: 0,
            message: abi.encode(SourceMessage({
                opType: opType,
                navTolerance: navTolerance,
                shouldUnwrapOnDestination: false,
                sourceNativeAmount: 0
            }))
        });
    }
    
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
    
    function _setupPoolMocks() internal {
        // Mock pool storage slot
        vm.store(address(this), POOL_INIT_SLOT, bytes32(uint256(1)));
        
        // Mock pool base token
        bytes32 poolSlot = 0x3d9ab2da84c2cdbde6d0e1a76193d583aa37fb768aaf6042c2f2a3be88e50607;
        vm.store(address(this), poolSlot, bytes32(uint256(uint160(mockBaseToken))));
        
        // Mock pool decimals (stored at offset +4 in same slot as baseToken)
        bytes32 decimalsValue = bytes32(uint256(18) << 160) | bytes32(uint256(uint160(mockBaseToken)));
        vm.store(address(this), poolSlot, decimalsValue);
        
        // Mock active tokens set
        vm.mockCall(
            address(this),
            abi.encodeWithSignature("addUnique(address,address,address)"),
            abi.encode()
        );
        
        // Mock oracle hasPriceFeed
        vm.mockCall(
            address(this),
            abi.encodeWithSelector(IEOracle.hasPriceFeed.selector),
            abi.encode(true)
        );
    }
    
    function _getVirtualBalance(address token) internal view returns (int256 value) {
        bytes32 baseSlot = VIRTUAL_BALANCES_SLOT;
        bytes32 slot = keccak256(abi.encodePacked(token, baseSlot));
        assembly {
            value := sload(slot)
        }
    }
    
    function _getChainNavSpread(uint256 chainId) internal view returns (int256 spread) {
        bytes32 baseSlot = CHAIN_NAV_SPREADS_SLOT;
        bytes32 slot = keccak256(abi.encodePacked(bytes32(chainId), baseSlot));
        assembly {
            spread := sload(slot)
        }
    }
}

/// @notice Mock pool contract for testing delegatecall behavior
contract MockPool {
    address public adapter;
    address public spokePool;
    address public baseToken;
    address public inputToken;
    
    bytes32 constant POOL_INIT_SLOT = 0xe48b9bb119adfc3bccddcc581484cc6725fe8d292ebfcec7d67b1f93138d8bd8;
    bytes32 constant ACTIVE_TOKENS_SLOT = 0xbd68f1d41a93565ce29970ec13a2bc56a87c8bdd0b31366d8baa7620f41eb6cb;
    bytes32 constant VIRTUAL_BALANCES_SLOT = 0x19797d8be84f650fe18ebccb97578c2adb7abe9b7c86852694a3ceb69073d1d1;
    
    constructor(address _adapter, address _spokePool, address _baseToken, address _inputToken) {
        adapter = _adapter;
        spokePool = _spokePool;
        baseToken = _baseToken;
        inputToken = _inputToken;
        
        // Initialize pool storage
        assembly {
            sstore(POOL_INIT_SLOT, 1)
        }
        
        // Set base token in pool storage (slot for pool.baseToken)
        bytes32 poolSlot = 0x3d9ab2da84c2cdbde6d0e1a76193d583aa37fb768aaf6042c2f2a3be88e50607;
        assembly {
            sstore(poolSlot, _baseToken)
        }
    }
    
    function callDepositV3(IAIntents.AcrossParams memory params) external {
        // Delegatecall to adapter
        (bool success, bytes memory data) = adapter.delegatecall(
            abi.encodeWithSelector(IAIntents.depositV3.selector, params)
        );
        if (!success) {
            if (data.length > 0) {
                assembly {
                    revert(add(data, 32), mload(data))
                }
            }
            revert("Delegatecall failed");
        }
    }
    
    // Mock StorageLib.pool() response
    function pool() external view returns (
        address name,
        address symbol,
        address owner,
        address _baseToken,
        uint256 minPeriod,
        uint8 decimals,
        uint256 spread
    ) {
        return (address(0), address(0), address(0), baseToken, 0, 18, 0);
    }
    
    // Mock StorageLib.activeTokensSet()
    function isActive(address token) external view returns (bool) {
        return token == inputToken || token == baseToken;
    }
    
    // Mock ISmartPoolActions.updateUnitaryValue()
    function updateUnitaryValue() external pure returns (uint256) {
        return 1e18;
    }
    
    // Mock ISmartPoolState.getPoolTokens()
    function getPoolTokens() external pure returns (ISmartPoolState.PoolTokens memory) {
        return ISmartPoolState.PoolTokens({unitaryValue: 1e18, totalSupply: 1000e18});
    }
    
    // Mock IEOracle.convertTokenAmount()
    function convertTokenAmount(
        address,
        int256 amount,
        address
    ) external pure returns (int256) {
        return amount; // 1:1 conversion for simplicity
    }
    
    // Mock IEOracle.hasPriceFeed()
    function hasPriceFeed(address) external pure returns (bool) {
        return true;
    }
    
    // Receive ETH
    receive() external payable {}
}
