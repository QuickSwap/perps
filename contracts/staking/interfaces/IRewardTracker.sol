// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.6.12;

interface IRewardTracker {
    function depositBalances(address _account, address _depositToken) external view returns (uint256);
    function stakedAmounts(address _account) external view returns (uint256);
    function updateRewards(address _rewardToken) external;
    function stake(address _depositToken, uint256 _amount) external;
    function stakeForAccount(address _fundingAccount, address _account, address _depositToken, uint256 _amount) external;
    function unstake(address _depositToken, uint256 _amount) external;
    function unstakeForAccount(address _account, address _depositToken, uint256 _amount, address _receiver) external;
    function tokensPerInterval(address _rewardToken) external view returns (uint256);
    function claim(address _rewardToken, address _receiver) external returns (uint256);
    function claimForAccount(address _account, address _rewardToken, address _receiver) external returns (uint256);
    function claimAll(address _receiver) external returns (address[] memory,uint256[] memory);
    function claimAllForAccount(address _account, address _receiver) external returns (address[] memory,uint256[] memory);
    function claimable(address _account, address _rewardToken) external view returns (uint256);
    function claimableAll(address _account) external view  returns (address[] memory,uint256[] memory);
    function averageStakedAmounts(address _account) external view returns (uint256);
    function cumulativeRewards(address _account, address _rewardToken) external view returns (uint256);
    function hasCumulativeRewards(address _account) external view returns (bool);
    function getAllRewardTokens() external view returns (address[] memory);
    function rewardTokens(address _rewardToken) external view returns (bool);
    function allTokens(address _rewardToken) external view returns (bool);
}
