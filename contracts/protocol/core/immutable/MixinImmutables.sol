// SPDX-License-Identifier: Apache 2.0
/*

 Copyright 2022 Rigo Intl.

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

pragma solidity >=0.8.0 <0.9.0;

import "../../IRigoblockV3Pool.sol";

abstract contract MixinImmutables is IRigoblockV3Pool {
    constructor(address _authority) {
        authority = _authority;
        _coinbaseDecimals = 18;
        _coinbaseUnitaryValue = 1 * 10**_coinbaseDecimals;
        _implementation = address(this);
    }

    address public immutable override authority;

    // EIP1967 standard, must be immutable to be compile-time constant.
    address internal immutable _implementation;

    uint8 internal immutable _coinbaseDecimals;

    uint256 internal immutable _coinbaseUnitaryValue;
}
