// SPDX-License-Identifier: MIT

import "./interfaces/IPythPriceFeed.sol";
import "./interfaces/IPositionRouter.sol";
import "./Governable.sol";

import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

pragma solidity ^0.8.0;

contract PythPriceFeed is IPythPriceFeed, Governable {

    IPyth public immutable pyth;

    uint256 public constant PRICE_PRECISION = 10 ** 30;

    uint256 public constant BASIS_POINTS_DIVISOR = 10000;

    uint256 public constant MAX_PRICE_DURATION = 30 minutes;

    bool public isInitialized;
    bool public isSpreadEnabled;

    address public tokenManager;

    address public positionRouter;

    uint256 public priceDuration;
    uint256 public maxPriceUpdateDelay;
    uint256 public spreadBasisPointsIfInactive;
    uint256 public spreadBasisPointsIfChainError;
    uint256 public signersCount;

    // allowed deviation from primary price
    uint256 public maxDeviationBasisPoints;

    uint256 public minAuthorizations;
    uint256 public disableFastPriceVoteCount;

    mapping (address => bool) public isUpdater;

    mapping(address => bytes32) public priceFeedIds;
    mapping(address => uint256) public priceConfidenceMultipliers;  
    mapping(address => uint256) public priceConfidenceThresholds;

    mapping (address => bool) public isSigner;
    mapping (address => bool) public disableFastPriceVotes;

    event DisableFastPrice(address signer);
    event EnableFastPrice(address signer);
    event SetSigner(address indexed signer, bool isActive);
    event SetUpdater(address indexed updater, bool isActive);
    event SetPositionRouter(address positionRouter);

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
        require(_tokenManager != address(0), "FastPriceFeed: invalid tokenManager");
        require(_positionRouter != address(0), "FastPriceFeed: invalid positionRouter");
        require(_pythContract != address(0), "FastPriceFeed: invalid pythContract");
        priceDuration = _priceDuration;
        maxPriceUpdateDelay = _maxPriceUpdateDelay;
        maxDeviationBasisPoints = _maxDeviationBasisPoints;
        tokenManager = _tokenManager;
        positionRouter = _positionRouter;
        pyth = IPyth(_pythContract);
    }

    function initialize(uint256 _minAuthorizations, address[] calldata _signers, address[] calldata _updaters) external onlyGov {
        require(!isInitialized, "FastPriceFeed: already initialized");
        require(_minAuthorizations <= _signers.length, "FastPriceFeed: minAuthorizations > signersCount");

        isInitialized = true;

        minAuthorizations = _minAuthorizations;

        for (uint256 i = 0; i < _signers.length; i++) {
            _setSigner(_signers[i],true);
        }

        for (uint256 i = 0; i < _updaters.length; i++) {
            _setUpdater(_updaters[i],true);
        }

    }
    
    function setPositionRouter(address _positionRouter) external onlyTokenManager {
        positionRouter = _positionRouter;
        emit SetPositionRouter(_positionRouter);
    }
    function setSigner(address _account, bool _isActive) external override onlyGov {
        _setSigner(_account,_isActive);
    }

    function _setSigner(address _account, bool _isActive) private {
        if(!isSigner[_account] && _isActive) {
            signersCount++;
        } else if(isSigner[_account] && !_isActive) {
            require(minAuthorizations<signersCount,"FastPriceFeed: min auth must be reduce first");
            signersCount--;
        } else {
            return;
        }               

        isSigner[_account] = _isActive;
        emit SetSigner(_account,_isActive);
    }    

    function setUpdater(address _account, bool _isActive) external override onlyGov {
        _setUpdater(_account,_isActive);
    }

    function _setUpdater(address _account, bool _isActive) private {
        isUpdater[_account] = _isActive;
        emit SetUpdater(_account,_isActive);
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

    function setPriceFeedIds(address[] calldata _tokens,  bytes32[] calldata _priceFeedIds) external  onlyTokenManager {
        require(_tokens.length == _priceFeedIds.length, "FastPriceFeed: array lengths mismatch");
        for (uint256 i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];
            priceFeedIds[token] = _priceFeedIds[i];
        }
    }

    function setPriceConfidenceMultipliers(address[] calldata _tokens,  uint256[] calldata _priceConfidenceMultipliers) external  onlyGov {
        require(_tokens.length == _priceConfidenceMultipliers.length, "FastPriceFeed: array lengths mismatch");
        for (uint256 i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];
            priceConfidenceMultipliers[token] = _priceConfidenceMultipliers[i];
        }
    }

    function setPriceConfidenceThresholds(address[] calldata _tokens,  uint256[] calldata _priceConfidenceThresholds) external  onlyGov {
        require(_tokens.length == _priceConfidenceThresholds.length, "FastPriceFeed: array lengths mismatch");
        for (uint256 i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];
            priceConfidenceThresholds[token] = _priceConfidenceThresholds[i];
        }
    }

    function setMinAuthorizations(uint256 _minAuthorizations) external onlyTokenManager {
        require(_minAuthorizations <= signersCount, "FastPriceFeed: minAuthorizations > signersCount");
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
        uint256 maxEndIndexForIncrease = _positionRouter.increasePositionRequestKeysStart() + _maxIncreasePositions;
        uint256 maxEndIndexForDecrease = _positionRouter.decreasePositionRequestKeysStart() + _maxDecreasePositions;

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
        disableFastPriceVoteCount = disableFastPriceVoteCount++;

        emit DisableFastPrice(msg.sender);
    }

    function enableFastPrice() external onlySigner {
        require(disableFastPriceVotes[msg.sender], "FastPriceFeed: already enabled");
        disableFastPriceVotes[msg.sender] = false;
        disableFastPriceVoteCount = disableFastPriceVoteCount--;

        emit EnableFastPrice(msg.sender);
    }

    function _getPythPrice(address _token) private view returns (uint256,uint256,uint256){
        
        uint256 price;
        uint256 confDiff;
        uint256 publishTime;
        PythStructs.Price memory pythPrice = pyth.getPriceUnsafe(priceFeedIds[_token]);
        publishTime = pythPrice.publishTime;


        if (pythPrice.price>=0 && pythPrice.expo<=0){
            price =  (uint256(uint64(pythPrice.price)) * PRICE_PRECISION) / 10 ** uint32(-pythPrice.expo);         
                        
            uint256 conf = (uint256(pythPrice.conf) * PRICE_PRECISION) / 10 ** uint32(-pythPrice.expo);
            
            if((conf * BASIS_POINTS_DIVISOR) / price > priceConfidenceThresholds[_token]){
                confDiff = (conf * priceConfidenceMultipliers[_token]) / BASIS_POINTS_DIVISOR;        
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




        if (block.timestamp > lastUpdatedAt + maxPriceUpdateDelay) {
            if (_maximise) {
                return (_refPrice * (BASIS_POINTS_DIVISOR + spreadBasisPointsIfChainError)) / BASIS_POINTS_DIVISOR;
            }

            return (_refPrice * (BASIS_POINTS_DIVISOR - spreadBasisPointsIfChainError)) / BASIS_POINTS_DIVISOR;
        }

        if (block.timestamp > lastUpdatedAt + priceDuration) {
            if (_maximise) {
                return (_refPrice * (BASIS_POINTS_DIVISOR + spreadBasisPointsIfInactive)) / BASIS_POINTS_DIVISOR;
            }

            return (_refPrice * (BASIS_POINTS_DIVISOR - spreadBasisPointsIfInactive)) / BASIS_POINTS_DIVISOR;
        }

        if(fastPrice == 0) return _refPrice;

        if(confDiff>0){
            if (_maximise) {                
                fastPrice = fastPrice + confDiff;
            }else{
                fastPrice = fastPrice - confDiff;
            }    
        }



        uint256 diffBasisPoints = _refPrice > fastPrice ? _refPrice - fastPrice : fastPrice - _refPrice;
        diffBasisPoints = (diffBasisPoints * BASIS_POINTS_DIVISOR) / _refPrice;

        // create a spread between the _refPrice and the fastPrice if the maxDeviationBasisPoints is exceeded
        // or if watchers have flagged an issue with the fast price
        bool hasSpread = diffBasisPoints > maxDeviationBasisPoints || !favorFastPrice();

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
        return !isSpreadEnabled && disableFastPriceVoteCount < minAuthorizations;
    }

}
