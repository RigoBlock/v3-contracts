// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

/// @title MockPoolForAcross
/// @notice Simple delegatecall proxy for testing Across extension and adapter
/// @dev This is a testing mock. Production uses full SmartPool infrastructure.
contract MockPoolForAcross {
    address public owner;
    address public baseToken;
    uint8 public decimals;
    
    // ERC20 storage for pool token
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    
    // Virtual balances storage slot (matches MixinConstants)
    // bytes32(uint256(keccak256("pool.proxy.virtualBalances")) - 1)
    bytes32 constant VIRTUAL_BALANCES_SLOT = 0x19797d8be84f650fe18ebccb97578c2adb7abe9b7c86852694a3ceb69073d1d1;
    
    constructor(address _owner, address _baseToken, uint8 _decimals) {
        owner = _owner;
        baseToken = _baseToken;
        decimals = _decimals;
        totalSupply = 1000000e18; // Initial supply
        balanceOf[_owner] = totalSupply;
    }
    
    /// @notice Delegatecall to extension or adapter
    /// @param target The extension or adapter address
    /// @param data The calldata
    function execute(address target, bytes calldata data) external payable returns (bytes memory) {
        require(msg.sender == owner, "ONLY_OWNER");
        
        (bool success, bytes memory result) = target.delegatecall(data);
        require(success, "DELEGATECALL_FAILED");
        
        return result;
    }
    
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
