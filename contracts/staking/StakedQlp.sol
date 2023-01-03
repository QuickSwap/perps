// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "../libraries/math/SafeMath.sol";
import "../libraries/token/IERC20.sol";

import "../core/interfaces/IQlpManager.sol";

import "./interfaces/IRewardTracker.sol";

contract StakedQlp {
    using SafeMath for uint256;

    string public constant name = "StakedQlp";
    string public constant symbol = "sQLP";
    uint8 public constant decimals = 18;

    address public qlp;
    IQlpManager public qlpManager;
    address public stakedQlpTracker;
    address public feeQlpTracker;

    mapping (address => mapping (address => uint256)) public allowances;

    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(
        address _qlp,
        IQlpManager _qlpManager,
        address _stakedQlpTracker,
        address _feeQlpTracker
    ) public {
        qlp = _qlp;
        qlpManager = _qlpManager;
        stakedQlpTracker = _stakedQlpTracker;
        feeQlpTracker = _feeQlpTracker;
    }

    function allowance(address _owner, address _spender) external view returns (uint256) {
        return allowances[_owner][_spender];
    }

    function approve(address _spender, uint256 _amount) external returns (bool) {
        _approve(msg.sender, _spender, _amount);
        return true;
    }

    function transfer(address _recipient, uint256 _amount) external returns (bool) {
        _transfer(msg.sender, _recipient, _amount);
        return true;
    }

    function transferFrom(address _sender, address _recipient, uint256 _amount) external returns (bool) {
        uint256 nextAllowance = allowances[_sender][msg.sender].sub(_amount, "StakedQlp: transfer amount exceeds allowance");
        _approve(_sender, msg.sender, nextAllowance);
        _transfer(_sender, _recipient, _amount);
        return true;
    }

    function balanceOf(address _account) external view returns (uint256) {
        return IRewardTracker(feeQlpTracker).depositBalances(_account, qlp);
    }

    function totalSupply() external view returns (uint256) {
        return IERC20(stakedQlpTracker).totalSupply();
    }

    function _approve(address _owner, address _spender, uint256 _amount) private {
        require(_owner != address(0), "StakedQlp: approve from the zero address");
        require(_spender != address(0), "StakedQlp: approve to the zero address");

        allowances[_owner][_spender] = _amount;

        emit Approval(_owner, _spender, _amount);
    }

    function _transfer(address _sender, address _recipient, uint256 _amount) private {
        require(_sender != address(0), "StakedQlp: transfer from the zero address");
        require(_recipient != address(0), "StakedQlp: transfer to the zero address");

        require(
            qlpManager.lastAddedAt(_sender).add(qlpManager.cooldownDuration()) <= block.timestamp,
            "StakedQlp: cooldown duration not yet passed"
        );

        IRewardTracker(stakedQlpTracker).unstakeForAccount(_sender, feeQlpTracker, _amount, _sender);
        IRewardTracker(feeQlpTracker).unstakeForAccount(_sender, qlp, _amount, _sender);

        IRewardTracker(feeQlpTracker).stakeForAccount(_sender, _recipient, qlp, _amount);
        IRewardTracker(stakedQlpTracker).stakeForAccount(_recipient, _recipient, feeQlpTracker, _amount);
    }
}
