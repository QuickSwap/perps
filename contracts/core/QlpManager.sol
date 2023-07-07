// SPDX-License-Identifier: BUSL-1.1

import "../libraries/math/SafeMath.sol";
import "../libraries/token/IERC20.sol";
import "../libraries/token/SafeERC20.sol";
import "../libraries/utils/ReentrancyGuard.sol";

import "./interfaces/IVault.sol";
import "./interfaces/IQlpManager.sol";
import "./interfaces/IShortsTracker.sol";
import "../tokens/interfaces/IUSDQ.sol";
import "../tokens/interfaces/IMintable.sol";
import "../access/Governable.sol";

pragma solidity 0.6.12;

contract QlpManager is ReentrancyGuard, Governable, IQlpManager {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    uint256 public constant PRICE_PRECISION = 10 ** 30;
    uint256 public constant USDQ_DECIMALS = 18;
    uint256 public constant QLP_PRECISION = 10 ** 18;
    uint256 public constant MAX_COOLDOWN_DURATION = 48 hours;
    uint256 public constant BASIS_POINTS_DIVISOR = 10000;

    IVault public override vault;
    IShortsTracker public shortsTracker;
    address public override usdq;
    address public override qlp;

    uint256 public override cooldownDuration;
    mapping (address => uint256) public override lastAddedAt;

    uint256 public aumAddition;
    uint256 public aumDeduction;

    bool public inPrivateMode;
    uint256 public shortsTrackerAveragePriceWeight;
    mapping (address => bool) public isHandler;

    event AddLiquidity(
        address account,
        address token,
        uint256 amount,
        uint256 aumInUsdq,
        uint256 qlpSupply,
        uint256 usdqAmount,
        uint256 mintAmount
    );

    event RemoveLiquidity(
        address account,
        address token,
        uint256 qlpAmount,
        uint256 aumInUsdq,
        uint256 qlpSupply,
        uint256 usdqAmount,
        uint256 amountOut
    );

    constructor(address _vault, address _usdq, address _qlp, address _shortsTracker, uint256 _cooldownDuration) public {
        gov = msg.sender;
        vault = IVault(_vault);
        usdq = _usdq;
        qlp = _qlp;
        shortsTracker = IShortsTracker(_shortsTracker);
        cooldownDuration = _cooldownDuration;
    }

    function setInPrivateMode(bool _inPrivateMode) external onlyGov {
        inPrivateMode = _inPrivateMode;
    }

    function setShortsTracker(IShortsTracker _shortsTracker) external onlyGov {
        shortsTracker = _shortsTracker;
    }

    function setShortsTrackerAveragePriceWeight(uint256 _shortsTrackerAveragePriceWeight) external override onlyGov {
        require(shortsTrackerAveragePriceWeight <= BASIS_POINTS_DIVISOR, "QlpManager: invalid weight");
        shortsTrackerAveragePriceWeight = _shortsTrackerAveragePriceWeight;
    }

    function setHandler(address _handler, bool _isActive) external onlyGov {
        isHandler[_handler] = _isActive;
    }

    function setCooldownDuration(uint256 _cooldownDuration) external override onlyGov {
        require(_cooldownDuration <= MAX_COOLDOWN_DURATION, "QlpManager: invalid _cooldownDuration");
        cooldownDuration = _cooldownDuration;
    }

    function setAumAdjustment(uint256 _aumAddition, uint256 _aumDeduction) external onlyGov {
        aumAddition = _aumAddition;
        aumDeduction = _aumDeduction;
    }

    function addLiquidity(address _token, uint256 _amount, uint256 _minUsdq, uint256 _minQlp) external override nonReentrant returns (uint256) {
        if (inPrivateMode) { revert("QlpManager: action not enabled"); }
        return _addLiquidity(msg.sender, msg.sender, _token, _amount, _minUsdq, _minQlp);
    }

    function addLiquidityForAccount(address _fundingAccount, address _account, address _token, uint256 _amount, uint256 _minUsdq, uint256 _minQlp) external override nonReentrant returns (uint256) {
        _validateHandler();
        return _addLiquidity(_fundingAccount, _account, _token, _amount, _minUsdq, _minQlp);
    }

    function removeLiquidity(address _tokenOut, uint256 _qlpAmount, uint256 _minOut, address _receiver) external override nonReentrant returns (uint256) {
        if (inPrivateMode) { revert("QlpManager: action not enabled"); }
        return _removeLiquidity(msg.sender, _tokenOut, _qlpAmount, _minOut, _receiver);
    }

    function removeLiquidityForAccount(address _account, address _tokenOut, uint256 _qlpAmount, uint256 _minOut, address _receiver) external override nonReentrant returns (uint256) {
        _validateHandler();
        return _removeLiquidity(_account, _tokenOut, _qlpAmount, _minOut, _receiver);
    }

    function getPrice(bool _maximise) external view returns (uint256) {
        uint256 aum = getAum(_maximise);
        uint256 supply = IERC20(qlp).totalSupply();
        return aum.mul(QLP_PRECISION).div(supply);
    }

    function getAums() public view returns (uint256[] memory) {
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = getAum(true);
        amounts[1] = getAum(false);
        return amounts;
    }

    function getAumInUsdq(bool maximise) public override view returns (uint256) {
        uint256 aum = getAum(maximise);
        return aum.mul(10 ** USDQ_DECIMALS).div(PRICE_PRECISION);
    }

    function getAum(bool maximise) public view returns (uint256) {
        uint256 length = vault.allWhitelistedTokensLength();
        uint256 aum = aumAddition;
        uint256 shortProfits = 0;
        IVault _vault = vault;

        for (uint256 i = 0; i < length; i++) {
            address token = vault.allWhitelistedTokens(i);
            bool isWhitelisted = vault.whitelistedTokens(token);

            if (!isWhitelisted) {
                continue;
            }

            uint256 price = maximise ? _vault.getMaxPrice(token) : _vault.getMinPrice(token);
            uint256 poolAmount = _vault.poolAmounts(token);
            uint256 decimals = _vault.tokenDecimals(token);

            if (_vault.stableTokens(token)) {
                aum = aum.add(poolAmount.mul(price).div(10 ** decimals));
            } else {
                // add global short profit / loss
                uint256 size = _vault.globalShortSizes(token);

                if (size > 0) {
                    (uint256 delta, bool hasProfit) = getGlobalShortDelta(token, price, size);
                    if (!hasProfit) {
                        // add losses from shorts
                        aum = aum.add(delta);
                    } else {
                        shortProfits = shortProfits.add(delta);
                    }
                }

                aum = aum.add(_vault.guaranteedUsd(token));

                uint256 reservedAmount = _vault.reservedAmounts(token);
                aum = aum.add(poolAmount.sub(reservedAmount).mul(price).div(10 ** decimals));
            }
        }

        aum = shortProfits > aum ? 0 : aum.sub(shortProfits);
        return aumDeduction > aum ? 0 : aum.sub(aumDeduction);
    }

    function getGlobalShortDelta(address _token, uint256 _price, uint256 _size) public view returns (uint256, bool) {
        uint256 averagePrice = getGlobalShortAveragePrice(_token);
        uint256 priceDelta = averagePrice > _price ? averagePrice.sub(_price) : _price.sub(averagePrice);
        uint256 delta = _size.mul(priceDelta).div(averagePrice);
        return (delta, averagePrice > _price);
    }

    function getGlobalShortAveragePrice(address _token) public view returns (uint256) {
        IShortsTracker _shortsTracker = shortsTracker;
        if (address(_shortsTracker) == address(0) || !_shortsTracker.isGlobalShortDataReady()) {
            return vault.globalShortAveragePrices(_token);
        }

        uint256 _shortsTrackerAveragePriceWeight = shortsTrackerAveragePriceWeight;
        if (_shortsTrackerAveragePriceWeight == 0) {
            return vault.globalShortAveragePrices(_token);
        } else if (_shortsTrackerAveragePriceWeight == BASIS_POINTS_DIVISOR) {
            return _shortsTracker.globalShortAveragePrices(_token);
        }

        uint256 vaultAveragePrice = vault.globalShortAveragePrices(_token);
        uint256 shortsTrackerAveragePrice = _shortsTracker.globalShortAveragePrices(_token);

        return vaultAveragePrice.mul(BASIS_POINTS_DIVISOR.sub(_shortsTrackerAveragePriceWeight))
            .add(shortsTrackerAveragePrice.mul(_shortsTrackerAveragePriceWeight))
            .div(BASIS_POINTS_DIVISOR);
    }

    function _addLiquidity(address _fundingAccount, address _account, address _token, uint256 _amount, uint256 _minUsdq, uint256 _minQlp) private returns (uint256) {
        require(_amount != 0, "QlpManager: invalid _amount");

        // calculate aum before buyUSDQ
        uint256 aumInUsdq = getAumInUsdq(true);
        uint256 qlpSupply = IERC20(qlp).totalSupply();

        IERC20(_token).safeTransferFrom(_fundingAccount, address(vault), _amount);
        uint256 usdqAmount = vault.buyUSDQ(_token, address(this));
        require(usdqAmount >= _minUsdq, "QlpManager: insufficient USDQ output");

        uint256 mintAmount = aumInUsdq == 0 ? usdqAmount : usdqAmount.mul(qlpSupply).div(aumInUsdq);
        require(mintAmount >= _minQlp, "QlpManager: insufficient QLP output");

        IMintable(qlp).mint(_account, mintAmount);

        lastAddedAt[_account] = block.timestamp;

        emit AddLiquidity(_account, _token, _amount, aumInUsdq, qlpSupply, usdqAmount, mintAmount);

        return mintAmount;
    }

    function _removeLiquidity(address _account, address _tokenOut, uint256 _qlpAmount, uint256 _minOut, address _receiver) private returns (uint256) {
        require(_qlpAmount != 0, "QlpManager: invalid _qlpAmount");
        require(lastAddedAt[_account].add(cooldownDuration) <= block.timestamp, "QlpManager: cooldown duration not yet passed");

        // calculate aum before sellUSDQ
        uint256 aumInUsdq = getAumInUsdq(false);
        uint256 qlpSupply = IERC20(qlp).totalSupply();

        uint256 usdqAmount = _qlpAmount.mul(aumInUsdq).div(qlpSupply);
        uint256 usdqBalance = IERC20(usdq).balanceOf(address(this));
        if (usdqAmount > usdqBalance) {
            IUSDQ(usdq).mint(address(this), usdqAmount.sub(usdqBalance));
        }

        IMintable(qlp).burn(_account, _qlpAmount);

        IERC20(usdq).transfer(address(vault), usdqAmount);
        uint256 amountOut = vault.sellUSDQ(_tokenOut, _receiver);
        require(amountOut >= _minOut, "QlpManager: insufficient output");

        emit RemoveLiquidity(_account, _tokenOut, _qlpAmount, aumInUsdq, qlpSupply, usdqAmount, amountOut);

        return amountOut;
    }

    function _validateHandler() private view {
        require(isHandler[msg.sender], "QlpManager: forbidden");
    }
}
