// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./interfaces/IFastPriceFeedForReader.sol";

contract FastPriceFeedReader {
    function getPrices(address _fastPriceFeed,
    address[] memory _tokens
    ) public view returns (uint256[] memory) {

        IFastPriceFeedForReader fastPriceFeed = IFastPriceFeedForReader(_fastPriceFeed);

        uint256[] memory prices = new uint256[](_tokens.length);
        for (uint256 i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];
            prices[i] = fastPriceFeed.prices(token);
        }

        return prices;
    }
}    

