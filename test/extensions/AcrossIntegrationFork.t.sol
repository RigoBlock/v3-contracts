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
import {TestProxyForAcross} from "../fixtures/TestProxyForAcross.sol";

/// @title AcrossIntegrationFork - Comprehensive fork-based integration tests
/// @notice Merged integration tests for Across protocol testing on real forks
contract AcrossIntegrationForkTest is Test {
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
    
    // Tokens on Base
    address constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH_BASE = 0x4200000000000000000000000000000000000006;
    
    // Chain IDs
    uint256 constant ARB_CHAIN_ID = 42161;
    uint256 constant OPT_CHAIN_ID = 10;
    uint256 constant BASE_CHAIN_ID = 8453;
    
    // Test actors
    address poolOwner;
    address user1;
    address user2;
    
    // Fork IDs
    uint256 arbFork;
    uint256 optFork;
    uint256 baseFork;
    
    // Deployed test contracts on Arbitrum
    TestProxyForAcross arbPool;
    AIntents arbAdapter;
    EAcrossHandler arbHandler;
    
    // Deployed test contracts on Optimism
    TestProxyForAcross optPool;
    AIntents optAdapter;
    EAcrossHandler optHandler;
    
    // Deployed test contracts on Base
    TestProxyForAcross basePool;
    AIntents baseAdapter;
    EAcrossHandler baseHandler;
    
    function setUp() public {
        // Create test accounts
        poolOwner = makeAddr("poolOwner");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        
        // Create forks using Infura
        string memory infuraKey = vm.envOr("INFURA_KEY", string(""));
        
        if (bytes(infuraKey).length > 0) {
            string memory arbRpc = string.concat("https://arbitrum-mainnet.infura.io/v3/", infuraKey);
            string memory optRpc = string.concat("https://optimism-mainnet.infura.io/v3/", infuraKey);
            string memory baseRpc = string.concat("https://base-mainnet.infura.io/v3/", infuraKey);
            
            arbFork = vm.createFork(arbRpc);
            vm.selectFork(arbFork);
            _setupArbitrum();
            
            optFork = vm.createFork(optRpc);
            vm.selectFork(optFork);
            _setupOptimism();
            
            baseFork = vm.createFork(baseRpc);
            vm.selectFork(baseFork);
            _setupBase();
            
            console2.log("=== All forks created successfully ===");
        } else {
            // Fallback to individual RPC URLs from env
            string memory arbRpc = vm.envOr("ARBITRUM_RPC_URL", string(""));
            string memory optRpc = vm.envOr("OPTIMISM_RPC_URL", string(""));
            string memory baseRpc = vm.envOr("BASE_RPC_URL", string(""));
            
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
            
            if (bytes(baseRpc).length > 0) {
                baseFork = vm.createFork(baseRpc);
                vm.selectFork(baseFork);
                _setupBase();
            }
        }
    }
    
    function _setupArbitrum() private {
        console2.log("=== Setting up Arbitrum fork ===");
        
        // Deploy handler
        arbHandler = new EAcrossHandler(ARB_SPOKE_POOL);
        console2.log("  Handler:", address(arbHandler));
        
        // Deploy adapter
        arbAdapter = new AIntents(ARB_SPOKE_POOL);
        console2.log("  Adapter:", address(arbAdapter));
        
        // Deploy test proxy with proper fallback
        arbPool = new TestProxyForAcross(
            address(arbHandler),
            address(arbAdapter),
            poolOwner,
            USDC_ARB,
            6
        );
        console2.log("  TestProxy:", address(arbPool));
        
        // Fund pool with USDC and WETH for testing
        deal(USDC_ARB, address(arbPool), 100000e6); // 100k USDC
        deal(WETH_ARB, address(arbPool), 100e18);   // 100 WETH
        
        console2.log("Arbitrum setup complete");
    }
    
    function _setupOptimism() private {
        console2.log("=== Setting up Optimism fork ===");
        
        // Deploy handler
        optHandler = new EAcrossHandler(OPT_SPOKE_POOL);
        console2.log("  Handler:", address(optHandler));
        
        // Deploy adapter
        optAdapter = new AIntents(OPT_SPOKE_POOL);
        console2.log("  Adapter:", address(optAdapter));
        
        // Deploy test proxy
        optPool = new TestProxyForAcross(
            address(optHandler),
            address(optAdapter),
            poolOwner,
            USDC_OPT,
            6
        );
        console2.log("  TestProxy:", address(optPool));
        
        // Fund pool
        deal(USDC_OPT, address(optPool), 100000e6);
        deal(WETH_OPT, address(optPool), 100e18);
        
        console2.log("Optimism setup complete");
    }
    
    function _setupBase() private {
        console2.log("=== Setting up Base fork ===");
        
        // Deploy handler
        baseHandler = new EAcrossHandler(BASE_SPOKE_POOL);
        console2.log("  Handler:", address(baseHandler));
        
        // Deploy adapter
        baseAdapter = new AIntents(BASE_SPOKE_POOL);
        console2.log("  Adapter:", address(baseAdapter));
        
        // Deploy test proxy
        basePool = new TestProxyForAcross(
            address(baseHandler),
            address(baseAdapter),
            poolOwner,
            USDC_BASE,
            6
        );
        console2.log("  TestProxy:", address(basePool));
        
        // Fund pool
        deal(USDC_BASE, address(basePool), 100000e6);
        deal(WETH_BASE, address(basePool), 100e18);
        
        console2.log("Base setup complete");
    }
    
    /*
     * CONFIGURATION TESTS
     */
    
    /// @notice Test adapter configuration on all chains
    function testFork_AdapterConfiguration() public {
        if (arbFork != 0) {
            vm.selectFork(arbFork);
            assertEq(address(arbAdapter.acrossSpokePool()), ARB_SPOKE_POOL, "Wrong ARB SpokePool");
            assertEq(arbAdapter.requiredVersion(), "HF_4.1.0", "Wrong version");
            console2.log("Arbitrum adapter OK");
        }
        
        if (optFork != 0) {
            vm.selectFork(optFork);
            assertEq(address(optAdapter.acrossSpokePool()), OPT_SPOKE_POOL, "Wrong OPT SpokePool");
            assertEq(optAdapter.requiredVersion(), "HF_4.1.0", "Wrong version");
            console2.log("Optimism adapter OK");
        }
        
        if (baseFork != 0) {
            vm.selectFork(baseFork);
            assertEq(address(baseAdapter.acrossSpokePool()), BASE_SPOKE_POOL, "Wrong BASE SpokePool");
            assertEq(baseAdapter.requiredVersion(), "HF_4.1.0", "Wrong version");
            console2.log("Base adapter OK");
        }
    }
    
    /// @notice Test handler configuration
    function testFork_HandlerConfiguration() public {
        if (arbFork != 0) {
            vm.selectFork(arbFork);
            assertEq(arbHandler.acrossSpokePool(), ARB_SPOKE_POOL, "Wrong ARB SpokePool");
        }
        
        if (optFork != 0) {
            vm.selectFork(optFork);
            assertEq(optHandler.acrossSpokePool(), OPT_SPOKE_POOL, "Wrong OPT SpokePool");
        }
        
        if (baseFork != 0) {
            vm.selectFork(baseFork);
            assertEq(baseHandler.acrossSpokePool(), BASE_SPOKE_POOL, "Wrong BASE SpokePool");
        }
    }
    
    /*
     * SECURITY TESTS
     */
    
    /// @notice Test handler rejects calls not from SpokePool
    function testFork_Arb_HandlerRejectsUnauthorized() public {
        if (arbFork == 0) return;
        vm.selectFork(arbFork);
        
        address unauthorized = makeAddr("unauthorized");
        uint256 amount = 100e6;
        
        DestinationMessage memory message = DestinationMessage({
            opType: OpType.Transfer,
            sourceChainId: OPT_CHAIN_ID,
            sourceNav: 0,
            sourceDecimals: 6,
            navTolerance: 0,
            shouldUnwrap: false,
            sourceNativeAmount: 0
        });
        
        bytes memory callData = abi.encodeWithSelector(
            IEAcrossHandler.handleV3AcrossMessage.selector,
            USDC_ARB,
            amount,
            abi.encode(message)
        );
        
        // Should revert when not called from SpokePool
        vm.prank(unauthorized);
        vm.expectRevert();
        (bool success,) = address(arbPool).call(callData);
        assertFalse(success, "Should reject unauthorized caller");
    }
    
    /// @notice Test adapter rejects direct calls
    function testFork_Arb_AdapterRejectsDirectCall() public {
        if (arbFork == 0) return;
        vm.selectFork(arbFork);
        
        vm.expectRevert();
        arbAdapter.depositV3(
            IAIntents.AcrossParams({
                depositor: address(arbAdapter),
                recipient: user1,
                inputToken: USDC_ARB,
                outputToken: USDC_BASE,
                inputAmount: 1000e6,
                outputAmount: 1000e6,
                destinationChainId: BASE_CHAIN_ID,
                exclusiveRelayer: address(0),
                quoteTimestamp: uint32(block.timestamp),
                fillDeadline: uint32(block.timestamp + 3600),
                exclusivityDeadline: 0,
                message: abi.encode("")
            })
        );
    }
    
    /*
     * HANDLER TESTS - Transfer Mode
     */
    
    /// @notice Test handler processes Transfer message correctly
    function testFork_Arb_HandlerTransferMode() public {
        if (arbFork == 0) return;
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
        
        // Check virtual balance before
        int256 vBalanceBefore = arbPool.getVirtualBalance(USDC_ARB);
        assertEq(vBalanceBefore, 0, "Initial virtual balance should be 0");
        
        // Simulate SpokePool calling handler via proxy fallback
        bytes memory callData = abi.encodeWithSelector(
            IEAcrossHandler.handleV3AcrossMessage.selector,
            USDC_ARB,
            amount,
            abi.encode(message)
        );
        
        vm.prank(ARB_SPOKE_POOL);
        (bool success, bytes memory result) = address(arbPool).call(callData);
        assertTrue(success, "Handler call should succeed");
        
        // Check virtual balance after (should be negative)
        int256 vBalanceAfter = arbPool.getVirtualBalance(USDC_ARB);
        assertEq(vBalanceAfter, -int256(amount), "Virtual balance should be negative amount");
        
        console2.log("Transfer mode: virtual balance =", vBalanceAfter);
    }
    
    /// @notice Test handler processes Rebalance message
    function testFork_Arb_HandlerRebalanceMode() public {
        if (arbFork == 0) return;
        vm.selectFork(arbFork);
        
        uint256 amount = 1000e6;
        
        DestinationMessage memory message = DestinationMessage({
            opType: OpType.Rebalance,
            sourceChainId: OPT_CHAIN_ID,
            sourceNav: 1000000, // 1.0 in 6 decimals
            sourceDecimals: 6,
            navTolerance: 10000, // 1%
            shouldUnwrap: false,
            sourceNativeAmount: 0
        });
        
        bytes memory callData = abi.encodeWithSelector(
            IEAcrossHandler.handleV3AcrossMessage.selector,
            USDC_ARB,
            amount,
            abi.encode(message)
        );
        
        vm.prank(ARB_SPOKE_POOL);
        (bool success,) = address(arbPool).call(callData);
        assertTrue(success, "Handler call should succeed");
        
        // In Rebalance mode, no virtual balance created
        int256 vBalance = arbPool.getVirtualBalance(USDC_ARB);
        assertEq(vBalance, 0, "No virtual balance in Rebalance mode");
    }
    
    /// @notice Test handler processes Sync message
    function testFork_Arb_HandlerSyncMode() public {
        if (arbFork == 0) return;
        vm.selectFork(arbFork);
        
        uint256 amount = 1000e6;
        
        // Set up existing virtual balance
        vm.prank(poolOwner);
        arbPool.setVirtualBalance(USDC_ARB, -2000e6);
        
        DestinationMessage memory message = DestinationMessage({
            opType: OpType.Sync,
            sourceChainId: OPT_CHAIN_ID,
            sourceNav: 0,
            sourceDecimals: 6,
            navTolerance: 0,
            shouldUnwrap: false,
            sourceNativeAmount: 0
        });
        
        bytes memory callData = abi.encodeWithSelector(
            IEAcrossHandler.handleV3AcrossMessage.selector,
            USDC_ARB,
            amount,
            abi.encode(message)
        );
        
        vm.prank(ARB_SPOKE_POOL);
        (bool success,) = address(arbPool).call(callData);
        assertTrue(success, "Handler call should succeed");
        
        // Virtual balance should be reduced
        int256 vBalanceAfter = arbPool.getVirtualBalance(USDC_ARB);
        assertEq(vBalanceAfter, -1000e6, "Virtual balance should be reduced");
    }
    
    /*
     * ADAPTER TESTS
     */
    
    /// @notice Test adapter can initiate deposit via proxy fallback
    function testFork_Arb_AdapterDepositV3() public {
        if (arbFork == 0) return;
        vm.selectFork(arbFork);
        
        uint256 depositAmount = 1000e6;
        
        // Prepare depositV3 call
        bytes memory callData = abi.encodeWithSelector(
            IAIntents.depositV3.selector,
            user1,                      // depositor
            USDC_ARB,                   // inputToken
            depositAmount,              // inputAmount
            depositAmount,              // outputAmount
            OPT_CHAIN_ID,              // destinationChainId
            address(0),                 // exclusiveRelayer
            uint32(block.timestamp + 3600),    // quoteTimestamp
            uint32(block.timestamp + 7200),    // fillDeadline
            0,                          // exclusivityDeadline
            abi.encode("")              // message
        );
        
        // Approve tokens
        vm.prank(address(arbPool));
        IERC20(USDC_ARB).approve(ARB_SPOKE_POOL, depositAmount);
        
        // Call via proxy fallback (should delegate to adapter)
        vm.prank(poolOwner);
        (bool success,) = address(arbPool).call(callData);
        assertTrue(success, "Adapter depositV3 should succeed");
        
        console2.log("depositV3 executed successfully");
    }
    
    /*
     * CROSS-CHAIN INTEGRATION TESTS
     */
    
    /// @notice Test simulated cross-chain transfer: Arbitrum -> Optimism
    function testFork_CrossChainTransfer_ArbToOpt() public {
        if (arbFork == 0 || optFork == 0) return;
        
        uint256 amount = 1000e6;
        
        // Step 1: On Arbitrum - initiate deposit
        vm.selectFork(arbFork);
        console2.log("=== Source Chain (Arbitrum) ===");
        
        // Set virtual balance on source (simulate outgoing transfer)
        vm.prank(poolOwner);
        arbPool.setVirtualBalance(USDC_ARB, int256(amount));
        
        int256 arbVBalance = arbPool.getVirtualBalance(USDC_ARB);
        console2.log("ARB virtual balance after send:", arbVBalance);
        assertEq(arbVBalance, int256(amount), "Positive virtual balance on source");
        
        // Step 2: On Optimism - receive via handler
        vm.selectFork(optFork);
        console2.log("=== Destination Chain (Optimism) ===");
        
        DestinationMessage memory message = DestinationMessage({
            opType: OpType.Transfer,
            sourceChainId: ARB_CHAIN_ID,
            sourceNav: 0,
            sourceDecimals: 6,
            navTolerance: 0,
            shouldUnwrap: false,
            sourceNativeAmount: 0
        });
        
        bytes memory callData = abi.encodeWithSelector(
            IEAcrossHandler.handleV3AcrossMessage.selector,
            USDC_OPT,
            amount,
            abi.encode(message)
        );
        
        vm.prank(OPT_SPOKE_POOL);
        (bool success,) = address(optPool).call(callData);
        assertTrue(success, "Handler should succeed");
        
        int256 optVBalance = optPool.getVirtualBalance(USDC_OPT);
        console2.log("OPT virtual balance after receive:", optVBalance);
        assertEq(optVBalance, -int256(amount), "Negative virtual balance on destination");
        
        console2.log("=== Cross-chain transfer completed ===");
    }
    
    /// @notice Test round-trip: Arb -> Opt -> Arb
    function testFork_CrossChainRoundTrip() public {
        if (arbFork == 0 || optFork == 0) return;
        
        uint256 amount = 500e6;
        
        // Arb -> Opt
        vm.selectFork(arbFork);
        vm.prank(poolOwner);
        arbPool.setVirtualBalance(USDC_ARB, int256(amount));
        
        vm.selectFork(optFork);
        DestinationMessage memory message1 = DestinationMessage({
            opType: OpType.Transfer,
            sourceChainId: ARB_CHAIN_ID,
            sourceNav: 0,
            sourceDecimals: 6,
            navTolerance: 0,
            shouldUnwrap: false,
            sourceNativeAmount: 0
        });
        
        vm.prank(OPT_SPOKE_POOL);
        (bool success1,) = address(optPool).call(
            abi.encodeWithSelector(
                IEAcrossHandler.handleV3AcrossMessage.selector,
                USDC_OPT,
                amount,
                abi.encode(message1)
            )
        );
        assertTrue(success1);
        
        // Opt -> Arb (return)
        vm.prank(poolOwner);
        optPool.setVirtualBalance(USDC_OPT, int256(amount) - int256(amount));
        
        vm.selectFork(arbFork);
        DestinationMessage memory message2 = DestinationMessage({
            opType: OpType.Sync,
            sourceChainId: OPT_CHAIN_ID,
            sourceNav: 0,
            sourceDecimals: 6,
            navTolerance: 0,
            shouldUnwrap: false,
            sourceNativeAmount: 0
        });
        
        vm.prank(ARB_SPOKE_POOL);
        (bool success2,) = address(arbPool).call(
            abi.encodeWithSelector(
                IEAcrossHandler.handleV3AcrossMessage.selector,
                USDC_ARB,
                amount,
                abi.encode(message2)
            )
        );
        assertTrue(success2);
        
        // Check balances are synced
        int256 finalArbBalance = arbPool.getVirtualBalance(USDC_ARB);
        assertEq(finalArbBalance, 0, "Should be synced after round trip");
        
        console2.log("Round trip completed successfully");
    }
    
    /*
     * ADVANCED COVERAGE TESTS - EAcrossHandler
     */
    
    /// @notice Test handler with shouldUnwrap flag (WETH unwrapping)
    function testFork_Arb_HandlerUnwrapWETH() public {
        if (arbFork == 0) return;
        vm.selectFork(arbFork);
        
        uint256 amount = 1e18;
        
        // Deal WETH to pool
        deal(WETH_ARB, address(arbPool), amount);
        
        DestinationMessage memory message = DestinationMessage({
            opType: OpType.Transfer,
            sourceChainId: OPT_CHAIN_ID,
            sourceNav: 0,
            sourceDecimals: 18,
            navTolerance: 0,
            shouldUnwrap: true,
            sourceNativeAmount: amount
        });
        
        uint256 ethBalanceBefore = address(arbPool).balance;
        
        bytes memory callData = abi.encodeWithSelector(
            IEAcrossHandler.handleV3AcrossMessage.selector,
            WETH_ARB,
            amount,
            abi.encode(message)
        );
        
        vm.prank(ARB_SPOKE_POOL);
        (bool success,) = address(arbPool).call(callData);
        assertTrue(success, "Handler with unwrap should succeed");
        
        // Check ETH was received (WETH unwrapped)
        uint256 ethBalanceAfter = address(arbPool).balance;
        assertGt(ethBalanceAfter, ethBalanceBefore, "Should receive ETH from unwrap");
        
        console2.log("WETH unwrapped successfully");
    }
    
    /// @notice Test handler with different decimal conversions
    function testFork_Arb_HandlerDifferentDecimals() public {
        if (arbFork == 0) return;
        vm.selectFork(arbFork);
        
        // Test with 18 decimals token (WETH)
        uint256 amount = 5e18;
        deal(WETH_ARB, address(arbPool), amount);
        
        DestinationMessage memory message = DestinationMessage({
            opType: OpType.Transfer,
            sourceChainId: OPT_CHAIN_ID,
            sourceNav: 0,
            sourceDecimals: 18,
            navTolerance: 0,
            shouldUnwrap: false,
            sourceNativeAmount: 0
        });
        
        bytes memory callData = abi.encodeWithSelector(
            IEAcrossHandler.handleV3AcrossMessage.selector,
            WETH_ARB,
            amount,
            abi.encode(message)
        );
        
        vm.prank(ARB_SPOKE_POOL);
        (bool success,) = address(arbPool).call(callData);
        assertTrue(success, "Should handle 18 decimals");
        
        // Virtual balance should be in base token decimals (6)
        int256 vBalance = arbPool.getVirtualBalance(USDC_ARB);
        console2.log("Virtual balance after 18 dec transfer:", vBalance);
    }
    
    /// @notice Test handler with large amounts
    function testFork_Arb_HandlerLargeAmount() public {
        if (arbFork == 0) return;
        vm.selectFork(arbFork);
        
        uint256 largeAmount = 1000000e6; // 1M USDC
        deal(USDC_ARB, address(arbPool), largeAmount);
        
        DestinationMessage memory message = DestinationMessage({
            opType: OpType.Transfer,
            sourceChainId: OPT_CHAIN_ID,
            sourceNav: 0,
            sourceDecimals: 6,
            navTolerance: 0,
            shouldUnwrap: false,
            sourceNativeAmount: 0
        });
        
        bytes memory callData = abi.encodeWithSelector(
            IEAcrossHandler.handleV3AcrossMessage.selector,
            USDC_ARB,
            largeAmount,
            abi.encode(message)
        );
        
        vm.prank(ARB_SPOKE_POOL);
        (bool success,) = address(arbPool).call(callData);
        assertTrue(success, "Should handle large amounts");
        
        int256 vBalance = arbPool.getVirtualBalance(USDC_ARB);
        assertEq(vBalance, -int256(largeAmount), "Virtual balance should match");
    }
    
    /// @notice Test handler Rebalance mode with NAV check
    function testFork_Arb_HandlerRebalanceWithNavCheck() public {
        if (arbFork == 0) return;
        vm.selectFork(arbFork);
        
        uint256 amount = 1000e6;
        uint256 poolNav = 1005000; // 1.005 in 6 decimals
        uint256 sourceNav = 1000000; // 1.0 in 6 decimals
        
        // Mock pool NAV
        vm.mockCall(
            address(arbPool),
            abi.encodeWithSignature("getPoolTokens()"),
            abi.encode(1000e18, poolNav) // totalSupply, unitaryValue
        );
        
        DestinationMessage memory message = DestinationMessage({
            opType: OpType.Rebalance,
            sourceChainId: OPT_CHAIN_ID,
            sourceNav: sourceNav,
            sourceDecimals: 6,
            navTolerance: 10000, // 1% tolerance
            shouldUnwrap: false,
            sourceNativeAmount: 0
        });
        
        bytes memory callData = abi.encodeWithSelector(
            IEAcrossHandler.handleV3AcrossMessage.selector,
            USDC_ARB,
            amount,
            abi.encode(message)
        );
        
        vm.prank(ARB_SPOKE_POOL);
        (bool success,) = address(arbPool).call(callData);
        assertTrue(success, "Rebalance with valid NAV should succeed");
        
        vm.clearMockedCalls();
    }
}
