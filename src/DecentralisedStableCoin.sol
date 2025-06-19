// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/*
 * @title DecentralisedStableCoin
 * @author Mary
 * Collateral: Exogenus (BTC and ETH)
 * Minting: Algorithmic
 * Stability: Pegged to USD
 * @notice This contract is goverened by DSCEngine. This contract is the ERC20 implementation of the Decentralised Stable Coin (DSC).
 */

contract DecentralisedStableCoin is ERC20Burnable, Ownable {
    constructor() ERC20("DecentralisedStableCoin", "DSC") Ownable(msg.sender) {}

    //Errors
    error DecentralisedStableCoin_MustBeGreaterThanZero();
    error DecentralisedStableCoin_BurnAmountExceedsBalance();
    error DecentralisedStableCoin_ZeroAddressNotAllowed();

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);

        if (_amount <= 0) {
            revert DecentralisedStableCoin_MustBeGreaterThanZero();
        }
        if (_amount > balance) {
            revert DecentralisedStableCoin_BurnAmountExceedsBalance();
        }
        super.burn(_amount);
    }

    function mint(
        address _to,
        uint256 _amount
    ) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert DecentralisedStableCoin_ZeroAddressNotAllowed();
        }
        if (_amount <= 0) {
            revert DecentralisedStableCoin_MustBeGreaterThanZero();
        }

        _mint(_to, _amount);
        return true;
    }
}
