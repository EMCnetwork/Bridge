pragma solidity ^0.6.4;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract WETH is ERC20 {

    event Deposit(address indexed account, uint256 amount);
    event Withdrawal(address indexed account, uint256 amount);

    constructor() ERC20("Wrapped Ether", "WETH") public {}

    /**
     * @dev Fallback function that allows the contract to receive ETH.
     */
    receive() external payable {
        deposit();
    }

    /**
     * @dev Function to deposit ETH and mint WETH.
     */
    function deposit() public payable {
        require(msg.value > 0, "Must send ETH to deposit");
        _mint(msg.sender, msg.value);
        emit Deposit(msg.sender, msg.value);
    }

    /**
     * @dev Function to withdraw ETH by burning WETH.
     * @param amount The amount of WETH to burn.
     */
    function withdraw(uint256 amount) public {
        require(amount > 0, "Must withdraw more than 0");
        require(balanceOf(msg.sender) >= amount, "Not enough WETH balance");
        _burn(msg.sender, amount);
        msg.sender.transfer(amount);
        emit Withdrawal(msg.sender, amount);
    }
}
