// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console.sol";
import {OperationTest, ERC20, IStrategyInterface} from "./Operation.t.sol";

contract WmaticOperationTest is OperationTest {
    function setUp() public override {
        super.setUp();

        asset = ERC20(tokenAddrs["WMATIC"]);
        pool = 0xcd78A20c597E367A4e478a2411cEB790604D7c8F;
        rewardsContract = 0x39EE6Fb813052E67260A3F95D3739B336aABD2C6;
        maxSingleTrade = 1e24;
        decimals = asset.decimals();
        minFuzzAmount = 400e18;
        maxFuzzAmount = 1e24;

        strategy = IStrategyInterface(setUpStrategy());
    }
}