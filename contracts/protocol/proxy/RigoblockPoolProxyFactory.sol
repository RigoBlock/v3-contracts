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

pragma solidity 0.8.14;

import { IDragoRegistry as DragoRegistry } from "../../interfaces/IDragoRegistry.sol";
import { IAuthority as Authority } from "../../interfaces/IAuthority.sol";
import { IDragoEventful as DragoEventful } from "../../interfaces/IDragoEventful.sol";
import { DragoFactoryLibrary, Drago } from "../DragoFactoryLibrary/DragoFactoryLibrary.sol";
import { OwnedUninitialized as Owned } from "../../../utils/Owned/OwnedUninitialized.sol";
import { IRigoblockPoolProxyFactory } from "./RigoblockPoolProxyFactory.sol";

/// @title Rigoblock Pool Proxy Factory contract - allows creation of new Rigoblock pools.
/// @author Gabriele Rigo - <gab@rigoblock.com>
// solhint-disable-next-line
contract RigoblockPoolProxyFactory is Owned, IRigoblockPoolProxyFactory {

    DragoFactoryLibrary.NewDrago private libraryData;

    string public constant VERSION = "DF 0.5.2";

    Data private data;

    struct Data {
        uint256 fee;
        address dragoRegistry;
        address payable dragoDao;
        address authority;
        mapping(address => address[]) dragos;
    }

    event DragoCreated(
        string name,
        string symbol,
        address indexed drago,
        address indexed owner,
        uint256 dragoId
    );

    modifier whitelistedFactory(address _authority) {
        Authority auth = Authority(_authority);
        if (auth.isWhitelistedFactory(address(this))) _;
    }

    modifier whenFeePaid {
        require(msg.value >= data.fee);
        _;
    }

    modifier onlyOwner {
        require(msg.sender == owner);
        _;
    }

    modifier onlyDragoDao {
        require(msg.sender == data.dragoDao);
        _;
    }

    constructor(
        address _registry,
        address payable _dragoDao,
        address _authority)
        public
    {
        data.dragoRegistry = _registry;
        data.dragoDao = _dragoDao;
        data.authority = _authority;
        owner = msg.sender;
    }

    /*
     * PUBLIC FUNCTIONS
     */
    /// @dev allows creation of a new drago
    /// @param _name String of the name
    /// @param _symbol String of the symbol
    /// @return Bool the transaction executed correctly
    function createDrago(string calldata _name, string calldata _symbol)
        external
        payable
        whenFeePaid
        returns (bool success)
    {
        DragoRegistry registry = DragoRegistry(data.dragoRegistry);
        uint256 regFee = registry.getFee();
        uint256 dragoId = registry.dragoCount();
        require(createDragoInternal(_name, _symbol, msg.sender, dragoId));
        assert(registry.register.value(regFee)(
            libraryData.newAddress,
            _name,
            _symbol,
            dragoId,
            msg.sender)
        );
        return true;
    }

    /// @dev Allows factory owner to update the address of the dao/factory
    /// @dev Enables manual update of dao for single dragos
    /// @param _targetDrago Address of the target drago
    /// @param _dragoDao Address of the new drago dao
    function setTargetDragoDao(address payable _targetDrago, address _dragoDao)
        external
        onlyOwner
    {
        Drago drago = Drago(_targetDrago);
        drago.changeDragoDao(_dragoDao);
    }

    /// @dev Allows drago dao/factory to update its address
    /// @dev Creates internal record
    /// @param _newDragoDao Address of the drago dao
    function changeDragoDao(address payable _newDragoDao)
        external
        onlyDragoDao
    {
        data.dragoDao = _newDragoDao;
    }

    /// @dev Allows owner to update the registry
    /// @param _newRegistry Address of the new registry
    function setRegistry(address _newRegistry)
        external
        onlyOwner
    {
        data.dragoRegistry = _newRegistry;
    }

    /// @dev Allows owner to set the address which can collect creation fees
    /// @param _dragoDao Address of the new drago dao/factory
    function setBeneficiary(address payable _dragoDao)
        external
        onlyOwner
    {
        data.dragoDao = _dragoDao;
    }

    /// @dev Allows owner to set the drago creation fee
    /// @param _fee Value of the fee in wei
    function setFee(uint256 _fee)
        external
        onlyOwner
    {
        data.fee = _fee;
    }

    /// @dev Allows owner to collect fees
    function drain()
        external
        onlyOwner
    {
        data.dragoDao.transfer(address(this).balance);
    }

    /*
     * CONSTANT PUBLIC FUNCTIONS
     */
    /// @dev Returns the address of the pool registry
    /// @return Address of the registry
    function getRegistry()
        external view
        returns (address)
    {
        return (data.dragoRegistry);
    }

    /// @dev Returns administrative data for this factory
    /// @return Address of the drago dao
    /// @return String of the version
    /// @return Number of the next drago from the registry
    function getStorage()
        external
        view
        returns (
            address dragoDao,
            string memory version,
            uint256 nextDragoId
        )
    {
        return (
            dragoDao = data.dragoDao,
            version = VERSION,
            nextDragoId = getNextId()
        );
    }

    /// @dev Returns the address of the logger contract
    /// @dev Queries from authority contract
    /// @return Address of the eventful contract
    function getEventful()
        external view
        returns (address)
    {
        Authority auth = Authority(data.authority);
        return auth.getDragoEventful();
    }

    /// @dev Returns an array of dragos the owner has created
    /// @param _owner Address of the queried owner
    /// @return Array of drago addresses
    function getDragosByAddress(address _owner)
        external
        view
        returns (address[] memory)
    {
        return data.dragos[_owner];
    }

    /*
     * INTERNAL FUNCTIONS
     */
    /// @dev Creates a drago and routes to eventful
    /// @param _name String of the name
    /// @param _symbol String of the symbol
    /// @param _owner Address of the owner
    /// @param _dragoId Number of the new drago Id
    /// @return Bool the transaction executed correctly
    function createDragoInternal(
        string memory _name,
        string memory _symbol,
        address _owner,
        uint256 _dragoId)
        internal
        returns (bool success)
    {
        Authority auth = Authority(data.authority);
        require(RigoblockPoolProxyFactoryLibrary.createPool(
            libraryData,
            _name,
            _symbol,
            _owner,
            _poolId,
            data.authority)
        );
        data.dragos[_owner].push(libraryData.newAddress);
        DragoEventful events = DragoEventful(auth.getDragoEventful());
        require(events.createDrago(
            _owner,
            libraryData.newAddress,
            _name,
            _symbol,
            _dragoId)
        );
        auth.whitelistDrago(libraryData.newAddress, true);
        auth.whitelistUser(_owner, true);
        emit DragoCreated(_name, _symbol, libraryData.newAddress, _owner, _dragoId);
        return true;
    }

    /// @dev Returns the next Id for a drago
    /// @return Number of the next Id from the registry
    function getNextId()
        internal view
        returns (uint256 nextDragoId)
    {
        DragoRegistry registry = DragoRegistry(data.dragoRegistry);
        nextDragoId = registry.dragoCount();
    }
}
