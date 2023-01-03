// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./RewardDistributor.sol";


contract StakedQlpDistributor is RewardDistributor {
    constructor(address _rewardToken, address _rewardTracker) public RewardDistributor(_rewardToken, _rewardTracker) {}
}
contract FeeQlpDistributor is RewardDistributor {
    constructor(address _rewardToken, address _rewardTracker) public RewardDistributor(_rewardToken, _rewardTracker) {}
}
