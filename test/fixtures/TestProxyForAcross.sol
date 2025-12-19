// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;


import {IEOracle} from "../../contracts/protocol/extensions/adapters/interfaces/IEOracle.sol";
import {ISmartPoolImmutable} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolImmutable.sol";
import {ISmartPoolState} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolState.sol";
import {IAIntents} from "../../contracts/protocol/extensions/adapters/interfaces/IAIntents.sol";
import {IEAcrossHandler} from "../../contracts/protocol/extensions/adapters/interfaces/IEAcrossHandler.sol";
import {SlotDerivation} from "../../contracts/protocol/libraries/SlotDerivation.sol";

/// @title TestProxyForAcross
/// @notice Proper delegatecall proxy with fallback for testing Across extension and adapter
/// @dev Mimics RigoblockPoolProxy fallback pattern but simplified for testing
contract TestProxyForAcross {
    using SlotDerivation for bytes32;
    address public immutable handler;
    address public immutable adapter;
    address public owner;
    address public baseToken;
    uint8 public decimals;
    
    // ERC20 storage for pool token
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    
    // Virtual balances storage slot (matches MixinConstants and VirtualBalanceLib)
    // bytes32(uint256(keccak256("pool.proxy.virtual.balances")) - 1)
    bytes32 constant VIRTUAL_BALANCES_SLOT = 0x52fe1e3ba959a28a9d52ea27285aed82cfb0b6d02d0df76215ab2acc4b84d64f;
    
    constructor(
        address _handler,
        address _adapter,
        address _owner,
        address _baseToken,
        uint8 _decimals
    ) {
        handler = _handler;
        adapter = _adapter;
        owner = _owner;
        baseToken = _baseToken;
        decimals = _decimals;
        totalSupply = 1000000e18; // Initial supply
        balanceOf[_owner] = totalSupply;
    }
    
    /// @notice Fallback to delegate calls to handler or adapter based on selector
    fallback() external payable {
        address target;
        
        // Get selector from calldata
        bytes4 selector;
        assembly {
            selector := calldataload(0)
        }
        
        if (selector == IEAcrossHandler.handleV3AcrossMessage.selector) {
            target = handler;
        } else if (selector == IAIntents.depositV3.selector) {
            target = adapter;
        } else if (selector == ISmartPoolState.getPoolTokens.selector) {
            // Don't delegate this - handle it directly with our implementation below
            // This is a view function that doesn't need delegation
            return;
        } else {
            revert("SELECTOR_NOT_FOUND");
        }
        
        // Delegatecall to target
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), target, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            
            switch result
            case 0 {
                revert(0, returndatasize())
            }
            default {
                return(0, returndatasize())
            }
        }
    }
    
    // TODO: check these method are correct here, as we might use the fallback to redirect to internal methods, because
    // we should mimic the real env as close as possible.
    /// @notice Get virtual balance for a token
    /// @param token The token address
    /// @return The virtual balance (can be negative)
    function getVirtualBalance(address token) external view returns (int256) {
        bytes32 slot = VIRTUAL_BALANCES_SLOT.deriveMapping(token);
        int256 value;
        assembly {
            value := sload(slot)
        }
        return value;
    }
    
    /// @notice Mock functions that handler needs
    function hasPriceFeed(address) external pure returns (bool) {
        return true; // Always true for testing
    }
    
    function wrappedNative() external view returns (address) {
        // Return appropriate WETH based on chain
        if (block.chainid == 1) {
            return 0xc02Aaa39b223fe8d0A6263C51c404Ee8E5a532E1; // WETH on Ethereum
        } else if (block.chainid == 8453) {
            return 0x4200000000000000000000000000000000000006; // WETH on Base
        }
        return address(0); // Default
    }
    
    function getPoolTokens() external view returns (ISmartPoolState.PoolTokens memory) {
        return ISmartPoolState.PoolTokens({
            unitaryValue: 1000000, // 1.0 in base token decimals
            totalSupply: totalSupply
        });
    }
    
    /// @notice Set virtual balance for testing
    /// @param token The token address
    /// @param value The virtual balance value
    function setVirtualBalance(address token, int256 value) external {
        require(msg.sender == owner, "ONLY_OWNER");
        bytes32 slot = VIRTUAL_BALANCES_SLOT.deriveMapping(token);
        assembly {
            sstore(slot, value)
        }
    }
    
    /// @notice Accept ETH transfers
    receive() external payable {}
}
