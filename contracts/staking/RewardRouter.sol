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
import "./../core/interfaces/IVault.sol";
import "./interfaces/IRewardTrackerClaim.sol";

contract RewardRouter is ReentrancyGuard, Governable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using Address for address payable;

    address public immutable weth;

    address public immutable qlp; 

    address public immutable feeQlpTracker;

    address public immutable qlpManager;

    address public immutable oldStakedQlpTracker;   //For migration
    address public immutable oldFeeQlpTracker;      //For migration  

    IVault public immutable vault;




    mapping(address => address) public pendingReceivers;

    event StakeQlp(address indexed account, uint256 amount);
    event UnstakeQlp(address indexed account, uint256 amount);
    event StakeMigration(address indexed account, uint256 amount);

    receive() external payable {
        require(msg.sender == weth, "Router: invalid sender");
    }

    constructor(
        address _weth,
        address _qlp,
        address _vault,
        address _feeQlpTracker,
        address _qlpManager,
        address _oldStakedQlpTracker,
        address _oldFeeQlpTracker
    ) public{
        weth = _weth;
        qlp = _qlp;
        vault = IVault(_vault);    

        feeQlpTracker = _feeQlpTracker;

        qlpManager = _qlpManager;

        oldStakedQlpTracker = _oldStakedQlpTracker;
        oldFeeQlpTracker = _oldFeeQlpTracker;  

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

        return _mintAndStakeQlp(msg.sender,msg.sender,_token, _amount, _minUsdq, _minQlp);
    }

    function _mintAndStakeQlp(
        address fundingAccount,
        address account,
        address _token,
        uint256 _amount,
        uint256 _minUsdq,
        uint256 _minQlp
    ) private returns (uint256) {

        uint256 qlpAmount = IQlpManager(qlpManager).addLiquidityForAccount(fundingAccount, account, _token, _amount, _minUsdq, _minQlp);
        IRewardTracker(feeQlpTracker).stakeForAccount(account, account, qlp, qlpAmount);

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
        IRewardTracker(feeQlpTracker).unstakeForAccount(account, qlp, _qlpAmount, account);
        uint256 amountOut = IQlpManager(qlpManager).removeLiquidityForAccount(account, weth, _qlpAmount, _minOut, address(this));

        IWETH(weth).withdraw(amountOut);

        _receiver.sendValue(amountOut);

        emit UnstakeQlp(account, _qlpAmount);

        return amountOut;
    }

    function claim(address _rewardToken, bool _shouldAddIntoQLP, bool withdrawEth) external nonReentrant {
        require(IRewardTracker(feeQlpTracker).allTokens(_rewardToken), "RewardRouter: invalid _rewardToken");
        address account = msg.sender;
        if(_shouldAddIntoQLP && vault.whitelistedTokens(_rewardToken)){ 
            uint256 amount = IRewardTracker(feeQlpTracker).claimForAccount(account, _rewardToken, address(this));
            if(amount>0){
                if(_rewardToken == weth){
                    _mintAndStakeQlpETH(amount,0,0);
                }else{
                    IERC20(_rewardToken).approve(qlpManager, amount);
                    _mintAndStakeQlp(address(this),account,_rewardToken,amount,0,0);
                }
            }   
        }else if(withdrawEth && _rewardToken == weth){
            uint256 amount = IRewardTracker(feeQlpTracker).claimForAccount(account, _rewardToken, address(this));
            if(amount>0){
                IWETH(weth).withdraw(amount);
                payable(account).sendValue(amount);
            }
        }else{
            IRewardTracker(feeQlpTracker).claimForAccount(account, _rewardToken, account);
        }
    }

    function claimOldFees() external nonReentrant {
        address account = msg.sender;
        IRewardTrackerClaim(oldFeeQlpTracker).claimForAccount(account, account);
    }


    function handleRewards(
        bool _shouldConvertWethToEth,
        bool _shouldAddIntoQLP
    ) external nonReentrant {
        address account = msg.sender;
        if (_shouldConvertWethToEth || _shouldAddIntoQLP ) {
            (address[] memory tokens,uint256[] memory amounts) = IRewardTracker(feeQlpTracker).claimAllForAccount(account, address(this));
            for (uint256 i = 0; i < tokens.length; i++) {
                address token = tokens[i];
                uint256 amount = amounts[i];
                if(amount>0){
                    if(_shouldAddIntoQLP && vault.whitelistedTokens(token)){ 
                        if(token == weth){
                            _mintAndStakeQlpETH(amount,0,0);
                        }else{
                            IERC20(token).approve(qlpManager, amount);
                            _mintAndStakeQlp(address(this),account,token,amount,0,0);
                        }
                    }else if(_shouldConvertWethToEth && token == weth ){
                        IWETH(weth).withdraw(amount);
                        payable(account).sendValue(amount);
                    }else{
                        IERC20(token).safeTransfer(account, amount);
                    }    
                }         
            }    
        } else {
            IRewardTracker(feeQlpTracker).claimAllForAccount(account, account);
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
            IRewardTracker(feeQlpTracker).unstakeForAccount(_sender, qlp, qlpAmount, _sender);
            IRewardTracker(feeQlpTracker).stakeForAccount(_sender, receiver, qlp, qlpAmount);
        }
    }

    function _validateReceiver(address _receiver) private view {
	    require(IRewardTracker(feeQlpTracker).averageStakedAmounts(_receiver) == 0, "RewardRouter: feeQlpTracker.averageStakedAmounts > 0");
        require(!IRewardTracker(feeQlpTracker).hasCumulativeRewards(_receiver), "RewardRouter: feeQlpTracker.cumulativeRewards > 0");
    }

    function migrateStaking() external nonReentrant {
        address account = msg.sender;
        uint256 qlpAmount = IRewardTracker(oldFeeQlpTracker).depositBalances(account, qlp);
        if (qlpAmount > 0) {
            IRewardTracker(oldStakedQlpTracker).unstakeForAccount(account, oldFeeQlpTracker, qlpAmount, account);
            IRewardTracker(oldFeeQlpTracker).unstakeForAccount(account, qlp, qlpAmount, account);            
            IRewardTracker(feeQlpTracker).stakeForAccount(account, account, qlp, qlpAmount);
            IRewardTrackerClaim(oldFeeQlpTracker).claimForAccount(account, account);
            emit StakeMigration(account, qlpAmount);
        }
    }


}
