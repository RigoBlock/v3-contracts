// SPDX-License-Identifier: Apache-2.0-or-later
/*

 Copyright 2018 RigoBlock, Rigo Investment Sagl.

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

pragma solidity 0.8.14;

abstract contract WETH9 {
    function deposit() external payable virtual;

    function withdraw(uint256 wad) external virtual;
}

/// @title WETH adapter - A helper to wrap ETH to the wrapper token.
/// @author Gabriele Rigo - <gab@rigoblock.com>
// solhint-disable-next-line
contract AWeth {
    address public immutable WETH_ADDRESS;

    constructor(address _wethAddress) {
        WETH_ADDRESS = _wethAddress;
    }

    /// @dev allows a manager to deposit eth to an approved eth wrapper.
    /// @param amount Value of the Eth in wei
    function wrapEth(uint256 amount) external {
        WETH9(WETH_ADDRESS).deposit{value: amount}();
    }

    /// @dev allows a manager to withdraw ETH from WETH9
    /// @param amount Value of the Eth in wei
    function unwrapEth(uint256 amount) external {
        WETH9(WETH_ADDRESS).withdraw(amount);
    }
}
