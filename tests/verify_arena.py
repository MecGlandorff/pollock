"""Recount the release games and reproduce the local Elo estimate."""

import hashlib
import json
import random
from collections import Counter, defaultdict
from pathlib import Path


BOOTSTRAP_DRAWS = 50_000
BOOTSTRAP_SEED = 66_116_010
WHITE_POINTS = {"1-0": 1, "1/2-1/2": 0.5, "0-1": 0}


def totals(outcomes):
    return {
        "games": sum(outcomes.values()),
        "wins": outcomes[1],
        "draws": outcomes[0.5],
        "losses": outcomes[0],
        "points": outcomes[1] + outcomes[0.5] / 2,
    }


def recount(games, opponents):
    counts = {slug: Counter() for slug in opponents}
    pairs = defaultdict(dict)
    for game in games:
        opponent = game["opponent"]
        color = game["pollock_color"]
        assert opponent in counts and color in ("white", "black")
        points = WHITE_POINTS[game["result"]]
        if color == "black":
            points = 1 - points
        assert points == game["pollock_points"] and game["moves_uci"]
        pair = pairs[opponent, game["opening_number"]]
        assert color not in pair, "Duplicate game"
        pair[color] = game
        counts[opponent][points] += 1

    strata = defaultdict(list)
    used_sources = set()
    for (opponent, number), pair in sorted(pairs.items()):
        assert 1 <= number <= 8 and set(pair) == {"white", "black"}
        white, black = pair["white"], pair["black"]
        for key in ("opening_source_game", "opening_side", "start_fen", "book_plies"):
            assert white[key] == black[key], f"Mismatched {key} in opening pair"
        prefix = white["book_plies"]
        assert white["moves_uci"].split()[:prefix] == black["moves_uci"].split()[:prefix]
        assert white["opening_source_game"] not in used_sources
        used_sources.add(white["opening_source_game"])
        strata[opponent, white["opening_side"]].append(white["pollock_points"] + black["pollock_points"])

    for slug in opponents:
        for side in ("white", "black"):
            assert len(strata[slug, side]) == 4
    return {slug: totals(outcomes) for slug, outcomes in counts.items()}, totals(sum(counts.values(), Counter())), [
        values for _, values in sorted(strata.items())
    ]


def fit_elo(points, anchors):
    low, high = min(anchors) - 4000, max(anchors) + 4000
    for _ in range(48):
        rating = (low + high) / 2
        expected = sum(16 / (1 + 10 ** ((anchor - rating) / 400)) for anchor in anchors)
        if expected < points:
            low = rating
        else:
            high = rating
    return round((low + high) / 2, 3)


def quantile(values, probability):
    rank = probability * (len(values) - 1)
    index = int(rank)
    return values[index] + (values[index + 1] - values[index]) * (rank - index)


def rating_estimate(points, anchors, strata):
    randomizer = random.Random(BOOTSTRAP_SEED)
    resampled = sorted(
        sum(sum(randomizer.choices(group, k=len(group))) for group in strata)
        for _ in range(BOOTSTRAP_DRAWS)
    )
    interval = [fit_elo(quantile(resampled, p), anchors) for p in (0.025, 0.975)]
    return {
        "local_blitz_elo": fit_elo(points, anchors),
        "paired_95_elo": interval,
        "bootstrap_draws": BOOTSTRAP_DRAWS,
        "bootstrap_seed": BOOTSTRAP_SEED,
    }


def main():
    root = Path(__file__).resolve().parents[1]
    archive = json.loads((root / "arena_archive_played_games/games.json").read_bytes())
    net = root / archive["candidate"]["weights_file"]
    assert hashlib.sha256(net.read_bytes()).hexdigest() == archive["candidate"]["weights_sha256"]
    match = archive["match"]
    opponents = match["opponents"]
    assert len(opponents) == 9
    by_opponent, total, strata = recount(archive["games"], opponents)
    assert total["games"] == match["scheduled_games"] == 144 and match["totals"] == total
    for slug, record in by_opponent.items():
        assert {key: opponents[slug][key] for key in record} == record
    anchors = [opponents[slug]["ccrl_blitz_elo"] for slug in sorted(opponents)]
    assert match["estimate"] == rating_estimate(total["points"], anchors, strata)
    print(f"Verified {total['points']:g}/{total['games']} and the paired local Elo estimate")


if __name__ == "__main__":
    main()
