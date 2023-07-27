// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.18;


import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract TokenDistributor is Ownable {
    using SafeERC20 for IERC20;


    IERC20 public immutable token;
    uint256 public bufferTime = 4 weeks;

    struct Reward{
        uint256 timestamp;
        uint256 amount;
    }
    mapping(address => Reward[]) public claimableRewards;

    mapping(address => uint256) public duplicateCheck;

    mapping(address => bool) public activeAccounts;

    uint256 public totalReward;
    uint256 public totalClaimed;
    uint256 public totalExpired;
    uint256 public totalExpiredWithdraw;
    
   
    event CanClaim(address indexed recipient, uint256 amount, uint256 timestamp);

    event ExpiredClaim(address indexed recipient, uint256 amount, uint256 timestamp);

    event HasClaimedWithTimestamp(address indexed recipient, uint256 amount, uint256 timestamp);

    event HasClaimed(address indexed recipient, uint256 amount);
  
    event Withdrawal(address indexed token, address indexed recipient, uint256 amount);

    event WithdrawalExpiredToken(address indexed recipient, uint256 amount);

    event ActivateAccount(address indexed account, bool isActive);

    constructor(
        IERC20 _token,
        address _owner
    ) Ownable() {
        require(address(_token) != address(0), "TokenDistributor: zero token address");
        require(_owner != address(0), "TokenDistributor: zero owner address");

        token = _token;
        _transferOwnership(_owner);
    }

    function setBufferTime(uint256 _bufferTime) external onlyOwner {
        require(_bufferTime > 0, "TokenDistributor: bufferTime should be greater than zero");
        bufferTime = _bufferTime;
    }

    function withdrawExpiredToken(address _receiver) external onlyOwner {
        require(_receiver != address(0), "TokenDistributor: zero receiver address");
        require(totalExpired != 0, "TokenDistributor: totalExpired should be greater than zero");
        uint256 amount = totalExpired;
        totalExpired = 0;
        unchecked {
            totalExpiredWithdraw += amount;
        }
        token.safeTransfer(_receiver, amount);
        emit WithdrawalExpiredToken(_receiver, amount);
    }    

    function withdrawEmergencyToken(IERC20 _token, address _receiver, uint256 _amount) external onlyOwner {
        require(address(_token) != address(0), "TokenDistributor: zero token address");
        require(_receiver != address(0), "TokenDistributor: zero receiver address");
        _token.safeTransfer(_receiver, _amount);
        emit Withdrawal(address(_token), _receiver, _amount);
    }


    function setRecipients(address[] calldata _recipients, uint256[] calldata _claimableAmount)
        external
        onlyOwner
    {
        require(
            _recipients.length == _claimableAmount.length, "TokenDistributor: invalid array length"
        );

        uint256 sumReward = totalReward;
        uint256 sumExpired = totalExpired;
        uint256 currentDay = (block.timestamp / 1 days) * 1 days;
        for (uint256 i = 0; i < _recipients.length; i++) {
            address recipient = _recipients[i];

            require(duplicateCheck[recipient] != currentDay,"TokenDistributor: recipient already set");
            duplicateCheck[recipient] = currentDay;

            uint256 claimableAmount = _claimableAmount[i];
            uint256 length = claimableRewards[recipient].length;
            if(length>0 && claimableRewards[recipient][0].timestamp + bufferTime < currentDay){
                Reward[] memory oldRewards = claimableRewards[recipient];
                delete(claimableRewards[recipient]);
                for(uint256 j = 0; j < oldRewards.length; j++) {
                    if(oldRewards[j].timestamp + bufferTime >= currentDay ){
                        claimableRewards[recipient].push(oldRewards[j]);
                    }else{
                        unchecked {
                            sumExpired += oldRewards[j].amount;
                        }    
                        emit ExpiredClaim(recipient, oldRewards[j].amount, oldRewards[j].timestamp);
                    }
                }  
            }

            claimableRewards[recipient].push(Reward(currentDay,claimableAmount));
            emit CanClaim(recipient, claimableAmount, currentDay);
            
            unchecked {
                sumReward += claimableAmount;
            }
        }
        require(token.balanceOf(address(this)) >= sumReward - totalExpiredWithdraw - totalClaimed, "TokenDistributor: not enough balance");

        totalReward = sumReward;
        totalExpired = sumExpired;
    }

    function activateAccount(bool _isActive) external  {
        activeAccounts[msg.sender] = _isActive;
        emit ActivateAccount(msg.sender,_isActive);
    }


    function claim() external {
        address recipient = msg.sender;
        require(activeAccounts[recipient], "TokenDistributor: not active user");
        uint256 length = claimableRewards[recipient].length;
        if(length>0){
            uint256 claimableAmount;
            uint256 currentDay = (block.timestamp / 1 days) * 1 days;
            uint256 sumExpired = totalExpired;
            for(uint256 i = 0; i < length; i++) {
                if(claimableRewards[recipient][i].timestamp + bufferTime >= currentDay ){
                    unchecked {                        
                        claimableAmount += claimableRewards[recipient][i].amount;
                    }
                    emit HasClaimedWithTimestamp(recipient, claimableRewards[recipient][i].amount, claimableRewards[recipient][i].timestamp);
                }else{
                    unchecked {
                        sumExpired += claimableRewards[recipient][i].amount;
                    }    
                    emit ExpiredClaim(recipient, claimableRewards[recipient][i].amount, claimableRewards[recipient][i].timestamp);
                }
            }  
            delete(claimableRewards[recipient]);
            totalExpired = sumExpired;
            if(claimableAmount > 0){
                unchecked {
                    totalClaimed += claimableAmount;
                }
                token.safeTransfer(recipient, claimableAmount);
            }
            emit HasClaimed(recipient, claimableAmount);
        }else{
            revert("TokenDistributor: nothing to claim");
        }

    }

    function claimable() external view returns (uint256) {
        return _claimable(msg.sender);
    }

    function _claimable(address _recipient) private view returns (uint256) {
        uint256 claimableAmount;
        if(activeAccounts[_recipient]){
            uint256 length = claimableRewards[_recipient].length;
            if(length > 0){
                uint256 currentDay = (block.timestamp / 1 days) * 1 days;
                for(uint256 i = 0; i < length; i++) {
                    if(claimableRewards[_recipient][i].timestamp + bufferTime >= currentDay ){
                        claimableAmount += claimableRewards[_recipient][i].amount;
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

    function getAccountsClaimable(address[] calldata _accounts) external view returns (uint256[] memory) {
        require(_accounts.length > 0 , "TokenDistributor: invalid array length");
        uint256[] memory claimableList = new uint256[](_accounts.length);
        for (uint256 i = 0; i < _accounts.length; i++) {
            claimableList[i] = _claimable(_accounts[i]);
        }    
        return claimableList;
    }

}