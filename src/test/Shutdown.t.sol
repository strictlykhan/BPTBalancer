pragma solidity ^0.8.18;

import "forge-std/console.sol";
import {Setup} from "./utils/Setup.sol";

contract ShutdownTest is Setup {
    function setUp() public override {
        super.setUp();
    }

    function test_shutdownCanWithdraw(uint256 _amount) public {
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

        // Shutdown the strategy
        vm.prank(management);
        strategy.shutdownStrategy();

        checkStrategyTotals(strategy, _amount, _amount, 0);

        // Make sure we can still withdraw the full amount
        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertRelApproxEq(asset.balanceOf(user), balanceBefore + _amount, 10);
    }

    function test_manualWithdraw(uint256 _amount) public {
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

        // withdraw from the strategy
        vm.prank(management);
        strategy.manualWithdraw(_amount / 2);

        // Totals wouldn't have moved.
        checkStrategyTotals(strategy, _amount, _amount, 0);
        // Should have adjusted deposit trigger an max swap
        assertEq(strategy.depositTrigger(), type(uint256).max);
        assertEq(strategy.maxSingleTrade(), 0);
        assertEq(strategy.maxDeposit(user), 0);
        assertEq(strategy.maxWithdraw(user), 0);
        uint256 assetBalance = asset.balanceOf(address(strategy));
        assertRelApproxEq(assetBalance, _amount / 2, 10);

        vm.prank(keeper);
        strategy.tend();

        // Tend adjusts amounts
        checkStrategyTotals(
            strategy,
            _amount,
            _amount - assetBalance,
            assetBalance
        );

        vm.prank(management);
        strategy.manualWithdraw(_amount * 2);

        assetBalance = asset.balanceOf(address(strategy));
        assertRelApproxEq(assetBalance, _amount, 10);
        assertEq(strategy.totalLpBalance(), 0);

        vm.prank(keeper);
        strategy.tend();

        checkStrategyTotals(
            strategy,
            _amount,
            _amount - assetBalance,
            assetBalance
        );

        vm.prank(management);
        strategy.setMaxSingleTrade(_amount * 2);
        // Should have adjusted deposit trigger an max swap
        assertEq(strategy.maxSingleTrade(), _amount * 2);
        assertGt(strategy.maxDeposit(user), 0);
        assertGt(strategy.maxWithdraw(user), 0);

        // Make sure we can still withdraw the full amount
        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertRelApproxEq(asset.balanceOf(user), balanceBefore + _amount, 10);
    }
}
