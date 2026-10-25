class_name RSTeams
extends RefCounted
## Versus and teams for RSPartyGame: static helpers, no state of their own (the sides live in
## Player.team, the fillers in RSPartyGame.players). A game declares its mode with the
## _team_mode() hook; MODE_IDS match the module manifest's `mode` field:
##   FFA     "ffa"     各打各的: every player is its own side. The default, and then nothing here
##                     changes the round (ranking, results, points, views stay as they were).
##   VERSUS  "versus"  同场对战: two sides of one (1v1).
##   TEAMS   "teams"   组队: two sides of two (2v2).
## A game may grow the sides with the player count through _team_size(count) (table tennis:
## 1v1 for two players, 2v2 for three or four); a side never holds more than MAX_SIDE.
##
## When the countdown starts, fill() completes the sides with computer fillers on the free
## player slots (Player.filler, also `fake`: the game drives them like demo bots) and lets the
## game's _assign_teams() hook set Player.team (0 = 红队, 1 = 蓝队; default: people, then bots,
## alternate sides, fillers take the places left). Back in the lobby clear() removes the
## fillers, so joining, readiness and tournament entry never see them.
##
## Ranking: a side scores the game's _team_score(members) (default: the sum of Player.score).
## Sides are placed by it, best first, with shared places for equal scores (1, 1 between two
## sides that tie); every member takes the side's place, so all members of a side get the same
## party points (RSTournament.POINTS of that place). Fillers never write records, never get
## solo stars, never enter the tournament, and show as "电脑" in BOT_COLOR.

enum Mode { FFA, VERSUS, TEAMS }

const MODE_IDS := ["ffa", "versus", "teams"]
const NAMES := ["红队", "蓝队"]
const COLORS := [Color("ef4444"), Color("3b82f6")]
const ACCESSIBLE_COLORS := [Color("d55e00"), Color("0072b2")]   ## Okabe-Ito, for RSSettings.color_safe
const BOT_COLOR := RSUi.TEXT_MUTED       ## fillers: neutral, never a player colour
const FILLER_ID := -10                   ## filler controller id = FILLER_ID - slot (solo CPU is -1)
const MAX_SIDE := 2                      ## four local slots, two sides


static func mode_id(mode: int) -> String:
	return MODE_IDS[clampi(mode, 0, MODE_IDS.size() - 1)]


static func mode_from_id(id: String) -> int:
	return maxi(MODE_IDS.find(id), Mode.FFA)


static func default_size(mode: int) -> int:
	## Players per side for a mode (FFA has no sides).
	return [0, 1, 2][clampi(mode, 0, 2)]


static func color(team: int) -> Color:
	var colors: Array = ACCESSIBLE_COLORS if RSSettings.color_safe else COLORS
	return colors[clampi(team, 0, 1)]


static func team_name(team: int) -> String:
	return RSLang.t(NAMES[clampi(team, 0, 1)])


static func side(team: int) -> float:
	## Which end of a shared court a side plays from: +1 for 红队 (the +Z end, facing -Z, the
	## camera's default forward), -1 for 蓝队. Games place p.cam behind their own end with it.
	return -1.0 if team == 1 else 1.0


static func teamed(game: RSPartyGame) -> bool:
	return game._team_mode() != Mode.FFA


static func side_size(game: RSPartyGame, count: int) -> int:
	## Players per side for `count` players in the game's mode; 0 in FFA.
	if not teamed(game):
		return 0
	return clampi(maxi(game._team_size(count), ceili(count / 2.0)), 1, MAX_SIDE)


# --------------------------------------------------------------------------- sides ----

static func fill(game: RSPartyGame) -> void:
	## Countdown: add fillers on free slots until both sides are full, then assign the sides.
	var size := side_size(game, game.players.size())
	if size == 0:
		return
	var free: Array = []
	for slot in range(1, 5):
		if not game.ordered().any(func(p: RSPartyGame.Player) -> bool: return p.c.player == slot):
			free.append(slot)
	while game.players.size() < size * 2 and not free.is_empty():
		var c := RSController.new()
		var slot: int = free.pop_front()
		c.id = FILLER_ID - slot
		c.player = slot
		c.kind = "bot"
		c.display_name = RSLang.t("电脑")
		c.connected = true
		game._add_player(c, true, true)
	game._assign_teams(lineup(game), size)


static func clear(game: RSPartyGame) -> void:
	## Lobby: drop the fillers and forget the sides.
	for id: int in game.players.keys():
		var p: RSPartyGame.Player = game.players[id]
		if p.filler:
			game._remove_player(id)
		else:
			p.team = -1


static func lineup(game: RSPartyGame) -> Array:
	## Assignment order: people, demo bots, fillers, then other computer players (the solo
	## CPU), each by slot.
	var list := game.ordered()
	list.sort_custom(func(a: RSPartyGame.Player, b: RSPartyGame.Player) -> bool:
		var ka := _kind(a)
		var kb := _kind(b)
		return ka < kb if ka != kb else a.c.player < b.c.player)
	return list


static func _kind(p: RSPartyGame.Player) -> int:
	if not p.fake:
		return 0
	if p.filler:
		return 2
	return 1 if p.c.kind == "replay" else 3


static func assign(list: Array, size: int) -> void:
	## Default _assign_teams: everyone but the fillers alternates sides in `list` order, so
	## people play against each other (and the solo CPU against its player); fillers take the
	## places left.
	var counts := [0, 0]
	var turn := 0
	for p: RSPartyGame.Player in list:
		if p.filler:
			continue
		var t := turn if counts[turn] < size else 1 - turn
		p.team = t
		counts[t] += 1
		turn = 1 - t
	for p: RSPartyGame.Player in list:
		if p.filler:
			p.team = 0 if counts[0] < counts[1] or (counts[0] == counts[1] and counts[0] < size) else 1
			counts[p.team] += 1


static func members(game: RSPartyGame, team: int) -> Array:
	## A side's players in slot order.
	return game.ordered().filter(func(p: RSPartyGame.Player) -> bool: return p.team == team)


static func sum_score(list: Array) -> int:
	## Default _team_score: the side's total (小队合计).
	var total := 0
	for p: RSPartyGame.Player in list:
		total += p.score
	return total


static func shared_score(list: Array) -> int:
	## For games that give every member the side's own score (a rally score): count it once.
	var best := 0
	for i in list.size():
		var p: RSPartyGame.Player = list[i]
		best = p.score if i == 0 else maxi(best, p.score)
	return best


# ------------------------------------------------------------------------- ranking ----

static func ranked_teams(game: RSPartyGame) -> Array:
	## [{team, members (slot order), score, rank}], best first. Without sides (FFA, or before
	## the countdown) every player is its own entry with team -1 and its own score.
	var groups: Dictionary = {}
	var keys: Array = []
	for p: RSPartyGame.Player in game.ordered():
		var key := p.team if teamed(game) and p.team >= 0 else 10 + p.c.player
		if not groups.has(key):
			groups[key] = []
			keys.append(key)
		groups[key].append(p)
	var rows: Array = []
	for key: int in keys:
		var list: Array = groups[key]
		var first: RSPartyGame.Player = list[0]
		var sided := key < 10
		rows.append({"team": key if sided else -1, "members": list,
			"score": game._team_score(list) if sided else first.score})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["score"] != b["score"]:
			return a["score"] > b["score"]
		return (a["members"][0] as RSPartyGame.Player).c.player < (b["members"][0] as RSPartyGame.Player).c.player)
	for i in rows.size():
		rows[i]["rank"] = rows[i - 1]["rank"] if i > 0 and rows[i]["score"] == rows[i - 1]["score"] else i + 1
	return rows


static func ranked_players(game: RSPartyGame) -> Array:
	## Players in ranked_teams() order, teammates together in slot order.
	var list: Array = []
	for row: Dictionary in ranked_teams(game):
		list.append_array(row["members"])
	return list


static func places(game: RSPartyGame, list: Array) -> PackedInt32Array:
	## Each player's place in `list` (game.ranked_players() order). FFA: by score, equal scores
	## sharing the place (1, 1, 3), exactly as the results always did. With sides: the side's place.
	var result := PackedInt32Array()
	if not teamed(game):
		var rank := 1
		for i in list.size():
			if i > 0 and (list[i] as RSPartyGame.Player).score != (list[i - 1] as RSPartyGame.Player).score:
				rank = i + 1
			result.append(rank)
		return result
	var by_slot: Dictionary = {}
	for row: Dictionary in ranked_teams(game):
		for p: RSPartyGame.Player in row["members"]:
			by_slot[p.c.player] = row["rank"]
	for p: RSPartyGame.Player in list:
		result.append(int(by_slot.get(p.c.player, list.size())))
	return result


static func podium_scores(game: RSPartyGame, list: Array) -> PackedInt64Array:
	## RSPodium.present() scores for `list` (ranked_players() order): a side's score for each of
	## its members, so teammates share a step; pass places() alongside.
	var by_slot: Dictionary = {}
	for row: Dictionary in ranked_teams(game):
		for p: RSPartyGame.Player in row["members"]:
			by_slot[p.c.player] = row["score"]
	var result := PackedInt64Array()
	for p: RSPartyGame.Player in list:
		result.append(int(by_slot.get(p.c.player, p.score)))
	return result


static func grouped(game: RSPartyGame) -> bool:
	## Results list sides instead of players (a side holds more than one player).
	for p: RSPartyGame.Player in game.players.values():
		if teamed(game) and p.team >= 0 and members(game, p.team).size() > 1:
			return true
	return false


static func view_order(game: RSPartyGame) -> Array:
	## Split-screen order with sides: 红队 in the left column, 蓝队 in the right (1v1: left and
	## right halves), so each side's views sit together. Without sides: slot order.
	var list := game.ordered()
	if not teamed(game) or list.any(func(p: RSPartyGame.Player) -> bool: return p.team < 0):
		return list
	var red := members(game, 0)
	var blue := members(game, 1)
	var result: Array = []
	for i in maxi(red.size(), blue.size()):
		for side_list: Array in [red, blue]:
			if i < side_list.size():
				result.append(side_list[i])
	for p: RSPartyGame.Player in list:
		if not p in result:
			result.append(p)
	return result


# ---------------------------------------------------------------------------- text ----

static func result_lines(game: RSPartyGame) -> PackedStringArray:
	## Results entries by side: place, side name in its colour, side score; members below.
	var lines := PackedStringArray()
	for row: Dictionary in ranked_teams(game):
		var rank: int = row["rank"]
		var medal: Color = RSPodium.TRIMS[rank - 1] if rank <= RSPodium.TRIMS.size() else RSUi.TEXT_MUTED
		var names := PackedStringArray()
		for p: RSPartyGame.Player in row["members"]:
			var detail := game._result_detail(p)
			names.append("[color=#%s]P%d[/color] %s" % [game.color_of(p).to_html(false), p.c.player,
				RSProfiles.bbcode(game.name_of(p)) + ("" if detail.is_empty() else " · " + detail)])
		var team: int = row["team"]
		var label := team_name(team) if team >= 0 else "P%d" % (row["members"][0] as RSPartyGame.Player).c.player
		lines.append(RSLang.t("[font_size=30][color=#%s]第 %d 名[/color]  [color=#%s]%s[/color]  %d 分[/font_size]\n[color=#%s]%s[/color]") % [
			medal.to_html(false), rank, color(team).to_html(false) if team >= 0 else RSUi.TEXT.to_html(false), label, row["score"],
			RSUi.TEXT_MUTED.to_html(false), "   ".join(names)])
	return lines


static func lobby_line(game: RSPartyGame) -> String:
	## Lobby: the match format, e.g. "2 对 2 · 人数不够时由电脑补位".
	var size := side_size(game, game.players.size())
	if size == 0:
		return ""
	return RSLang.t("%d 对 %d · 人数不够时由电脑补位") % [size, size]
