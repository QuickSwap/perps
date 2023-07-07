// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.6.12;

import "../libraries/math/SafeMath.sol";
import "../libraries/token/IERC20.sol";
import "../libraries/token/SafeERC20.sol";

import "./interfaces/IRewardDistributor.sol";
import "./interfaces/IRewardTracker.sol";
import "../access/Governable.sol";

contract RewardDistributor is IRewardDistributor, Governable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    uint256 public constant MAX_ALL_REWARD_TOKENS = 10;

    address[] public override allRewardTokens;
    mapping (address => bool) public override allTokens;    

    mapping (address => bool) public override rewardTokens;

    uint256 public override rewardTokenCount;


    mapping (address => uint256) public override tokensPerInterval;

    mapping (address => uint256) public lastDistributionTime;

    address public rewardTracker;

    address public admin;

    event Distribute(address rewardToken, uint256 amount);
    event TokensPerIntervalChange(address rewardToken, uint256 amount);
    event AddRewardToken(address rewardToken);
    event RemoveRewardToken(address rewardToken);

    modifier onlyAdmin() {
        require(msg.sender == admin, "RewardDistributor: forbidden");
        _;
    }

    constructor( address _rewardTracker) public {
        rewardTracker = _rewardTracker;
        admin = msg.sender;
    }

    function setAdmin(address _admin) external onlyGov {
        admin = _admin;
    }

    function allRewardTokensLength() external override view returns (uint256) {
        return allRewardTokens.length;
    }

    function getAllRewardTokens() external override view returns (address[] memory) {
        address[] memory tokens = new address[](rewardTokenCount);
        uint256 index;
        uint256 length = allRewardTokens.length;
        for (uint256 i = 0; i < length; i++) {
            address token = allRewardTokens[i];
            if(!rewardTokens[token]){
                continue;
            }
            tokens[index] = token;
            index++;
        }

        return tokens;
    }

    function addRewardToken(
        address _token
    ) external override onlyAdmin{
        if (!rewardTokens[_token]) {
            if (!allTokens[_token]) {
                require(allRewardTokens.length < MAX_ALL_REWARD_TOKENS,"RewardDistributor: too many rewardTokens");
                allRewardTokens.push(_token);
                allTokens[_token] = true;
            }
            rewardTokens[_token] = true;
            rewardTokenCount++;
            emit AddRewardToken(_token);
        }
    }

    function removeRewardToken(
        address _token
    ) external override onlyAdmin{
        if(rewardTokens[_token]){
            require(tokensPerInterval[_token] == 0,"RewardDistributor: tokensPerInterval must be zero");
            delete rewardTokens[_token];
            rewardTokenCount--;
            emit RemoveRewardToken(_token);
        }
    }

    // to help users who accidentally send their tokens to this contract
    function withdrawToken(
        address _token,
        address _account,
        uint256 _amount
    ) external onlyGov {
        IERC20(_token).safeTransfer(_account, _amount);
    }

    function updateAllLastDistributionTime() external onlyAdmin {
        uint256 length = allRewardTokens.length;
        for (uint256 i = 0; i < length; i++) {
            address token = allRewardTokens[i];
            if(!rewardTokens[token]){
                continue;
            }
            _updateLastDistributionTime(token);
        }
    }

    function updateLastDistributionTime(address _rewardToken) external onlyAdmin {
        require(rewardTokens[_rewardToken], "RewardDistributor: invalid _rewardToken");
        _updateLastDistributionTime(_rewardToken);
    }

    function _updateLastDistributionTime(address _rewardToken) private {
        lastDistributionTime[_rewardToken] = block.timestamp;
    }

    function setTokensPerInterval(address _rewardToken, uint256 _amount) external onlyAdmin {
        require(rewardTokens[_rewardToken], "RewardDistributor: invalid _rewardToken");
        require(lastDistributionTime[_rewardToken] != 0, "RewardDistributor: invalid lastDistributionTime");
        IRewardTracker(rewardTracker).updateRewards(_rewardToken);
        tokensPerInterval[_rewardToken] = _amount;
        emit TokensPerIntervalChange(_rewardToken, _amount);
    }

    function pendingRewards(address _rewardToken) public view override returns (uint256) {
        require(allTokens[_rewardToken], "RewardDistributor: invalid _rewardToken");
        if (block.timestamp == lastDistributionTime[_rewardToken]) {
            return 0;
        }

        uint256 timeDiff = block.timestamp.sub(lastDistributionTime[_rewardToken]);
        return tokensPerInterval[_rewardToken].mul(timeDiff);
    }

    function distribute(address _rewardToken) external override returns (uint256) {
        require(msg.sender == rewardTracker, "RewardDistributor: invalid msg.sender");
        uint256 amount = pendingRewards(_rewardToken);
        if (amount == 0) {
            return 0;
        }

        lastDistributionTime[_rewardToken] = block.timestamp;

        uint256 balance = IERC20(_rewardToken).balanceOf(address(this));
        if (amount > balance) {
            amount = balance;
        }

        IERC20(_rewardToken).safeTransfer(msg.sender, amount);

        emit Distribute(_rewardToken, amount);
        return amount;
    }
}
