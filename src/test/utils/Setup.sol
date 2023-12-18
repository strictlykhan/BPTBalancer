// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.18;

import "forge-std/console.sol";
import {ExtendedTest} from "./ExtendedTest.sol";

import {BPTBalancer, ERC20} from "../../BPTBalancer.sol";
import {IStrategyInterface} from "../../interfaces/IStrategyInterface.sol";

import {BPTBalancerFactory} from "../../BPTBalancerFactory.sol";

// Inherit the events so they can be checked if desired.
import {IEvents} from "@tokenized-strategy/interfaces/IEvents.sol";

interface IFactory {
    function governance() external view returns (address);

    function set_protocol_fee_bps(uint16) external;

    function set_protocol_fee_recipient(address) external;
}

contract Setup is ExtendedTest, IEvents {
    // Contract instances that we will use repeatedly.
    ERC20 public asset;
    IStrategyInterface public strategy;
    BPTBalancerFactory public strategyFactory;

    address internal constant bal = 0x9a71012B13CA4d3D0Cdc72A177DF3ef03b0E76A3;
    address internal constant aura = 0x1509706a6c66CA549ff0cB464de88231DDBe213B;
    address internal constant stader = 0x1d734A02eF1e1f5886e66b0673b71Af5B53ffA94;
    address public auraRewardsContract;
    address[3][] public rewardsTargetsPools;
    address public illiquidReward;

    mapping(string => address) public tokenAddrs;

    // Addresses for different roles we will use repeatedly.
    address public user = address(10);
    address public keeper = address(4);
    address public management = address(1);
    address public performanceFeeRecipient = address(3);

    // Address of the real deployed Factory
    address public factory;

    // Integer variables that will be used repeatedly.
    uint256 public decimals;
    uint256 public MAX_BPS = 10_000;

    // Fuzz from $0.01 of 1e6 stable coins up to 1 trillion of a 1e18 coin
    uint256 public maxFuzzAmount = 1e22;
    uint256 public minFuzzAmount = 100e18;

    // Default profit max unlock time is set for 10 days
    uint256 public profitMaxUnlockTime = 10 days;

    function setUp() public virtual {
        _setTokenAddrs();

        strategyFactory = new BPTBalancerFactory(
            management,
            performanceFeeRecipient,
            keeper
        );

        // Set asset
        asset = ERC20(0xcd78A20c597E367A4e478a2411cEB790604D7c8F);
        auraRewardsContract = 0x39EE6Fb813052E67260A3F95D3739B336aABD2C6;
        
        rewardsTargetsPools.push([
            bal,
            tokenAddrs["WMATIC"],
            0x0297e37f1873D2DAb4487Aa67cD56B58E2F27875]
        );

        rewardsTargetsPools.push([
            stader,
            tokenAddrs["MATICX"],
            0x577f6076E558818A5dF21Ce4acdE9A9623eC0b4c]
        );
        
        illiquidReward = aura;

        // Set decimals
        decimals = asset.decimals();

        // Deploy strategy and set variables
        strategy = IStrategyInterface(setUpStrategy());

        factory = strategy.FACTORY();

        // label all the used addresses for traces
        vm.label(keeper, "keeper");
        vm.label(factory, "factory");
        vm.label(address(asset), "asset");
        vm.label(management, "management");
        vm.label(address(strategy), "strategy");
        vm.label(performanceFeeRecipient, "performanceFeeRecipient");
    }

    function setUpStrategy() public returns (address) {
        // we save the strategy as a IStrategyInterface to give it the needed interface
        IStrategyInterface _strategy = IStrategyInterface(
            strategyFactory.newBPTBalancer(
                "Tokenized Balancer Strategy",
                address(asset),
                auraRewardsContract,
                rewardsTargetsPools,
                illiquidReward
            )
        );

        vm.prank(management);
        _strategy.acceptManagement();

        return address(_strategy);
    }

    function depositIntoStrategy(
        IStrategyInterface _strategy,
        address _user,
        uint256 _amount
    ) public {
        vm.prank(_user);
        asset.approve(address(_strategy), _amount);

        vm.prank(_user);
        _strategy.deposit(_amount, _user);
    }

    function mintAndDepositIntoStrategy(
        IStrategyInterface _strategy,
        address _user,
        uint256 _amount
    ) public {
        airdrop(asset, _user, _amount);
        depositIntoStrategy(_strategy, _user, _amount);
    }

    // For checking the amounts in the strategy
    function checkStrategyTotals(
        IStrategyInterface _strategy,
        uint256 _totalAssets,
        uint256 _totalDebt,
        uint256 _totalIdle
    ) public {
        assertEq(_strategy.totalAssets(), _totalAssets, "!totalAssets");
        assertEq(_strategy.totalDebt(), _totalDebt, "!totalDebt");
        assertEq(_strategy.totalIdle(), _totalIdle, "!totalIdle");
        assertEq(_totalAssets, _totalDebt + _totalIdle, "!Added");
    }

    function airdrop(ERC20 _asset, address _to, uint256 _amount) public {
        uint256 balanceBefore = _asset.balanceOf(_to);
        deal(address(_asset), _to, balanceBefore + _amount);
    }

    function setFees(uint16 _protocolFee, uint16 _performanceFee) public {
        address gov = IFactory(factory).governance();

        // Need to make sure there is a protocol fee recipient to set the fee.
        vm.prank(gov);
        IFactory(factory).set_protocol_fee_recipient(gov);

        vm.prank(gov);
        IFactory(factory).set_protocol_fee_bps(_protocolFee);

        vm.prank(management);
        strategy.setPerformanceFee(_performanceFee);
    }

    function _setTokenAddrs() internal {
        tokenAddrs["WBTC"] = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
        tokenAddrs["YFI"] = 0x0bc529c00C6401aEF6D220BE8C6Ea1667F6Ad93e;
        tokenAddrs["WETH"] = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        tokenAddrs["LINK"] = 0x514910771AF9Ca656af840dff83E8264EcF986CA;
        tokenAddrs["USDT"] = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
        tokenAddrs["DAI"] = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
        tokenAddrs["USDC"] = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
        tokenAddrs["WMATIC"] = 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270;
        tokenAddrs["MATICX"] = 0xfa68FB4628DFF1028CFEc22b4162FCcd0d45efb6;
    }
}
