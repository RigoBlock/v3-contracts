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

pragma solidity >=0.7.0 <0.9.0;

/// @title Authority Interface - Allows interaction with the Authority contract.
/// @author Gabriele Rigo - <gab@rigoblock.com>
// solhint-disable-next-line
interface IAuthorityCore {

    /*
     * EVENTS
     */
    event AuthoritySet(address indexed authority);
    event WhitelisterSet(address indexed whitelister);
    event WhitelistedFactory(address indexed factory);
    event RemovedAuthority(address indexed authority);
    event RemovedFactory(address indexed factory);
    event RemovedWhitelister(address indexed whitelsiter);
    event NewExtensionsAuthority(address indexed extensionsAuthority);

    /*
     * CORE FUNCTIONS
     */
    function setAuthority(address _authority, bool _isWhitelisted) external;
    function setExtensionsAuthority(address _extensionsAuthority) external;
    function setWhitelister(address _whitelister, bool _isWhitelisted) external;
    function whitelistFactory(address _factory, bool _isWhitelisted) external;

    /*
     * CONSTANT PUBLIC FUNCTIONS
     */
    function isAuthority(address _authority) external view returns (bool);
    function isWhitelistedFactory(address _factory) external view returns (bool);
    function getAuthorityExtensions() external view returns (address);
}
