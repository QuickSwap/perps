// SPDX-License-Identifier: MIT
pragma solidity ^0.7.5;

interface IFarming {
  function distributedTokensLength() external view returns (uint256);

  function distributedToken(uint256 index) external view returns (address);

  function isDistributedToken(address token) external view returns (bool);

  function addFarmingToPending(address token, uint256 amount) external;

  function addPendingToCurrentDistribution(address token) external;

  function allocate(uint256 amount) external;
  
  function deallocate(uint256 amount) external;
}