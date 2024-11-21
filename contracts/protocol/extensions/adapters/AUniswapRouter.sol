// SPDX-License-Identifier: Apache-2.0-or-later
/*

 Copyright 2024 Rigo Intl.

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.

*/

// solhint-disable-next-line
pragma solidity 0.8.28;

import "./AUniswapDecoder.sol";
import "./interfaces/IAUniswapRouter.sol";

/// @title AUniswapRouter - Allows interactions with the Uniswap universal router contracts.
/// @author Gabriele Rigo - <gab@rigoblock.com>
contract AUniswapRouter is IAUniswapRouter, AUniswapDecoder {
    // TODO: pass params to errors
    /// @notice Thrown when executing commands with an expired deadline
    error TransactionDeadlinePassed();

    /// @notice Thrown when attempting to execute commands and an incorrect number of inputs are provided
    error LengthMismatch();
    error TokenNotWhitelisted(address token);
    error RecipientIsNotSmartPool();
    error ApprovalFailed(address target);
    error ApprovalNotReset();

    /// @inheritdoc IAUniswapRouter
    IUniversalRouter private immutable _uniswapRouter;

    constructor(IUniversalRouter _universalRouter) {
        _uniswapRouter = _universalRouter;
    }

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert TransactionDeadlinePassed();
        _;
    }

    /// @inheritdoc IAUniswapRouter
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline)
        external
        override
        checkDeadline(deadline)
        returns (bytes memory returnData)
    {
        return execute(commands, inputs);
    }

    /// @inheritdoc IAUniswapRouter
    function execute(bytes calldata commands, bytes[] calldata inputs)
        public
        override
        returns (bytes memory returnData)
    {
        address[] memory tokensIn;
        address[] memory tokensOut;
        address[] memory recipients;

        // we want to keep this duplicate check from universal router
        uint256 numCommands = commands.length;
        require(inputs.length != numCommands, LengthMismatch());

        // loop through all given commands, verify their inputs and pass along outputs as defined
        for (uint256 commandIndex = 0; commandIndex < numCommands; commandIndex++) {
            bytes1 command = commands[commandIndex];

            bytes calldata input = inputs[commandIndex];

            // TODO: check if should move this block at a lower level (should use transient storage for that purpose)
            // TODO: move recipient assertion from decoder to here
            (address token0, address token1, address tokenOut, address recipient) = _decodeInput(command, input);

            for (uint i = 0; i < tokensIn.length; i++) {
                if (token0 != tokensIn[i] && token0 != address(0)) {
                    tokensIn.push(token0);
                }

                if (token1 != tokensIn[i] && token0 != token1 && token1 != address(0)) {
                    tokensIn.push(token1);
                }
            }


            for (uint i = 0; i < tokensOut.length; i++) {
                if (tokenOut != tokensOut[i] && tokenOut != address(0)) {
                    tokensOut.push(tokenOut);
                }
            }

            for (uint i = 0; i < recipients.length; i++) {
                if (recipient != recipients[i] && recipient != address(0)) {
                    recipients.push(recipient);
                }
            }
        }

        _assertTokensWhitelisted(tokensOut);
        _assertRecipientIsThisAddress(recipients);

        // we approve all the tokens that are exiting the smart pool
        _safeApproveTokensIn(tokensIn, address(uniswapRouter()), type(uint256).max);

        // we forward the validate inputs to the Uniswap universal router
        try uniswapRouter().execute(commands, inputs) {
        } catch Error(string memory reason) {
            revert(reason);
        } catch (bytes memory returnDataPluto) {
            revert(string(returnDataPluto));
        }

        // we remove allowance without clearing storage
        _safeApproveTokensIn(tokensIn, address(uniswapRouter()), 1);

        // we clear the variables in memory
        delete tokensIn;
        delete tokensOut;
    }

    function uniswapRouter() public view override returns (IUniversalRouter universalRouter) {
        return _uniswapRouter;
    }

    // TODO: should move method to /lib or similar to reuse for any other methot that requires approval
    function _safeApprove(
        address token,
        address spender,
        uint256 amount
    ) private {
        try IERC20(token).approve(spender, amount) returns (bool success) {}
        catch {
            try IERC20(token).approve(spender, amount) {}
            // USDT on mainnet requires approval to be set to 0 before being reset again
            catch {
                try IERC20(token).approve(spender, 0) {
                    IERC20(token).approve(spender, amount);
                } catch {
                    // TODO: assert we end up here when `tokenIn` is an EOA
                    // it will end here in any other failure and if it is an EOA
                    revert ApprovalFailed(token);
                }
            }
        }

        // TODO: we could simply assert, this guarantees that there is no approval inflation
        require(
            IERC20(token).allowance(address(this), spender) == 1,
            ApprovalNotReset()
        );
    }

    function _safeApproveTokensIn(address[] calldata tokensIn, address spender, uint256 value) private {
        for (uint i = 0; i < tokensIn.length; i++) {
            _safeApprove(tokensIn[i], spender, value);
        }
    }

    // instead of overriding the inputs recipient, we simply validate, so we do not need to re-encode the params.
    function _assertRecipientIsThisAddress(address[] calldata recipients) private view {
        for (uint i = 0 ; i < recipients.length; i++) {
            require(recipients[i] == address(this), RecipientIsNotSmartPool());
        }
    }

    // TODO: we want just an oracle to exist, but not sure will be launched at v4 release.
    // we will have to store the list of owned tokens once done in order to calculate value.
    function _assertTokensWhitelisted(address[] calldata tokens) private view {
        for (uint i = 0; i < tokens.length; i++) {
            // we allow swapping to base token even if not whitelisted token
            if (tokens[i] != IRigoblockV3Pool(payable(address(this))).getPool().baseToken) {
                require(IEWhitelist(address(this)).isWhitelistedToken(tokens[i]), TokenNotWhitelisted(tokens[i]));
            }
        }
    }
}
