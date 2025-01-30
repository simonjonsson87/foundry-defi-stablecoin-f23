// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "openzeppelin-contracts/contracts/access/ownable.sol";
import {ERC20Burnable, ERC20} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/**
 * @title DecentralisedStablecoin
 *     @author Simon Jonsson
 *     This is done as coursework for Patrick Collins' Advanced Foundry course, and is done according to instruction.
 *     The course repo is here https://github.com/Cyfrin/foundry-defi-stablecoin-cu
 *
 *     This contract is the ERC20 stablecoin. All user-facing functions are in DSCEngine.sol. This is simply the token contract.
 */
contract DecentralisedStableCoin is ERC20Burnable, Ownable {
    // errors
    error DecentralisedStableCoin__CannotBurnZero();
    error DecentralisedStableCoin__InsufficientFunds();
    error DecentralisedStableCoin__CannotMintToZeroAddress();
    error DecentralisedStableCoin__CannotMintZero();

    // Type declarations
    // State variables
    // Events
    // Modifiers

    constructor() ERC20("DecentralisedStableCoin", "DSC") {}

    function burn(uint256 amount) public override onlyOwner {
        uint256 balance = msg.sender.balance;
        if (amount == 0) {
            revert DecentralisedStableCoin__CannotBurnZero();
        }
        if (balance < amount) {
            revert DecentralisedStableCoin__InsufficientFunds();
        }
        super.burn(amount);
    }

    function mint(address to, uint256 amount) public onlyOwner returns (bool) {
        if (to == address(0)) {
            revert DecentralisedStableCoin__CannotMintToZeroAddress();
        }
        if (amount <= 0) {
            revert DecentralisedStableCoin__CannotMintZero();
        }
        _mint(to, amount);
        return true;
    }
}
