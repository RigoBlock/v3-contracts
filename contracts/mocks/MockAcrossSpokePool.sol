// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

// TODO: absurd defining erc20 here when we can import it. Absurd using erc20 when we can mock state, but leaving as it is probably
// the root of why across foundry tests fail even when creating the price feed for the base token - because the token is probably different (i.e. deployed in foundry fixture)
/// @notice Mock ERC20 token for testing
contract MockERC20 {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    
    mapping(address => uint256) private balances;
    mapping(address => mapping(address => uint256)) private allowances;
    
    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }
    
    function mint(address to, uint256 amount) external {
        balances[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }
    
    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }
    
    function transfer(address to, uint256 amount) external returns (bool) {
        require(balances[msg.sender] >= amount, "Insufficient balance");
        balances[msg.sender] -= amount;
        balances[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balances[from] >= amount, "Insufficient balance");
        require(allowances[from][msg.sender] >= amount, "Insufficient allowance");
        
        balances[from] -= amount;
        balances[to] += amount;
        allowances[from][msg.sender] -= amount;
        
        emit Transfer(from, to, amount);
        return true;
    }
    
    function approve(address spender, uint256 amount) external returns (bool) {
        allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
    
    function allowance(address owner, address spender) external view returns (uint256) {
        return allowances[owner][spender];
    }
}

/// @notice Mock Across SpokePool for testing
contract MockAcrossSpokePool {
    event V3FundsDeposited(
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        address depositor,
        address recipient,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityDeadline,
        address exclusiveRelayer,
        bytes message
    );

    address public wrappedNativeToken;
    uint32 public immutable fillDeadlineBuffer;
    
    constructor(address _wrappedNativeToken) {
        wrappedNativeToken = _wrappedNativeToken;
        fillDeadlineBuffer = 21600;
    }

    receive() external payable {}
    
    function depositV3(
        address depositor,
        address recipient,
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        address exclusiveRelayer,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityDeadline,
        bytes calldata message
    ) external payable {
        // Transfer tokens from depositor
        if (inputToken != address(0)) {
            MockERC20(inputToken).transferFrom(msg.sender, address(this), inputAmount);
        }
        
        emit V3FundsDeposited(
            inputToken,
            outputToken,
            inputAmount,
            outputAmount,
            destinationChainId,
            depositor,
            recipient,
            quoteTimestamp,
            fillDeadline,
            exclusivityDeadline,
            exclusiveRelayer,
            message
        );
    }

    /// @notice Mock function to simulate filling a deposit and calling handler
    function simulateFill(
        address handler,
        address tokenReceived,
        uint256 amount,
        bytes calldata message
    ) external {
        (bool success,) = handler.call(
            abi.encodeWithSignature(
                "handleV3AcrossMessage(address,uint256,bytes)",
                tokenReceived,
                amount,
                message
            )
        );
        require(success, "Handler call failed");
    }
}
