//SPDX-License-Identifier: Unlicensed
pragma solidity 0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IBalancerVault} from "../Balancer/IBalancerVault.sol";

interface IRewardsContract {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function getReward(
        address _account,
        bool _claimExtras
    ) external returns (bool);
    function withdrawAndUnwrap(
        uint256 _amount,
        bool _claim
    ) external returns (bool);
}