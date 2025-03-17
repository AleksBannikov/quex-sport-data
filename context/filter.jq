.[0] | [.Game.GameId, .Game.HomeTeamId, .Game.AwayTeamId, .Game.HomeTeamScore, .Game.AwayTeamScore, (.Goals | map([.GameMinute, .GameMinuteExtra, .TeamId]))]

