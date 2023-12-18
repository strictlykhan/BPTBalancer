// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.18;

import {IBaseHealthCheck} from "@periphery/HealthCheck/IBaseHealthCheck.sol";

interface IStrategyInterface is IBaseHealthCheck {
    function slippage() external view returns (uint256);

    function setSlippage(uint256 _slippage) external;

    function claimIlliquidReward(address _to) external;

}
