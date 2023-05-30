// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "../libraries/math/SafeMath.sol";
import "../libraries/token/IERC20.sol";
import "../libraries/token/SafeERC20.sol";
import "../libraries/utils/ReentrancyGuard.sol";
import "../libraries/utils/Address.sol";

import "./interfaces/IRewardTracker.sol";
import "../tokens/interfaces/IMintable.sol";
import "../tokens/interfaces/IWETH.sol";
import "../core/interfaces/IQlpManager.sol";
import "../access/Governable.sol";

contract RewardRouter is ReentrancyGuard, Governable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using Address for address payable;

    bool public isInitialized;

    address public weth;

    address public qlp; // QPX Liquidity Provider token

    address public stakedQlpTracker;
    address public feeQlpTracker;

    address public qlpManager;


    mapping(address => address) public pendingReceivers;

    event StakeQlp(address account, uint256 amount);
    event UnstakeQlp(address account, uint256 amount);

    receive() external payable {
        require(msg.sender == weth, "Router: invalid sender");
    }

    constructor(
        address _weth,
        address _qlp
    ) public{
        weth = _weth;
        qlp = _qlp;        
    }

    function initialize(
        address _feeQlpTracker,
	    address _stakedQlpTracker,
        address _qlpManager
    ) external onlyGov {
        require(!isInitialized, "RewardRouter: already initialized");
        isInitialized = true;

        feeQlpTracker = _feeQlpTracker;
	    stakedQlpTracker = _stakedQlpTracker;

        qlpManager = _qlpManager;

    }

    // to help users who accidentally send their tokens to this contract
    function withdrawToken(
        address _token,
        address _account,
        uint256 _amount
    ) external onlyGov {
        IERC20(_token).safeTransfer(_account, _amount);
    }

    function mintAndStakeQlp(
        address _token,
        uint256 _amount,
        uint256 _minUsdq,
        uint256 _minQlp
    ) external nonReentrant returns (uint256) {
        require(_amount > 0, "RewardRouter: invalid _amount");

        address account = msg.sender;
        uint256 qlpAmount = IQlpManager(qlpManager).addLiquidityForAccount(account, account, _token, _amount, _minUsdq, _minQlp);
        IRewardTracker(feeQlpTracker).stakeForAccount(account, account, qlp, qlpAmount);
	    IRewardTracker(stakedQlpTracker).stakeForAccount(account, account, feeQlpTracker, qlpAmount);

        emit StakeQlp(account, qlpAmount);

        return qlpAmount;
    }

    function mintAndStakeQlpETH(uint256 _minUsdq, uint256 _minQlp) external payable nonReentrant returns (uint256) {
        require(msg.value > 0, "RewardRouter: invalid msg.value");

        IWETH(weth).deposit{value: msg.value}();
        return _mintAndStakeQlpETH(msg.value,_minUsdq, _minQlp);
    }

    function _mintAndStakeQlpETH(uint256 _amount,uint256 _minUsdq, uint256 _minQlp) private returns (uint256) {
        require(_amount > 0, "RewardRouter: invalid _amount");

        IERC20(weth).approve(qlpManager, _amount);

        address account = msg.sender;
        uint256 qlpAmount = IQlpManager(qlpManager).addLiquidityForAccount(address(this), account, weth, _amount, _minUsdq, _minQlp);

        IRewardTracker(feeQlpTracker).stakeForAccount(account, account, qlp, qlpAmount);
	    IRewardTracker(stakedQlpTracker).stakeForAccount(account, account, feeQlpTracker, qlpAmount);

        emit StakeQlp(account, qlpAmount);

        return qlpAmount;
    }

    function unstakeAndRedeemQlp(
        address _tokenOut,
        uint256 _qlpAmount,
        uint256 _minOut,
        address _receiver
    ) external nonReentrant returns (uint256) {
        require(_qlpAmount > 0, "RewardRouter: invalid _qlpAmount");

        address account = msg.sender;
	    IRewardTracker(stakedQlpTracker).unstakeForAccount(account, feeQlpTracker, _qlpAmount, account);
        IRewardTracker(feeQlpTracker).unstakeForAccount(account, qlp, _qlpAmount, account);
        uint256 amountOut = IQlpManager(qlpManager).removeLiquidityForAccount(account, _tokenOut, _qlpAmount, _minOut, _receiver);

        emit UnstakeQlp(account, _qlpAmount);

        return amountOut;
    }

    function unstakeAndRedeemQlpETH(
        uint256 _qlpAmount,
        uint256 _minOut,
        address payable _receiver
    ) external nonReentrant returns (uint256) {
        require(_qlpAmount > 0, "RewardRouter: invalid _qlpAmount");

        address account = msg.sender;
	    IRewardTracker(stakedQlpTracker).unstakeForAccount(account, feeQlpTracker, _qlpAmount, account);
        IRewardTracker(feeQlpTracker).unstakeForAccount(account, qlp, _qlpAmount, account);
        uint256 amountOut = IQlpManager(qlpManager).removeLiquidityForAccount(account, weth, _qlpAmount, _minOut, address(this));

        IWETH(weth).withdraw(amountOut);

        _receiver.sendValue(amountOut);

        emit UnstakeQlp(account, _qlpAmount);

        return amountOut;
    }

    function claim() external nonReentrant {
        address account = msg.sender;

        IRewardTracker(feeQlpTracker).claimForAccount(account, account);
	IRewardTracker(stakedQlpTracker).claimForAccount(account, account);
    }

    function claimFees() external nonReentrant {
        address account = msg.sender;
        IRewardTracker(feeQlpTracker).claimForAccount(account, account);
    }

    function handleRewards(
        bool _shouldClaimWeth,
        bool _shouldConvertWethToEth,
        bool _shouldAddIntoQLP
    ) external nonReentrant {
        address account = msg.sender;

        if (_shouldClaimWeth) {
            if (_shouldConvertWethToEth || _shouldAddIntoQLP ) {
                uint256 wethAmount = IRewardTracker(feeQlpTracker).claimForAccount(account, address(this));
                

                if(_shouldAddIntoQLP){
                    _mintAndStakeQlpETH(wethAmount,0,0);
                }else{
                    IWETH(weth).withdraw(wethAmount);
                    payable(account).sendValue(wethAmount);
                }
            } else {
                IRewardTracker(feeQlpTracker).claimForAccount(account, account);
            }
        }
    }

    function signalTransfer(address _receiver) external nonReentrant {
        _validateReceiver(_receiver);
        pendingReceivers[msg.sender] = _receiver;
    }

    function acceptTransfer(address _sender) external nonReentrant {
        address receiver = msg.sender;
        require(pendingReceivers[_sender] == receiver, "RewardRouter: transfer not signalled");
        delete pendingReceivers[_sender];

        _validateReceiver(receiver);
        uint256 qlpAmount = IRewardTracker(feeQlpTracker).depositBalances(_sender, qlp);
        if (qlpAmount > 0) {
	    IRewardTracker(stakedQlpTracker).unstakeForAccount(_sender, feeQlpTracker, qlpAmount, _sender);
            IRewardTracker(feeQlpTracker).unstakeForAccount(_sender, qlp, qlpAmount, _sender);
            IRewardTracker(feeQlpTracker).stakeForAccount(_sender, receiver, qlp, qlpAmount);
	    IRewardTracker(stakedQlpTracker).stakeForAccount(receiver, receiver, feeQlpTracker, qlpAmount);
        }
    }

    function _validateReceiver(address _receiver) private view {
        require(IRewardTracker(stakedQlpTracker).averageStakedAmounts(_receiver) == 0, "RewardRouter: stakedQlpTracker.averageStakedAmounts > 0");
        require(IRewardTracker(stakedQlpTracker).cumulativeRewards(_receiver) == 0, "RewardRouter: stakedQlpTracker.cumulativeRewards > 0");

	    require(IRewardTracker(feeQlpTracker).averageStakedAmounts(_receiver) == 0, "RewardRouter: feeQlpTracker.averageStakedAmounts > 0");
        require(IRewardTracker(feeQlpTracker).cumulativeRewards(_receiver) == 0, "RewardRouter: feeQlpTracker.cumulativeRewards > 0");

    }


}
