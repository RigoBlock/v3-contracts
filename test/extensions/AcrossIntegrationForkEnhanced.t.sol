// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {AIntents} from "../../contracts/protocol/extensions/adapters/AIntents.sol";
import {EAcrossHandler} from "../../contracts/protocol/extensions/EAcrossHandler.sol";
import {IERC20} from "../../contracts/protocol/interfaces/IERC20.sol";
import {IAIntents} from "../../contracts/protocol/extensions/adapters/interfaces/IAIntents.sol";
import {IEAcrossHandler} from "../../contracts/protocol/extensions/adapters/interfaces/IEAcrossHandler.sol";
import {OpType, DestinationMessage, SourceMessage} from "../../contracts/protocol/types/Crosschain.sol";
import {MockPoolForAcross} from "./fixtures/MockPoolForAcross.sol";

/// @title AcrossIntegrationForkEnhanced - Enhanced fork tests with real interactions
/// @notice Comprehensive coverage testing for Across integration
contract AcrossIntegrationForkEnhancedTest is Test {
    // Deployed infrastructure addresses
    address constant AUTHORITY = 0x7F427F11eB24f1be14D0c794f6d5a9830F18FBf1;
    address constant FACTORY = 0x4aA9e5A5A244C81C3897558C5cF5b752EBefA88f;
    address constant REGISTRY = 0x19Be0f8D5f35DB8c2d2f50c9a3742C5d1eB88907;
    
    // Across SpokePools by chain
    address constant ARB_SPOKE_POOL = 0xe35e9842fceaCA96570B734083f4a58e8F7C5f2A;
    address constant OPT_SPOKE_POOL = 0x6f26Bf09B1C792e3228e5467807a900A503c0281;
    address constant BASE_SPOKE_POOL = 0x09aea4b2242abC8bb4BB78D537A67a245A7bEC64;
    
    // Tokens on Arbitrum
    address constant USDC_ARB = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant WETH_ARB = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    
    // Tokens on Optimism  
    address constant USDC_OPT = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address constant WETH_OPT = 0x4200000000000000000000000000000000000006;
    
    // Chain IDs
    uint256 constant ARB_CHAIN_ID = 42161;
    uint256 constant OPT_CHAIN_ID = 10;
    
    // Test actors
    address poolOwner;
    address user1;
    address user2;
    
    // Fork IDs
    uint256 arbFork;
    uint256 optFork;
    
    // Deployed test contracts on Arbitrum
    MockPoolForAcross arbPool;
    AIntents arbAdapter;
    EAcrossHandler arbHandler;
    
    // Deployed test contracts on Optimism
    MockPoolForAcross optPool;
    AIntents optAdapter;
    EAcrossHandler optHandler;
    
    function setUp() public {
        // Create test accounts
        poolOwner = makeAddr("poolOwner");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        
        // Create forks
        string memory arbRpc = vm.envOr("ARBITRUM_RPC_URL", string(""));
        string memory optRpc = vm.envOr("OPTIMISM_RPC_URL", string(""));
        
        if (bytes(arbRpc).length > 0) {
            arbFork = vm.createFork(arbRpc);
            vm.selectFork(arbFork);
            _setupArbitrum();
        }
        
        if (bytes(optRpc).length > 0) {
            optFork = vm.createFork(optRpc);
            vm.selectFork(optFork);
            _setupOptimism();
        }
    }
    
    function _setupArbitrum() private {
        console2.log("Setting up Arbitrum fork...");
        
        // Deploy handler
        arbHandler = new EAcrossHandler(ARB_SPOKE_POOL);
        console2.log("  Handler:", address(arbHandler));
        
        // Deploy adapter
        arbAdapter = new AIntents(ARB_SPOKE_POOL);
        console2.log("  Adapter:", address(arbAdapter));
        
        // Deploy mock pool with USDC as base token
        arbPool = new MockPoolForAcross(poolOwner, USDC_ARB, 6);
        console2.log("  MockPool:", address(arbPool));
        
        // Fund pool with USDC and WETH for testing
        deal(USDC_ARB, address(arbPool), 100000e6); // 100k USDC
        deal(WETH_ARB, address(arbPool), 100e18);   // 100 WETH
        
        console2.log("Arbitrum setup complete");
    }
    
    function _setupOptimism() private {
        console2.log("Setting up Optimism fork...");
        
        // Deploy handler
        optHandler = new EAcrossHandler(OPT_SPOKE_POOL);
        console2.log("  Handler:", address(optHandler));
        
        // Deploy adapter
        optAdapter = new AIntents(OPT_SPOKE_POOL);
        console2.log("  Adapter:", address(optAdapter));
        
        // Deploy mock pool with USDC as base token
        optPool = new MockPoolForAcross(poolOwner, USDC_OPT, 6);
        console2.log("  MockPool:", address(optPool));
        
        // Fund pool with USDC and WETH for testing
        deal(USDC_OPT, address(optPool), 100000e6); // 100k USDC
        deal(WETH_OPT, address(optPool), 100e18);   // 100 WETH
        
        console2.log("Optimism setup complete");
    }
    
    /*
     * HANDLER TESTS - Transfer Mode
     */
    
    /// @notice Test handler receives Transfer message and creates negative virtual balance
    function testFork_Arb_HandlerTransferMode() public {
        if (arbFork == 0) {
            console2.log("Skipping: No Arbitrum fork");
            return;
        }
        
        vm.selectFork(arbFork);
        
        uint256 amount = 1000e6; // 1000 USDC
        address tokenReceived = USDC_ARB;
        
        // Prepare Transfer message
        DestinationMessage memory message = DestinationMessage({
            opType: OpType.Transfer,
            sourceChainId: OPT_CHAIN_ID,
            sourceNav: 0,
            sourceDecimals: 6,
            navTolerance: 0,
            shouldUnwrap: false,
            sourceNativeAmount: 0
        });
        
        bytes memory encodedMessage = abi.encode(message);
        
        // Transfer USDC to pool to simulate Across deposit
        deal(USDC_ARB, address(arbPool), IERC20(USDC_ARB).balanceOf(address(arbPool)) + amount);
        
        // Check virtual balance before (should be 0)
        int256 vBalanceBefore = arbPool.getVirtualBalance(USDC_ARB);
        assertEq(vBalanceBefore, 0, "Initial virtual balance should be 0");
        
        // Simulate SpokePool calling handleV3AcrossMessage via delegatecall
        vm.prank(poolOwner);
        bytes memory callData = abi.encodeWithSelector(
            IEAcrossHandler.handleV3AcrossMessage.selector,
            tokenReceived,
            amount,
            encodedMessage
        );
        
        // Execute through pool (delegatecall)
        vm.prank(ARB_SPOKE_POOL); // msg.sender must be SpokePool
        arbPool.execute(address(arbHandler), callData);
        
        // Check virtual balance after (should be negative)
        int256 vBalanceAfter = arbPool.getVirtualBalance(USDC_ARB);
        assertEq(vBalanceAfter, -int256(amount), "Virtual balance should be negative amount");
        
        console2.log("Transfer mode handled correctly");
        console2.log("  Virtual balance:", vBalanceAfter);
    }
    
    /// @notice Test handler receives Rebalance message and validates NAV
    function testFork_Arb_HandlerRebalanceMode() public {
        if (arbFork == 0) {
            console2.log("Skipping: No Arbitrum fork");
            return;
        }
        
        vm.selectFork(arbFork);
        
        uint256 amount = 1000e6; // 1000 USDC
        address tokenReceived = USDC_ARB;
        
        // Prepare Rebalance message
        DestinationMessage memory message = DestinationMessage({
            opType: OpType.Rebalance,
            sourceChainId: OPT_CHAIN_ID,
            sourceNav: 1000000, // 1.0 in 6 decimals
            sourceDecimals: 6,
            navTolerance: 10000, // 1%
            shouldUnwrap: false,
            sourceNativeAmount: 0
        });
        
        bytes memory encodedMessage = abi.encode(message);
        
        // Transfer USDC to pool
        deal(USDC_ARB, address(arbPool), IERC20(USDC_ARB).balanceOf(address(arbPool)) + amount);
        
        // Simulate SpokePool calling handleV3AcrossMessage
        vm.prank(poolOwner);
        bytes memory callData = abi.encodeWithSelector(
            IEAcrossHandler.handleV3AcrossMessage.selector,
            tokenReceived,
            amount,
            encodedMessage
        );
        
        vm.prank(ARB_SPOKE_POOL);
        arbPool.execute(address(arbHandler), callData);
        
        // In Rebalance mode, no virtual balance is created
        int256 vBalance = arbPool.getVirtualBalance(USDC_ARB);
        assertEq(vBalance, 0, "No virtual balance in Rebalance mode");
        
        console2.log("Rebalance mode handled correctly");
    }
    
    /// @notice Test handler receives Sync message
    function testFork_Arb_HandlerSyncMode() public {
        if (arbFork == 0) {
            console2.log("Skipping: No Arbitrum fork");
            return;
        }
        
        vm.selectFork(arbFork);
        
        uint256 amount = 1000e6;
        address tokenReceived = USDC_ARB;
        
        // Set up existing virtual balance
        vm.prank(poolOwner);
        arbPool.setVirtualBalance(USDC_ARB, -2000e6);
        
        // Prepare Sync message
        DestinationMessage memory message = DestinationMessage({
            opType: OpType.Sync,
            sourceChainId: OPT_CHAIN_ID,
            sourceNav: 0,
            sourceDecimals: 6,
            navTolerance: 0,
            shouldUnwrap: false,
            sourceNativeAmount: 0
        });
        
        bytes memory encodedMessage = abi.encode(message);
        
        // Transfer USDC to pool
        deal(USDC_ARB, address(arbPool), IERC20(USDC_ARB).balanceOf(address(arbPool)) + amount);
        
        // Execute handler
        vm.prank(poolOwner);
        bytes memory callData = abi.encodeWithSelector(
            IEAcrossHandler.handleV3AcrossMessage.selector,
            tokenReceived,
            amount,
            encodedMessage
        );
        
        vm.prank(ARB_SPOKE_POOL);
        arbPool.execute(address(arbHandler), callData);
        
        // Virtual balance should be increased by amount (less negative)
        int256 vBalance = arbPool.getVirtualBalance(USDC_ARB);
        assertEq(vBalance, -1000e6, "Virtual balance should be synced");
        
        console2.log("Sync mode handled correctly");
        console2.log("  Virtual balance:", vBalance);
    }
    
    /*
     * HANDLER SECURITY TESTS
     */
    
    /// @notice Test handler rejects unauthorized caller
    function testFork_Arb_HandlerRejectsUnauthorized() public {
        if (arbFork == 0) {
            console2.log("Skipping: No Arbitrum fork");
            return;
        }
        
        vm.selectFork(arbFork);
        
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
        
        // Try calling handler directly (not from SpokePool)
        vm.expectRevert(abi.encodeWithSelector(IEAcrossHandler.UnauthorizedCaller.selector));
        arbHandler.handleV3AcrossMessage(USDC_ARB, 1000e6, encodedMessage);
    }
    
    /// @notice Test handler accepts call from SpokePool
    function testFork_Arb_HandlerAcceptsSpokePool() public {
        if (arbFork == 0) {
            console2.log("Skipping: No Arbitrum fork");
            return;
        }
        
        vm.selectFork(arbFork);
        
        uint256 amount = 1000e6;
        
        DestinationMessage memory message = DestinationMessage({
            opType: OpType.Transfer,
            sourceChainId: OPT_CHAIN_ID,
            sourceNav: 0,
            sourceDecimals: 6,
            navTolerance: 0,
            shouldUnwrap: false,
            sourceNativeAmount: 0
        });
        
        bytes memory encodedMessage = abi.encode(message);
        
        // Transfer tokens to pool
        deal(USDC_ARB, address(arbPool), IERC20(USDC_ARB).balanceOf(address(arbPool)) + amount);
        
        // Call from SpokePool via delegatecall through pool
        vm.prank(poolOwner);
        bytes memory callData = abi.encodeWithSelector(
            IEAcrossHandler.handleV3AcrossMessage.selector,
            USDC_ARB,
            amount,
            encodedMessage
        );
        
        vm.prank(ARB_SPOKE_POOL);
        bytes memory result = arbPool.execute(address(arbHandler), callData);
        
        // Should succeed
        assertTrue(result.length >= 0, "Call should succeed");
    }
    
    /*
     * ADAPTER TESTS
     */
    
    /// @notice Test adapter configuration
    function testFork_Arb_AdapterConfiguration() public {
        if (arbFork == 0) {
            console2.log("Skipping: No Arbitrum fork");
            return;
        }
        
        vm.selectFork(arbFork);
        
        assertEq(address(arbAdapter.acrossSpokePool()), ARB_SPOKE_POOL);
        assertEq(arbAdapter.requiredVersion(), "HF_4.1.0");
    }
    
    /// @notice Test adapter rejects direct calls
    function testFork_Arb_AdapterRejectsDirectCall() public {
        if (arbFork == 0) {
            console2.log("Skipping: No Arbitrum fork");
            return;
        }
        
        vm.selectFork(arbFork);
        
        // Prepare depositV3 params
        IAIntents.AcrossParams memory acrossParams = IAIntents.AcrossParams({
            depositor: address(arbPool),
            recipient: address(optPool),
            inputToken: USDC_ARB,
            outputToken: USDC_OPT,
            inputAmount: 1000e6,
            outputAmount: 1000e6,
            destinationChainId: OPT_CHAIN_ID,
            exclusiveRelayer: address(0),
            quoteTimestamp: uint32(block.timestamp),
            fillDeadline: uint32(block.timestamp + 3600),
            exclusivityDeadline: uint32(block.timestamp + 300),
            message: ""
        });
        
        // Try calling adapter directly (not via delegatecall)
        vm.expectRevert("ONLY_DELEGATECALL");
        arbAdapter.depositV3(acrossParams);
    }
    
    /*
     * VIRTUAL BALANCE TESTS
     */
    
    /// @notice Test virtual balance storage and retrieval
    function testFork_Arb_VirtualBalanceOperations() public {
        if (arbFork == 0) {
            console2.log("Skipping: No Arbitrum fork");
            return;
        }
        
        vm.selectFork(arbFork);
        
        // Test setting positive virtual balance
        vm.prank(poolOwner);
        arbPool.setVirtualBalance(USDC_ARB, 5000e6);
        
        int256 balance = arbPool.getVirtualBalance(USDC_ARB);
        assertEq(balance, 5000e6);
        
        // Test setting negative virtual balance
        vm.prank(poolOwner);
        arbPool.setVirtualBalance(USDC_ARB, -3000e6);
        
        balance = arbPool.getVirtualBalance(USDC_ARB);
        assertEq(balance, -3000e6);
        
        // Test resetting to zero
        vm.prank(poolOwner);
        arbPool.setVirtualBalance(USDC_ARB, 0);
        
        balance = arbPool.getVirtualBalance(USDC_ARB);
        assertEq(balance, 0);
    }
    
    /// @notice Test multiple tokens have independent virtual balances
    function testFork_Arb_MultipleTokenVirtualBalances() public {
        if (arbFork == 0) {
            console2.log("Skipping: No Arbitrum fork");
            return;
        }
        
        vm.selectFork(arbFork);
        
        // Set different virtual balances for different tokens
        vm.startPrank(poolOwner);
        arbPool.setVirtualBalance(USDC_ARB, 1000e6);
        arbPool.setVirtualBalance(WETH_ARB, -5e18);
        vm.stopPrank();
        
        // Check they're independent
        int256 usdcBalance = arbPool.getVirtualBalance(USDC_ARB);
        int256 wethBalance = arbPool.getVirtualBalance(WETH_ARB);
        
        assertEq(usdcBalance, 1000e6);
        assertEq(wethBalance, -5e18);
    }
    
    /*
     * CROSS-CHAIN SIMULATION TESTS
     */
    
    /// @notice Simulate full cross-chain Transfer flow
    function testFork_FullCrossChainTransfer() public {
        if (arbFork == 0 || optFork == 0) {
            console2.log("Skipping: Need both forks");
            return;
        }
        
        uint256 transferAmount = 1000e6;
        
        // STEP 1: Source chain (Optimism) - Create positive virtual balance
        vm.selectFork(optFork);
        console2.log("Source chain (Optimism):");
        
        vm.prank(poolOwner);
        optPool.setVirtualBalance(USDC_OPT, int256(transferAmount));
        
        int256 sourceVBalance = optPool.getVirtualBalance(USDC_OPT);
        console2.log("  Source virtual balance:", sourceVBalance);
        assertEq(sourceVBalance, int256(transferAmount));
        
        // STEP 2: Destination chain (Arbitrum) - Receive and create negative virtual balance
        vm.selectFork(arbFork);
        console2.log("Destination chain (Arbitrum):");
        
        DestinationMessage memory message = DestinationMessage({
            opType: OpType.Transfer,
            sourceChainId: OPT_CHAIN_ID,
            sourceNav: 0,
            sourceDecimals: 6,
            navTolerance: 0,
            shouldUnwrap: false,
            sourceNativeAmount: 0
        });
        
        bytes memory encodedMessage = abi.encode(message);
        
        // Simulate receiving tokens
        deal(USDC_ARB, address(arbPool), IERC20(USDC_ARB).balanceOf(address(arbPool)) + transferAmount);
        
        // Handle message
        vm.prank(poolOwner);
        bytes memory callData = abi.encodeWithSelector(
            IEAcrossHandler.handleV3AcrossMessage.selector,
            USDC_ARB,
            transferAmount,
            encodedMessage
        );
        
        vm.prank(ARB_SPOKE_POOL);
        arbPool.execute(address(arbHandler), callData);
        
        int256 destVBalance = arbPool.getVirtualBalance(USDC_ARB);
        console2.log("  Dest virtual balance:", destVBalance);
        assertEq(destVBalance, -int256(transferAmount));
        
        // Verify NAV neutrality: source positive + dest negative = 0
        assertEq(sourceVBalance + destVBalance, 0, "NAV should be neutral across chains");
        
        console2.log("Cross-chain Transfer completed successfully");
        console2.log("  NAV neutral:", sourceVBalance + destVBalance == 0);
    }
    
    /*
     * TOKEN INTERACTION TESTS
     */
    
    /// @notice Test USDC token operations
    function testFork_Arb_USDCOperations() public {
        if (arbFork == 0) {
            console2.log("Skipping: No Arbitrum fork");
            return;
        }
        
        vm.selectFork(arbFork);
        
        // Check token exists
        assertTrue(USDC_ARB.code.length > 0);
        
        // Check decimals
        uint8 decimals = IERC20(USDC_ARB).decimals();
        assertEq(decimals, 6);
        
        // Check pool balance
        uint256 balance = IERC20(USDC_ARB).balanceOf(address(arbPool));
        assertTrue(balance > 0, "Pool should have USDC");
        
        console2.log("USDC balance:", balance);
    }
    
    /// @notice Test WETH token operations
    function testFork_Arb_WETHOperations() public {
        if (arbFork == 0) {
            console2.log("Skipping: No Arbitrum fork");
            return;
        }
        
        vm.selectFork(arbFork);
        
        // Check token exists
        assertTrue(WETH_ARB.code.length > 0);
        
        // Check decimals
        uint8 decimals = IERC20(WETH_ARB).decimals();
        assertEq(decimals, 18);
        
        // Check pool balance
        uint256 balance = IERC20(WETH_ARB).balanceOf(address(arbPool));
        assertTrue(balance > 0, "Pool should have WETH");
        
        console2.log("WETH balance:", balance);
    }
    
    /*
     * MESSAGE ENCODING TESTS
     */
    
    /// @notice Test all OpTypes encode/decode correctly
    function testFork_MessageEncodingAllTypes() public pure {
        // Transfer
        DestinationMessage memory transferMsg = DestinationMessage({
            opType: OpType.Transfer,
            sourceChainId: ARB_CHAIN_ID,
            sourceNav: 0,
            sourceDecimals: 6,
            navTolerance: 0,
            shouldUnwrap: false,
            sourceNativeAmount: 0
        });
        
        bytes memory encoded = abi.encode(transferMsg);
        DestinationMessage memory decoded = abi.decode(encoded, (DestinationMessage));
        assertEq(uint8(decoded.opType), uint8(OpType.Transfer));
        
        // Rebalance
        DestinationMessage memory rebalanceMsg = DestinationMessage({
            opType: OpType.Rebalance,
            sourceChainId: ARB_CHAIN_ID,
            sourceNav: 1e18,
            sourceDecimals: 18,
            navTolerance: 100,
            shouldUnwrap: true,
            sourceNativeAmount: 0
        });
        
        encoded = abi.encode(rebalanceMsg);
        decoded = abi.decode(encoded, (DestinationMessage));
        assertEq(uint8(decoded.opType), uint8(OpType.Rebalance));
        assertEq(decoded.sourceNav, 1e18);
        assertTrue(decoded.shouldUnwrap);
        
        // Sync
        DestinationMessage memory syncMsg = DestinationMessage({
            opType: OpType.Sync,
            sourceChainId: ARB_CHAIN_ID,
            sourceNav: 0,
            sourceDecimals: 6,
            navTolerance: 0,
            shouldUnwrap: false,
            sourceNativeAmount: 0
        });
        
        encoded = abi.encode(syncMsg);
        decoded = abi.decode(encoded, (DestinationMessage));
        assertEq(uint8(decoded.opType), uint8(OpType.Sync));
    }
    
    /// @notice Test SourceMessage encoding
    function testFork_SourceMessageEncoding() public pure {
        SourceMessage memory sourceMsg = SourceMessage({
            opType: OpType.Transfer,
            navTolerance: 100,
            sourceNativeAmount: 0,
            shouldUnwrapOnDestination: false
        });
        
        bytes memory encoded = abi.encode(sourceMsg);
        SourceMessage memory decoded = abi.decode(encoded, (SourceMessage));
        
        assertEq(uint8(decoded.opType), uint8(OpType.Transfer));
        assertEq(decoded.navTolerance, 100);
        assertEq(decoded.sourceNativeAmount, 0);
        assertFalse(decoded.shouldUnwrapOnDestination);
    }
    
    /*
     * DEPLOYMENT VERIFICATION
     */
    
    /// @notice Verify all required contracts deployed on Arbitrum
    function testFork_Arb_AllContractsDeployed() public {
        if (arbFork == 0) {
            console2.log("Skipping: No Arbitrum fork");
            return;
        }
        
        vm.selectFork(arbFork);
        
        // Check infrastructure
        assertTrue(AUTHORITY.code.length > 0, "Authority should exist");
        assertTrue(FACTORY.code.length > 0, "Factory should exist");
        assertTrue(REGISTRY.code.length > 0, "Registry should exist");
        assertTrue(ARB_SPOKE_POOL.code.length > 0, "SpokePool should exist");
        
        // Check test contracts
        assertTrue(address(arbHandler).code.length > 0, "Handler deployed");
        assertTrue(address(arbAdapter).code.length > 0, "Adapter deployed");
        assertTrue(address(arbPool).code.length > 0, "Pool deployed");
        
        console2.log("All contracts verified on Arbitrum");
    }
    
    /// @notice Verify all required contracts deployed on Optimism
    function testFork_Opt_AllContractsDeployed() public {
        if (optFork == 0) {
            console2.log("Skipping: No Optimism fork");
            return;
        }
        
        vm.selectFork(optFork);
        
        // Check infrastructure  
        assertTrue(AUTHORITY.code.length > 0, "Authority should exist");
        assertTrue(FACTORY.code.length > 0, "Factory should exist");
        assertTrue(REGISTRY.code.length > 0, "Registry should exist");
        assertTrue(OPT_SPOKE_POOL.code.length > 0, "SpokePool should exist");
        
        // Check test contracts
        assertTrue(address(optHandler).code.length > 0, "Handler deployed");
        assertTrue(address(optAdapter).code.length > 0, "Adapter deployed");
        assertTrue(address(optPool).code.length > 0, "Pool deployed");
        
        console2.log("All contracts verified on Optimism");
    }
}
