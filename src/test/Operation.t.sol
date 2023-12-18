// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";

contract OperationTest is Setup {
    function setUp() public virtual override {
        super.setUp();
    }

    function testSetupStrategyOK() public {
        console.log("address of strategy", address(strategy));
        assertTrue(address(0) != address(strategy));
        assertEq(strategy.asset(), address(asset));
        assertEq(strategy.management(), management);
        assertEq(strategy.performanceFeeRecipient(), performanceFeeRecipient);
        assertEq(strategy.keeper(), keeper);
        // TODO: add additional check on strat params
    }

    function test_deployment() public {
        assertTrue(strategyFactory.isDeployedStrategy(address(strategy)));

        // Shouldn't be able to redeploy the same strategy
        vm.expectRevert();
        strategyFactory.newBPTBalancer(
            "Tokenized Balancer Strategy",
            address(asset),
            auraRewardsContract,
            rewardsTargetsPools,
            illiquidReward
        );
    }

    function test_operation(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        checkStrategyTotals(strategy, _amount, _amount, 0);

        // Earn Interest
        skip(1 days);

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertRelApproxEq(asset.balanceOf(user), balanceBefore + _amount, 10);
    }

    function test_profitableReport(
        uint256 _amount,
        uint16 _profitFactor
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        _profitFactor = uint16(
            bound(uint256(_profitFactor), 10, MAX_BPS - 100)
        );

        vm.prank(management);
        strategy.setProfitLimitRatio(10_000);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        checkStrategyTotals(strategy, _amount, _amount, 0);

        // Earn Interest
        skip(10 days);

        uint256 toAirdrop = (_amount * _profitFactor) / MAX_BPS;
        airdrop(asset, address(strategy), toAirdrop);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGt(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        // Make sure we either ended in profit or barely below
        if (asset.balanceOf(user) < balanceBefore + _amount) {
            assertRelApproxEq(
                asset.balanceOf(user),
                balanceBefore + _amount,
                10
            );
        }
    }

    function test_profitableReportRewards(
        uint256 _amount,
        uint16 _profitFactor
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        _profitFactor = uint16(
            bound(uint256(_profitFactor), 10, MAX_BPS - 100)
        );

        vm.prank(management);
        strategy.setProfitLimitRatio(10_000);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        checkStrategyTotals(strategy, _amount, _amount, 0);

        // Earn Interest
        skip(50 days);

        //uint256 toAirdrop = (_amount * _profitFactor) / MAX_BPS;
        //airdrop(asset, address(strategy), toAirdrop);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGt(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        // Make sure we either ended in profit or barely below
        if (asset.balanceOf(user) < balanceBefore + _amount) {
            assertRelApproxEq(
                asset.balanceOf(user),
                balanceBefore + _amount,
                10
            );
        }
    }

    function test_profitableReport_withFees(
        uint256 _amount,
        uint16 _profitFactor
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        _profitFactor = uint16(
            bound(uint256(_profitFactor), 10, MAX_BPS - 100)
        );

        vm.prank(management);
        strategy.setProfitLimitRatio(10_000);

        // Set protocol fee to 0 and perf fee to 10%
        setFees(0, 1_000);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        checkStrategyTotals(strategy, _amount, _amount, 0);

        // Earn Interest
        skip(10 days);
        uint256 toAirdrop = (_amount * _profitFactor) / MAX_BPS;
        airdrop(asset, address(strategy), toAirdrop);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGt(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

        // Get the expected fee
        uint256 expectedShares = (profit * 1_000) / MAX_BPS;

        assertEq(strategy.balanceOf(performanceFeeRecipient), expectedShares);

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        // Make sure we either ended in profit or barely below
        if (asset.balanceOf(user) < balanceBefore + _amount) {
            assertRelApproxEq(
                asset.balanceOf(user),
                balanceBefore + _amount,
                10
            );
        }

        if (expectedShares > 0) {
            vm.prank(performanceFeeRecipient);
            strategy.redeem(
                expectedShares,
                performanceFeeRecipient,
                performanceFeeRecipient
            );

            // Make sure we either ended in profit or barely below
            if (asset.balanceOf(performanceFeeRecipient) < expectedShares) {
                assertRelApproxEq(
                    asset.balanceOf(performanceFeeRecipient),
                    expectedShares,
                    10
                );
            }

            checkStrategyTotals(strategy, 0, 0, 0);
        }
    }

    function test_auraRewards(
        uint256 _amount,
        uint16 _profitFactor
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        _profitFactor = uint16(
            bound(uint256(_profitFactor), 10, MAX_BPS - 100)
        );

        vm.prank(management);
        strategy.setProfitLimitRatio(10_000);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        checkStrategyTotals(strategy, _amount, _amount, 0);

        assertEq(ERC20(aura).balanceOf(address(strategy)), 0, "aura in strategy");
        // Earn Interest
        skip(50 days);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGt(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        assertGt(ERC20(aura).balanceOf(address(strategy)), 100, "!aura");

        vm.prank(management);
        strategy.claimIlliquidReward(management);
        assertEq(ERC20(aura).balanceOf(address(strategy)), 0, "!aura");
        assertGt(ERC20(aura).balanceOf(management), 100, "!aura");

    }

}
