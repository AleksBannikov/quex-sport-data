pragma solidity ^0.8.0;

struct Goal {
    uint8 gameMinute;        // The minute of the game when the goal was scored
    uint8 gameMinuteExtra;   // Extra time added to the minute, if applicable
    uint256 teamId;          // The ID of the team that scored the goal
}

struct MatchResult {
    uint256 gameId;          // Unique identifier for the match
    uint256 homeTeamId;      // ID of the home team
    uint256 awayTeamId;      // ID of the away team
    uint256 homeScore;       // Final score of the home team
    uint256 awayScore;       // Final score of the away team
    Goal[] goals;            // Array of goals scored in the match
}