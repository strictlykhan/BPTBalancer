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

    function test_operation(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        vm.prank(management);
        strategy.setDepositTrigger(_amount - 1);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        checkStrategyTotals(strategy, _amount, 0, _amount);

        (bool trigger, ) = strategy.tendTrigger();
        assertTrue(trigger);

        vm.prank(keeper);
        strategy.tend();

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

        vm.prank(management);
        strategy.setDepositTrigger(_amount - 1);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        checkStrategyTotals(strategy, _amount, 0, _amount);

        (bool trigger, ) = strategy.tendTrigger();
        assertTrue(trigger);

        vm.prank(keeper);
        strategy.tend();

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

    function test_setTradeFactory(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        vm.prank(management);
        strategy.setDoHealthCheck(false);

        assertEq(strategy.tradeFactory(), address(0));
        assertTrue(!mockTradeFactory.enabled());

        vm.expectRevert("!management");
        vm.prank(user);
        strategy.setTradeFactory(address(mockTradeFactory));

        vm.prank(management);
        strategy.setDepositTrigger(_amount - 1);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        checkStrategyTotals(strategy, _amount, 0, _amount);

        (bool trigger, ) = strategy.tendTrigger();
        assertTrue(trigger);

        vm.prank(keeper);
        strategy.tend();

        checkStrategyTotals(strategy, _amount, _amount, 0);

        // Earn Interest
        skip(10 days);

        // Report profit
        vm.prank(keeper);
        strategy.report();

        // There should be loose Aura in the strategy.
        assertGt(ERC20(aura).balanceOf(address(strategy)), 0);

        vm.prank(management);
        strategy.setTradeFactory(address(mockTradeFactory));

        assertEq(strategy.tradeFactory(), address(mockTradeFactory));
        assertEq(mockTradeFactory.strategy(), address(strategy));
        assertTrue(mockTradeFactory.enabled());
        assertEq(
            ERC20(aura).allowance(address(strategy), address(mockTradeFactory)),
            type(uint256).max
        );

        // Make sure it can pull tokens
        assertGt(ERC20(aura).balanceOf(address(strategy)), 0);
        assertEq(ERC20(aura).balanceOf(address(mockTradeFactory)), 0);

        mockTradeFactory.pull();

        // There should be no more Aura in the strategy.
        assertEq(ERC20(aura).balanceOf(address(strategy)), 0);
        assertGt(ERC20(aura).balanceOf(address(mockTradeFactory)), 0);

        vm.prank(management);
        strategy.setTradeFactory(address(0));

        assertEq(strategy.tradeFactory(), address(0));
        assertEq(
            ERC20(aura).allowance(address(strategy), address(mockTradeFactory)),
            0
        );
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

        vm.prank(management);
        strategy.setDepositTrigger(_amount - 1);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        checkStrategyTotals(strategy, _amount, 0, _amount);

        (bool trigger, ) = strategy.tendTrigger();
        assertTrue(trigger);

        vm.prank(keeper);
        strategy.tend();

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

    function test_tendTrigger(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        (bool trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Skip some time
        skip(1 days);

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        vm.prank(keeper);
        strategy.report();

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Unlock Profits
        skip(strategy.profitMaxUnlockTime());

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        vm.prank(user);
        strategy.redeem(_amount, user, user);

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);
    }
}
