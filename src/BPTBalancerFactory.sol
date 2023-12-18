// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.18;

import {BPTBalancer} from "./BPTBalancer.sol";
import {IStrategyInterface} from "./interfaces/IStrategyInterface.sol";

contract BPTBalancerFactory {
    /// @notice Revert message for when a strategy has already been deployed.
    error AlreadyDeployed(address _strategy);

    /// @notice Address of the contract managing the strategies
    address public management;
    /// @notice Address where performance fees are sent
    address public rewards;
    /// @notice Address of the keeper bot
    address public keeper;

    /// @notice Track the deployments. asset => strategy
    mapping(address => address) public deployments;

    /**
     * @notice Emitted when a new strategy is deployed
     * @param strategy Address of the deployed strategy contract
     */
    event Deployed(address indexed strategy);

    /**
     * @param _management Address of the management contract
     * @param _rewards Address where performance fees will be sent
     * @param _keeper Address of the keeper bot
     */
    constructor(address _management, address _rewards, address _keeper) {
        management = _management;
        rewards = _rewards;
        keeper = _keeper;
    }

    function name() external pure returns (string memory) {
        return "Balancer Strategy Factory";
    }

    /**
     * @notice Deploys a new tokenized Single Sided Balancer strategy.
     * @return strategy Address of the deployed strategy
     */
    function newBPTBalancer(
        string memory _name,
        address _asset,
        address _auraRewardsContract,
        address[3][] memory _rewardsTargetsPools,
        address _illiquidReward
    ) external returns (address) {
        if (deployments[_asset] != address(0))
            revert AlreadyDeployed(deployments[_asset]);

        /// Need to give the address the correct interface.
        IStrategyInterface strategy = IStrategyInterface(
            address(
                new BPTBalancer(
                    _name,
                    _asset,
                    _auraRewardsContract,
                    _rewardsTargetsPools,
                    _illiquidReward
                )
            )
        );

        /// Set the addresses.
        strategy.setPerformanceFeeRecipient(rewards);
        strategy.setKeeper(keeper);
        strategy.setPendingManagement(management);

        // Add to deployment addresses.
        deployments[_asset] = address(strategy);

        emit Deployed(address(strategy));
        return address(strategy);
    }

    function setAddresses(
        address _management,
        address _rewards,
        address _keeper
    ) external {
        require(msg.sender == management, "!management");
        management = _management;
        rewards = _rewards;
        keeper = _keeper;
    }

    function isDeployedStrategy(
        address _strategy
    ) external view returns (bool) {
        address _asset = IStrategyInterface(_strategy).asset();
        return deployments[_asset] == _strategy;
    }
}
