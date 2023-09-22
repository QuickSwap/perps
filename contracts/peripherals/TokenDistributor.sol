// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.18;


import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract TokenDistributor is Ownable {
    using SafeERC20 for IERC20;


    uint256 public constant MAX_ALL_REWARD_TOKENS = 5;

    address[] public  allRewardTokens;
    mapping (address => bool) public  allTokens;    

    mapping (address => bool) public  rewardTokens;

    uint256 public  rewardTokenCount;

    uint256 public bufferTime = 4 weeks;

    struct Reward{
        uint256 timestamp;
        uint256 amount;
    }

    mapping(address => mapping(address => Reward[])) public  claimableRewards;  //account => token => reward[]

    mapping(address => mapping(address => uint256)) public duplicateCheck;  // account => token => timestamp

    mapping(address => bool) public activeAccounts;

    mapping(address => uint256) public totalReward;
    mapping(address => uint256) public totalClaimed;
    mapping(address => uint256) public totalExpired;
    mapping(address => uint256) public totalExpiredWithdraw;
    
   
    event CanClaim(address indexed recipient, address indexed token, uint256 amount, uint256 timestamp);

    event ExpiredClaim(address indexed recipient, address indexed token , uint256 amount, uint256 timestamp);

    event HasClaimedWithTimestamp(address indexed recipient, address indexed token , uint256 amount, uint256 timestamp);

    event HasClaimed(address indexed recipient, address indexed token , uint256 amount);
  
    event Withdrawal(address indexed token, address indexed recipient, uint256 amount);

    event WithdrawalExpiredToken(address indexed token, address indexed recipient,  uint256 amount);

    event ActivateAccount(address indexed account, bool isActive);

    event AddRewardToken(address rewardToken);

    event RemoveRewardToken(address rewardToken);

    constructor(
        address _owner
    ) Ownable() {
        require(_owner != address(0), "TokenDistributor: zero owner address");
        _transferOwnership(_owner);
    }

    function allRewardTokensLength() external view returns (uint256) {
        return allRewardTokens.length;
    }

    function getAllRewardTokens() external view returns (address[] memory) {
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
    ) external onlyOwner{
        if (!rewardTokens[_token]) {
            if (!allTokens[_token]) {
                require(allRewardTokens.length < MAX_ALL_REWARD_TOKENS,"TokenDistributor: too many rewardTokens");
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
    ) external onlyOwner{
        if(rewardTokens[_token]){
            delete rewardTokens[_token];
            rewardTokenCount--;
            emit RemoveRewardToken(_token);
        }
    }

    function setBufferTime(uint256 _bufferTime) external onlyOwner {
        require(_bufferTime > 0, "TokenDistributor: bufferTime should be greater than zero");
        bufferTime = _bufferTime;
    }

    function withdrawExpiredToken(address _token, address _receiver ) external onlyOwner {
        require(allTokens[_token], "TokenDistributor: invalid _token");
        require(_receiver != address(0), "TokenDistributor: zero receiver address");
        require(totalExpired[_token] != 0, "TokenDistributor: totalExpired should be greater than zero");
        uint256 amount = totalExpired[_token];
        totalExpired[_token] = 0;
        unchecked {
            totalExpiredWithdraw[_token] += amount;
        }
        IERC20(_token).safeTransfer(_receiver, amount);
        emit WithdrawalExpiredToken(_token, _receiver, amount);
    }    

    function withdrawEmergencyToken(IERC20 _token, address _receiver, uint256 _amount) external onlyOwner {
        require(address(_token) != address(0), "TokenDistributor: zero token address");
        require(_receiver != address(0), "TokenDistributor: zero receiver address");
        _token.safeTransfer(_receiver, _amount);
        emit Withdrawal(address(_token), _receiver, _amount);
    }


    function setRecipients(address _token, address[] calldata _recipients, uint256[] calldata _claimableAmount)
        external
        onlyOwner
    {
        require(rewardTokens[_token], "TokenDistributor: invalid _token");
        require(
            _recipients.length == _claimableAmount.length, "TokenDistributor: invalid array length"
        );

        uint256 sumReward = totalReward[_token];
        uint256 sumExpired = totalExpired[_token];
        uint256 currentDay = (block.timestamp / 1 days) * 1 days;
        for (uint256 i = 0; i < _recipients.length; i++) {
            address recipient = _recipients[i];

            require(duplicateCheck[recipient][_token] != currentDay,"TokenDistributor: recipient already set");
            duplicateCheck[recipient][_token] = currentDay;

            uint256 claimableAmount = _claimableAmount[i];
            uint256 length = claimableRewards[recipient][_token].length;
            if(length>0 && claimableRewards[recipient][_token][0].timestamp + bufferTime < currentDay){
                Reward[] memory oldRewards = claimableRewards[recipient][_token];
                delete(claimableRewards[recipient][_token]);
                for(uint256 j = 0; j < oldRewards.length; j++) {
                    if(oldRewards[j].timestamp + bufferTime >= currentDay ){
                        claimableRewards[recipient][_token].push(oldRewards[j]);
                    }else{
                        unchecked {
                            sumExpired += oldRewards[j].amount;
                        }    
                        emit ExpiredClaim(recipient, _token, oldRewards[j].amount, oldRewards[j].timestamp);
                    }
                }  
            }

            claimableRewards[recipient][_token].push(Reward(currentDay,claimableAmount));
            emit CanClaim(recipient, _token, claimableAmount, currentDay);
            
            unchecked {
                sumReward += claimableAmount;
            }
        }
        require(IERC20(_token).balanceOf(address(this)) >= sumReward - totalExpiredWithdraw[_token] - totalClaimed[_token], "TokenDistributor: not enough balance");

        totalReward[_token] = sumReward;
        totalExpired[_token] = sumExpired;
    }

    function activateAccount(bool _isActive) external  {
        activeAccounts[msg.sender] = _isActive;
        emit ActivateAccount(msg.sender,_isActive);
    }

    function claimAll() external  returns (address[] memory,uint256[] memory) {
        uint256 length = allRewardTokens.length;

        address[] memory tokens = new address[](length);
        uint256[] memory amounts = new uint256[](length);

        for (uint256 i = 0; i < length; i++) {
            address token = allRewardTokens[i];
            tokens[i] = token;
            amounts[i] = claim(token);
        }
        return (tokens,amounts);
    }


    function claim(address _token) public returns (uint256) {
        require(allTokens[_token], "TokenDistributor: invalid _token");
        address recipient = msg.sender;
        require(activeAccounts[recipient], "TokenDistributor: not active user");
        uint256 length = claimableRewards[recipient][_token].length;
        uint256 claimableAmount;
        if(length>0){
            uint256 currentDay = (block.timestamp / 1 days) * 1 days;
            uint256 sumExpired = totalExpired[_token];
            for(uint256 i = 0; i < length; i++) {
                if(claimableRewards[recipient][_token][i].timestamp + bufferTime >= currentDay ){
                    unchecked {                        
                        claimableAmount += claimableRewards[recipient][_token][i].amount;
                    }
                    emit HasClaimedWithTimestamp(recipient, _token, claimableRewards[recipient][_token][i].amount, claimableRewards[recipient][_token][i].timestamp);
                }else{
                    unchecked {
                        sumExpired += claimableRewards[recipient][_token][i].amount;
                    }    
                    emit ExpiredClaim(recipient, _token, claimableRewards[recipient][_token][i].amount, claimableRewards[recipient][_token][i].timestamp);
                }
            }  
            delete(claimableRewards[recipient][_token]);
            totalExpired[_token] = sumExpired;
            if(claimableAmount > 0){
                unchecked {
                    totalClaimed[_token] += claimableAmount;
                }
                IERC20(_token).safeTransfer(recipient, claimableAmount);
            }
            emit HasClaimed(recipient, _token, claimableAmount);
        }
        
        return claimableAmount;

    }

    function claimableAll() external view returns (address[] memory,uint256[] memory) {
        uint256 length = allRewardTokens.length;

        address[] memory tokens = new address[](length);
        uint256[] memory amounts = new uint256[](length);

        for (uint256 i = 0; i < length; i++) {
            address token = allRewardTokens[i];
            tokens[i] = token;
            amounts[i] = _claimable(token, msg.sender);
        }
        return (tokens,amounts);
    }

    function claimable(address _token) external view returns (uint256) {
        return _claimable(_token, msg.sender);
    }

    function _claimable(address _token, address _recipient) private view returns (uint256) {
        require(allTokens[_token], "TokenDistributor: invalid _token");
        uint256 claimableAmount;

        if(activeAccounts[_recipient]){
            uint256 length = claimableRewards[_recipient][_token].length;
            if(length > 0){
                uint256 currentDay = (block.timestamp / 1 days) * 1 days;
                for(uint256 i = 0; i < length; i++) {
                    if(claimableRewards[_recipient][_token][i].timestamp + bufferTime >= currentDay ){
                        claimableAmount += claimableRewards[_recipient][_token][i].amount;
                    }
                }  
            }        
        }
        return claimableAmount;
    }

    function getActiveAccounts(address[] calldata _accounts) external view returns (bool[] memory) {
        require(_accounts.length > 0 , "TokenDistributor: invalid array length");
        bool[] memory accountList = new bool[](_accounts.length);
        for (uint256 i = 0; i < _accounts.length; i++) {
            accountList[i] = activeAccounts[_accounts[i]];
        }    
        return accountList;
    }

    function getAccountsClaimable(address _token, address[] calldata _accounts) external view returns (uint256[] memory) {
        require(_accounts.length > 0 , "TokenDistributor: invalid array length");
        uint256[] memory claimableList = new uint256[](_accounts.length);
        for (uint256 i = 0; i < _accounts.length; i++) {
            claimableList[i] = _claimable(_token, _accounts[i]);
        }    
        return claimableList;
    }

}