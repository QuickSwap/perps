// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./RewardTracker.sol";

contract StakedQlpTracker is RewardTracker {
    constructor() public RewardTracker("Fee + Staked QLP", "fsQLP") {}
}

contract FeeQlpTracker is RewardTracker {
    constructor() public RewardTracker("Fee QLP", "fQLP") {}
}
