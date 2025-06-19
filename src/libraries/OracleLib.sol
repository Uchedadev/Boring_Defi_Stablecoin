// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
/*
 *@Title OracleLib
 *@author insecureMary
 *@notice This library is used to check the Chainlink oracle for stale data, as it is possible the data might not be updated.
 *If a price is stale, the function will revert and it will render the engine unusable.
 *We want the engine to freeze if prices become stale
 *If you have money locked in the engine and Chainlink network explodes, you are fucked.
 */

library OracleLib {
    uint256 private constant TIMEOUT = 3 hours; //This returns 3 hours in seconds

    //Error
    error OracleLib_StalePrice();

    function staleCheckLatestRoundData(
        AggregatorV3Interface priceFeed
    ) public view returns (uint80, int256, uint256, uint256, uint80) {
        (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();

        uint256 secondsSinceLastUpdate = block.timestamp - updatedAt;
        if (secondsSinceLastUpdate > TIMEOUT) {
            revert OracleLib_StalePrice();
        } else {
            return (roundId, answer, startedAt, updatedAt, answeredInRound);
        }
    }
}
