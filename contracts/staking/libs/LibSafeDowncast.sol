// SPDX-License-Identifier: Apache 2.0
/*

  Original work Copyright 2019 ZeroEx Intl.
  Modified work Copyright 2020 Rigo Intl.

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

library LibSafeDowncast {
    /// @dev Safely downcasts to a uint96
    /// Note that this reverts if the input value is too large.
    function downcastToUint96(uint256 a) internal pure returns (uint96 b) {
        b = uint96(a);
        require(uint256(b) == a, "VALUE_TOO_LARGE_TO_DOWNCAST_TO_UINT96");
        return b;
    }

    /// @dev Safely downcasts to a uint64
    /// Note that this reverts if the input value is too large.
    function downcastToUint64(uint256 a) internal pure returns (uint64 b) {
        b = uint64(a);
        require(uint256(b) == a, "VALUE_TOO_LARGE_TO_DOWNCAST_TO_UINT64");
        return b;
    }
}
