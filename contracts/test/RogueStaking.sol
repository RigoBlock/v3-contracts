// SPDX-License-Identifier: Apache-2.0-or-later

pragma solidity 0.8.17;

contract RogueStaking {
    address public owner;
    mapping(address => bool) public authorized;
    address[] public authorities;
    address public stakingContract;
    mapping(uint8 => StoredBalance) internal _globalStakeByStatus;
    mapping(uint8 => mapping(address => StoredBalance)) internal _ownerStakeByStatus;
    mapping(address => mapping(bytes32 => StoredBalance)) internal _delegatedStakeToPoolByOwner;
    mapping(bytes32 => StoredBalance) internal _delegatedStakeByPoolId;
    mapping(address => bytes32) public poolIdByRbPoolAccount;
    mapping(bytes32 => Pool) internal _poolById;
    mapping(bytes32 => uint256) public rewardsByPoolId;
    uint256 public currentEpoch;
    uint256 public currentEpochStartTimeInSeconds;
    mapping(bytes32 => mapping(uint256 => Fraction)) internal _cumulativeRewardsByPool;
    mapping(bytes32 => uint256) internal _cumulativeRewardsByPoolLastStored;
    mapping(address => bool) public validPops;
    uint256 public epochDurationInSeconds;
    uint32 public rewardDelegatedStakeWeight; // 1e15
    uint256 public minimumPoolStake; // 1e19
    uint32 public cobbDouglasAlphaNumerator; // 2
    uint32 public cobbDouglasAlphaDenominator; // 3
    address public inflation;
    struct StoredBalance {
        uint64 currentEpoch;
        uint96 currentEpochBalance;
        uint96 nextEpochBalance;
    }
    struct Pool {
        address operator;
        address stakingPal;
        uint32 operatorShare;
        uint32 stakingPalShare;
    }
    struct Fraction {
        uint256 numerator;
        uint256 denominator;
    }

    function init() public {}

    function setAlphaNum(uint32 value) public {
        cobbDouglasAlphaNumerator = value;
    }

    function setAlphaDenom(uint32 value) public {
        cobbDouglasAlphaDenominator = value;
    }

    function setMinimumStake(uint256 value) public {
        minimumPoolStake = value;
    }

    function setStakeWeight(uint32 value) public {
        rewardDelegatedStakeWeight = value;
    }

    function setDuration(uint256 _duration) public {
        epochDurationInSeconds = _duration;
    }

    function setStaking(address _staking) public {
        stakingContract = _staking;
    }

    function setInflation(address _inflation) public {
        inflation = _inflation;
    }

    function endEpoch() public returns (uint256) {
        bytes4 selector = bytes4(keccak256(bytes("mintInflation()")));
        bytes memory encodedCall = abi.encodeWithSelector(selector);
        (bool success, bytes memory data) = inflation.call(encodedCall);
        if (!success) {
            revert(string(data));
        }
        return uint256(bytes32(data));
    }

    function getInflation() public view returns (uint256) {
        bytes4 selector = bytes4(keccak256(bytes("getEpochInflation()")));
        bytes memory encodedCall = abi.encodeWithSelector(selector);
        (, bytes memory data) = inflation.staticcall(encodedCall);
        return uint256(bytes32(data));
    }

    function getParams() external view returns (uint256, uint32, uint256, uint32, uint32) {
        return (epochDurationInSeconds, 1, 1, 1, 1);
    }
}
