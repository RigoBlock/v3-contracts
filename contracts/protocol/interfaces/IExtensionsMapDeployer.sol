// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {DeploymentParams} from "../types/DeploymentParams.sol";

interface IExtensionsMapDeployer {
    function version() external view returns (uint24);
    function deployExtensionsMap(DeploymentParams memory params) external returns (address);
    function parameters() external view returns (DeploymentParams memory);
}