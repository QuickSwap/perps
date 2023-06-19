// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

interface IRewardTrackerClaim {
        function claimForAccount(address _account, address _receiver) external returns (uint256); //BackCompatibility
}
