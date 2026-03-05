"""Generate geographic alias table from WordNet holonym/hypernym chains.

Walks from each nucleus synset up through part_holonyms, instance_hypernyms,
and member_holonyms looking for country matches against world.bin region names.
Outputs a Zig source snippet.
"""

from nltk.corpus import wordnet as wn
import sqlite3
import struct


def load_regions():
    """Load region names from world.bin."""
    with open("viewer/data/world.bin", "rb") as f:
        buf = f.read()
    off = 0
    nr = struct.unpack_from("<I", buf, off)[0]; off += 4
    regions = {}
    for _ in range(nr):
        nl = struct.unpack_from("<H", buf, off)[0]; off += 2
        name = buf[off:off + nl].decode(); off += nl
        iso = buf[off:off + 2].decode(); off += 2
        off += 8
        np = struct.unpack_from("<H", buf, off)[0]; off += 2
        for _ in range(np):
            npts = struct.unpack_from("<I", buf, off)[0]; off += 4
            off += npts * 8
        regions[name.lower()] = name
    return regions


def build_country_synset_map(regions):
    """Map WordNet synsets to region names."""
    country_synsets = {}
    for rname_lower in regions:
        for ss in wn.synsets(rname_lower.replace(" ", "_"), pos="n"):
            country_synsets[ss] = rname_lower
    return country_synsets


def find_aliases(nuclei, regions, country_synsets, max_depth=3):
    """Walk holonym/hypernym chains from each nucleus synset."""
    results = []
    seen = set()

    for synset_name, word in nuclei:
        if word.lower() in regions:
            continue  # already a direct match

        try:
            ss = wn.synset(synset_name)
        except Exception:
            continue

        visited = set()
        frontier = [ss]
        found = False
        for depth in range(max_depth):
            if found:
                break
            next_frontier = []
            for s in frontier:
                if s in visited:
                    continue
                visited.add(s)

                if s in country_synsets and s is not ss:
                    key = (word.lower(), country_synsets[s])
                    if key not in seen:
                        seen.add(key)
                        results.append((word.lower(), country_synsets[s], depth, synset_name))
                    found = True
                    break

                for h in s.part_holonyms() + s.instance_hypernyms() + s.member_holonyms():
                    next_frontier.append(h)
            frontier = next_frontier

    return results


def main():
    regions = load_regions()
    country_synsets = build_country_synset_map(regions)

    conn = sqlite3.connect("nucleus.db")
    nuclei = conn.execute("SELECT synset, word FROM nuclei").fetchall()
    conn.close()

    results = find_aliases(nuclei, regions, country_synsets)

    # Filter out false positives — common words that happen to be inside a country
    blocklist = {
        "twin", "charles", "james", "union", "lawrence", "hudson",
        "madison", "montgomery", "clinton", "boulder", "phoenix",
        "plymouth", "portland", "helena", "fargo", "greenville",
        "huntington", "peoria", "riverside", "roanoke", "pasadena",
        "canadian",  # Canadian River, not the demonym
        "memphis",  # city in Tennessee, not Egypt
        "turkey wing",  # a plant
        "american falls",  # waterfall
        "american state",  # too generic
        "new river",  # generic river
        "gates of the arctic national park",
        "chinese wall",
        "deep south",
        "sun city",
        "right bank",  # Paris, too generic
        "west country",
        "brown university",
        "erin",  # poetic name for Ireland, too ambiguous
        "lower egypt", "lower california",
        "west malaysia",
        "center for disease control and prevention",  # CDC → Georgia (the country!)
        "nile",  # river, not Uganda
        "willamette",
        "key west",
        "johnson city",
        "lake michigan", "lake superior",
        "new britain",  # island, not UK
        "scot",  # too short/ambiguous
        "gulf of california",
    }
    results = [(w, r, d, s) for w, r, d, s in results if w not in blocklist]

    # Also add hardcoded aliases that WordNet won't find
    hardcoded = [
        # Institutions / demonyms
        ("american", "united states of america"),
        ("pentagon", "united states of america"),
        ("white house", "united states of america"),
        ("congress", "united states of america"),
        ("senate", "united states of america"),
        ("capitol", "united states of america"),
        ("democrat", "united states of america"),
        ("republican", "united states of america"),
        ("trump", "united states of america"),
        ("british", "united kingdom"),
        ("kremlin", "russia"),
        ("hamas", "palestine"),
        ("palestinian", "palestine"),
        ("european union", "belgium"),
    ]
    seen_keys = {(r[0], r[1]) for r in results}
    for alias, canonical in hardcoded:
        if (alias, canonical) not in seen_keys:
            results.append((alias, canonical, 0, "hardcoded"))

    # Group by country for readability
    by_country = {}
    for word, region, depth, syn in results:
        by_country.setdefault(region, []).append((word, depth, syn))

    print(f"// Generated by gen_geo_aliases.py — {len(results)} aliases across {len(by_country)} countries")
    print(f"// From WordNet holonym/hypernym chains + hardcoded institutions/demonyms")
    print(f"const geo_aliases = [_]struct {{ alias: []const u8, canonical: []const u8 }}{{")

    for country in sorted(by_country):
        entries = sorted(by_country[country], key=lambda x: x[0])
        print(f"    // {country.title()}")
        for word, depth, syn in entries:
            # Escape for Zig string literal
            w = word.replace("\\", "\\\\").replace('"', '\\"')
            c = country.replace("\\", "\\\\").replace('"', '\\"')
            print(f'    .{{ .alias = "{w}", .canonical = "{c}" }},')

    print("};")
    print(f"\n// Total: {len(results)} aliases")


if __name__ == "__main__":
    main()
