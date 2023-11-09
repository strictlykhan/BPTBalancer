//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.12;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IBalancerVault} from "../Balancer/IBalancerVault.sol";

interface IRewardPoolDepositWrapper {
    function depositSingle(
        address _rewardPoolAddress,
        ERC20 _inputToken,
        uint256 _inputAmount,
        bytes32 _balancerPoolId,
        IBalancerVault.JoinPoolRequest memory _request
    ) external;
}
