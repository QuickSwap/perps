// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

interface IPositionRouter {
    function increasePositionRequestKeysStart() external view returns (uint256);
    function decreasePositionRequestKeysStart() external view returns (uint256);
    function increasePositionRequestKeys(uint256 index) external view returns (bytes32);
    function decreasePositionRequestKeys(uint256 index) external view returns (bytes32);
    function executeIncreasePositions(uint256 _count, address payable _executionFeeReceiver) external;
    function executeDecreasePositions(uint256 _count, address payable _executionFeeReceiver) external;
    function getRequestQueueLengths() external view returns (uint256, uint256, uint256, uint256);
    function getIncreasePositionRequestPath(bytes32 _key) external view returns (address[] memory);
    function getDecreasePositionRequestPath(bytes32 _key) external view returns (address[] memory);
}
