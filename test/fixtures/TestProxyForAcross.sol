// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

/// @title TestProxyForAcross
/// @notice Proper delegatecall proxy with fallback for testing Across extension and adapter
/// @dev Mimics RigoblockPoolProxy fallback pattern but simplified for testing
contract TestProxyForAcross {
    address public immutable handler;
    address public immutable adapter;
    address public owner;
    address public baseToken;
    uint8 public decimals;
    
    // ERC20 storage for pool token
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    
    // Virtual balances storage slot (matches MixinConstants)
    // bytes32(uint256(keccak256("pool.proxy.virtual.balances")) - 1)
    bytes32 constant VIRTUAL_BALANCES_SLOT = 0x19797d8be84f650fe18ebccb97578c2adb7abe9b7c86852694a3ceb69073d1d1;
    
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
        
        // handleV3AcrossMessage selector: 0x52ebbe5b
        if (selector == 0x52ebbe5b) {
            target = handler;
        }
        // depositV3 selector: 0xd0cc7a67
        else if (selector == 0xd0cc7a67) {
            target = adapter;
        }
        else {
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
        bytes32 slot = keccak256(abi.encode(token, VIRTUAL_BALANCES_SLOT));
        int256 value;
        assembly {
            value := sload(slot)
        }
        return value;
    }
    
    /// @notice Set virtual balance for testing
    /// @param token The token address
    /// @param value The virtual balance value
    function setVirtualBalance(address token, int256 value) external {
        require(msg.sender == owner, "ONLY_OWNER");
        bytes32 slot = keccak256(abi.encode(token, VIRTUAL_BALANCES_SLOT));
        assembly {
            sstore(slot, value)
        }
    }
    
    /// @notice Accept ETH transfers
    receive() external payable {}
}
