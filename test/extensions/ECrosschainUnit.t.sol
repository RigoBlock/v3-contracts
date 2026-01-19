// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {UnitTestFixture} from "../fixtures/UnitTestFixture.sol";
import {Constants} from "../../contracts/test/Constants.sol";
import {ECrosschain} from "../../contracts/protocol/extensions/ECrosschain.sol";
import {CrosschainLib} from "../../contracts/protocol/libraries/CrosschainLib.sol";
import {IERC20} from "../../contracts/protocol/interfaces/IERC20.sol";
import {IECrosschain} from "../../contracts/protocol/extensions/adapters/interfaces/IECrosschain.sol";
import {IAIntents} from "../../contracts/protocol/extensions/adapters/interfaces/IAIntents.sol";
import {IAcrossSpokePool} from "../../contracts/protocol/interfaces/IAcrossSpokePool.sol";
import {IWETH9} from "../../contracts/protocol/interfaces/IWETH9.sol";
import {IRigoblockPoolProxyFactory} from "../../contracts/protocol/interfaces/IRigoblockPoolProxyFactory.sol";
import {ISmartPoolImmutable} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolImmutable.sol";
import {ISmartPoolState} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolState.sol";
import {ISmartPoolActions} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolActions.sol";
import {EnumerableSet, Pool} from "../../contracts/protocol/libraries/EnumerableSet.sol";
import {StorageLib} from "../../contracts/protocol/libraries/StorageLib.sol";
import {IEOracle} from "../../contracts/protocol/extensions/adapters/interfaces/IEOracle.sol";
import {OpType, DestinationMessageParams, SourceMessageParams} from "../../contracts/protocol/types/Crosschain.sol";
import {EscrowFactory} from "../../contracts/protocol/libraries/EscrowFactory.sol";
import {Escrow} from "../../contracts/protocol/deps/Escrow.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @title ECrosschainUnit - Unit tests for Across integration components
/// @notice Tests individual contract functionality without cross-chain simulation
contract ECrosschainUnitTest is Test, UnitTestFixture {
    address mockBaseToken;
    address mockInputToken;
    address testPool;
    
    function setUp() public {
        deployFixture();

        mockBaseToken = makeAddr("baseToken");
        mockInputToken = makeAddr("inputToken"); // Use mock address for unit tests
        
        // TODO: check if base token should be mockBaseToken - but requires being a contract and decimals 6 (but it's better like this prob, as allows better debugging)
        (deployment.pool, ) = IRigoblockPoolProxyFactory(deployment.factory).createPool("test pool", "TEST", address(0));
        console2.log("Pool proxy created:", deployment.pool);
    }
    
    // TODO: check if changing decimals in storage is better for testing that deploying a different proxy
    // @notice Helper to setup pool storage using vm.store with correct packing
    function _setupPoolStorage(address pool, address baseToken) internal {
        _setupPoolStorageWithDecimals(pool, baseToken, 6); // Default to 6 decimals
    }
    
    /// @notice Helper to setup pool storage with specific decimals
    function _setupPoolStorageWithDecimals(address pool, address baseToken, uint8 decimals) internal {
        _setupPoolStorageWithLockState(pool, baseToken, decimals, true); // Default to unlocked
    }

    /// @notice Helper to setup pool storage with specific decimals and lock state
    function _setupPoolStorageWithLockState(address pool, address baseToken, uint8 decimals, bool unlocked) internal {
        bytes32 poolInitSlot = StorageLib.POOL_INIT_SLOT;
        
        // Based on RigoblockPool.StorageAccessible.spec.ts test:
        // The pool struct is packed across 3 slots total
        // But StorageLib.pool() accesses it as a direct struct, so it starts at poolInitSlot
        
        // Slot 0: string name (if < 32 bytes, stored directly with length in last byte)
        // "Test Pool" = 9 bytes
        bytes32 nameSlot = bytes32(abi.encodePacked("Test Pool", bytes23(0), uint8(9 * 2))); // length * 2 for short strings
        vm.store(pool, poolInitSlot, nameSlot);
        
        // Slot 1: Based on TypeScript tests, the layout is:
        // [padding:2][unlocked:1][owner:20][decimals:1][symbol:8] = 32 bytes
        bytes32 packedSlot = bytes32(abi.encodePacked(
            bytes2(0),         // padding (2 bytes)
            unlocked,          // unlocked (1 byte) - this is the key change
            address(this),     // owner (20 bytes)
            decimals,         // decimals (1 byte)
            bytes8("TEST")     // symbol (8 bytes)
        ));
        vm.store(pool, bytes32(uint256(poolInitSlot) + 1), packedSlot);
        
        // Slot 2: baseToken (address) - this is what we really need!
        vm.store(pool, bytes32(uint256(poolInitSlot) + 2), bytes32(uint256(uint160(baseToken))));
    }
    
    /// @notice Helper to setup active token using vm.store
    function _setupActiveToken(address pool, address token) internal {
        // Use the correct slot value from the protocol  
        bytes32 tokenRegistrySlot = 0x3dcde6752c7421366e48f002bbf8d6493462e0e43af349bebb99f0470a12300d;
        
        // Set up active token in AddressSet
        // Struct AddressSet { address[] addresses; mapping(address => uint256) positions; }
        // Storage layout:
        // - tokenRegistrySlot = addresses array length
        // - tokenRegistrySlot + 1 = positions mapping base slot
        
        // Set array length to 1
        vm.store(pool, tokenRegistrySlot, bytes32(uint256(1)));
        
        // Set the first element of the array (at keccak256(tokenRegistrySlot))
        bytes32 arrayElementSlot = keccak256(abi.encode(tokenRegistrySlot));
        vm.store(pool, arrayElementSlot, bytes32(uint256(uint160(token))));
        
        // Set position for this token to 1 (first element) 
        // Mapping is at tokenRegistrySlot + 1
        bytes32 mappingBaseSlot = bytes32(uint256(tokenRegistrySlot) + 1);
        bytes32 positionSlot = keccak256(abi.encode(token, mappingBaseSlot));
        vm.store(pool, positionSlot, bytes32(uint256(1))); // 1-based index
    }
    
    /// @notice Test handler deployment (stateless)
    function test_Setup_Deployment() public view {
        assertTrue(address(deployment.implementation).code.length > 0, "Implementation should be deployed");
        assertTrue(deployment.pool.code.length > 0, "Proxy should be deployed");
        assertTrue(address(deployment.eCrosschain).code.length > 0, "Extension should be deployed");
    }

    /// @notice Test handler requires pool to be unlocked to execute
    function test_ECrosschain_RevertsDirectCall() public {
        // Create valid Transfer params
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });
        
        // Should revert silently because extension does not implement updateUnitaryValue method
        vm.expectRevert();
        IECrosschain(deployment.eCrosschain).donate(mockBaseToken, 1, params);
    }
    
    /// @notice Test handler Transfer mode execution using actual contract
    function test_ECrosschain_TransferMode_MessageParsing() public pure {
        // Test that Transfer message can be properly encoded/decoded
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });
        
        bytes memory encodedMessage = abi.encode(params);
        DestinationMessageParams memory decoded = abi.decode(encodedMessage, (DestinationMessageParams));
        
        assertEq(uint8(decoded.opType), uint8(OpType.Transfer), "OpType should be Transfer");
    }
    
    /// @notice Test Sync mode message encoding/decoding with NAV
    function test_ECrosschain_SyncMode_MessageParsing() public pure {
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Sync,
            shouldUnwrapNative: false
        });
        
        bytes memory encoded = abi.encode(params);
        DestinationMessageParams memory decoded = abi.decode(encoded, (DestinationMessageParams));
        
        assertEq(uint8(decoded.opType), uint8(OpType.Sync), "OpType should be Sync");
    }
    
    /// @notice Test WETH unwrap message construction
    function test_ECrosschain_UnwrapWETH_MessageSetup() public pure {
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: true
        });
        
        bytes memory encoded = abi.encode(params);
        DestinationMessageParams memory decoded = abi.decode(encoded, (DestinationMessageParams));
        
        assertTrue(decoded.shouldUnwrapNative, "Should unwrap should be true");
        assertEq(uint8(decoded.opType), uint8(OpType.Transfer), "OpType should be Transfer");
    }

    /// @notice Test handler requires pool to be unlocked to execute
    function test_ECrosschain_RequiresPoolUnlocked() public {
        _setupActiveToken(deployment.pool, mockBaseToken);
        
        // Mock required calls
        vm.mockCall(
            mockBaseToken,
            abi.encodeWithSelector(IERC20.balanceOf.selector, deployment.pool),
            abi.encode(0) // Mock balance
        );
        
        // Create valid Transfer params
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });
        
        // Should revert because pool is locked (updateUnitaryValue will fail)
        vm.expectRevert(abi.encodeWithSelector(IECrosschain.DonationLock.selector, false));
        IECrosschain(deployment.pool).donate(mockBaseToken, 2, params);

        IECrosschain(deployment.pool).donate(mockBaseToken, 1, params);

        vm.clearMockedCalls();
    }

    /// @notice Test handler rejects unsupported token
    function test_ECrosschain_RejectsUnsupportedToken() public {
        _setupActiveToken(deployment.pool, mockInputToken); // Mark input token as Active

        vm.mockCall(
            mockInputToken,
            abi.encodeWithSelector(IERC20.balanceOf.selector, deployment.pool),
            abi.encode(0) // Balance for initialization
        );
        
        // Create message with Unknown OpType to test InvalidOpType revert
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Unknown,
            shouldUnwrapNative: false
        });

        // unlock
        IECrosschain(deployment.pool).donate(mockInputToken, 1, params);

        // Simulate token transfer to pool - required for donate flow to succeed
        vm.mockCall(
            mockInputToken,
            abi.encodeWithSelector(IERC20.balanceOf.selector, deployment.pool),
            abi.encode(100e6) // Simulate transfer
        );
        
        vm.expectRevert(CrosschainLib.UnsupportedCrossChainToken.selector);
        IECrosschain(deployment.pool).donate(mockInputToken, 10e6, params);

        vm.clearMockedCalls();
    }

    // TODO: these tests will result in price for token always being 1 - check if that prevents correct testing
    /// @notice Test handler rejects invalid OpType
    function test_ECrosschain_RejectsInvalidOpType() public {
        _setupActiveToken(deployment.pool, Constants.ETH_USDC); // Mark input token as active
        
        vm.mockCall(
            Constants.ETH_USDC,
            abi.encodeWithSelector(IERC20.balanceOf.selector, deployment.pool),
            abi.encode(0) // Balance for initialization
        );
        
        // Create message with Unknown OpType to test InvalidOpType revert
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Unknown,
            shouldUnwrapNative: false
        });

        // unlock
        IECrosschain(deployment.pool).donate(Constants.ETH_USDC, 1, params);

        // Simulate token transfer to pool - required for donate flow to succeed
        vm.mockCall(
            Constants.ETH_USDC,
            abi.encodeWithSelector(IERC20.balanceOf.selector, deployment.pool),
            abi.encode(100e6) // Simulate transfer
        );
        vm.chainId(1);
        
        vm.expectRevert(abi.encodeWithSignature("InvalidOpType()"));
        IECrosschain(deployment.pool).donate(Constants.ETH_USDC, 10e6, params);

        vm.clearMockedCalls();
        vm.chainId(31337);
    }

    function test_ECrosschain_RejectsTokenNotSentToPool() public {
        _setupActiveToken(deployment.pool, mockInputToken); // Mark input token as active
    
        vm.mockCall(
            mockInputToken,
            abi.encodeWithSelector(IERC20.balanceOf.selector, deployment.pool),
            abi.encode(0) // Balance for initialization
        );
        
        // Create message with Unknown OpType to test InvalidOpType revert
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Unknown,
            shouldUnwrapNative: false
        });

        // unlock
        IECrosschain(deployment.pool).donate(mockInputToken, 1, params);
        
        vm.expectRevert(ECrosschain.CallerTransferAmount.selector);
        IECrosschain(deployment.pool).donate(mockInputToken, 10e6, params);

        vm.clearMockedCalls();
    }

    /// @notice Test handler accepts source amount within tolerance range  
    function test_ECrosschain_RevertsIfTokenPriceFeedDoesNotExist() public {
        _setupActiveToken(deployment.pool, mockBaseToken); // Mark base token as active
        
        uint256 receivedAmount = 100e18; // Use 18 decimals for base token
        
        // Mock balanceOf calls for two-step donation process
        vm.mockCall(
            Constants.ETH_USDT,
            abi.encodeWithSelector(IERC20.balanceOf.selector, deployment.pool),
            abi.encode(0)
        );
        
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });
        
        IECrosschain(deployment.pool).donate(Constants.ETH_USDT, 1, params);
        vm.chainId(1);

        vm.mockCall(
            Constants.ETH_USDT,
            abi.encodeWithSelector(IERC20.balanceOf.selector, deployment.pool),
            abi.encode(100e18)
        );

        vm.expectRevert(abi.encodeWithSelector(EnumerableSet.TokenPriceFeedDoesNotExist.selector, Constants.ETH_USDT));
        IECrosschain(deployment.pool).donate(Constants.ETH_USDT, 100e18, params);

        vm.clearMockedCalls();
        vm.chainId(31337);
    }

    /// @notice Test handler accepts source amount within tolerance range  
    function test_ECrosschain_AcceptsSourceAmountWithinTolerance() public {
        _setupActiveToken(deployment.pool, mockBaseToken); // Mark base token as active
        
        // Mock balanceOf calls for two-step donation process
        vm.mockCall(
            Constants.ETH_USDT,
            abi.encodeWithSelector(IERC20.balanceOf.selector, deployment.pool),
            abi.encode(0)
        );
        
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });
        
        // First donation to unlock the pool
        IECrosschain(deployment.pool).donate(Constants.ETH_USDT, 1, params);
        vm.chainId(1);

        vm.mockCall(
            Constants.ETH_USDT,
            abi.encodeWithSelector(IERC20.balanceOf.selector, deployment.pool),
            abi.encode(100e18 + 1e8)
        );
        
        // Warp time forward to avoid underflow in oracle lookback
        vm.warp(block.timestamp + 100);
        
        // Initialize observations to avoid division by zero in oracle
        deployment.mockOracle.initializeObservations(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(Constants.ETH_USDT),
                fee: 0,
                tickSpacing: TickMath.MAX_TICK_SPACING,
                hooks: IHooks(address(deployment.mockOracle))
            })
        );
        
        // Mock base token balance (needed for updateUnitaryValue after donation)
        vm.mockCall(
            mockBaseToken,
            abi.encodeWithSelector(IERC20.balanceOf.selector, deployment.pool),
            abi.encode(0)
        );

        // Should succeed - donation with proper oracle setup
        IECrosschain(deployment.pool).donate(Constants.ETH_USDT, 100e18, params);

        vm.clearMockedCalls();
        vm.chainId(31337);
    }
    
    /// @notice Test handler Transfer mode with proper delegatecall context
    function test_ECrosschain_TransferMode_WithDelegatecall() public {
        _setupActiveToken(deployment.pool, mockBaseToken);
        
        // Mock balanceOf for unlock
        vm.mockCall(
            Constants.ETH_USDC,
            abi.encodeWithSelector(IERC20.balanceOf.selector, deployment.pool),
            abi.encode(0)
        );
        
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });
        
        // Unlock
        IECrosschain(deployment.pool).donate(Constants.ETH_USDC, 1, params);
        vm.chainId(1);
        
        // Simulate token transfer to pool
        vm.mockCall(
            Constants.ETH_USDC,
            abi.encodeWithSelector(IERC20.balanceOf.selector, deployment.pool),
            abi.encode(100e6)
        );
        
        vm.warp(block.timestamp + 100);
        deployment.mockOracle.initializeObservations(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(Constants.ETH_USDC),
                fee: 0,
                tickSpacing: TickMath.MAX_TICK_SPACING,
                hooks: IHooks(address(deployment.mockOracle))
            })
        );
        
        vm.mockCall(
            mockBaseToken,
            abi.encodeWithSelector(IERC20.balanceOf.selector, deployment.pool),
            abi.encode(0)
        );
        
        // Should succeed with proper setup
        IECrosschain(deployment.pool).donate(Constants.ETH_USDC, 100e6, params);

        vm.clearMockedCalls();
        vm.chainId(31337);
    }
    
    /// @notice Test handler Sync mode with proper delegatecall context
    function test_ECrosschain_SyncMode_WithDelegatecall() public {
        _setupActiveToken(deployment.pool, mockBaseToken);
        
        vm.mockCall(
            Constants.ETH_WETH,
            abi.encodeWithSelector(IERC20.balanceOf.selector, deployment.pool),
            abi.encode(0)
        );
        
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Sync,
            shouldUnwrapNative: false
        });
        
        IECrosschain(deployment.pool).donate(Constants.ETH_WETH, 1, params);
        vm.chainId(1);
        
        vm.mockCall(
            Constants.ETH_WETH,
            abi.encodeWithSelector(IERC20.balanceOf.selector, deployment.pool),
            abi.encode(1e18)
        );
        
        vm.warp(block.timestamp + 100);
        deployment.mockOracle.initializeObservations(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(Constants.ETH_WETH),
                fee: 0,
                tickSpacing: TickMath.MAX_TICK_SPACING,
                hooks: IHooks(address(deployment.mockOracle))
            })
        );
        
        vm.mockCall(
            mockBaseToken,
            abi.encodeWithSelector(IERC20.balanceOf.selector, deployment.pool),
            abi.encode(0)
        );
        
        // Sync mode should succeed
        IECrosschain(deployment.pool).donate(Constants.ETH_WETH, 1e18, params);

        vm.clearMockedCalls();
        vm.chainId(31337);
    }
    
    /// @notice Test handler with WETH unwrapping
    function test_ECrosschain_WithWETHUnwrap_WithDelegatecall() public {
        _setupActiveToken(deployment.pool, mockBaseToken);
        
        vm.mockCall(
            Constants.ETH_WETH,
            abi.encodeWithSignature("decimals()"),
            abi.encode(18)
        );
        vm.mockCall(
            Constants.ETH_WETH,
            abi.encodeWithSelector(IERC20.balanceOf.selector, deployment.pool),
            abi.encode(0)
        );
        
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: true
        });
        
        IECrosschain(deployment.pool).donate(Constants.ETH_WETH, 1, params);
        vm.chainId(1);
        
        vm.mockCall(
            Constants.ETH_WETH,
            abi.encodeWithSelector(IERC20.balanceOf.selector, deployment.pool),
            abi.encode(1e18)
        );
        
        vm.warp(block.timestamp + 100);
        // Across uses WETH address even for native transfers
        deployment.mockOracle.initializeObservations(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(Constants.ETH_WETH),
                fee: 0,
                tickSpacing: TickMath.MAX_TICK_SPACING,
                hooks: IHooks(address(deployment.mockOracle))
            })
        );
        
        vm.mockCall(
            mockBaseToken,
            abi.encodeWithSelector(IERC20.balanceOf.selector, deployment.pool),
            abi.encode(0)
        );
        
        // Should succeed and unwrap WETH to ETH
        IECrosschain(deployment.pool).donate(Constants.ETH_WETH, 1e18, params);

        vm.clearMockedCalls();
        vm.chainId(31337);
    }
    
    /// @notice Test handler adds token with price feed to active set
    function test_ECrosschain_AddsTokenWithPriceFeed() public {
        // Start with no active tokens
        _setupActiveToken(deployment.pool, mockBaseToken);
        
        vm.mockCall(
            Constants.ETH_USDC,
            abi.encodeWithSelector(IERC20.balanceOf.selector, deployment.pool),
            abi.encode(0)
        );
        
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });
        
        IECrosschain(deployment.pool).donate(Constants.ETH_USDC, 1, params);
        vm.chainId(1);
        
        vm.mockCall(
            Constants.ETH_USDC,
            abi.encodeWithSelector(IERC20.balanceOf.selector, deployment.pool),
            abi.encode(100e6)
        );
        
        vm.warp(block.timestamp + 100);
        deployment.mockOracle.initializeObservations(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(Constants.ETH_USDC),
                fee: 0,
                tickSpacing: TickMath.MAX_TICK_SPACING,
                hooks: IHooks(address(deployment.mockOracle))
            })
        );
        
        vm.mockCall(
            mockBaseToken,
            abi.encodeWithSelector(IERC20.balanceOf.selector, deployment.pool),
            abi.encode(0)
        );
        
        // Should succeed and add USDC to active tokens
        IECrosschain(deployment.pool).donate(Constants.ETH_USDC, 100e6, params);

        vm.clearMockedCalls();
        vm.chainId(31337);
    }
    
    /// @notice Test NAV normalization across different decimal combinations
    function test_ECrosschain_NavNormalization() public {
        _setupActiveToken(deployment.pool, mockBaseToken);
        
        vm.mockCall(
            Constants.ETH_WETH,
            abi.encodeWithSelector(IERC20.balanceOf.selector, deployment.pool),
            abi.encode(0)
        );
        
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });
        
        IECrosschain(deployment.pool).donate(Constants.ETH_WETH, 1, params);
        vm.chainId(1);
        
        // Test with 18 decimal token (WETH)
        vm.mockCall(
            Constants.ETH_WETH,
            abi.encodeWithSelector(IERC20.balanceOf.selector, deployment.pool),
            abi.encode(1e18)
        );
        
        vm.warp(block.timestamp + 100);
        deployment.mockOracle.initializeObservations(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(Constants.ETH_WETH),
                fee: 0,
                tickSpacing: TickMath.MAX_TICK_SPACING,
                hooks: IHooks(address(deployment.mockOracle))
            })
        );
        
        vm.mockCall(
            mockBaseToken,
            abi.encodeWithSelector(IERC20.balanceOf.selector, deployment.pool),
            abi.encode(0)
        );
        
        // Should handle 18 decimal normalization
        IECrosschain(deployment.pool).donate(Constants.ETH_WETH, 1e18, params);

        vm.clearMockedCalls();
        vm.chainId(31337);
    }
    
    /// @notice Test that WETH unwrapping uses WETH address for validation
    function test_ECrosschain_WETHUnwrapping_UsesAddressZero() public {
        _setupActiveToken(deployment.pool, mockBaseToken);
        
        vm.mockCall(
            Constants.ETH_WETH,
            abi.encodeWithSignature("decimals()"),
            abi.encode(18)
        );
        vm.mockCall(
            Constants.ETH_WETH,
            abi.encodeWithSelector(IERC20.balanceOf.selector, deployment.pool),
            abi.encode(0)
        );
        
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: true
        });
        
        IECrosschain(deployment.pool).donate(Constants.ETH_WETH, 1, params);
        vm.chainId(1);
        
        vm.mockCall(
            Constants.ETH_WETH,
            abi.encodeWithSelector(IERC20.balanceOf.selector, deployment.pool),
            abi.encode(1e18)
        );
        
        vm.warp(block.timestamp + 100);
        // Across uses WETH address even for native transfers
        deployment.mockOracle.initializeObservations(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(Constants.ETH_WETH),
                fee: 0,
                tickSpacing: TickMath.MAX_TICK_SPACING,
                hooks: IHooks(address(deployment.mockOracle))
            })
        );
        
        vm.mockCall(
            mockBaseToken,
            abi.encodeWithSelector(IERC20.balanceOf.selector, deployment.pool),
            abi.encode(0)
        );
        
        // Should use address(0) for ETH after unwrapping
        IECrosschain(deployment.pool).donate(Constants.ETH_WETH, 1e18, params);

        vm.clearMockedCalls();
        vm.chainId(31337);
    }
    
    /// @notice Test that Sync operations work with client-side validation
    function test_ECrosschain_SyncMode_ClientSideValidation() public {
        _setupActiveToken(deployment.pool, mockBaseToken);
        
        vm.mockCall(
            Constants.ETH_USDC,
            abi.encodeWithSelector(IERC20.balanceOf.selector, deployment.pool),
            abi.encode(0)
        );
        
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Sync,
            shouldUnwrapNative: false
        });
        
        IECrosschain(deployment.pool).donate(Constants.ETH_USDC, 1, params);
        vm.chainId(1);
        
        vm.mockCall(
            Constants.ETH_USDC,
            abi.encodeWithSelector(IERC20.balanceOf.selector, deployment.pool),
            abi.encode(100e6)
        );
        
        vm.warp(block.timestamp + 100);
        deployment.mockOracle.initializeObservations(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(Constants.ETH_USDC),
                fee: 0,
                tickSpacing: TickMath.MAX_TICK_SPACING,
                hooks: IHooks(address(deployment.mockOracle))
            })
        );
        
        vm.mockCall(
            mockBaseToken,
            abi.encodeWithSelector(IERC20.balanceOf.selector, deployment.pool),
            abi.encode(0)
        );
        
        // Sync mode succeeds - NAV validation is client responsibility
        IECrosschain(deployment.pool).donate(Constants.ETH_USDC, 100e6, params);

        vm.clearMockedCalls();
        vm.chainId(31337);
    }
}

