// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.28;

import {DeploymentParams} from "../types/DeploymentParams.sol";

interface IExtensionsMapDeployer {
    /// @notice Returns the nonce of the deployed ExtensionsMap contract.
    /// @dev It is increased only when a new contract is deployed.
    /// @param deployer Address of the deployer wallet.
    /// @param salt Bytes32 input to allow multi-chain deterministic deployment.
    /// @return mapAddress Address of the mapped contract.
    function deployedMaps(address deployer, bytes32 salt) external view returns (address mapAddress);

    /// @notice Returns the address of the deployed contract.
    /// @dev If the params are unchanged, the address of the already-deployed contract is returned.
    function deployExtensionsMap(DeploymentParams memory params, bytes32 salt) external returns (address);

    /// @notice Returns the extensions deployment parameters.
    /// @return Tuple of the deployment parameters '(Extensions, address)'.
    function parameters() external view returns (DeploymentParams memory);
}
