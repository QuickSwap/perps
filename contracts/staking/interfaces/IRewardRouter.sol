// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

interface IRewardRouter {

    function signalTransfer(address _receiver) external;

    function handleRewards(
        bool _shouldClaimWeth,
        bool _shouldConvertWethToEth,
        bool _shouldAddIntoKLP
    ) external;
}
