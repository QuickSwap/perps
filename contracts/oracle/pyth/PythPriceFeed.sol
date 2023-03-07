// SPDX-License-Identifier: MIT

import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "./interfaces/IPythPriceFeed.sol";
import "./interfaces/IPositionRouter.sol";
import "./Governable.sol";

import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

pragma solidity ^0.8.0;

contract PythPriceFeed is IPythPriceFeed, Governable {
    using SafeMath for uint256;

    IPyth public pyth;

    uint256 public constant PRICE_PRECISION = 10 ** 30;

    uint256 public constant BASIS_POINTS_DIVISOR = 10000;

    uint256 public constant MAX_PRICE_DURATION = 30 minutes;

    bool public isInitialized;
    bool public isSpreadEnabled = false;

    address public tokenManager;

    address public positionRouter;

    uint256 public priceDuration;
    uint256 public maxPriceUpdateDelay;
    uint256 public spreadBasisPointsIfInactive;
    uint256 public spreadBasisPointsIfChainError;

    // allowed deviation from primary price
    uint256 public maxDeviationBasisPoints;

    uint256 public minAuthorizations;
    uint256 public disableFastPriceVoteCount = 0;

    mapping (address => bool) public isUpdater;

    mapping(address => bytes32) public priceFeedIds;
    mapping(address => uint256) public priceConfidenceMultipliers;  
    mapping(address => uint256) public priceConfidenceThresholds;

    mapping (address => bool) public isSigner;
    mapping (address => bool) public disableFastPriceVotes;

    event DisableFastPrice(address signer);
    event EnableFastPrice(address signer);

    modifier onlySigner() {
        require(isSigner[msg.sender], "FastPriceFeed: forbidden");
        _;
    }

    modifier onlyUpdater() {
        require(isUpdater[msg.sender], "FastPriceFeed: forbidden");
        _;
    }

    modifier onlyTokenManager() {
        require(msg.sender == tokenManager, "FastPriceFeed: forbidden");
        _;
    }

    constructor(
      uint256 _priceDuration,
      uint256 _maxPriceUpdateDelay,
      uint256 _maxDeviationBasisPoints,
      address _tokenManager,
      address _positionRouter,
      address _pythContract
    )  {
        require(_priceDuration <= MAX_PRICE_DURATION, "FastPriceFeed: invalid _priceDuration");
        priceDuration = _priceDuration;
        maxPriceUpdateDelay = _maxPriceUpdateDelay;
        maxDeviationBasisPoints = _maxDeviationBasisPoints;
        tokenManager = _tokenManager;
        positionRouter = _positionRouter;
        pyth = IPyth(_pythContract);
    }

    function initialize(uint256 _minAuthorizations, address[] memory _signers, address[] memory _updaters) public onlyGov {
        require(!isInitialized, "FastPriceFeed: already initialized");
        isInitialized = true;

        minAuthorizations = _minAuthorizations;

        for (uint256 i = 0; i < _signers.length; i++) {
            address signer = _signers[i];
            isSigner[signer] = true;
        }

        for (uint256 i = 0; i < _updaters.length; i++) {
            address updater = _updaters[i];
            isUpdater[updater] = true;
        }
    }
    
    function setPositionRouter(address _positionRouter) external onlyTokenManager {
        positionRouter = _positionRouter;
    }
    function setSigner(address _account, bool _isActive) external override onlyGov {
        isSigner[_account] = _isActive;
    }

    function setUpdater(address _account, bool _isActive) external override onlyGov {
        isUpdater[_account] = _isActive;
    }

    function setPriceDuration(uint256 _priceDuration) external override onlyGov {
        require(_priceDuration <= MAX_PRICE_DURATION, "FastPriceFeed: invalid _priceDuration");
        priceDuration = _priceDuration;
    }

    function setMaxPriceUpdateDelay(uint256 _maxPriceUpdateDelay) external override onlyGov {
        maxPriceUpdateDelay = _maxPriceUpdateDelay;
    }

    function setSpreadBasisPointsIfInactive(uint256 _spreadBasisPointsIfInactive) external override onlyGov {
        spreadBasisPointsIfInactive = _spreadBasisPointsIfInactive;
    }

    function setSpreadBasisPointsIfChainError(uint256 _spreadBasisPointsIfChainError) external override onlyGov {
        spreadBasisPointsIfChainError = _spreadBasisPointsIfChainError;
    }

    function setIsSpreadEnabled(bool _isSpreadEnabled) external override onlyGov {
        isSpreadEnabled = _isSpreadEnabled;
    }

    function setTokenManager(address _tokenManager) external onlyTokenManager {
        tokenManager = _tokenManager;
    }

    function setMaxDeviationBasisPoints(uint256 _maxDeviationBasisPoints) external override onlyTokenManager {
        maxDeviationBasisPoints = _maxDeviationBasisPoints;
    }

    function setPriceFeedIds(address[] memory _tokens,  bytes32[] memory _priceFeedIds) external  onlyTokenManager {
        for (uint256 i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];
            priceFeedIds[token] = _priceFeedIds[i];
        }
    }

    function setPriceConfidenceMultipliers(address[] memory _tokens,  uint256[] memory _priceConfidenceMultipliers) external  onlyGov {
        for (uint256 i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];
            priceConfidenceMultipliers[token] = _priceConfidenceMultipliers[i];
        }
    }

    function setPriceConfidenceThresholds(address[] memory _tokens,  uint256[] memory _priceConfidenceThresholds) external  onlyGov {
        for (uint256 i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];
            priceConfidenceThresholds[token] = _priceConfidenceThresholds[i];
        }
    }

    function setMinAuthorizations(uint256 _minAuthorizations) external onlyTokenManager {
        minAuthorizations = _minAuthorizations;
    }

    function setPythPricesAndExecute(
        bytes[] calldata priceUpdateData,
        bytes32[] calldata priceIds,
        uint64[] calldata publishTimes,
        uint256 _endIndexForIncreasePositions,
        uint256 _endIndexForDecreasePositions,
        uint256 _maxIncreasePositions,
        uint256 _maxDecreasePositions
    ) external payable onlyUpdater {
        uint fee = pyth.getUpdateFee(priceUpdateData);
        require(msg.value == fee, "PythPriceFeed: invalid msg.value");
        // pyth.updatePriceFeeds(priceUpdateData);

        try pyth.updatePriceFeedsIfNecessary{ value: fee }(priceUpdateData,priceIds,publishTimes) {
        } catch {
            payable(msg.sender).transfer(fee);
        }


        IPositionRouter _positionRouter = IPositionRouter(positionRouter);
        uint256 maxEndIndexForIncrease = _positionRouter.increasePositionRequestKeysStart().add(_maxIncreasePositions);
        uint256 maxEndIndexForDecrease = _positionRouter.decreasePositionRequestKeysStart().add(_maxDecreasePositions);

        if (_endIndexForIncreasePositions > maxEndIndexForIncrease) {
            _endIndexForIncreasePositions = maxEndIndexForIncrease;
        }

        if (_endIndexForDecreasePositions > maxEndIndexForDecrease) {
            _endIndexForDecreasePositions = maxEndIndexForDecrease;
        }

        _positionRouter.executeIncreasePositions(_endIndexForIncreasePositions, payable(msg.sender));
        _positionRouter.executeDecreasePositions(_endIndexForDecreasePositions, payable(msg.sender));
    }




    function disableFastPrice() external onlySigner {
        require(!disableFastPriceVotes[msg.sender], "FastPriceFeed: already voted");
        disableFastPriceVotes[msg.sender] = true;
        disableFastPriceVoteCount = disableFastPriceVoteCount.add(1);

        emit DisableFastPrice(msg.sender);
    }

    function enableFastPrice() external onlySigner {
        require(disableFastPriceVotes[msg.sender], "FastPriceFeed: already enabled");
        disableFastPriceVotes[msg.sender] = false;
        disableFastPriceVoteCount = disableFastPriceVoteCount.sub(1);

        emit EnableFastPrice(msg.sender);
    }

    function _getPythPrice(address _token) private view returns (uint256,uint256,uint256){ //must be private 
        
        uint256 price;
        uint256 confDiff;
        uint256 publishTime;
        PythStructs.Price memory pythPrice = pyth.getPriceUnsafe(priceFeedIds[_token]);
        publishTime = pythPrice.publishTime;


        if (pythPrice.price>=0 && pythPrice.expo<=0){
            price =  (uint256(uint64(pythPrice.price)).mul(PRICE_PRECISION)).div(10 ** uint32(-pythPrice.expo));
            uint256 conf = uint256(pythPrice.conf).mul(PRICE_PRECISION).div(10 ** uint32(-pythPrice.expo));
            if(conf.mul(BASIS_POINTS_DIVISOR).div(price)>priceConfidenceThresholds[_token]){
                confDiff = conf.mul(priceConfidenceMultipliers[_token]).div(BASIS_POINTS_DIVISOR);        
            }   
            
        }
        return (price,confDiff,publishTime); 

    }

    // if the fastPrice has not been updated within priceDuration then it is ignored and only _refPrice with a spread is used (spread: spreadBasisPointsIfInactive)
    // in case the fastPrice has not been updated for maxPriceUpdateDelay then the _refPrice with a larger spread is used (spread: spreadBasisPointsIfChainError)
    //
    // there will be a spread from the _refPrice to the fastPrice in the following cases:
    // - in case isSpreadEnabled is set to true
    // - in case the maxDeviationBasisPoints between _refPrice and fastPrice is exceeded
    // - in case watchers flag an issue
    function getPrice(address _token, uint256 _refPrice, bool _maximise) external override view returns (uint256) {
        if(priceFeedIds[_token] == bytes32(0)) return _refPrice;


        (uint256 fastPrice,
        uint256 confDiff,
        uint256 lastUpdatedAt) = _getPythPrice(_token);




        if (block.timestamp > lastUpdatedAt.add(maxPriceUpdateDelay)) {
            if (_maximise) {
                return _refPrice.mul(BASIS_POINTS_DIVISOR.add(spreadBasisPointsIfChainError)).div(BASIS_POINTS_DIVISOR);
            }

            return _refPrice.mul(BASIS_POINTS_DIVISOR.sub(spreadBasisPointsIfChainError)).div(BASIS_POINTS_DIVISOR);
        }

        if (block.timestamp > lastUpdatedAt.add(priceDuration)) {
            if (_maximise) {
                return _refPrice.mul(BASIS_POINTS_DIVISOR.add(spreadBasisPointsIfInactive)).div(BASIS_POINTS_DIVISOR);
            }

            return _refPrice.mul(BASIS_POINTS_DIVISOR.sub(spreadBasisPointsIfInactive)).div(BASIS_POINTS_DIVISOR);
        }

        if(fastPrice == 0) return _refPrice;

        if(confDiff>0){
            if (_maximise) {                
                fastPrice = fastPrice.add(confDiff);
            }else{
                fastPrice = fastPrice.sub(confDiff);
            }    
        }



        uint256 diffBasisPoints = _refPrice > fastPrice ? _refPrice.sub(fastPrice) : fastPrice.sub(_refPrice);
        diffBasisPoints = diffBasisPoints.mul(BASIS_POINTS_DIVISOR).div(_refPrice);

        // create a spread between the _refPrice and the fastPrice if the maxDeviationBasisPoints is exceeded
        // or if watchers have flagged an issue with the fast price
        bool hasSpread = !favorFastPrice() || diffBasisPoints > maxDeviationBasisPoints;

        if (hasSpread) {
            // return the higher of the two prices
            if (_maximise) {
                return _refPrice > fastPrice ? _refPrice : fastPrice;
            }

            // return the lower of the two prices
            return _refPrice < fastPrice ? _refPrice : fastPrice;
        }

        return fastPrice;
    }

    function favorFastPrice() public view returns (bool) {
        if (isSpreadEnabled) {
            return false;
        }

        if (disableFastPriceVoteCount >= minAuthorizations) {
            // force a spread if watchers have flagged an issue with the fast price
            return false;
        }

        return true;
    }

}
