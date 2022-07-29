// SPDX-License-Identifier: Apache 2.0
/*

 Copyright 2022 RigoBlock, Rigo Intl.

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
pragma solidity =0.8.14;

interface IASelfCustody {
    event SelfCustodyTransfer(address indexed from, address indexed to, address indexed token, uint256 amount);

    function GRG_VAULT_ADDRESS() external view returns (address);

    /// @dev transfers ETH or tokens to self custody.
    /// @param selfCustodyAccount Address of the target account.
    /// @param token Address of the target token.
    /// @param amount Number of tokens.
    /// @return shortfall Number of GRG pool operator shortfall.
    function transferToSelfCustody(
        address payable selfCustodyAccount,
        address token,
        uint256 amount
    ) external returns (uint256 shortfall);

    /// @dev external check if minimum pool GRG amount requirement satisfied.
    /// @return shortfall Number of GRG pool operator shortfall.
    function poolGrgShortfall(address _poolAddress) external view returns (uint256);
}
