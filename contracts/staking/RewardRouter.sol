// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "../libraries/math/SafeMath.sol";
import "../libraries/token/IERC20.sol";
import "../libraries/token/SafeERC20.sol";
import "../libraries/utils/ReentrancyGuard.sol";
import "../libraries/utils/Address.sol";

import "./interfaces/IRewardTracker.sol";
import "./interfaces/IRewardRouterV2.sol";
import "./interfaces/IVester.sol";
import "../tokens/interfaces/IMintable.sol";
import "../tokens/interfaces/IWETH.sol";
import "../core/interfaces/IQlpManager.sol";
import "../access/Governable.sol";

contract RewardRouterV2 is IRewardRouterV2, ReentrancyGuard, Governable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using Address for address payable;

    bool public isInitialized;

    address public weth;

    address public qperp;
    address public esQperp;
    address public bnQperp;

    address public qlp; // QPERP Liquidity Provider token

    address public stakedQperpTracker;
    address public bonusQperpTracker;
    address public feeQperpTracker;

    address public override stakedQlpTracker;
    address public override feeQlpTracker;

    address public qlpManager;

    address public qperpVester;
    address public qlpVester;

    mapping (address => address) public pendingReceivers;

    event StakeQperp(address account, address token, uint256 amount);
    event UnstakeQperp(address account, address token, uint256 amount);

    event StakeQlp(address account, uint256 amount);
    event UnstakeQlp(address account, uint256 amount);

    receive() external payable {
        require(msg.sender == weth, "Router: invalid sender");
    }

    function initialize(
        address _weth,
        address _qperp,
        address _esQperp,
        address _bnQperp,
        address _qlp,
        address _stakedQperpTracker,
        address _bonusQperpTracker,
        address _feeQperpTracker,
        address _feeQlpTracker,
        address _stakedQlpTracker,
        address _qlpManager,
        address _qperpVester,
        address _qlpVester
    ) external onlyGov {
        require(!isInitialized, "RewardRouter: already initialized");
        isInitialized = true;

        weth = _weth;

        qperp = _qperp;
        esQperp = _esQperp;
        bnQperp = _bnQperp;

        qlp = _qlp;

        stakedQperpTracker = _stakedQperpTracker;
        bonusQperpTracker = _bonusQperpTracker;
        feeQperpTracker = _feeQperpTracker;

        feeQlpTracker = _feeQlpTracker;
        stakedQlpTracker = _stakedQlpTracker;

        qlpManager = _qlpManager;

        qperpVester = _qperpVester;
        qlpVester = _qlpVester;
    }

    // to help users who accidentally send their tokens to this contract
    function withdrawToken(address _token, address _account, uint256 _amount) external onlyGov {
        IERC20(_token).safeTransfer(_account, _amount);
    }

    function batchStakeQperpForAccount(address[] memory _accounts, uint256[] memory _amounts) external nonReentrant onlyGov {
        address _qperp = qperp;
        for (uint256 i = 0; i < _accounts.length; i++) {
            _stakeQperp(msg.sender, _accounts[i], _qperp, _amounts[i]);
        }
    }

    function stakeQperpForAccount(address _account, uint256 _amount) external nonReentrant onlyGov {
        _stakeQperp(msg.sender, _account, qperp, _amount);
    }

    function stakeQperp(uint256 _amount) external nonReentrant {
        _stakeQperp(msg.sender, msg.sender, qperp, _amount);
    }

    function stakeEsQperp(uint256 _amount) external nonReentrant {
        _stakeQperp(msg.sender, msg.sender, esQperp, _amount);
    }

    function unstakeQperp(uint256 _amount) external nonReentrant {
        _unstakeQperp(msg.sender, qperp, _amount, true);
    }

    function unstakeEsQperp(uint256 _amount) external nonReentrant {
        _unstakeQperp(msg.sender, esQperp, _amount, true);
    }

    function mintAndStakeQlp(address _token, uint256 _amount, uint256 _minUsdq, uint256 _minQlp) external nonReentrant returns (uint256) {
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
        IERC20(weth).approve(qlpManager, msg.value);

        address account = msg.sender;
        uint256 qlpAmount = IQlpManager(qlpManager).addLiquidityForAccount(address(this), account, weth, msg.value, _minUsdq, _minQlp);

        IRewardTracker(feeQlpTracker).stakeForAccount(account, account, qlp, qlpAmount);
        IRewardTracker(stakedQlpTracker).stakeForAccount(account, account, feeQlpTracker, qlpAmount);

        emit StakeQlp(account, qlpAmount);

        return qlpAmount;
    }

    function unstakeAndRedeemQlp(address _tokenOut, uint256 _qlpAmount, uint256 _minOut, address _receiver) external nonReentrant returns (uint256) {
        require(_qlpAmount > 0, "RewardRouter: invalid _qlpAmount");

        address account = msg.sender;
        IRewardTracker(stakedQlpTracker).unstakeForAccount(account, feeQlpTracker, _qlpAmount, account);
        IRewardTracker(feeQlpTracker).unstakeForAccount(account, qlp, _qlpAmount, account);
        uint256 amountOut = IQlpManager(qlpManager).removeLiquidityForAccount(account, _tokenOut, _qlpAmount, _minOut, _receiver);

        emit UnstakeQlp(account, _qlpAmount);

        return amountOut;
    }

    function unstakeAndRedeemQlpETH(uint256 _qlpAmount, uint256 _minOut, address payable _receiver) external nonReentrant returns (uint256) {
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

        IRewardTracker(feeQperpTracker).claimForAccount(account, account);
        IRewardTracker(feeQlpTracker).claimForAccount(account, account);

        IRewardTracker(stakedQperpTracker).claimForAccount(account, account);
        IRewardTracker(stakedQlpTracker).claimForAccount(account, account);
    }

    function claimEsQperp() external nonReentrant {
        address account = msg.sender;

        IRewardTracker(stakedQperpTracker).claimForAccount(account, account);
        IRewardTracker(stakedQlpTracker).claimForAccount(account, account);
    }

    function claimFees() external nonReentrant {
        address account = msg.sender;

        IRewardTracker(feeQperpTracker).claimForAccount(account, account);
        IRewardTracker(feeQlpTracker).claimForAccount(account, account);
    }

    function compound() external nonReentrant {
        _compound(msg.sender);
    }

    function compoundForAccount(address _account) external nonReentrant onlyGov {
        _compound(_account);
    }

    function handleRewards(
        bool _shouldClaimQperp,
        bool _shouldStakeQperp,
        bool _shouldClaimEsQperp,
        bool _shouldStakeEsQperp,
        bool _shouldStakeMultiplierPoints,
        bool _shouldClaimWeth,
        bool _shouldConvertWethToEth
    ) external nonReentrant {
        address account = msg.sender;

        uint256 qperpAmount = 0;
        if (_shouldClaimQperp) {
            uint256 qperpAmount0 = IVester(qperpVester).claimForAccount(account, account);
            uint256 qperpAmount1 = IVester(qlpVester).claimForAccount(account, account);
            qperpAmount = qperpAmount0.add(qperpAmount1);
        }

        if (_shouldStakeQperp && qperpAmount > 0) {
            _stakeQperp(account, account, qperp, qperpAmount);
        }

        uint256 esQperpAmount = 0;
        if (_shouldClaimEsQperp) {
            uint256 esQperpAmount0 = IRewardTracker(stakedQperpTracker).claimForAccount(account, account);
            uint256 esQperpAmount1 = IRewardTracker(stakedQlpTracker).claimForAccount(account, account);
            esQperpAmount = esQperpAmount0.add(esQperpAmount1);
        }

        if (_shouldStakeEsQperp && esQperpAmount > 0) {
            _stakeQperp(account, account, esQperp, esQperpAmount);
        }

        if (_shouldStakeMultiplierPoints) {
            uint256 bnQperpAmount = IRewardTracker(bonusQperpTracker).claimForAccount(account, account);
            if (bnQperpAmount > 0) {
                IRewardTracker(feeQperpTracker).stakeForAccount(account, account, bnQperp, bnQperpAmount);
            }
        }

        if (_shouldClaimWeth) {
            if (_shouldConvertWethToEth) {
                uint256 weth0 = IRewardTracker(feeQperpTracker).claimForAccount(account, address(this));
                uint256 weth1 = IRewardTracker(feeQlpTracker).claimForAccount(account, address(this));

                uint256 wethAmount = weth0.add(weth1);
                IWETH(weth).withdraw(wethAmount);

                payable(account).sendValue(wethAmount);
            } else {
                IRewardTracker(feeQperpTracker).claimForAccount(account, account);
                IRewardTracker(feeQlpTracker).claimForAccount(account, account);
            }
        }
    }

    function batchCompoundForAccounts(address[] memory _accounts) external nonReentrant onlyGov {
        for (uint256 i = 0; i < _accounts.length; i++) {
            _compound(_accounts[i]);
        }
    }

    function signalTransfer(address _receiver) external nonReentrant {
        require(IERC20(qperpVester).balanceOf(msg.sender) == 0, "RewardRouter: sender has vested tokens");
        require(IERC20(qlpVester).balanceOf(msg.sender) == 0, "RewardRouter: sender has vested tokens");

        _validateReceiver(_receiver);
        pendingReceivers[msg.sender] = _receiver;
    }

    function acceptTransfer(address _sender) external nonReentrant {
        require(IERC20(qperpVester).balanceOf(_sender) == 0, "RewardRouter: sender has vested tokens");
        require(IERC20(qlpVester).balanceOf(_sender) == 0, "RewardRouter: sender has vested tokens");

        address receiver = msg.sender;
        require(pendingReceivers[_sender] == receiver, "RewardRouter: transfer not signalled");
        delete pendingReceivers[_sender];

        _validateReceiver(receiver);
        _compound(_sender);

        uint256 stakedQperp = IRewardTracker(stakedQperpTracker).depositBalances(_sender, qperp);
        if (stakedQperp > 0) {
            _unstakeQperp(_sender, qperp, stakedQperp, false);
            _stakeQperp(_sender, receiver, qperp, stakedQperp);
        }

        uint256 stakedEsQperp = IRewardTracker(stakedQperpTracker).depositBalances(_sender, esQperp);
        if (stakedEsQperp > 0) {
            _unstakeQperp(_sender, esQperp, stakedEsQperp, false);
            _stakeQperp(_sender, receiver, esQperp, stakedEsQperp);
        }

        uint256 stakedBnQperp = IRewardTracker(feeQperpTracker).depositBalances(_sender, bnQperp);
        if (stakedBnQperp > 0) {
            IRewardTracker(feeQperpTracker).unstakeForAccount(_sender, bnQperp, stakedBnQperp, _sender);
            IRewardTracker(feeQperpTracker).stakeForAccount(_sender, receiver, bnQperp, stakedBnQperp);
        }

        uint256 esQperpBalance = IERC20(esQperp).balanceOf(_sender);
        if (esQperpBalance > 0) {
            IERC20(esQperp).transferFrom(_sender, receiver, esQperpBalance);
        }

        uint256 qlpAmount = IRewardTracker(feeQlpTracker).depositBalances(_sender, qlp);
        if (qlpAmount > 0) {
            IRewardTracker(stakedQlpTracker).unstakeForAccount(_sender, feeQlpTracker, qlpAmount, _sender);
            IRewardTracker(feeQlpTracker).unstakeForAccount(_sender, qlp, qlpAmount, _sender);

            IRewardTracker(feeQlpTracker).stakeForAccount(_sender, receiver, qlp, qlpAmount);
            IRewardTracker(stakedQlpTracker).stakeForAccount(receiver, receiver, feeQlpTracker, qlpAmount);
        }

        IVester(qperpVester).transferStakeValues(_sender, receiver);
        IVester(qlpVester).transferStakeValues(_sender, receiver);
    }

    function _validateReceiver(address _receiver) private view {
        require(IRewardTracker(stakedQperpTracker).averageStakedAmounts(_receiver) == 0, "RewardRouter: stakedQperpTracker.averageStakedAmounts > 0");
        require(IRewardTracker(stakedQperpTracker).cumulativeRewards(_receiver) == 0, "RewardRouter: stakedQperpTracker.cumulativeRewards > 0");

        require(IRewardTracker(bonusQperpTracker).averageStakedAmounts(_receiver) == 0, "RewardRouter: bonusQperpTracker.averageStakedAmounts > 0");
        require(IRewardTracker(bonusQperpTracker).cumulativeRewards(_receiver) == 0, "RewardRouter: bonusQperpTracker.cumulativeRewards > 0");

        require(IRewardTracker(feeQperpTracker).averageStakedAmounts(_receiver) == 0, "RewardRouter: feeQperpTracker.averageStakedAmounts > 0");
        require(IRewardTracker(feeQperpTracker).cumulativeRewards(_receiver) == 0, "RewardRouter: feeQperpTracker.cumulativeRewards > 0");

        require(IVester(qperpVester).transferredAverageStakedAmounts(_receiver) == 0, "RewardRouter: qperpVester.transferredAverageStakedAmounts > 0");
        require(IVester(qperpVester).transferredCumulativeRewards(_receiver) == 0, "RewardRouter: qperpVester.transferredCumulativeRewards > 0");

        require(IRewardTracker(stakedQlpTracker).averageStakedAmounts(_receiver) == 0, "RewardRouter: stakedQlpTracker.averageStakedAmounts > 0");
        require(IRewardTracker(stakedQlpTracker).cumulativeRewards(_receiver) == 0, "RewardRouter: stakedQlpTracker.cumulativeRewards > 0");

        require(IRewardTracker(feeQlpTracker).averageStakedAmounts(_receiver) == 0, "RewardRouter: feeQlpTracker.averageStakedAmounts > 0");
        require(IRewardTracker(feeQlpTracker).cumulativeRewards(_receiver) == 0, "RewardRouter: feeQlpTracker.cumulativeRewards > 0");

        require(IVester(qlpVester).transferredAverageStakedAmounts(_receiver) == 0, "RewardRouter: qperpVester.transferredAverageStakedAmounts > 0");
        require(IVester(qlpVester).transferredCumulativeRewards(_receiver) == 0, "RewardRouter: qperpVester.transferredCumulativeRewards > 0");

        require(IERC20(qperpVester).balanceOf(_receiver) == 0, "RewardRouter: qperpVester.balance > 0");
        require(IERC20(qlpVester).balanceOf(_receiver) == 0, "RewardRouter: qlpVester.balance > 0");
    }

    function _compound(address _account) private {
        _compoundQperp(_account);
        _compoundQlp(_account);
    }

    function _compoundQperp(address _account) private {
        uint256 esQperpAmount = IRewardTracker(stakedQperpTracker).claimForAccount(_account, _account);
        if (esQperpAmount > 0) {
            _stakeQperp(_account, _account, esQperp, esQperpAmount);
        }

        uint256 bnQperpAmount = IRewardTracker(bonusQperpTracker).claimForAccount(_account, _account);
        if (bnQperpAmount > 0) {
            IRewardTracker(feeQperpTracker).stakeForAccount(_account, _account, bnQperp, bnQperpAmount);
        }
    }

    function _compoundQlp(address _account) private {
        uint256 esQperpAmount = IRewardTracker(stakedQlpTracker).claimForAccount(_account, _account);
        if (esQperpAmount > 0) {
            _stakeQperp(_account, _account, esQperp, esQperpAmount);
        }
    }

    function _stakeQperp(address _fundingAccount, address _account, address _token, uint256 _amount) private {
        require(_amount > 0, "RewardRouter: invalid _amount");

        IRewardTracker(stakedQperpTracker).stakeForAccount(_fundingAccount, _account, _token, _amount);
        IRewardTracker(bonusQperpTracker).stakeForAccount(_account, _account, stakedQperpTracker, _amount);
        IRewardTracker(feeQperpTracker).stakeForAccount(_account, _account, bonusQperpTracker, _amount);

        emit StakeQperp(_account, _token, _amount);
    }

    function _unstakeQperp(address _account, address _token, uint256 _amount, bool _shouldReduceBnQperp) private {
        require(_amount > 0, "RewardRouter: invalid _amount");

        uint256 balance = IRewardTracker(stakedQperpTracker).stakedAmounts(_account);

        IRewardTracker(feeQperpTracker).unstakeForAccount(_account, bonusQperpTracker, _amount, _account);
        IRewardTracker(bonusQperpTracker).unstakeForAccount(_account, stakedQperpTracker, _amount, _account);
        IRewardTracker(stakedQperpTracker).unstakeForAccount(_account, _token, _amount, _account);

        if (_shouldReduceBnQperp) {
            uint256 bnQperpAmount = IRewardTracker(bonusQperpTracker).claimForAccount(_account, _account);
            if (bnQperpAmount > 0) {
                IRewardTracker(feeQperpTracker).stakeForAccount(_account, _account, bnQperp, bnQperpAmount);
            }

            uint256 stakedBnQperp = IRewardTracker(feeQperpTracker).depositBalances(_account, bnQperp);
            if (stakedBnQperp > 0) {
                uint256 reductionAmount = stakedBnQperp.mul(_amount).div(balance);
                IRewardTracker(feeQperpTracker).unstakeForAccount(_account, bnQperp, reductionAmount, _account);
                IMintable(bnQperp).burn(_account, reductionAmount);
            }
        }

        emit UnstakeQperp(_account, _token, _amount);
    }
}
