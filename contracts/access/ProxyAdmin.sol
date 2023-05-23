// SPDX-License-Identifier: MIT

pragma solidity  0.8.18;

import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

contract ProxyAdmin is AccessControl {

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    event Call(
        address indexed sender,
        address indexed target,
        uint256 value,
        bytes data
    );

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

}