// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

interface IFastPriceFeedForReader {
    function prices(address _token) external view returns (uint256);
}
