// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockTradeFactory {
    bool public enabled;
    address public strategy;
    address internal constant aura = 0x1509706a6c66CA549ff0cB464de88231DDBe213B;

    function enable(address _from, address _to) external {
        enabled = true;
        strategy = msg.sender;
    }

    function pull() external {
        uint256 balance = ERC20(aura).balanceOf(strategy);
        ERC20(aura).transferFrom(strategy, address(this), balance);
    }
}
