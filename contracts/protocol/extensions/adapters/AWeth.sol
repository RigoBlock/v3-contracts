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

pragma solidity 0.5.0;

import { Drago } from "../../Drago/Drago.sol";
import { AuthorityFace as Authority } from "../../authorities/Authority/AuthorityFace.sol";
import { ExchangesAuthorityFace as ExchangesAuthority } from "../../authorities/ExchangesAuthority/ExchangesAuthorityFace.sol";
import { WETH9 } from "../../../tokens/WETH9/WETH9.sol";

/// @title Weth adapter - A helper to wrap eth to the 0x wrapper token.
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
        WETH9(wrapper).deposit.value(amount)();
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
