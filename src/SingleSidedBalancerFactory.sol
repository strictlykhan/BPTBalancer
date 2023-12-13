// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.18;

import {SingleSidedBalancer} from "./SingleSidedBalancer.sol";
import {IStrategyInterface} from "./interfaces/IStrategyInterface.sol";

contract SingleSidedBalancerFactory {
    /// @notice Revert message for when a strategy has already been deployed.
    error AlreadyDeployed(address _strategy);

    /// @notice Address of the contract managing the strategies
    address public management;
    /// @notice Address where performance fees are sent
    address public rewards;
    /// @notice Address of the keeper bot
    address public keeper;

    /// @notice Track the deployments. asset => pool => strategy
    mapping(address => mapping(address => address)) deployments;

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
        return "Single Sided Balancer Factory";
    }

    /**
     * @notice Deploys a new tokenized Single Sided Balancer strategy.
     * @param _asset Underlying asset address
     * @param _name Name for strategy
     * @param _pool Balancer pool to deposit into
     * @param _rewardsContract Aurora contract to stake lp token
     * @param _maxSingleTrade Max in asset to join/exit at a time.
     * @return strategy Address of the deployed strategy
     */
    function newSingleSidedBalancer(
        address _asset,
        string memory _name,
        address _pool,
        address _rewardsContract,
        uint256 _maxSingleTrade
    ) external returns (address) {
        // Check if a SSB has already been deployed for that pool.
        if (deployments[_asset][_pool] != address(0))
            revert AlreadyDeployed(deployments[_asset][_pool]);

        /// Need to give the address the correct interface.
        IStrategyInterface strategy = IStrategyInterface(
            address(
                new SingleSidedBalancer(
                    _asset,
                    _name,
                    _pool,
                    _rewardsContract,
                    _maxSingleTrade
                )
            )
        );

        /// Set the addresses.
        strategy.setPerformanceFeeRecipient(rewards);
        strategy.setKeeper(keeper);
        strategy.setPendingManagement(management);

        // Add to deployment addresses.
        deployments[_asset][_pool] = address(strategy);

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
        address _pool = IStrategyInterface(_strategy).pool();
        return deployments[_asset][_pool] == _strategy;
    }
}
