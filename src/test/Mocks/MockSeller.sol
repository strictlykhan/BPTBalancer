// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockSeller {
    function depositRewardToken(address _token, uint256 _amount) external {
        ERC20(_token).transferFrom(msg.sender, address(this), _amount);
    }
}
