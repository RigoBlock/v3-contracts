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

/// @title Find Method Library - library to find the method of a call.
/// @author Gabriele Rigo - <gab@rigoblock.com>
library LibFindMethod {

    /// @dev Returns the method of an ABIencoded call
    /// @param assembledData Bytes of the call data
    /// @return Bytes4 of the function signature
    function findMethod(bytes memory assembledData)
        internal
        pure
        returns (bytes4 method)
    {
        // find the bytes4(keccak256('functionABI')) of the function
        assembly {
            // Load free memory pointer
            method := mload(0x00)
            let transaction := assembledData
            method := mload(add(transaction, 0x20))
        }
        return method;
    }
}
