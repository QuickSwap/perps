// SPDX-License-Identifier: MIT

pragma solidity  0.8.18;

import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract ProxyAdmin is AccessControl {
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    event Call(
        address indexed sender,
        address indexed target,
        uint256 value,
        bytes data
    );

    event WithdrawToken(address indexed sender, address receiver, address token, uint256 amount);

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
    }

    function functionCallWithValue(
        address target,
        bytes memory data,
        uint256 value
    )
        external
        onlyRole(ADMIN_ROLE)
    {
        Address.functionCallWithValue(target, data, value);

        emit Call(
            msg.sender,
            target,
            value,
            data
        );
    }

    function withdrawToken(
        IERC20 token,
        address receiver
    ) external onlyRole(ADMIN_ROLE) 
    {
        uint256 balance = token.balanceOf(address(this));
        require(balance>0,"Not enough balance");
        token.safeTransfer(receiver, balance);
        emit WithdrawToken(msg.sender, receiver, address(token), balance);
    }

}