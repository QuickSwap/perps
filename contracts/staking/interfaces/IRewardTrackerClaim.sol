// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.6.12;

interface IRewardTrackerClaim {
        function claimForAccount(address _account, address _receiver) external returns (uint256); //BackCompatibility
}
