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

pragma solidity 0.5.0;

/// @title Lib Sanitize - Sanitize strings in smart contracts.
/// @author Gabriele Rigo - <gab@rigoblock.com>
library LibSanitize {

    function isValidCheck(string memory str)
        internal
        pure
        returns (bool)
    {
        bytes memory bStr = bytes(str);
        uint arrayLength = bStr.length;
        require(
            bStr[0] != byte(uint8(32))
        );    
        require(
            bStr[arrayLength - 1] != byte(uint8(32))
        );    
        for (uint i =0; i < arrayLength; i++) {
            if (
                (
                    bStr[i] < byte(uint8(48)) ||
                    bStr[i] > byte(uint8(122)) ||
                    bStr[i] > byte(uint8(57)) && bStr[i] < byte(uint8(65)) ||
                    bStr[i] > byte(uint8(90)) && bStr[i] < byte(uint8(97))
                ) && bStr[i] != byte(uint8(32))
            ) return false;
        } return true;
    }

    function isLowercase(string memory str)
        internal
        pure
        returns (bool)
    {
        bytes memory bStr = bytes(str);
        uint arrayLength = bStr.length;
		    for (uint i = 0; i < arrayLength; i++) {
			     if ((bStr[i] >= byte(uint8(65))) && (bStr[i] <= byte(uint8(90)))) return false;
		    } return true;
    }

    function isUppercase(string memory str)
        internal
        pure
        returns (bool)
    {
        bytes memory bStr = bytes(str);
        uint arrayLength = bStr.length;
        for (uint i = 0; i < arrayLength; i++) {
            if ((bStr[i] >= byte(uint8(97))) && (bStr[i] <= byte(uint8(122)))) return false;
        } return true;
    }
}
