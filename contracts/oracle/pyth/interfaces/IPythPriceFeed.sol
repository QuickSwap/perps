// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IPythPriceFeed {
    function getPrice(address _token, uint256 _referencePrice, bool _maximise) external view returns (uint256);
    function setSigner(address _account, bool _isActive) external;
    function setUpdater(address _account, bool _isActive) external;
    function setPriceDuration(uint256 _priceDuration) external;
    function setMaxPriceUpdateDelay(uint256 _maxPriceUpdateDelay) external;
    function setSpreadBasisPointsIfInactive(uint256 _spreadBasisPointsIfInactive) external;
    function setSpreadBasisPointsIfChainError(uint256 _spreadBasisPointsIfChainError) external;
    function setIsSpreadEnabled(bool _isSpreadEnabled) external;
    function setMaxDeviationBasisPoints(uint256 _maxDeviationBasisPoints) external;
}
