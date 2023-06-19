// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "../libraries/math/SafeMath.sol";
import "../libraries/token/IERC20.sol";
import "../libraries/token/SafeERC20.sol";
import "../libraries/utils/ReentrancyGuard.sol";

import "./interfaces/IRewardDistributor.sol";
import "./interfaces/IRewardTracker.sol";
import "../access/Governable.sol";

contract RewardTracker is IERC20, ReentrancyGuard, IRewardTracker, Governable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    uint256 public constant BASIS_POINTS_DIVISOR = 10000;
    uint256 public constant PRECISION = 1e30;

    uint8 public constant decimals = 18;

    bool public isInitialized;

    string public name;
    string public symbol;

    address public distributor;
    mapping(address => bool) public isDepositToken;
    mapping(address => mapping(address => uint256)) public override depositBalances;
    mapping(address => uint256) public totalDepositSupply;

    uint256 public override totalSupply;
    mapping(address => uint256) public balances;
    mapping(address => mapping(address => uint256)) public allowances;

    mapping(address => uint256) public  cumulativeRewardPerToken;

    mapping(address => uint256) public override stakedAmounts;
    mapping(address => mapping(address => uint256)) public  claimableReward;

    mapping(address => mapping(address => uint256)) public previousCumulatedRewardPerToken;

    mapping(address => mapping(address => uint256)) public override cumulativeRewards;

    mapping(address => uint256) public override averageStakedAmounts;


    bool public inPrivateTransferMode;
    bool public inPrivateStakingMode;
    bool public inPrivateClaimingMode;
    mapping(address => bool) public isHandler;

    event Claim(address indexed receiver,address  rewardToken, uint256 amount);

    constructor(string memory _name, string memory _symbol) public {
        name = _name;
        symbol = _symbol;
    }

    function initialize(address[] memory _depositTokens, address _distributor) external onlyGov {
        require(!isInitialized, "RewardTracker: already initialized");
        isInitialized = true;

        for (uint256 i = 0; i < _depositTokens.length; i++) {
            address depositToken = _depositTokens[i];
            isDepositToken[depositToken] = true;
        }

        distributor = _distributor;
    }

    function setDepositToken(address _depositToken, bool _isDepositToken) external onlyGov {
        isDepositToken[_depositToken] = _isDepositToken;
    }

    function setInPrivateTransferMode(bool _inPrivateTransferMode) external onlyGov {
        inPrivateTransferMode = _inPrivateTransferMode;
    }

    function setInPrivateStakingMode(bool _inPrivateStakingMode) external onlyGov {
        inPrivateStakingMode = _inPrivateStakingMode;
    }

    function setInPrivateClaimingMode(bool _inPrivateClaimingMode) external onlyGov {
        inPrivateClaimingMode = _inPrivateClaimingMode;
    }

    function setHandler(address _handler, bool _isActive) external onlyGov {
        isHandler[_handler] = _isActive;
    }

    // to help users who accidentally send their tokens to this contract
    function withdrawToken(
        address _token,
        address _account,
        uint256 _amount
    ) external onlyGov {
        IERC20(_token).safeTransfer(_account, _amount);
    }

    function balanceOf(address _account) external view override returns (uint256) {
        return balances[_account];
    }

    function stake(address _depositToken, uint256 _amount) external override nonReentrant {
        if (inPrivateStakingMode) {
            revert("RewardTracker: action not enabled");
        }
        _stake(msg.sender, msg.sender, _depositToken, _amount);
    }

    function stakeForAccount(
        address _fundingAccount,
        address _account,
        address _depositToken,
        uint256 _amount
    ) external override nonReentrant {
        _validateHandler();
        _stake(_fundingAccount, _account, _depositToken, _amount);
    }

    function unstake(address _depositToken, uint256 _amount) external override nonReentrant {
        if (inPrivateStakingMode) {
            revert("RewardTracker: action not enabled");
        }
        _unstake(msg.sender, _depositToken, _amount, msg.sender);
    }

    function unstakeForAccount(
        address _account,
        address _depositToken,
        uint256 _amount,
        address _receiver
    ) external override nonReentrant {
        _validateHandler();
        _unstake(_account, _depositToken, _amount, _receiver);
    }

    function transfer(address _recipient, uint256 _amount) external override returns (bool) {
        _transfer(msg.sender, _recipient, _amount);
        return true;
    }

    function allowance(address _owner, address _spender) external view override returns (uint256) {
        return allowances[_owner][_spender];
    }

    function approve(address _spender, uint256 _amount) external override returns (bool) {
        _approve(msg.sender, _spender, _amount);
        return true;
    }

    function transferFrom(
        address _sender,
        address _recipient,
        uint256 _amount
    ) external override returns (bool) {
        if (isHandler[msg.sender]) {
            _transfer(_sender, _recipient, _amount);
            return true;
        }

        uint256 nextAllowance = allowances[_sender][msg.sender].sub(_amount, "RewardTracker: transfer amount exceeds allowance");
        _approve(_sender, msg.sender, nextAllowance);
        _transfer(_sender, _recipient, _amount);
        return true;
    }

    function tokensPerInterval(address _rewardToken) external view override returns (uint256) {
        return IRewardDistributor(distributor).tokensPerInterval(_rewardToken);
    }

    function updateRewards(address _rewardToken) external override nonReentrant {
        require(IRewardDistributor(distributor).allTokens(_rewardToken), "RewardTracker: invalid _rewardToken");
        _updateRewards(address(0),_rewardToken);
    }

    function hasCumulativeRewards(address _account) external view override returns (bool) {
        uint256 length = IRewardDistributor(distributor).allRewardTokensLength();
        for (uint256 i = 0; i < length; i++) {
            address token = IRewardDistributor(distributor).allRewardTokens(i);
            if(cumulativeRewards[_account][token]>0){
                return true;
            }
        }
        return false;
    }

    function claimAll(address _receiver) external override nonReentrant returns (address[] memory,uint256[] memory) {
        if (inPrivateClaimingMode) {
            revert("RewardTracker: action not enabled");
        }
        return _claimAll(msg.sender, _receiver);
    }

    function claim(address _rewardToken, address _receiver) external override nonReentrant returns (uint256) {
        if (inPrivateClaimingMode) {
            revert("RewardTracker: action not enabled");
        }
        require(IRewardDistributor(distributor).allTokens(_rewardToken), "RewardTracker: invalid _rewardToken");
        return _claim(msg.sender, _rewardToken, _receiver);
    }

    function claimAllForAccount(address _account, address _receiver) external override nonReentrant returns (address[] memory,uint256[] memory) {
        _validateHandler();
        return _claimAll(_account, _receiver);
    }

    function _claimAll(address _account, address _receiver) private returns (address[] memory,uint256[] memory) {
        uint256 length = IRewardDistributor(distributor).allRewardTokensLength();

        address[] memory tokens = new address[](length);
        uint256[] memory amounts = new uint256[](length);

        for (uint256 i = 0; i < length; i++) {
            address token = IRewardDistributor(distributor).allRewardTokens(i);
            tokens[i] = token;
            amounts[i] = _claim(_account, token, _receiver);
        }
        return (tokens,amounts);
    }

    function claimForAccount(address _account, address _rewardToken, address _receiver) external override nonReentrant returns (uint256) {
        _validateHandler();
        require(IRewardDistributor(distributor).allTokens(_rewardToken), "RewardTracker: invalid _rewardToken");
        return _claim(_account, _rewardToken, _receiver);
    }

    function claimableAll(address _account) external view override returns (address[] memory,uint256[] memory) {
       
        uint256 length = IRewardDistributor(distributor).allRewardTokensLength();

        address[] memory tokens = new address[](length);
        uint256[] memory amounts = new uint256[](length);

        for (uint256 i = 0; i < length; i++) {
            address token = IRewardDistributor(distributor).allRewardTokens(i);
            uint256 amount = claimable(_account, token);
            tokens[i] = token;
            amounts[i] = amount;
        }
        return (tokens,amounts);
    }


    function claimable(address _account, address _rewardToken) public view override returns (uint256) {
        require(IRewardDistributor(distributor).allTokens(_rewardToken), "RewardTracker: invalid _rewardToken");
        uint256 stakedAmount = stakedAmounts[_account];
        if (stakedAmount == 0) {
            return claimableReward[_account][_rewardToken];
        }
        uint256 supply = totalSupply;
        uint256 pendingRewards = IRewardDistributor(distributor).pendingRewards(_rewardToken).mul(PRECISION);
        uint256 nextCumulativeRewardPerToken = cumulativeRewardPerToken[_rewardToken].add(pendingRewards.div(supply));
        return claimableReward[_account][_rewardToken].add(stakedAmount.mul(nextCumulativeRewardPerToken.sub(previousCumulatedRewardPerToken[_account][_rewardToken])).div(PRECISION));
    }

    function getAllRewardTokens() external override view returns (address[] memory) {
        return IRewardDistributor(distributor).getAllRewardTokens();
    }

    function rewardTokens(address _rewardToken) external override view returns (bool) {
        return IRewardDistributor(distributor).rewardTokens(_rewardToken);
    }

    function allTokens(address _rewardToken) external override view returns (bool) {
        return IRewardDistributor(distributor).allTokens(_rewardToken);
    }


    function _claim(address _account, address _rewardToken, address _receiver) private returns (uint256) {
        _updateRewards(_account, _rewardToken);

        uint256 tokenAmount = claimableReward[_account][_rewardToken];
        claimableReward[_account][_rewardToken] = 0;

        if (tokenAmount > 0) {
            IERC20(_rewardToken).safeTransfer(_receiver, tokenAmount);
            emit Claim(_account, _rewardToken, tokenAmount);
        }

        return tokenAmount;
    }

    function _mint(address _account, uint256 _amount) internal {
        require(_account != address(0), "RewardTracker: mint to the zero address");

        totalSupply = totalSupply.add(_amount);
        balances[_account] = balances[_account].add(_amount);

        emit Transfer(address(0), _account, _amount);
    }

    function _burn(address _account, uint256 _amount) internal {
        require(_account != address(0), "RewardTracker: burn from the zero address");

        balances[_account] = balances[_account].sub(_amount, "RewardTracker: burn amount exceeds balance");
        totalSupply = totalSupply.sub(_amount);

        emit Transfer(_account, address(0), _amount);
    }

    function _transfer(
        address _sender,
        address _recipient,
        uint256 _amount
    ) private {
        require(_sender != address(0), "RewardTracker: transfer from the zero address");
        require(_recipient != address(0), "RewardTracker: transfer to the zero address");

        if (inPrivateTransferMode) {
            _validateHandler();
        }

        balances[_sender] = balances[_sender].sub(_amount, "RewardTracker: transfer amount exceeds balance");
        balances[_recipient] = balances[_recipient].add(_amount);

        emit Transfer(_sender, _recipient, _amount);
    }

    function _approve(
        address _owner,
        address _spender,
        uint256 _amount
    ) private {
        require(_owner != address(0), "RewardTracker: approve from the zero address");
        require(_spender != address(0), "RewardTracker: approve to the zero address");

        allowances[_owner][_spender] = _amount;

        emit Approval(_owner, _spender, _amount);
    }

    function _validateHandler() private view {
        require(isHandler[msg.sender], "RewardTracker: forbidden");
    }

    function _stake(
        address _fundingAccount,
        address _account,
        address _depositToken,
        uint256 _amount
    ) private {
        require(_amount > 0, "RewardTracker: invalid _amount");
        require(isDepositToken[_depositToken], "RewardTracker: invalid _depositToken");

        IERC20(_depositToken).safeTransferFrom(_fundingAccount, address(this), _amount);

        _updateRewardsAll(_account);

        stakedAmounts[_account] = stakedAmounts[_account].add(_amount);
        depositBalances[_account][_depositToken] = depositBalances[_account][_depositToken].add(_amount);
        totalDepositSupply[_depositToken] = totalDepositSupply[_depositToken].add(_amount);

        _mint(_account, _amount);
    }

    function _unstake(
        address _account,
        address _depositToken,
        uint256 _amount,
        address _receiver
    ) private {
        require(_amount > 0, "RewardTracker: invalid _amount");
        require(isDepositToken[_depositToken], "RewardTracker: invalid _depositToken");

        _updateRewardsAll(_account);

        uint256 stakedAmount = stakedAmounts[_account];
        require(stakedAmounts[_account] >= _amount, "RewardTracker: _amount exceeds stakedAmount");

        stakedAmounts[_account] = stakedAmount.sub(_amount);

        uint256 depositBalance = depositBalances[_account][_depositToken];
        require(depositBalance >= _amount, "RewardTracker: _amount exceeds depositBalance");
        depositBalances[_account][_depositToken] = depositBalance.sub(_amount);
        totalDepositSupply[_depositToken] = totalDepositSupply[_depositToken].sub(_amount);

        _burn(_account, _amount);
        IERC20(_depositToken).safeTransfer(_receiver, _amount);
    }

    function _updateRewardsAll(address _account) private {
        uint256 length = IRewardDistributor(distributor).allRewardTokensLength();
        for (uint256 i = 0; i < length; i++) {
            address token = IRewardDistributor(distributor).allRewardTokens(i);
            _updateRewards(_account, token);
        }
    }



    function _updateRewards(address _account, address _rewardToken) private {
        uint256 blockReward = IRewardDistributor(distributor).distribute(_rewardToken);

        uint256 supply = totalSupply;
        uint256 _cumulativeRewardPerToken = cumulativeRewardPerToken[_rewardToken];
        if (supply > 0 && blockReward > 0) {
            _cumulativeRewardPerToken = _cumulativeRewardPerToken.add(blockReward.mul(PRECISION).div(supply));
            cumulativeRewardPerToken[_rewardToken] = _cumulativeRewardPerToken;
        }

        // cumulativeRewardPerToken can only increase
        // so if cumulativeRewardPerToken is zero, it means there are no rewards yet
        if (_cumulativeRewardPerToken == 0) {
            return;
        }

        if (_account != address(0)) {
            _updateAccountRewards(_account, _rewardToken, _cumulativeRewardPerToken);
        }
    }

    function _updateAccountRewards(address _account, address _rewardToken, uint256 _cumulativeRewardPerToken) private {
        uint256 stakedAmount = stakedAmounts[_account];
        uint256 accountReward = stakedAmount.mul(_cumulativeRewardPerToken.sub(previousCumulatedRewardPerToken[_account][_rewardToken])).div(PRECISION);
        uint256 _claimableReward = claimableReward[_account][_rewardToken].add(accountReward);

        claimableReward[_account][_rewardToken] = _claimableReward;
        previousCumulatedRewardPerToken[_account][_rewardToken] = _cumulativeRewardPerToken;

        if (_claimableReward > 0 && stakedAmounts[_account] > 0) {
            uint256 nextCumulativeReward = cumulativeRewards[_account][_rewardToken].add(accountReward);

            averageStakedAmounts[_account] = averageStakedAmounts[_account].mul(cumulativeRewards[_account][_rewardToken]).div(nextCumulativeReward).add(
                stakedAmount.mul(accountReward).div(nextCumulativeReward)
            );

            cumulativeRewards[_account][_rewardToken] = nextCumulativeReward;
        }
    }

}
