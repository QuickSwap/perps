// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.7.5;

import "./lib/Ownable.sol";
import "./lib/SafeERC20.sol";
import "./lib/ReentrancyGuard.sol";
import "./lib/SafeMath.sol";
import "./lib/EnumerableSet.sol";

import "./interfaces/IFarming.sol";
import "./interfaces/IWETH.sol";


/*
 * This contract is used to distribute farming to users that allocated depositToken here
 *
 * farming can be distributed in the form of one or more tokens
 * They are mainly managed to be received from the FeeManager contract, but other sources can be added (dev wallet for instance)
 *
 * The freshly received farming are stored in a pending slot
 *
 * The content of this pending slot will be progressively transferred over time into a distribution slot
 * This distribution slot is the source of the farming distribution to depositToken allocators during the current cycle
 *
 * This transfer from the pending slot to the distribution slot is based on cycleFarmingPercent and CYCLE_PERIOD_SECONDS
 *
 */
contract Farming is Ownable, ReentrancyGuard, IFarming {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;
  using EnumerableSet for EnumerableSet.AddressSet;

  struct UserInfo {
    uint256 pendingFarming;
    uint256 rewardDebt;
  }

  struct FarmingInfo {
    uint256 currentDistributionAmount; // total amount to distribute during the current cycle
    uint256 currentCycleDistributedAmount; // amount already distributed for the current cycle (times 1e2)
    uint256 pendingAmount; // total amount in the pending slot, not distributed yet
    uint256 distributedAmount; // total amount that has been distributed since initialization
    uint256 accFarmingPerShare; // accumulated farming per share (times 1e9)
    uint256 lastUpdateTime; // last time the farming distribution occurred
    uint256 cycleFarmingPercent; // fixed part of the pending farming to assign to currentDistributionAmount on every cycle
    bool distributionDisabled; // deactivate a token distribution (for temporary farming)
  }

  // actively distributed tokens
  EnumerableSet.AddressSet private _distributedTokens;
  uint256 public constant MAX_DISTRIBUTED_TOKENS = 10;
  uint256 public constant BUFFER_TIME = 86400;
  address public immutable weth;
  // farming info for every farming token
  mapping(address => FarmingInfo) public farmingInfo;
  mapping(address => mapping(address => UserInfo)) public users;

  address public immutable depositToken; // depositToken contract

  mapping(address => uint256) public usersAllocation; // User's depositToken allocation
  uint256 public totalAllocation; // Contract's total depositToken allocation

  mapping(bytes32 => uint256) public pendingActions;

  uint256 public constant MIN_CYCLE_FARMING_PERCENT = 1; // 0.01%
  uint256 public constant DEFAULT_CYCLE_FARMING_PERCENT = 100; // 1%
  uint256 public constant MAX_CYCLE_FARMING_PERCENT = 10000; // 100%
  // farming will be added to the currentDistributionAmount on each new cycle
  uint256 internal _cycleDurationSeconds = 7 days;
  uint256 public currentCycleStartTime;

  constructor(address depositToken_, uint256 startTime_, address weth_) {
    require(depositToken_ != address(0), "zero address");
    depositToken = depositToken_;
    currentCycleStartTime = startTime_;
    weth = weth_;
  }

  /********************************************/
  /****************** EVENTS ******************/
  /********************************************/

  event UserUpdated(address indexed user, uint256 previousBalance, uint256 newBalance);
  event FarmingCollected(address indexed user, address indexed token, uint256 amount);
  event CycleFarmingPercentUpdated(address indexed token, uint256 previousValue, uint256 newValue);
  event FarmingAddedToPending(address indexed token, uint256 amount);
  event DistributedTokenDisabled(address indexed token);
  event DistributedTokenRemoved(address indexed token);
  event DistributedTokenEnabled(address indexed token);

  event Allocate(address indexed userAddress,  uint256 amount);
  event Deallocate(address indexed userAddress,  uint256 amount);

  event EmergencyWithdraw(address token,uint256 amount,bytes32 action);
  event SignalEmergencyWithdraw(address token,bytes32 action);
  event SignalPendingAction(bytes32 action);
  event ClearAction(bytes32 action);

  /***********************************************/
  /****************** MODIFIERS ******************/
  /***********************************************/

  /**
   * @dev Checks if an index exists
   */
  modifier validateDistributedTokensIndex(uint256 index) {
    require(index < _distributedTokens.length(), "validateDistributedTokensIndex: index exists?");
    _;
  }

  /**
   * @dev Checks if token exists
   */
  modifier validateDistributedToken(address token) {
    require(_distributedTokens.contains(token), "validateDistributedTokens: token does not exists");
    _;
  }

  /*******************************************/
  /****************** VIEWS ******************/
  /*******************************************/

  function cycleDurationSeconds() external view returns (uint256) {
    return _cycleDurationSeconds;
  }

  /**
   * @dev Returns the number of farming tokens
   */
  function distributedTokensLength() external view override returns (uint256) {
    return _distributedTokens.length();
  }

  /**
   * @dev Returns farming token address from given index
   */
  function distributedToken(uint256 index) external view override validateDistributedTokensIndex(index) returns (address){
    return address(_distributedTokens.at(index));
  }

  /**
   * @dev Returns true if given token is a farming token
   */
  function isDistributedToken(address token) external view override returns (bool) {
    return _distributedTokens.contains(token);
  }

  /**
   * @dev Returns time at which the next cycle will start
   */
  function nextCycleStartTime() public view returns (uint256) {
    return currentCycleStartTime.add(_cycleDurationSeconds);
  }

  /**
   * @dev Returns user's farming pending amount for a given token
   */
  function pendingFarmingAmount(address token, address userAddress) external view returns (uint256) {
    if (totalAllocation == 0) {
      return 0;
    }

    FarmingInfo storage farmingInfo_ = farmingInfo[token];

    uint256 accFarmingPerShare = farmingInfo_.accFarmingPerShare;
    uint256 lastUpdateTime = farmingInfo_.lastUpdateTime;
    uint256 dividendAmountPerSecond_ = _farmingAmountPerSecond(token);

    // check if the current cycle has changed since last update
    if (_currentBlockTimestamp() > nextCycleStartTime()) {
      // get remaining rewards from last cycle
      accFarmingPerShare = accFarmingPerShare.add(
        (nextCycleStartTime().sub(lastUpdateTime)).mul(dividendAmountPerSecond_).mul(1e16).div(totalAllocation)
      );
      lastUpdateTime = nextCycleStartTime();
      dividendAmountPerSecond_ = farmingInfo_.pendingAmount.mul(farmingInfo_.cycleFarmingPercent).div(100).div(
        _cycleDurationSeconds
      );
    }

    // get pending rewards from current cycle
    accFarmingPerShare = accFarmingPerShare.add(
      (_currentBlockTimestamp().sub(lastUpdateTime)).mul(dividendAmountPerSecond_).mul(1e16).div(totalAllocation)
    );

    return usersAllocation[userAddress]
        .mul(accFarmingPerShare)
        .div(1e18)
        .sub(users[token][userAddress].rewardDebt)
        .add(users[token][userAddress].pendingFarming);
  }

  /**************************************************/
  /****************** PUBLIC FUNCTIONS **************/
  /**************************************************/

  /**
   * @dev Updates the current cycle start time if previous cycle has ended
   */
  function updateCurrentCycleStartTime() public {
    uint256 nextCycleStartTime_ = nextCycleStartTime();

    if (_currentBlockTimestamp() >= nextCycleStartTime_) {
      currentCycleStartTime = nextCycleStartTime_;
    }
  }

  /**
   * @dev Updates farming info for a given token
   */
  function updateFarmingInfo(address token) external validateDistributedToken(token) {
    _updateFarmingInfo(token);
  }

  /****************************************************************/
  /****************** EXTERNAL PUBLIC FUNCTIONS  ******************/
  /****************************************************************/

  /**
   * @dev Updates all farmingInfo
   */
  function massUpdateFarmingInfo() external {
    uint256 length = _distributedTokens.length();
    for (uint256 index = 0; index < length; ++index) {
      _updateFarmingInfo(_distributedTokens.at(index));
    }
  }

  /**
   * @dev Harvests caller's pending farming of a given token
   */
  function harvestFarming(address token, bool withdrawEth) external nonReentrant {
    if (!_distributedTokens.contains(token)) {
      require(farmingInfo[token].distributedAmount > 0, "harvestFarming: invalid token");
    }

    _harvestFarming(token, withdrawEth);
  }

  /**
   * @dev Harvests all caller's pending farming
   */
  function harvestAllFarming(bool withdrawEth) external nonReentrant {
    uint256 length = _distributedTokens.length();
    for (uint256 index = 0; index < length; ++index) {
      _harvestFarming(_distributedTokens.at(index), withdrawEth);
    }
  }

  /**
   * @dev Transfers the given amount of token from caller to pendingAmount
   *
   * Must only be called by a trustable address
   */
  function addFarmingToPending(address token, uint256 amount) external override nonReentrant {
    uint256 prevTokenBalance = IERC20(token).balanceOf(address(this));
    FarmingInfo storage farmingInfo_ = farmingInfo[token];

    IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

    // handle tokens with transfer tax
    uint256 receivedAmount = IERC20(token).balanceOf(address(this)).sub(prevTokenBalance);
    farmingInfo_.pendingAmount = farmingInfo_.pendingAmount.add(receivedAmount);

    emit FarmingAddedToPending(token, receivedAmount);
  }

  function addPendingToCurrentDistribution(address token) external override onlyOwner {
    uint256 currentBlockTimestamp = _currentBlockTimestamp();
    FarmingInfo storage farmingInfo_ = farmingInfo[token];

    uint256 pendingAmount = farmingInfo_.pendingAmount;
    uint256 currentDistributionAmount = pendingAmount.mul(farmingInfo_.cycleFarmingPercent).div(
      10000
    );
    farmingInfo_.currentDistributionAmount = farmingInfo_.currentDistributionAmount.add(currentDistributionAmount);
    farmingInfo_.pendingAmount = pendingAmount.sub(currentDistributionAmount);
    farmingInfo_.lastUpdateTime = currentBlockTimestamp;

    _updateFarmingInfo(token);
  }


  /**
   * @dev Emergency withdraw token's balance on the contract
   */
  function signalEmergencyWithdraw(IERC20 token) external  onlyOwner {
    bytes32 action = keccak256(abi.encodePacked("emergencyWithdraw", address(token)));
    _setPendingAction(action);
    emit SignalEmergencyWithdraw(address(token), action);
  }

  /**
   * @dev Emergency withdraw token's balance on the contract
   */
  function processEmergencyWithdraw(IERC20 token) external nonReentrant onlyOwner {
    bytes32 action = keccak256(abi.encodePacked("emergencyWithdraw", address(token)));
    _validateAction(action);
    _clearAction(action);

    uint256 balance = token.balanceOf(address(this));
    if(balance>0){
      _safeTokenTransfer(token, msg.sender, balance);
    }

    emit EmergencyWithdraw(address(token),balance, action);
  }



  /*****************************************************************/
  /****************** OWNABLE FUNCTIONS  ******************/
  /*****************************************************************/

  /**
   * Allocates "userAddress" user's "amount" of depositToken to this farming contract
   *
   * Can only be called by depositToken contract, which is trusted to verify amounts
   * "data" is only here for compatibility reasons (IdepositTokenUsage)
   */
  function allocate( uint256 amount) external override nonReentrant  {
    require(amount > 0, "farming: invalid amount");

    IERC20(depositToken).safeTransferFrom(msg.sender, address(this), amount);
    uint256 newUserAllocation = usersAllocation[msg.sender].add(amount);
    uint256 newTotalAllocation = totalAllocation.add(amount);
    _updateUser(msg.sender, newUserAllocation, newTotalAllocation);

    emit Allocate(msg.sender,amount);
  }

  /**
   * Deallocates "userAddress" user's "amount" of depositToken allocation from this farming contract
   *
   * Can only be called by depositToken contract, which is trusted to verify amounts
   * "data" is only here for compatibility reasons (IdepositTokenUsage)
   */
  function deallocate( uint256 amount) external override nonReentrant  {
    require(amount > 0, "farming: invalid amount");
    require(usersAllocation[msg.sender] >= amount, "farming: amount exceeds usersAllocation");

    uint256 newUserAllocation = usersAllocation[msg.sender].sub(amount);
    uint256 newTotalAllocation = totalAllocation.sub(amount);
    _updateUser(msg.sender, newUserAllocation, newTotalAllocation);
    IERC20(depositToken).safeTransfer(msg.sender, amount);

    emit Deallocate(msg.sender,amount);
  }

  /**
   * @dev Enables a given token to be distributed as farming
   *
   * Effective from the next cycle
   */
  function enableDistributedToken(address token) external onlyOwner {
    FarmingInfo storage farmingInfo_ = farmingInfo[token];
    require(
      farmingInfo_.lastUpdateTime == 0 || farmingInfo_.distributionDisabled,
      "enableDistributedToken: Already enabled farming token"
    );
    require(_distributedTokens.length() < MAX_DISTRIBUTED_TOKENS, "enableDistributedToken: too many distributedTokens");
    // initialize lastUpdateTime if never set before
    if (farmingInfo_.lastUpdateTime == 0) {
      farmingInfo_.lastUpdateTime = _currentBlockTimestamp();
    }
    // initialize cycleFarmingPercent to the minimum if never set before
    if (farmingInfo_.cycleFarmingPercent == 0) {
      farmingInfo_.cycleFarmingPercent = DEFAULT_CYCLE_FARMING_PERCENT;
    }
    farmingInfo_.distributionDisabled = false;
    _distributedTokens.add(token);
    emit DistributedTokenEnabled(token);
  }

  /**
   * @dev Disables distribution of a given token as farming
   *
   * Effective from the next cycle
   */
  function disableDistributedToken(address token) external onlyOwner {
    FarmingInfo storage farmingInfo_ = farmingInfo[token];
    require(
      farmingInfo_.lastUpdateTime > 0 && !farmingInfo_.distributionDisabled,
      "disableDistributedToken: Already disabled farming token"
    );
    farmingInfo_.distributionDisabled = true;
    emit DistributedTokenDisabled(token);
  }

  /**
   * @dev Updates the percentage of pending farming that will be distributed during the next cycle
   *
   * Must be a value between MIN_CYCLE_FARMING_PERCENT and MAX_CYCLE_FARMING_PERCENT
   */
  function updateCycleFarmingPercent(address token, uint256 percent) external onlyOwner {
    require(percent <= MAX_CYCLE_FARMING_PERCENT, "updateCycleFarmingPercent: percent mustn't exceed maximum");
    require(percent >= MIN_CYCLE_FARMING_PERCENT, "updateCycleFarmingPercent: percent mustn't exceed minimum");
    FarmingInfo storage farmingInfo_ = farmingInfo[token];
    uint256 previousPercent = farmingInfo_.cycleFarmingPercent;
    farmingInfo_.cycleFarmingPercent = percent;
    emit CycleFarmingPercentUpdated(token, previousPercent, farmingInfo_.cycleFarmingPercent);
  }

  /**
  * @dev remove an address from _distributedTokens
  *
  * Can only be valid for a disabled farming token and if the distribution has ended
  */
  function removeTokenFromDistributedTokens(address tokenToRemove) external onlyOwner {
    FarmingInfo storage _farmingInfo = farmingInfo[tokenToRemove];
    require(_farmingInfo.distributionDisabled && _farmingInfo.currentDistributionAmount == 0, "removeTokenFromDistributedTokens: cannot be removed");
    _distributedTokens.remove(tokenToRemove);
    emit DistributedTokenRemoved(tokenToRemove);
  }

  function updateCycleDurationSeconds(uint256 cycleDurationSeconds_) external onlyOwner {
    require(cycleDurationSeconds_ >= 7 days, "farming: Min cycle duration");
    require(cycleDurationSeconds_ <= 60 days, "farming: Max cycle duration");
    _cycleDurationSeconds = cycleDurationSeconds_;
  }

  /********************************************************/
  /****************** INTERNAL FUNCTIONS ******************/
  /********************************************************/

  /**
   * @dev Returns the amount of farming token distributed every second (times 1e2)
   */
  function _farmingAmountPerSecond(address token) internal view returns (uint256) {
    if (!_distributedTokens.contains(token)) return 0;
    return farmingInfo[token].currentDistributionAmount.mul(1e2).div(_cycleDurationSeconds);
  }

  /**
   * @dev Updates every user's rewards allocation for each distributed token
   */
  function _updateFarmingInfo(address token) internal {
    uint256 currentBlockTimestamp = _currentBlockTimestamp();
    FarmingInfo storage farmingInfo_ = farmingInfo[token];

    updateCurrentCycleStartTime();

    uint256 lastUpdateTime = farmingInfo_.lastUpdateTime;
    uint256 accFarmingPerShare = farmingInfo_.accFarmingPerShare;
    if (currentBlockTimestamp <= lastUpdateTime) {
      return;
    }

    // if no depositToken is allocated or initial distribution has not started yet
    if (totalAllocation == 0 || currentBlockTimestamp < currentCycleStartTime) {
      farmingInfo_.lastUpdateTime = currentBlockTimestamp;
      return;
    }

    uint256 currentDistributionAmount = farmingInfo_.currentDistributionAmount; // gas saving
    uint256 currentCycleDistributedAmount = farmingInfo_.currentCycleDistributedAmount; // gas saving

    // check if the current cycle has changed since last update
    if (lastUpdateTime < currentCycleStartTime) {
      // update accDividendPerShare for the end of the previous cycle
      accFarmingPerShare = accFarmingPerShare.add(
        (currentDistributionAmount.mul(1e2).sub(currentCycleDistributedAmount))
          .mul(1e16)
          .div(totalAllocation)
      );

      // check if distribution is enabled
      if (!farmingInfo_.distributionDisabled) {
        // transfer the token's cycleFarmingPercent part from the pending slot to the distribution slot
        farmingInfo_.distributedAmount = farmingInfo_.distributedAmount.add(currentDistributionAmount);

        uint256 pendingAmount = farmingInfo_.pendingAmount;
        currentDistributionAmount = pendingAmount.mul(farmingInfo_.cycleFarmingPercent).div(
          10000
        );
        farmingInfo_.currentDistributionAmount = currentDistributionAmount;
        farmingInfo_.pendingAmount = pendingAmount.sub(currentDistributionAmount);
      } else {
        // stop the token's distribution on next cycle
        farmingInfo_.distributedAmount = farmingInfo_.distributedAmount.add(currentDistributionAmount);
        currentDistributionAmount = 0;
        farmingInfo_.currentDistributionAmount = 0;
      }

      currentCycleDistributedAmount = 0;
      lastUpdateTime = currentCycleStartTime;
    }

    uint256 toDistribute = (currentBlockTimestamp.sub(lastUpdateTime)).mul(_farmingAmountPerSecond(token));
    // ensure that we can't distribute more than currentDistributionAmount (for instance w/ a > 24h service interruption)
    if (currentCycleDistributedAmount.add(toDistribute) > currentDistributionAmount.mul(1e2)) {
      toDistribute = currentDistributionAmount.mul(1e2).sub(currentCycleDistributedAmount);
    }

    farmingInfo_.currentCycleDistributedAmount = currentCycleDistributedAmount.add(toDistribute);
    farmingInfo_.accFarmingPerShare = accFarmingPerShare.add(toDistribute.mul(1e16).div(totalAllocation));
    farmingInfo_.lastUpdateTime = currentBlockTimestamp;
  }

  /**
   * Updates "userAddress" user's and total allocations for each distributed token
   */
  function _updateUser(address userAddress, uint256 newUserAllocation, uint256 newTotalAllocation) internal {
    uint256 previousUserAllocation = usersAllocation[userAddress];

    // for each distributedToken
    uint256 length = _distributedTokens.length();
    for (uint256 index = 0; index < length; ++index) {
      address token = _distributedTokens.at(index);
      _updateFarmingInfo(token);

      UserInfo storage user = users[token][userAddress];
      uint256 accFarmingPerShare = farmingInfo[token].accFarmingPerShare;

      uint256 pending = previousUserAllocation.mul(accFarmingPerShare).div(1e18).sub(user.rewardDebt);
      user.pendingFarming = user.pendingFarming.add(pending);
      user.rewardDebt = newUserAllocation.mul(accFarmingPerShare).div(1e18);
    }

    usersAllocation[userAddress] = newUserAllocation;
    totalAllocation = newTotalAllocation;

    emit UserUpdated(userAddress, previousUserAllocation, newUserAllocation);
  }

  /**
   * @dev Harvests msg.sender's pending farming of a given token
   */
  function _harvestFarming(address token, bool withdrawEth) internal {
    _updateFarmingInfo(token);

    UserInfo storage user = users[token][msg.sender];
    uint256 accFarmingPerShare = farmingInfo[token].accFarmingPerShare;

    uint256 userAllocation = usersAllocation[msg.sender];
    uint256 pending = user.pendingFarming.add(
      userAllocation.mul(accFarmingPerShare).div(1e18).sub(user.rewardDebt)
    );

    user.pendingFarming = 0;
    user.rewardDebt = userAllocation.mul(accFarmingPerShare).div(1e18);

    if(withdrawEth && token == weth ){
      _transferOutETH(pending, payable(msg.sender));
    } else {
      _safeTokenTransfer(IERC20(token), msg.sender, pending);
    }
    emit FarmingCollected(msg.sender, token, pending);
  }

  function _transferOutETH(uint256 _amountOut, address payable _receiver) internal {
    IWETH _weth = IWETH(weth);
    _weth.withdraw(_amountOut);

    (bool success, /* bytes memory data */) = _receiver.call{ value: _amountOut }("");

    if (success) { return; }

    // if the transfer failed, re-wrap the token and send it to the receiver
    _weth.deposit{ value: _amountOut }();
    _weth.transfer(address(_receiver), _amountOut);
  }

  receive() external payable {
      require(msg.sender == weth, "farming: invalid sender");
  }

  /**
   * @dev Safe token transfer function, in case rounding error causes pool to not have enough tokens
   */
  function _safeTokenTransfer(
    IERC20 token,
    address to,
    uint256 amount
  ) internal {
    if (amount > 0) {
      uint256 tokenBal = token.balanceOf(address(this));
      if (amount > tokenBal) {
        token.safeTransfer(to, tokenBal);
      } else {
        token.safeTransfer(to, amount);
      }
    }
  }

  /**
   * @dev Utility function to get the current block timestamp
   */
  function _currentBlockTimestamp() internal view virtual returns (uint256) {
    /* solhint-disable not-rely-on-time */
    return block.timestamp;
  }

  function cancelAction(bytes32 _action) external onlyOwner {
      _clearAction(_action);
  }

  function _setPendingAction(bytes32 _action) private {
      require(pendingActions[_action] == 0, "farming: action already signalled");
      pendingActions[_action] = block.timestamp.add(BUFFER_TIME);
      emit SignalPendingAction(_action);
  }

  function _validateAction(bytes32 _action) private view {
      require(pendingActions[_action] != 0, "farming: action not signalled");
      require(pendingActions[_action] < block.timestamp, "farming: action time not yet passed");
  }

  function _clearAction(bytes32 _action) private {
      require(pendingActions[_action] != 0, "farming: invalid _action");
      delete pendingActions[_action];
      emit ClearAction(_action);
  }
}