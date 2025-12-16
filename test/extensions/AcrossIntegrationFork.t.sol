// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {AIntents} from "../../contracts/protocol/extensions/adapters/AIntents.sol";
import {EAcrossHandler} from "../../contracts/protocol/extensions/EAcrossHandler.sol";
import {IERC20} from "../../contracts/protocol/interfaces/IERC20.sol";
import {IAIntents} from "../../contracts/protocol/extensions/adapters/interfaces/IAIntents.sol";
import {IEAcrossHandler} from "../../contracts/protocol/extensions/adapters/interfaces/IEAcrossHandler.sol";
import {ISmartPoolState} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolState.sol";
import {OpType, DestinationMessage, SourceMessage} from "../../contracts/protocol/types/Crosschain.sol";
import {TestProxyForAcross} from "../fixtures/TestProxyForAcross.sol";

/// @title AcrossIntegrationFork - Comprehensive fork-based integration tests
/// @notice Merged integration tests for Across protocol testing on real forks
contract AcrossIntegrationForkTest is Test {
    uint256 constant MAINNET_BLOCK    = 21_000_000;
    uint256 constant BASE_BLOCK   = 35521323;

    uint256 constant BASE_CHAIN_ID = 8453;

    // Deployed infrastructure addresses
    address constant AUTHORITY = 0x7F427F11eB24f1be14D0c794f6d5a9830F18FBf1;
    address constant FACTORY = 0x4aA9e5A5A244C81C3897558C5cF5b752EBefA88f;
    address constant REGISTRY = 0x19Be0f8D5f35DB8c2d2f50c9a3742C5d1eB88907;
    
    // Across SpokePools by chain
    address constant ETH_SPOKE_POOL = 0x5c7BCd6E7De5423a257D81B442095A1a6ced35C5;
    address constant BASE_SPOKE_POOL = 0x09aea4b2242abC8bb4BB78D537A67a245A7bEC64;
    
    // Tokens on Ethereum mainnet
    address constant USDC_ETH = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH_ETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    
    // Tokens on Base
    address constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH_BASE = 0x4200000000000000000000000000000000000006;
    
    // Test actors
    address poolOwner;
    address user1;
    address user2;
    
    // Fork IDs
    uint256 ethFork;
    uint256 baseFork;
    
    // Deployed test contracts on Ethereum
    TestProxyForAcross ethPool;
    AIntents ethAdapter;
    EAcrossHandler ethHandler;
    
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
            string memory ethRpc = string.concat("https://mainnet.infura.io/v3/", infuraKey);
            string memory baseRpc = string.concat("https://base-mainnet.infura.io/v3/", infuraKey);
            
            ethFork = vm.createSelectFork(ethRpc, MAINNET_BLOCK);
            _setupEthereum();
            
            baseFork = vm.createSelectFork(baseRpc, BASE_BLOCK);
            _setupBase();
            
            console2.log("=== All forks created successfully ===");
        } else {
            revert("NO_INFURA_KEY_FOUND");
            // Fallback to individual RPC URLs from env
            //string memory baseRpc = vm.envOr("BASE_RPC_URL", string(""));
            
            //if (bytes(baseRpc).length > 0) {
            //    baseFork = vm.createSelectFork(baseRpc, BASE_BLOCK);
            //    _setupBase();
            //}
        }
    }
    
    function _setupEthereum() private {
        console2.log("=== Setting up Ethereum fork ===");
        
        // Deploy handler
        ethHandler = new EAcrossHandler(ETH_SPOKE_POOL);
        console2.log("  Handler:", address(ethHandler));
        
        // Deploy adapter
        ethAdapter = new AIntents(ETH_SPOKE_POOL);
        console2.log("  Adapter:", address(ethAdapter));
        
        // Deploy test proxy with proper fallback
        ethPool = new TestProxyForAcross(
            address(ethHandler),
            address(ethAdapter),
            poolOwner,
            USDC_ETH,
            6
        );
        console2.log("  TestProxy:", address(ethPool));
        
        // Fund pool with USDC and WETH for testing
        deal(USDC_ETH, address(ethPool), 100000e6); // 100k USDC
        deal(WETH_ETH, address(ethPool), 100e18);   // 100 WETH
        
        console2.log("Ethereum setup complete");
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
        if (ethFork != 0) {
            vm.selectFork(ethFork);
            assertEq(address(ethAdapter.acrossSpokePool()), ETH_SPOKE_POOL, "Wrong ETH SpokePool");
            assertEq(ethAdapter.requiredVersion(), "HF_4.1.0", "Wrong version");
            console2.log("Ethereum adapter OK");
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
        if (ethFork != 0) {
            vm.selectFork(ethFork);
            assertEq(ethHandler.acrossSpokePool(), ETH_SPOKE_POOL, "Wrong ETH SpokePool");
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
    function testFork_Eth_HandlerRejectsUnauthorized() public {
        if (ethFork == 0) return;
        vm.selectFork(ethFork);
        
        address unauthorized = makeAddr("unauthorized");
        uint256 amount = 100e6;
        
        DestinationMessage memory message = DestinationMessage({
            opType: OpType.Transfer,
            sourceChainId: block.chainid,
            sourceNav: 0,
            sourceDecimals: 6,
            navTolerance: 0,
            shouldUnwrap: false,
            sourceNativeAmount: 0
        });
        
        bytes memory callData = abi.encodeWithSelector(
            IEAcrossHandler.handleV3AcrossMessage.selector,
            USDC_ETH,
            amount,
            abi.encode(message)
        );
        
        // Should revert when not called from SpokePool
        vm.prank(unauthorized);
        vm.expectRevert();
        (bool success,) = address(ethPool).call(callData);
        assertFalse(success, "Should reject unauthorized caller");
    }
    
    /// @notice Test adapter rejects direct calls
    function testFork_Eth_AdapterRejectsDirectCall() public {
        if (ethFork == 0) return;
        vm.selectFork(ethFork);
        
        vm.expectRevert();
        ethAdapter.depositV3(
            IAIntents.AcrossParams({
                depositor: address(ethAdapter),
                recipient: user1,
                inputToken: USDC_ETH,
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
    function testFork_Eth_HandlerTransferMode() public {
        if (ethFork == 0) return;
        vm.selectFork(ethFork);
        
        uint256 amount = 1000e6;
        
        DestinationMessage memory message = DestinationMessage({
            opType: OpType.Transfer,
            sourceChainId: block.chainid,
            sourceNav: 0,
            sourceDecimals: 6,
            navTolerance: 0,
            shouldUnwrap: false,
            sourceNativeAmount: 0
        });
        
        // Check virtual balance before
        int256 vBalanceBefore = ethPool.getVirtualBalance(USDC_ETH);
        assertEq(vBalanceBefore, 0, "Initial virtual balance should be 0");
        
        vm.prank(ETH_SPOKE_POOL);
        IEAcrossHandler(address(ethPool)).handleV3AcrossMessage(
            USDC_ETH,
            amount,
            abi.encode(message)
        );
        //assertTrue(success, "Handler call should succeed");
        
        // Check virtual balance after (should be negative)
        int256 vBalanceAfter = ethPool.getVirtualBalance(USDC_ETH);
        assertEq(vBalanceAfter, -int256(amount), "Virtual balance should be negative amount");
        
        console2.log("Transfer mode: virtual balance =", vBalanceAfter);
    }
    
    /// @notice Test handler processes Rebalance message
    function testFork_Eth_HandlerRebalanceMode() public {
        if (ethFork == 0) return;
        vm.selectFork(ethFork);
        
        uint256 amount = 1000e6;
        
        DestinationMessage memory message = DestinationMessage({
            opType: OpType.Rebalance,
            sourceChainId: block.chainid,
            sourceNav: 1000000, // 1.0 in 6 decimals
            sourceDecimals: 6,
            navTolerance: 10000, // 1%
            shouldUnwrap: false,
            sourceNativeAmount: 0
        });
        
        bytes memory callData = abi.encodeWithSelector(
            IEAcrossHandler.handleV3AcrossMessage.selector,
            USDC_ETH,
            amount,
            abi.encode(message)
        );
        
        vm.prank(ETH_SPOKE_POOL);
        (bool success,) = address(ethPool).call(callData);
        assertTrue(success, "Handler call should succeed");
        
        // In Rebalance mode, no virtual balance created
        int256 vBalance = ethPool.getVirtualBalance(USDC_ETH);
        assertEq(vBalance, 0, "No virtual balance in Rebalance mode");
    }
    
    /// @notice Test handler processes Sync message
    function testFork_Eth_HandlerSyncMode() public {
        if (ethFork == 0) return;
        vm.selectFork(ethFork);
        
        uint256 amount = 1000e6;
        
        // Set up existing virtual balance
        vm.prank(poolOwner);
        ethPool.setVirtualBalance(USDC_ETH, -2000e6);
        
        DestinationMessage memory message = DestinationMessage({
            opType: OpType.Sync,
            sourceChainId: block.chainid,
            sourceNav: 0,
            sourceDecimals: 6,
            navTolerance: 0,
            shouldUnwrap: false,
            sourceNativeAmount: 0
        });
        
        bytes memory callData = abi.encodeWithSelector(
            IEAcrossHandler.handleV3AcrossMessage.selector,
            USDC_ETH,
            amount,
            abi.encode(message)
        );
        
        vm.prank(ETH_SPOKE_POOL);
        (bool success,) = address(ethPool).call(callData);
        assertTrue(success, "Handler call should succeed");
        
        // Virtual balance should be reduced
        int256 vBalanceAfter = ethPool.getVirtualBalance(USDC_ETH);
        assertEq(vBalanceAfter, -1000e6, "Virtual balance should be reduced");
    }
    
    /*
     * ADAPTER TESTS
     */
    
    /// @notice Test adapter can initiate deposit via proxy fallback
    function testFork_Eth_AdapterDepositV3() public {
        if (ethFork == 0) return;
        vm.selectFork(ethFork);
        
        uint256 depositAmount = 1000e6;
        
        // Approve tokens
        vm.prank(address(ethPool));
        IERC20(USDC_ETH).approve(ETH_SPOKE_POOL, depositAmount);

        SourceMessage memory sourceMsg = SourceMessage({
            opType: OpType.Transfer,
            navTolerance: 100,
            sourceNativeAmount: 0,
            shouldUnwrapOnDestination: false
        });
        
        // Call via proxy fallback (should delegate to adapter)
        vm.prank(poolOwner);
        IAIntents(address(ethPool)).depositV3(
            IAIntents.AcrossParams({
                depositor: user1,
                recipient: user1,
                inputToken: USDC_ETH,
                outputToken: USDC_BASE,
                inputAmount: 1000e6,
                outputAmount: 1000e6,
                destinationChainId: BASE_CHAIN_ID,
                exclusiveRelayer: address(0),
                quoteTimestamp: uint32(block.timestamp),
                fillDeadline: uint32(block.timestamp + 3600),
                exclusivityDeadline: 0,
                message: abi.encode(sourceMsg)
            })
        );
        
        console2.log("depositV3 executed successfully");
    }
    
    /*
     * CROSS-CHAIN INTEGRATION TESTS
     */
    
    /// @notice Test simulated cross-chain transfer: Ethereum -> Optimism
    function testFork_CrossChainTransfer_EthToBase() public {
        if (ethFork == 0 || baseFork == 0) return;
        
        uint256 amount = 1000e6;
        
        // Step 1: On Ethereum - initiate deposit
        vm.selectFork(ethFork);
        console2.log("=== Source Chain (Ethereum) ===");
        
        // Set virtual balance on source (simulate outgoing transfer)
        vm.prank(poolOwner);
        ethPool.setVirtualBalance(USDC_ETH, int256(amount));
        
        int256 ethVBalance = ethPool.getVirtualBalance(USDC_ETH);
        console2.log("ETH virtual balance after send:", ethVBalance);
        assertEq(ethVBalance, int256(amount), "Positive virtual balance on source");
        
        // Step 2: On Optimism - receive via handler
        vm.selectFork(baseFork);
        console2.log("=== Destination Chain (Optimism) ===");
        
        DestinationMessage memory message = DestinationMessage({
            opType: OpType.Transfer,
            sourceChainId: block.chainid,
            sourceNav: 0,
            sourceDecimals: 6,
            navTolerance: 0,
            shouldUnwrap: false,
            sourceNativeAmount: 0
        });
        
        bytes memory callData = abi.encodeWithSelector(
            IEAcrossHandler.handleV3AcrossMessage.selector,
            USDC_BASE,
            amount,
            abi.encode(message)
        );
        
        vm.prank(BASE_SPOKE_POOL);
        (bool success,) = address(basePool).call(callData);
        assertTrue(success, "Handler should succeed");
        
        int256 baseVBalance = basePool.getVirtualBalance(USDC_BASE);
        console2.log("Base virtual balance after receive:", baseVBalance);
        assertEq(baseVBalance, -int256(amount), "Negative virtual balance on destination");
        
        console2.log("=== Cross-chain transfer completed ===");
    }
    
    /// @notice Test round-trip: Eth -> Opt -> Eth
    function testFork_CrossChainRoundTrip() public {
        if (ethFork == 0 || baseFork == 0) return;
        
        uint256 amount = 500e6;
        
        // Eth -> Opt
        vm.selectFork(ethFork);
        vm.prank(poolOwner);
        ethPool.setVirtualBalance(USDC_ETH, int256(amount));
        
        vm.selectFork(baseFork);
        DestinationMessage memory message1 = DestinationMessage({
            opType: OpType.Transfer,
            sourceChainId: block.chainid,
            sourceNav: 0,
            sourceDecimals: 6,
            navTolerance: 0,
            shouldUnwrap: false,
            sourceNativeAmount: 0
        });
        
        vm.prank(BASE_SPOKE_POOL);
        (bool success1,) = address(basePool).call(
            abi.encodeWithSelector(
                IEAcrossHandler.handleV3AcrossMessage.selector,
                USDC_BASE,
                amount,
                abi.encode(message1)
            )
        );
        assertTrue(success1);
        
        // Opt -> Eth (return)
        vm.prank(poolOwner);
        basePool.setVirtualBalance(USDC_BASE, int256(amount) - int256(amount));
        
        vm.selectFork(ethFork);
        DestinationMessage memory message2 = DestinationMessage({
            opType: OpType.Sync,
            sourceChainId: block.chainid,
            sourceNav: 0,
            sourceDecimals: 6,
            navTolerance: 0,
            shouldUnwrap: false,
            sourceNativeAmount: 0
        });
        
        vm.prank(ETH_SPOKE_POOL);
        (bool success2,) = address(ethPool).call(
            abi.encodeWithSelector(
                IEAcrossHandler.handleV3AcrossMessage.selector,
                USDC_ETH,
                amount,
                abi.encode(message2)
            )
        );
        assertTrue(success2);
        
        // Check balances are synced
        int256 finalEthBalance = ethPool.getVirtualBalance(USDC_ETH);
        assertEq(finalEthBalance, 0, "Should be synced after round trip");
        
        console2.log("Round trip completed successfully");
    }
    
    /*
     * ADVANCED COVERAGE TESTS - EAcrossHandler
     */
    
    /// @notice Test handler with shouldUnwrap flag (WETH unwrapping)
    function testFork_Eth_HandlerUnwrapWETH() public {
        if (ethFork == 0) return;
        vm.selectFork(ethFork);
        
        uint256 amount = 1e18;
        
        // Deal WETH to pool
        deal(WETH_ETH, address(ethPool), amount);
        
        DestinationMessage memory message = DestinationMessage({
            opType: OpType.Transfer,
            sourceChainId: block.chainid,
            sourceNav: 0,
            sourceDecimals: 18,
            navTolerance: 0,
            shouldUnwrap: true,
            sourceNativeAmount: amount
        });
        
        uint256 ethBalanceBefore = address(ethPool).balance;
        
        bytes memory callData = abi.encodeWithSelector(
            IEAcrossHandler.handleV3AcrossMessage.selector,
            WETH_ETH,
            amount,
            abi.encode(message)
        );
        
        vm.prank(ETH_SPOKE_POOL);
        (bool success,) = address(ethPool).call(callData);
        assertTrue(success, "Handler with unwrap should succeed");
        
        // Check ETH was received (WETH unwrapped)
        uint256 ethBalanceAfter = address(ethPool).balance;
        assertGt(ethBalanceAfter, ethBalanceBefore, "Should receive ETH from unwrap");
        
        console2.log("WETH unwrapped successfully");
    }
    
    /// @notice Test handler with different decimal conversions
    function testFork_Eth_HandlerDifferentDecimals() public {
        if (ethFork == 0) return;
        vm.selectFork(ethFork);
        
        // Test with 18 decimals token (WETH)
        uint256 amount = 5e18;
        deal(WETH_ETH, address(ethPool), amount);
        
        DestinationMessage memory message = DestinationMessage({
            opType: OpType.Transfer,
            sourceChainId: block.chainid,
            sourceNav: 0,
            sourceDecimals: 18,
            navTolerance: 0,
            shouldUnwrap: false,
            sourceNativeAmount: 0
        });
        
        bytes memory callData = abi.encodeWithSelector(
            IEAcrossHandler.handleV3AcrossMessage.selector,
            WETH_ETH,
            amount,
            abi.encode(message)
        );
        
        vm.prank(ETH_SPOKE_POOL);
        (bool success,) = address(ethPool).call(callData);
        assertTrue(success, "Should handle 18 decimals");
        
        // Virtual balance should be in base token decimals (6)
        int256 vBalance = ethPool.getVirtualBalance(USDC_ETH);
        console2.log("Virtual balance after 18 dec transfer:", vBalance);
    }
    
    /// @notice Test handler with large amounts
    function testFork_Eth_HandlerLargeAmount() public {
        if (ethFork == 0) return;
        vm.selectFork(ethFork);
        
        uint256 largeAmount = 1000000e6; // 1M USDC
        deal(USDC_ETH, address(ethPool), largeAmount);
        
        DestinationMessage memory message = DestinationMessage({
            opType: OpType.Transfer,
            sourceChainId: block.chainid,
            sourceNav: 0,
            sourceDecimals: 6,
            navTolerance: 0,
            shouldUnwrap: false,
            sourceNativeAmount: 0
        });
        
        bytes memory callData = abi.encodeWithSelector(
            IEAcrossHandler.handleV3AcrossMessage.selector,
            USDC_ETH,
            largeAmount,
            abi.encode(message)
        );
        
        vm.prank(ETH_SPOKE_POOL);
        (bool success,) = address(ethPool).call(callData);
        assertTrue(success, "Should handle large amounts");
        
        int256 vBalance = ethPool.getVirtualBalance(USDC_ETH);
        assertEq(vBalance, -int256(largeAmount), "Virtual balance should match");
    }
    
    /// @notice Test handler Rebalance mode with NAV check
    function testFork_Eth_HandlerRebalanceWithNavCheck() public {
        if (ethFork == 0) return;
        vm.selectFork(ethFork);
        
        uint256 amount = 1000e6;
        uint256 poolNav = 1005000; // 1.005 in 6 decimals
        uint256 sourceNav = 1000000; // 1.0 in 6 decimals
        
        // Mock pool NAV
        vm.mockCall(
            address(ethPool),
            abi.encodeWithSignature("getPoolTokens()"),
            abi.encode(1000e18, poolNav) // totalSupply, unitaryValue
        );
        
        DestinationMessage memory message = DestinationMessage({
            opType: OpType.Rebalance,
            sourceChainId: block.chainid,
            sourceNav: sourceNav,
            sourceDecimals: 6,
            navTolerance: 10000, // 1% tolerance
            shouldUnwrap: false,
            sourceNativeAmount: 0
        });
        
        bytes memory callData = abi.encodeWithSelector(
            IEAcrossHandler.handleV3AcrossMessage.selector,
            USDC_ETH,
            amount,
            abi.encode(message)
        );
        
        vm.prank(ETH_SPOKE_POOL);
        (bool success,) = address(ethPool).call(callData);
        assertTrue(success, "Rebalance with valid NAV should succeed");
        
        vm.clearMockedCalls();
    }
    
    /// @notice Test adapter depositV3 with actual balance transfer
    function testFork_Eth_AdapterDepositV3WithBalances() public {
        if (ethFork == 0) return;
        vm.selectFork(ethFork);
        
        // Mint tokens to pool
        deal(USDC_ETH, address(ethPool), 1000e6);
        
        // Approve SpokePool
        vm.prank(address(ethPool));
        IERC20(USDC_ETH).approve(ETH_SPOKE_POOL, 1000e6);
        
        SourceMessage memory sourceMsg = SourceMessage({
            opType: OpType.Transfer,
            navTolerance: 0,
            sourceNativeAmount: 0,
            shouldUnwrapOnDestination: false
        });
        
        bytes memory callData = abi.encodeWithSelector(
            IAIntents.depositV3.selector,
            address(ethPool),
            USDC_ETH,
            uint256(100e6),
            uint256(1000e6),
            uint256(BASE_CHAIN_ID),
            address(0),
            uint32(block.timestamp + 1 hours),
            uint32(block.timestamp + 2 hours),
            address(0),
            abi.encode(sourceMsg)
        );
        
        vm.prank(address(ethPool));
        (bool success,) = address(ethAdapter).delegatecall(callData);
        assertTrue(success, "depositV3 with balances should succeed");
    }
    
    /// @notice Test handler with actual WETH unwrapping
    function testFork_Eth_HandlerUnwrapWETHWithBalances() public {
        if (ethFork == 0) return;
        vm.selectFork(ethFork);
        
        // Give ethPool some WETH
        deal(WETH_ETH, address(ethPool), 1 ether);
        
        DestinationMessage memory message = DestinationMessage({
            opType: OpType.Transfer,
            sourceChainId: block.chainid,
            sourceNav: 0,
            sourceDecimals: 18,
            navTolerance: 0,
            shouldUnwrap: true,
            sourceNativeAmount: 0.5 ether
        });
        
        bytes memory callData = abi.encodeWithSelector(
            IEAcrossHandler.handleV3AcrossMessage.selector,
            WETH_ETH,
            0.5 ether,
            abi.encode(message)
        );
        
        uint256 balanceBefore = address(ethPool).balance;
        
        vm.prank(ETH_SPOKE_POOL);
        (bool success,) = address(ethPool).call(callData);
        assertTrue(success, "Unwrap should succeed");
        
        uint256 balanceAfter = address(ethPool).balance;
        assertEq(balanceAfter - balanceBefore, 0.5 ether, "Should receive unwrapped ETH");
    }
    
    /// @notice Test handler rebalance mode with NAV deviation
    function testFork_Eth_HandlerRebalanceNavDeviation() public {
        if (ethFork == 0) return;
        vm.selectFork(ethFork);
        
        // Mock NAV getter to return specific value
        vm.mockCall(
            address(ethPool),
            abi.encodeWithSelector(ISmartPoolState.getPoolTokens.selector),
            abi.encode(ISmartPoolState.PoolTokens({
                unitaryValue: 1.1e6, // 10% higher NAV
                totalSupply: 1000e6
            }))
        );
        
        DestinationMessage memory message = DestinationMessage({
            opType: OpType.Rebalance,
            sourceChainId: block.chainid,
            sourceNav: 1e6,
            sourceDecimals: 6,
            navTolerance: 0.05e6, // 5% tolerance
            shouldUnwrap: false,
            sourceNativeAmount: 0
        });
        
        bytes memory callData = abi.encodeWithSelector(
            IEAcrossHandler.handleV3AcrossMessage.selector,
            USDC_ETH,
            100e6,
            abi.encode(message)
        );
        
        vm.prank(ETH_SPOKE_POOL);
        (bool success,) = address(ethPool).call(callData);
        assertFalse(success, "Should reject NAV deviation beyond tolerance");
        
        vm.clearMockedCalls();
    }
    
    /// @notice Test handler sync mode with actual NAV sync
    function testFork_Eth_HandlerSyncModeWithNav() public {
        if (ethFork == 0) return;
        vm.selectFork(ethFork);
        
        // Mock NAV getter
        vm.mockCall(
            address(ethPool),
            abi.encodeWithSelector(ISmartPoolState.getPoolTokens.selector),
            abi.encode(ISmartPoolState.PoolTokens({
                unitaryValue: 1.02e6,
                totalSupply: 1000e6
            }))
        );
        
        DestinationMessage memory message = DestinationMessage({
            opType: OpType.Sync,
            sourceChainId: block.chainid,
            sourceNav: 1e6,
            sourceDecimals: 6,
            navTolerance: 0.05e6,
            shouldUnwrap: false,
            sourceNativeAmount: 0
        });
        
        bytes memory callData = abi.encodeWithSelector(
            IEAcrossHandler.handleV3AcrossMessage.selector,
            USDC_ETH,
            100e6,
            abi.encode(message)
        );
        
        vm.prank(ETH_SPOKE_POOL);
        (bool success,) = address(ethPool).call(callData);
        assertTrue(success, "Sync with valid NAV should succeed");
        
        vm.clearMockedCalls();
    }
    
    /// @notice Test adapter with different decimals
    function testFork_Eth_AdapterDifferentDecimalsMessage() public {
        if (ethFork == 0) return;
        vm.selectFork(ethFork);
        
        SourceMessage memory sourceMsg = SourceMessage({
            opType: OpType.Rebalance,
            navTolerance: 0.05e18,
            sourceNativeAmount: 0,
            shouldUnwrapOnDestination: false
        });
        
        bytes memory encoded = abi.encode(sourceMsg);
        SourceMessage memory decoded = abi.decode(encoded, (SourceMessage));
        
        assertEq(uint8(decoded.opType), uint8(OpType.Rebalance));
        assertEq(decoded.navTolerance, 0.05e18);
    }
    
    /// @notice Test handler with different token decimals
    function testFork_Eth_HandlerDifferentTokenDecimals() public {
        if (ethFork == 0) return;
        vm.selectFork(ethFork);
        
        DestinationMessage memory message = DestinationMessage({
            opType: OpType.Transfer,
            sourceChainId: block.chainid,
            sourceNav: 0,
            sourceDecimals: 18,
            navTolerance: 0,
            shouldUnwrap: false,
            sourceNativeAmount: 0
        });
        
        bytes memory callData = abi.encodeWithSelector(
            IEAcrossHandler.handleV3AcrossMessage.selector,
            WETH_ETH,
            1e18,
            abi.encode(message)
        );
        
        vm.prank(ETH_SPOKE_POOL);
        (bool success,) = address(ethPool).call(callData);
        assertTrue(success, "Should handle 18 decimal tokens");
    }
    
    /// @notice Test adapter with sync mode message
    function testFork_Eth_AdapterSyncModeMessage() public {
        if (ethFork == 0) return;
        vm.selectFork(ethFork);
        
        deal(USDC_ETH, address(ethPool), 1000e6);
        
        vm.prank(address(ethPool));
        IERC20(USDC_ETH).approve(ETH_SPOKE_POOL, 1000e6);
        
        SourceMessage memory sourceMsg = SourceMessage({
            opType: OpType.Sync,
            navTolerance: 0.05e6,
            sourceNativeAmount: 0,
            shouldUnwrapOnDestination: false
        });
        
        bytes memory callData = abi.encodeWithSelector(
            IAIntents.depositV3.selector,
            address(ethPool),
            USDC_ETH,
            uint256(100e6),
            uint256(1000e6),
            uint256(BASE_CHAIN_ID),
            address(0),
            uint32(block.timestamp + 1 hours),
            uint32(block.timestamp + 2 hours),
            address(0),
            abi.encode(sourceMsg)
        );
        
        vm.prank(address(ethPool));
        (bool success,) = address(ethAdapter).delegatecall(callData);
        assertTrue(success, "Sync mode deposit should succeed");
    }
}
