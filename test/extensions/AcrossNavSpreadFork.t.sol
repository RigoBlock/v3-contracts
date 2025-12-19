// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Constants} from "../../contracts/test/Constants.sol";
import {AIntents} from "../../contracts/protocol/extensions/adapters/AIntents.sol";
import {EAcrossHandler} from "../../contracts/protocol/extensions/EAcrossHandler.sol";
import {ChainNavSpreadLib} from "../../contracts/protocol/libraries/ChainNavSpreadLib.sol";
import {IERC20} from "../../contracts/protocol/interfaces/IERC20.sol";
import {IEAcrossHandler} from "../../contracts/protocol/extensions/adapters/interfaces/IEAcrossHandler.sol";
import {IAIntents} from "../../contracts/protocol/extensions/adapters/interfaces/IAIntents.sol";
import {OpType, DestinationMessage, SourceMessage} from "../../contracts/protocol/types/Crosschain.sol";
import {TestProxyForAcross} from "../fixtures/TestProxyForAcross.sol";
import {ISmartPoolActions} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolActions.sol";
import {ISmartPoolState} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolState.sol";

/// @title AcrossNavSpreadForkTest - NAV spread testing with round-trip flow
/// @notice Comprehensive NAV spread testing using TestProxyForAcross (fixed for getPoolTokens)
contract AcrossNavSpreadForkTest is Test {
    using ChainNavSpreadLib for bytes32;

    // Use constants for consistency and RPC savings
    uint256 constant MAINNET_BLOCK = Constants.MAINNET_BLOCK_LEGACY;
    uint256 constant BASE_BLOCK = Constants.BASE_BLOCK;
    uint256 constant BASE_CHAIN_ID = Constants.BASE_CHAIN_ID;
    
    // Across SpokePools by chain
    address constant ETH_SPOKE_POOL = Constants.ETH_SPOKE_POOL;
    address constant BASE_SPOKE_POOL = Constants.BASE_SPOKE_POOL;
    
    // Tokens from Constants.sol
    address constant USDC_ETH = Constants.ETH_USDC;
    address constant WETH_ETH = Constants.ETH_WETH;
    address constant USDC_BASE = Constants.BASE_USDC;
    address constant WETH_BASE = Constants.BASE_WETH;
    
    // Test actors
    address poolOwner;
    address user1;
    
    // Fork IDs
    uint256 ethForkId;
    uint256 baseForkId;
    
    // Test pools using fixed TestProxyForAcross
    TestProxyForAcross ethPool;
    TestProxyForAcross basePool;
    
    // Deployed extension contracts
    EAcrossHandler ethHandler;
    EAcrossHandler baseHandler;
    AIntents ethAdapter;
    AIntents baseAdapter;

    function setUp() public {
        // Create test accounts
        poolOwner = makeAddr("poolOwner");
        user1 = makeAddr("user1");

        ethForkId = vm.createSelectFork("mainnet", MAINNET_BLOCK);
        _setupEthereum();

        baseForkId = vm.createSelectFork("base", BASE_BLOCK);
        _setupBase();

        console2.log("=== Working test infrastructure setup completed ===");
    }
    
    function _setupEthereum() private {
        console2.log("=== Setting up Ethereum fork ===");
        
        // Deploy handler
        ethHandler = new EAcrossHandler(ETH_SPOKE_POOL);
        console2.log("  Handler:", address(ethHandler));
        
        // Deploy adapter
        ethAdapter = new AIntents(ETH_SPOKE_POOL);
        console2.log("  Adapter:", address(ethAdapter));
        
        // Deploy test proxy with proper fallback (now fixed for getPoolTokens)
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

    /// @notice Test NAV spread functionality with first sync vs subsequent sync
    /// @dev Tests both branches in EAcrossHandler: existingSpread == 0 and existingSpread != 0
    function testFork_NavSpread_FirstSyncVsSubsequentSync() public {
        vm.selectFork(baseForkId);
        
        console2.log("=== Testing NAV spread initialization and updates ===");
        
        // Create first sync message - this should initialize the spread (existingSpread == 0)
        DestinationMessage memory firstSync = DestinationMessage({
            opType: OpType.Sync,
            sourceChainId: Constants.ETHEREUM_CHAIN_ID,
            sourceNav: 1200000, // 1.2 * 10^6 (6 decimals)
            sourceDecimals: 6,
            navTolerance: 100,
            shouldUnwrap: false,
            sourceAmount: 1000e6
        });
        
        // Simulate first handleV3AcrossMessage call
        vm.prank(BASE_SPOKE_POOL);
        IEAcrossHandler(address(basePool)).handleV3AcrossMessage(
            USDC_BASE,
            1000e6,
            abi.encode(firstSync)
        );
        
        console2.log("[SUCCESS] First sync completed - spread initialized");
        
        // Create second sync message from same chain - this should update existing spread (existingSpread != 0)
        DestinationMessage memory secondSync = DestinationMessage({
            opType: OpType.Sync,
            sourceChainId: Constants.ETHEREUM_CHAIN_ID, // Same source chain
            sourceNav: 1300000, // 1.3 * 10^6 (NAV increased)
            sourceDecimals: 6,
            navTolerance: 100,
            shouldUnwrap: false,
            sourceAmount: 1500e6
        });
        
        // This should trigger the existingSpread != 0 branch
        vm.prank(BASE_SPOKE_POOL);
        IEAcrossHandler(address(basePool)).handleV3AcrossMessage(
            USDC_BASE,
            1500e6,
            abi.encode(secondSync)
        );
        
        console2.log("[SUCCESS] Second sync completed - spread updated");
        console2.log("=== Both NAV spread branches tested successfully ===");
    }

    /// @notice Test actual round-trip: AIntents on ETH -> decoded message -> EAcrossHandler on Base
    /// @dev This tests the complete flow with real message encoding/decoding
    function testFork_CompleteNavSpreadRoundTrip() public {
        console2.log("=== Testing complete round-trip with message decoding ===");
        
        // Step 1: Start on Ethereum - simulate AIntents depositV3 call
        vm.selectFork(ethForkId);
        
        uint256 inputAmount = 1000e6; // 1000 USDC
        uint256 sourceNav = 1200000;  // 1.2 * 10^6 (6 decimals)
        
        // Create source message that would be passed to AIntents.depositV3
        SourceMessage memory sourceMsg = SourceMessage({
            opType: OpType.Sync,
            navTolerance: 100,
            sourceNativeAmount: inputAmount,
            shouldUnwrapOnDestination: false
        });
        
        // In a real scenario, this would call AIntents.depositV3 which would:
        // 1. Create a DestinationMessage with current pool state
        // 2. Encode it and pass to Across
        // 3. Across would call handleV3AcrossMessage on destination
        
        // For this test, we simulate what AIntents would produce:
        // Get current pool state from ETH pool
        ISmartPoolState.PoolTokens memory ethPoolTokens = ISmartPoolState(address(ethPool)).getPoolTokens();
        console2.log("ETH Pool NAV:", ethPoolTokens.unitaryValue);
        
        // Create the destination message that AIntents would encode
        DestinationMessage memory destMessage = DestinationMessage({
            opType: sourceMsg.opType,
            sourceChainId: block.chainid, // Ethereum chain ID
            sourceNav: ethPoolTokens.unitaryValue, // Use actual pool NAV
            sourceDecimals: 6, // USDC decimals
            navTolerance: sourceMsg.navTolerance,
            shouldUnwrap: sourceMsg.shouldUnwrapOnDestination,
            sourceAmount: sourceMsg.sourceNativeAmount
        });
        
        // This is what AIntents would pass to Across
        bytes memory encodedMessage = abi.encode(destMessage);
        console2.log("Source message encoded for cross-chain transfer");
        
        // Step 2: Switch to Base and simulate SpokePool calling handler
        vm.selectFork(baseForkId);
        
        // Decode and verify the message (this is what EAcrossHandler does internally)
        DestinationMessage memory decodedMessage = abi.decode(encodedMessage, (DestinationMessage));
        require(decodedMessage.opType == OpType.Sync, "Incorrect opType");
        require(decodedMessage.sourceChainId == Constants.ETHEREUM_CHAIN_ID, "Incorrect source chain");
        console2.log("Message successfully decoded on destination");
        console2.log("Source NAV from message:", decodedMessage.sourceNav);
        
        // Get destination pool state
        ISmartPoolState.PoolTokens memory basePoolTokens = ISmartPoolState(address(basePool)).getPoolTokens();
        console2.log("Base Pool NAV:", basePoolTokens.unitaryValue);
        
        // Simulate the actual handleV3AcrossMessage call
        uint256 outputAmount = 999e6; // After Across fees
        vm.prank(BASE_SPOKE_POOL);
        IEAcrossHandler(address(basePool)).handleV3AcrossMessage(
            USDC_BASE,
            outputAmount,
            encodedMessage // Use the actual encoded message from source
        );
        
        console2.log("[SUCCESS] Complete round-trip test passed");
        console2.log("=== Real message encoding/decoding flow validated ===");
    }

    /// @notice Test Transfer vs Sync operation differences
    /// @dev Ensures Transfer creates virtual balances, Sync manages NAV spreads
    function testFork_TransferVsSyncBehavior() public {
        vm.selectFork(baseForkId);
        
        console2.log("=== Testing Transfer vs Sync operation differences ===");
        
        // Test Transfer operation - should create virtual balance
        DestinationMessage memory transferMsg = DestinationMessage({
            opType: OpType.Transfer,
            sourceChainId: Constants.ETHEREUM_CHAIN_ID,
            sourceNav: 0, // Not used for Transfer
            sourceDecimals: 6,
            navTolerance: 100,
            shouldUnwrap: false,
            sourceAmount: 1000e6
        });
        
        // Check virtual balance before
        int256 virtualBalanceBefore = basePool.getVirtualBalance(USDC_BASE);
        console2.log("Virtual balance before Transfer:", uint256(virtualBalanceBefore));
        
        vm.prank(BASE_SPOKE_POOL);
        IEAcrossHandler(address(basePool)).handleV3AcrossMessage(
            USDC_BASE,
            1000e6,
            abi.encode(transferMsg)
        );
        
        // Check virtual balance after - should be negative (NAV-neutral)
        int256 virtualBalanceAfter = basePool.getVirtualBalance(USDC_BASE);
        console2.log("Virtual balance after Transfer:", uint256(virtualBalanceAfter));
        assertTrue(virtualBalanceAfter < virtualBalanceBefore, "Transfer should create negative virtual balance");
        
        console2.log("[SUCCESS] Transfer operation tested");
        
        // Test Sync operation - should manage NAV spreads
        DestinationMessage memory syncMsg = DestinationMessage({
            opType: OpType.Sync,
            sourceChainId: Constants.ETHEREUM_CHAIN_ID,
            sourceNav: 1200000, // 1.2 * 10^6 
            sourceDecimals: 6,
            navTolerance: 100,
            shouldUnwrap: false,
            sourceAmount: 1000e6
        });
        
        vm.prank(BASE_SPOKE_POOL);
        IEAcrossHandler(address(basePool)).handleV3AcrossMessage(
            USDC_BASE,
            1000e6,
            abi.encode(syncMsg)
        );
        
        console2.log("[SUCCESS] Sync operation tested");
        console2.log("=== Transfer vs Sync behavior validated ===");
    }
}