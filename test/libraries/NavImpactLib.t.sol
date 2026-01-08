// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {NavImpactLib} from "../../contracts/protocol/libraries/NavImpactLib.sol";
import {ISmartPoolState} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolState.sol";
import {IEOracle} from "../../contracts/protocol/extensions/adapters/interfaces/IEOracle.sol";
import {StorageLib} from "../../contracts/protocol/libraries/StorageLib.sol";
import {SlotDerivation} from "../../contracts/protocol/libraries/SlotDerivation.sol";

/// @title NavImpactLibTest - Tests for NAV impact validation library
/// @notice Comprehensive testing of percentage-based NAV impact tolerance validation
contract NavImpactLibTest is Test {
    using SlotDerivation for bytes32;

    // Mock pool state for testing
    MockNavImpactPool pool;
    
    // Test tokens
    address constant USDC = 0xa0b86a33E6441319A87aA51FBbcFa4De9A7A24c8;
    address constant WETH = 0xc02Aaa39b223fe8d0A6263C51c404Ee8E5a532E1;
    
    function setUp() public {
        pool = new MockNavImpactPool();
    }

    /// @notice Test successful validation within tolerance
    function test_NavImpactValidation_WithinTolerance() public {
        // Setup: 1M USDC pool (unitaryValue=1 USDC per token, totalSupply=1M tokens)
        pool.setPoolState(1e6, 1000000e6, 6, USDC);
        
        // Transfer 50k USDC (5% impact) with 10% tolerance should pass
        uint256 transferAmount = 50000e6; // 50k USDC = 5% of 1M
        uint256 tolerance = 1000; // 10% in basis points
        
        // Calculate expected values:
        // totalAssetsValue = 1e6 * 1000000e6 / (10^6) = 1000000e6
        // impactBps = (50000e6 * 10000) / 1000000e6 = 500 bps = 5%
        // 500 <= 1000, so should pass
        
        // This should not revert 
        pool.testValidateNavImpactTolerance(USDC, transferAmount, tolerance);
    }    /// @notice Test validation exceeds tolerance
    function test_NavImpactValidation_ExceedsTolerance() public {
        // Try much smaller numbers to avoid overflow
        // Setup: 1000 USDC pool (unitaryValue=1 USDC per token, totalSupply=1000 tokens)
        pool.setPoolState(1e6, 1000e6, 6, USDC);
        
        // Transfer 300 USDC (30% impact) with 10% tolerance should fail  
        uint256 transferAmount = 300e6; // 300 USDC
        uint256 tolerance = 1000; // 10% in basis points
        
        // Calculation:
        // totalAssetsValue = 1e6 * 1000e6 / 1e6 = 1000e6
        // impactBps = (300e6 * 10000) / 1000e6 = 3000000000000000 / 1000000000 = 3000 = 30%
        
        // Let's see what error we actually get:
        try pool.testValidateNavImpactTolerance(USDC, transferAmount, tolerance) {
            // If no revert, this is wrong
            revert("Expected revert but got none");
        } catch Error(string memory reason) {
            // Standard revert string
            revert(string(abi.encodePacked("Got Error: ", reason)));
        } catch Panic(uint errorCode) {
            // Panic error (like overflow/underflow)
            revert(string(abi.encodePacked("Got Panic: ", vm.toString(errorCode))));
        } catch (bytes memory lowLevelData) {
            // Custom error or other
            if (lowLevelData.length >= 4) {
                bytes4 selector = bytes4(lowLevelData);
                if (selector == NavImpactLib.NavImpactTooHigh.selector) {
                    // This is what we want!
                    return;
                } else {
                    revert(string(abi.encodePacked("Got unexpected custom error: ", vm.toString(selector))));
                }
            } else {
                revert("Got unexpected low-level error");
            }
        }
    }

    /// @notice Test validation with non-base token
    function test_NavImpactValidation_NonBaseToken() public {
        // Setup: 1M USDC pool (unitaryValue=1 USDC per token, totalSupply=1M tokens)
        pool.setPoolState(1e6, 1000000e6, 6, USDC);
        
        // Mock WETH conversion: 1 WETH = 3000 USDC
        pool.setTokenConversion(WETH, 1e18, USDC, 3000e6);
        
        // Transfer 20 WETH (60k USDC equivalent = 6% impact) with 10% tolerance should pass
        uint256 transferAmount = 20e18; // 20 WETH
        uint256 tolerance = 1000; // 10% in basis points
        
        // This should not revert
        pool.testValidateNavImpactTolerance(WETH, transferAmount, tolerance);
    }

    /// @notice Test validation with empty pool (should always pass)
    function test_NavImpactValidation_EmptyPool() public {
        // Setup empty pool: 0 NAV, 0 total supply
        pool.setPoolState(0, 0, 6, USDC);
        
        // Any transfer amount should pass in empty pool
        uint256 transferAmount = 1000000e6; // 1M USDC
        uint256 tolerance = 100; // 1% in basis points (very low tolerance)
        
        // This should not revert (empty pool exception)
        pool.testValidateNavImpactTolerance(USDC, transferAmount, tolerance);
    }

    /// @notice Test exact tolerance boundary
    function test_NavImpactValidation_ExactTolerance() public {
        // Setup: 1M USDC pool (unitaryValue=1 USDC per token, totalSupply=1M tokens)
        pool.setPoolState(1e6, 1000000e6, 6, USDC);
        
        // Transfer exactly 10% of NAV with 10% tolerance should pass
        uint256 transferAmount = 100000e6; // 100k USDC = exactly 10%
        uint256 tolerance = 1000; // 10% in basis points
        
        // This should not revert (exact boundary)
        pool.testValidateNavImpactTolerance(USDC, transferAmount, tolerance);
    }

    /// @notice Test just over tolerance boundary
    function test_NavImpactValidation_JustOverTolerance() public {
        // Setup: 1M USDC pool (unitaryValue=1 USDC per token, totalSupply=1M tokens)
        pool.setPoolState(1e6, 1000000e6, 6, USDC);
        
        // Transfer clearly more than 10% to avoid integer division precision issues
        uint256 transferAmount = 101000e6; // 101,000 USDC = 10.1%  
        uint256 tolerance = 1000; // 10% in basis points
        
        vm.expectRevert(NavImpactLib.NavImpactTooHigh.selector);
        pool.testValidateNavImpactTolerance(USDC, transferAmount, tolerance);
    }

    /// @notice Test with different pool decimals (18 decimals like ETH)
    function test_NavImpactValidation_DifferentDecimals() public {
        // Setup pool with 18 decimals (like ETH pool)
        pool.setPoolState(1000e18, 1000e18, 18, WETH);
        
        // Transfer 50 ETH (5% impact) with 10% tolerance should pass
        uint256 transferAmount = 50e18; // 50 WETH
        uint256 tolerance = 1000; // 10% in basis points
        
        // This should not revert
        pool.testValidateNavImpactTolerance(WETH, transferAmount, tolerance);
    }

    /// @notice Test negative token conversion (should use absolute value)
    function test_NavImpactValidation_NegativeConversion() public {
        // Setup: 1M USDC pool (unitaryValue=1 USDC per token, totalSupply=1M tokens)
        pool.setPoolState(1e6, 1000000e6, 6, USDC);
        
        // Mock negative conversion (edge case)
        pool.setTokenConversion(WETH, 1e18, USDC, -3000e6);
        
        // Transfer 20 WETH (60k USDC equivalent = 6% impact) with 10% tolerance should pass
        uint256 transferAmount = 20e18; // 20 WETH  
        uint256 tolerance = 1000; // 10% in basis points
        
        // This should not revert (uses absolute value)
        pool.testValidateNavImpactTolerance(WETH, transferAmount, tolerance);
    }

    /// @notice Test very small tolerance
    function test_NavImpactValidation_VerySmallTolerance() public {
        // Setup: 1M USDC pool (unitaryValue=1 USDC per token, totalSupply=1M tokens)
        pool.setPoolState(1e6, 1000000e6, 6, USDC);
        
        // Transfer 200 USDC (0.02% impact) with 0.01% tolerance should fail
        uint256 transferAmount = 200e6; // 200 USDC = 0.02% > 0.01%
        uint256 tolerance = 1; // 0.01% in basis points
        
        vm.expectRevert(NavImpactLib.NavImpactTooHigh.selector);
        pool.testValidateNavImpactTolerance(USDC, transferAmount, tolerance);
    }

    /// @notice Test zero tolerance
    function test_NavImpactValidation_ZeroTolerance() public {
        // Setup: 1M USDC pool (unitaryValue=1 USDC per token, totalSupply=1M tokens)
        pool.setPoolState(1e6, 1000000e6, 6, USDC);
        
        // Any transfer with zero tolerance should fail (use larger amount to avoid rounding to 0)
        uint256 transferAmount = 1000e6; // 1000 USDC = 0.1%
        uint256 tolerance = 0; // 0% tolerance
        
        vm.expectRevert(NavImpactLib.NavImpactTooHigh.selector);
        pool.testValidateNavImpactTolerance(USDC, transferAmount, tolerance);
    }

    /// @notice Test zero transfer amount (should always pass)
    function test_NavImpactValidation_ZeroAmount() public {
        // Setup: 1M USDC pool (unitaryValue=1 USDC per token, totalSupply=1M tokens)
        pool.setPoolState(1e6, 1000000e6, 6, USDC);
        
        // Zero transfer should always pass regardless of tolerance
        uint256 transferAmount = 0;
        uint256 tolerance = 0; // Even with zero tolerance
        
        // This should not revert
        pool.testValidateNavImpactTolerance(USDC, transferAmount, tolerance);
    }
}

/// @notice Mock pool contract for testing NavImpactLib
/// @dev Implements required interfaces and allows state manipulation for testing
contract MockNavImpactPool {
    using SlotDerivation for bytes32;
    using NavImpactLib for address;

    // Pool state
    uint256 public unitaryValue;
    uint256 public totalSupply; 
    uint8 public decimals;
    address public baseToken;
    
    // Token conversion mocks
    mapping(bytes32 => int256) public tokenConversions;
    
    function setPoolState(
        uint256 _unitaryValue,
        uint256 _totalSupply,
        uint8 _decimals,
        address _baseToken
    ) external {
        unitaryValue = _unitaryValue;
        totalSupply = _totalSupply;
        decimals = _decimals;
        baseToken = _baseToken;
        
        // Set the exact storage that StorageLib.pool() reads from
        // Based on AcrossUnit.t.sol implementation
        bytes32 poolInitSlot = 0xe48b9bb119adfc3bccddcc581484cc6725fe8d292ebfcec7d67b1f93138d8bd8;
        
        // Use vm.store approach (note: this won't work in mock, but let's try a different approach)
        // Let's implement a simpler approach by directly using the struct pattern
        
        // Create a pool struct and store it in the expected slot
        bytes32 slot0 = bytes32(abi.encodePacked("Test Pool", bytes23(0), uint8(9 * 2)));
        
        // Based on TypeScript tests, the layout for slot 1 is:
        // [padding:2][unlocked:1][owner:20][decimals:1][symbol:8] = 32 bytes
        bytes32 slot1 = bytes32(abi.encodePacked(
            bytes2(0),         // padding (2 bytes)
            true,             // unlocked (1 byte)
            address(this),     // owner (20 bytes)
            _decimals,         // decimals (1 byte)
            bytes8("TEST")     // symbol (8 bytes)
        ));
        
        bytes32 slot2 = bytes32(uint256(uint160(_baseToken)));
        
        assembly {
            sstore(poolInitSlot, slot0)
            sstore(add(poolInitSlot, 1), slot1)  
            sstore(add(poolInitSlot, 2), slot2)
        }
    }
    
    function setTokenConversion(
        address fromToken,
        uint256 fromAmount,
        address toToken,
        int256 toAmount
    ) external {
        bytes32 key = keccak256(abi.encodePacked(fromToken, fromAmount, toToken));
        tokenConversions[key] = toAmount;
    }
    
    /// @notice Test wrapper for NavImpactLib.validateNavImpactTolerance
    function testValidateNavImpactTolerance(
        address token,
        uint256 amount,
        uint256 toleranceBps
    ) external view {
        NavImpactLib.validateNavImpact(token, amount, toleranceBps);
    }
    
    // Mock ISmartPoolState.getPoolTokens()
    function getPoolTokens() external view returns (ISmartPoolState.PoolTokens memory) {
        return ISmartPoolState.PoolTokens({
            unitaryValue: unitaryValue,
            totalSupply: totalSupply
        });
    }
    
    // Mock StorageLib.pool() - use storage slot pattern
    bytes32 constant POOL_SLOT = bytes32(uint256(keccak256("pool.proxy.storage")) - 1);
    
    struct Pool {
        uint8 decimals;
        address baseToken;
    }
    
    function pool() external view returns (Pool memory poolData) {
        // Always return the current storage vars for testing
        poolData.decimals = decimals;
        poolData.baseToken = baseToken;
    }
    
    // Mock IEOracle.convertTokenAmount() 
    function convertTokenAmount(
        address token,
        int256 amount,
        address targetToken
    ) external view returns (int256) {
        // Find a rate for this token pair (use 1 unit as reference)
        uint256 referenceAmount = token == 0xc02Aaa39b223fe8d0A6263C51c404Ee8E5a532E1 ? 1e18 : 1e6; // 1 WETH or 1 USDC
        bytes32 key = keccak256(abi.encodePacked(token, referenceAmount, targetToken));
        int256 referenceConversion = tokenConversions[key];
        
        if (referenceConversion != 0) {
            // Scale the conversion based on the actual amount
            int256 scaledConversion = (amount * referenceConversion) / int256(referenceAmount);
            return scaledConversion;
        }
        
        // Default 1:1 conversion if not mocked
        return amount;
    }
}