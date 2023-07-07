// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.6.12;

interface IRewardDistributor {
    function getAllRewardTokens() external view returns (address[] memory);
    function tokensPerInterval(address _rewardToken) external view returns (uint256);
    function pendingRewards(address _rewardToken) external view returns (uint256);
    function distribute(address _rewardToken) external returns (uint256);
    function addRewardToken(address _token) external;
    function removeRewardToken(address _token) external;
    function allRewardTokensLength() external view returns (uint256);
    function allRewardTokens(uint256) external view returns (address);
    function rewardTokens(address _token) external view returns (bool);
    function allTokens(address _token) external view returns (bool);
    function rewardTokenCount() external view returns (uint256);
}
