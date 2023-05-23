// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.6.12;

import "../libraries/math/SafeMath.sol";
import "../libraries/token/IERC20.sol";
import "../libraries/token/SafeERC20.sol";
import "../libraries/utils/ReentrancyGuard.sol";
import "../libraries/utils/Address.sol";

import "../tokens/interfaces/IWETH.sol";
import "../core/interfaces/IQlpManager.sol";
import "../access/Governable.sol";

contract RewardRouter is ReentrancyGuard, Governable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using Address for address payable;

    address public immutable weth;
    address public immutable qlpManager;

    receive() external payable {
        require(msg.sender == address(weth), "Router: invalid sender");
    }

    constructor(
        address _weth,
        address _qlpManager
    ) public{
        weth = _weth;   
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
        uint256 amountOut = IQlpManager(qlpManager).removeLiquidityForAccount(account, _tokenOut, _qlpAmount, _minOut, _receiver);

        return amountOut;
    }

    function unstakeAndRedeemQlpETH(
        uint256 _qlpAmount,
        uint256 _minOut,
        address payable _receiver
    ) external nonReentrant returns (uint256) {
        require(_qlpAmount > 0, "RewardRouter: invalid _qlpAmount");

        address account = msg.sender;
        uint256 amountOut = IQlpManager(qlpManager).removeLiquidityForAccount(account, weth, _qlpAmount, _minOut, address(this));

        IWETH(weth).withdraw(amountOut);
        _receiver.sendValue(amountOut);

        return amountOut;
    }

}
