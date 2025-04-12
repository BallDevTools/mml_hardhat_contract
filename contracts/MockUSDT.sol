// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockUSDT
 * @dev สัญญา USDT จำลองสำหรับการทดสอบ
 */
contract MockUSDT is ERC20 {
    uint8 private _decimals = 18;

    constructor() ERC20("Mock USDT", "USDT") {
        // Mint 1,000,000 USDT to the deployer
        _mint(msg.sender, 1000000 * 10**_decimals);
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
} 