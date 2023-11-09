// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.18;

import {IBaseHealthCheck} from "@periphery/HealthCheck/IBaseHealthCheck.sol";

interface IStrategyInterface is IBaseHealthCheck {
     function fromAssetToBpt(uint256 _amount) external view returns (uint256);
    function fromBptToAsset(uint256 _amount) external view returns (uint256);
    function totalLpBalance() external view returns (uint256);
    function balanceOfPool() external view returns (uint256);
    function balanceOfStake() external view returns (uint256);
    function setMaxSingleTrade(uint256 _maxSingleTrade) external;
}
