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

import { IAuthority as Authority } from "../../interfaces/IAuthority.sol";
import { IExchangesAuthority as ExchangesAuthority } from "../../interfaces/IExchangesAuthority.sol";

abstract contract WETH9 {
    function deposit() external payable virtual;
    function withdraw(uint256 wad) external virtual;
}

abstract contract Drago {

    address public owner;

    function getEventful() external view virtual returns (address);
    function getExchangesAuth() external view virtual returns (address);
}

/// @title WETH adapter - A helper to wrap ETH to the wrapper token.
/// @author Gabriele Rigo - <gab@rigoblock.com>
// solhint-disable-next-line
contract AWeth {

    /// @dev allows a manager to deposit eth to an approved exchange/wrap eth
    /// @param wrapper Address of the target exchange
    /// @param amount Value of the Eth in wei
    function wrapEth(
        address payable wrapper,
        uint256 amount)
        external
    {
        require(
            Drago(
                address(uint160(address(this)))
            )
            .owner() == msg.sender
        );
        require(
            ExchangesAuthority(
                Drago(
                    address(uint160(address(this)))
                )
                .getExchangesAuth()
            )
            .isWhitelistedWrapper(wrapper)
        );
        require(
            ExchangesAuthority(
                Drago(
                    address(uint160(address(this)))
                )
                .getExchangesAuth()
            )
            .canWrapTokenOnWrapper(address(0), wrapper)
        );
        WETH9(wrapper).deposit{value: amount}();
    }

    /// @dev allows a manager to withdraw ETH from WETH9
    /// @param wrapper Address of the weth9 contract
    /// @param amount Value of the Eth in wei
    function unwrapEth(
        address payable wrapper,
        uint256 amount)
        external
    {
        require(
            Drago(
                address(uint160(address(this)))
            )
            .owner() == msg.sender
        );
        require(
            ExchangesAuthority(
                Drago(
                    address(uint160(address(this)))
                )
                .getExchangesAuth()
            )
            .isWhitelistedWrapper(wrapper)
        );
        require(
            ExchangesAuthority(
                Drago(
                    address(uint160(address(this)))
                )
                .getExchangesAuth()
            )
            .canWrapTokenOnWrapper(address(0), wrapper)
        );

        WETH9(wrapper).withdraw(amount);
    }
}
