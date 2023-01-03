// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

interface IRewardRouterV2 {
    function feeQlpTracker() external view returns (address);
    function stakedQlpTracker() external view returns (address);
}
