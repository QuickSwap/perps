// SPDX-License-Identifier: BUSL-1.1

import "./interfaces/v0.8/IVaultPriceFeed.sol";
import "../oracle/interfaces/v0.8/ISecondaryPriceFeed.sol";
import "@api3/contracts/v0.8/interfaces/IProxy.sol";

pragma solidity ^0.8.0;

contract VaultPriceFeed is IVaultPriceFeed {

    uint256 public constant PRICE_PRECISION = 10**30;
    uint256 public constant ONE_USD = PRICE_PRECISION;
    uint256 public constant BASIS_POINTS_DIVISOR = 10000;
    uint256 public constant MAX_SPREAD_BASIS_POINTS = 50;
    uint256 public constant MAX_ADJUSTMENT_INTERVAL = 2 hours;
    uint256 public constant MAX_ADJUSTMENT_BASIS_POINTS = 20;

    address public gov;

    bool public isSecondaryPriceEnabled = true;
    bool public favorPrimaryPrice;
    uint256 public maxStrictPriceDeviation;
    address public secondaryPriceFeed;
    uint256 public spreadThresholdBasisPoints = 30;
    uint256 public expireTimeForPriceFeed = 1 days;


    mapping(address => address) public priceFeedProxies;
    mapping(address => uint256) public priceDecimals;
    mapping(address => uint256) public spreadBasisPoints;
    mapping(address => bool) public strictStableTokens;

    mapping(address => uint256) public override adjustmentBasisPoints;
    mapping(address => bool) public override isAdjustmentAdditive;
    mapping(address => uint256) public lastAdjustmentTimings;

    modifier onlyGov() {
        require(msg.sender == gov, "VaultPriceFeed: forbidden");
        _;
    }

    constructor()  {
        gov = msg.sender;
    }

    function setGov(address _gov) external onlyGov {
        require(_gov != address(0), "VaultPriceFeed: address(0)");
        gov = _gov;
    }

    function setAdjustment(
        address _token,
        bool _isAdditive,
        uint256 _adjustmentBps
    ) external override onlyGov {
        require(lastAdjustmentTimings[_token] + MAX_ADJUSTMENT_INTERVAL < block.timestamp, "VaultPriceFeed: adjustment frequency exceeded");
        require(_adjustmentBps <= MAX_ADJUSTMENT_BASIS_POINTS, "invalid _adjustmentBps");
        isAdjustmentAdditive[_token] = _isAdditive;
        adjustmentBasisPoints[_token] = _adjustmentBps;
        lastAdjustmentTimings[_token] = block.timestamp;
    }

    function setIsSecondaryPriceEnabled(bool _isEnabled) external override onlyGov {
        isSecondaryPriceEnabled = _isEnabled;
    }

    function setExpireTimeForPriceFeed(uint256 _expireTimeForPriceFeed) external override onlyGov {
        require(_expireTimeForPriceFeed >= 1 minutes,"invalid _expireTimeForPriceFeed");
        require(_expireTimeForPriceFeed <= 1 days,"invalid _expireTimeForPriceFeed");
        expireTimeForPriceFeed = _expireTimeForPriceFeed;
    }

    function setSecondaryPriceFeed(address _secondaryPriceFeed) external onlyGov {
        secondaryPriceFeed = _secondaryPriceFeed;
    }

    function setSpreadBasisPoints(address _token, uint256 _spreadBasisPoints) external override onlyGov {
        require(_spreadBasisPoints <= MAX_SPREAD_BASIS_POINTS, "VaultPriceFeed: invalid _spreadBasisPoints");
        spreadBasisPoints[_token] = _spreadBasisPoints;
    }

    function setSpreadThresholdBasisPoints(uint256 _spreadThresholdBasisPoints) external override onlyGov {
        spreadThresholdBasisPoints = _spreadThresholdBasisPoints;
    }

    function setFavorPrimaryPrice(bool _favorPrimaryPrice) external override onlyGov {
        favorPrimaryPrice = _favorPrimaryPrice;
    }

    function setMaxStrictPriceDeviation(uint256 _maxStrictPriceDeviation) external override onlyGov {
        maxStrictPriceDeviation = _maxStrictPriceDeviation;
    }

    function setTokenConfig(
        address _token,
        address _priceFeedProxy,
        uint256 _priceDecimals,
        bool _isStrictStable
    ) external override onlyGov {
        priceFeedProxies[_token] = _priceFeedProxy;
        priceDecimals[_token] = _priceDecimals;
        strictStableTokens[_token] = _isStrictStable;
    }

    function getPrice(
        address _token,
        bool _maximise,
        bool /*_includeAmmPrice */,
        bool /* _useSwapPricing */
    ) public view override returns (uint256) {
        uint256 price = getPriceV1(_token, _maximise);

        uint256 adjustmentBps = adjustmentBasisPoints[_token];
        if (adjustmentBps > 0) {
            bool isAdditive = isAdjustmentAdditive[_token];
            if (isAdditive) {
                price = (price * (BASIS_POINTS_DIVISOR + adjustmentBps)) / BASIS_POINTS_DIVISOR;
            } else {
                price = (price * (BASIS_POINTS_DIVISOR - adjustmentBps)) / BASIS_POINTS_DIVISOR;
            }
        }

        return price;
    }

    function getPriceV1(
        address _token,
        bool _maximise
    ) public view returns (uint256) {
        uint256 price = getPrimaryPrice(_token, _maximise);


        if (isSecondaryPriceEnabled) {
            price = getSecondaryPrice(_token, price, _maximise);
        }

        if (strictStableTokens[_token]) {
            uint256 delta = price > ONE_USD ? price - ONE_USD : ONE_USD - price;
            if (delta <= maxStrictPriceDeviation) {
                return ONE_USD;
            }

            // if _maximise and price is e.g. 1.02, return 1.02
            if (_maximise && price > ONE_USD) {
                return price;
            }

            // if !_maximise and price is e.g. 0.98, return 0.98
            if (!_maximise && price < ONE_USD) {
                return price;
            }

            return ONE_USD;
        }

        uint256 _spreadBasisPoints = spreadBasisPoints[_token];

        if (_maximise) {
            return (price * (BASIS_POINTS_DIVISOR + _spreadBasisPoints)) / BASIS_POINTS_DIVISOR;
        }

        return (price * (BASIS_POINTS_DIVISOR - _spreadBasisPoints)) / BASIS_POINTS_DIVISOR;
    }

    function getLatestPrimaryPrice(address _token) public override view returns (uint256) {
        return _getApi3Price(_token);
    }   

    function getPrimaryPrice(address _token, bool /*_maximise*/) public view override returns (uint256) {
        uint256 price = _getApi3Price(_token);

        uint256 _priceDecimals = priceDecimals[_token];
        return (price * PRICE_PRECISION) / 10 ** _priceDecimals;
    }

    function getSecondaryPrice(
        address _token,
        uint256 _referencePrice,
        bool _maximise
    ) public view returns (uint256) {
        if (secondaryPriceFeed == address(0)) {
            return _referencePrice;
        }
        return ISecondaryPriceFeed(secondaryPriceFeed).getPrice(_token, _referencePrice, _maximise);
    }

    function _getApi3Price(address _token) private view  returns (uint256) {
        address proxy = priceFeedProxies[_token];
        require(proxy != address(0), "VaultPriceFeed: invalid price feed proxy");
        (int224 price, uint256 timestamp) = IProxy(proxy).read();
        require(price > 0, "VaultPriceFeed: price not positive");
        require(
            timestamp + expireTimeForPriceFeed > block.timestamp,
            "VaultPriceFeed: expired"
        );
        return uint256(uint224(price));
    }
}
