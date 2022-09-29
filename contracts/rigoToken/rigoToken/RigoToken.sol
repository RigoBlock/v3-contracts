// SPDX-License-Identifier: Apache 2.0
/*

 Copyright 2017-2018 RigoBlock, Rigo Investment Sagl.

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

pragma solidity 0.8.17;

import {UnlimitedAllowanceToken} from "../../tokens/UnlimitedAllowanceToken/UnlimitedAllowanceToken.sol";
import "../interfaces/IRigoToken.sol";

/// @title Rigo Token - Rules of the Rigo token.
/// @author Gabriele Rigo - <gab@rigoblock.com>
/// @notice UnlimitedAllowanceToken is ERC20
contract RigoToken is IRigoToken, UnlimitedAllowanceToken {
    string public constant name = "Rigo Token";
    string public constant symbol = "GRG";
    uint8 public constant decimals = 18;

    /// @inheritdoc IRigoToken
    address public override minter;

    /// @inheritdoc IRigoToken
    address public override rigoblock;

    /*
     * MODIFIERS
     */
    modifier onlyMinter() {
        require(msg.sender == minter);
        _;
    }

    modifier onlyRigoblock() {
        require(msg.sender == rigoblock);
        _;
    }

    constructor(
        address _setMinter,
        address _setRigoblock,
        address _grgHolder
    ) {
        minter = _setMinter;
        rigoblock = _setRigoblock;
        totalSupply = 1e25; // 10 million tokens, 18 decimals
        balances[_grgHolder] = totalSupply;
    }

    /*
     * CORE FUNCTIONS
     */
    /// @inheritdoc IRigoToken
    function mintToken(address _recipient, uint256 _amount) external override onlyMinter {
        balances[_recipient] += _amount;
        totalSupply += _amount;
        emit TokenMinted(_recipient, _amount);
    }

    /// @inheritdoc IRigoToken
    function changeMintingAddress(address _newAddress) external override onlyRigoblock {
        minter = _newAddress;
    }

    /// @inheritdoc IRigoToken
    function changeRigoblockAddress(address _newAddress) external override onlyRigoblock {
        rigoblock = _newAddress;
    }
}
