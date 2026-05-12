"""Deterministic demo-tree generator.

Uses random.Random(seed) so the same seed yields the same tree (and
therefore the same GEDCOM bytes) on every host. The algorithm walks a
binary-ish descent: a root couple in generation 0, then 2-4 children
per couple over `generations` generations; ~80 % of adult children
marry a synthetic spouse drawn from the same name pools.
"""

from __future__ import annotations

import functools
import json
import random
from collections import deque
from importlib import resources

from webtrees_installer.gedcom import Family, GedcomDocument, Person, Sex


# Public knobs — same defaults the spec calls out.
GENERATIONS_DEFAULT = 7
ROOT_BIRTH_YEAR_DEFAULT = 1850
GENERATION_GAP_YEARS = 28

# Tunables hoisted from the algorithm. Promoting them to module
# constants keeps the BFS body declarative and makes test variants
# (different fertility, different lifespan) a one-line patch.
DEATH_RATE = 0.3                 # fraction of people who are still alive at export time
MALE_BIRTH_RATIO = 0.51          # P(child.sex == MALE) per child
MARRIAGE_RATE = 0.8              # P(adult child marries a synthetic spouse)
CHILD_COUNT_RANGE = (2, 4)       # inclusive bounds for randint per couple
LIFESPAN_RANGE = (50, 95)        # inclusive year-of-life bounds for the dead


def generate_tree(
    *,
    seed: int,
    generations: int = GENERATIONS_DEFAULT,
    root_birth_year: int = ROOT_BIRTH_YEAR_DEFAULT,
) -> GedcomDocument:
    """Build a GedcomDocument deterministically from ``seed``.

    ``generations`` must be at least 1; ``generations=1`` produces just
    the root couple, ``generations=GENERATIONS_DEFAULT`` produces
    100-400 people / 30-150 families.
    """
    if generations < 1:
        raise ValueError(f"generations must be >= 1, got {generations}")

    rng = random.Random(seed)
    pools = _load_pools()

    people: list[Person] = []
    families: list[Family] = []
    # O(1) xref → index maps so _find_person, _link_spouse and
    # _append_child are constant-time even on a deep tree.
    person_idx: dict[str, int] = {}
    family_idx: dict[str, int] = {}

    def new_person(
        *, sex: Sex, surname: str, birth_year: int,
        parents_xref: str | None,
    ) -> Person:
        xref = f"I{len(people) + 1}"
        pool = pools["male"] if sex is Sex.MALE else pools["female"]
        given = rng.choice(pool)
        death_year = (
            None if rng.random() < DEATH_RATE
            else birth_year + rng.randint(*LIFESPAN_RANGE)
        )
        person = Person(
            xref=xref, given_name=given, surname=surname, sex=sex,
            birth_year=birth_year, death_year=death_year,
            parents_xref=parents_xref, spouse_xref=None,
        )
        person_idx[xref] = len(people)
        people.append(person)
        return person

    def new_family(*, husband: Person, wife: Person, marriage_year: int) -> Family:
        xref = f"F{len(families) + 1}"
        family = Family(
            xref=xref,
            husband_xref=husband.xref,
            wife_xref=wife.xref,
            marriage_year=marriage_year,
            children_xrefs=[],
        )
        family_idx[xref] = len(families)
        families.append(family)
        return family

    def find_person(xref: str) -> Person:
        return people[person_idx[xref]]

    def link_spouse(xref: str, family_xref: str) -> None:
        idx = person_idx[xref]
        old = people[idx]
        people[idx] = Person(
            xref=old.xref, given_name=old.given_name,
            surname=old.surname, sex=old.sex,
            birth_year=old.birth_year, death_year=old.death_year,
            parents_xref=old.parents_xref, spouse_xref=family_xref,
        )

    def append_child(xref: str, child_xref: str) -> None:
        idx = family_idx[xref]
        old = families[idx]
        families[idx] = Family(
            xref=old.xref,
            husband_xref=old.husband_xref,
            wife_xref=old.wife_xref,
            marriage_year=old.marriage_year,
            children_xrefs=[*old.children_xrefs, child_xref],
        )

    # Root couple.
    root_surname = rng.choice(pools["surnames"])
    root_husband = new_person(
        sex=Sex.MALE, surname=root_surname, birth_year=root_birth_year,
        parents_xref=None,
    )
    root_wife = new_person(
        sex=Sex.FEMALE, surname=rng.choice(pools["surnames"]),
        birth_year=root_birth_year + rng.randint(-3, 3), parents_xref=None,
    )
    root_family = new_family(
        husband=root_husband, wife=root_wife,
        marriage_year=root_birth_year + 24,
    )

    link_spouse(root_husband.xref, root_family.xref)
    link_spouse(root_wife.xref, root_family.xref)

    queue: deque[tuple[Family, int]] = deque([(root_family, 0)])
    while queue:
        family, gen = queue.popleft()
        if gen + 1 >= generations:
            continue
        child_count = rng.randint(*CHILD_COUNT_RANGE)
        child_birth = family.marriage_year + 1
        for _ in range(child_count):
            child_birth += rng.randint(1, 4)
            sex = Sex.MALE if rng.random() < MALE_BIRTH_RATIO else Sex.FEMALE
            husband_record = find_person(family.husband_xref)
            child = new_person(
                sex=sex, surname=husband_record.surname,
                birth_year=child_birth, parents_xref=family.xref,
            )
            append_child(family.xref, child.xref)

            # Some adult children marry a synthetic spouse and become
            # the seed of a next-generation family.
            if (rng.random() < MARRIAGE_RATE
                    and child_birth + 22
                    < root_birth_year + generations * GENERATION_GAP_YEARS):
                if child.sex is Sex.MALE:
                    spouse = new_person(
                        sex=Sex.FEMALE,
                        surname=rng.choice(pools["surnames"]),
                        birth_year=child.birth_year + rng.randint(-3, 3),
                        parents_xref=None,
                    )
                    husband, wife = child, spouse
                else:
                    spouse = new_person(
                        sex=Sex.MALE,
                        surname=rng.choice(pools["surnames"]),
                        birth_year=child.birth_year + rng.randint(-3, 3),
                        parents_xref=None,
                    )
                    husband, wife = spouse, child

                family_marriage = child.birth_year + 24
                sub_family = new_family(
                    husband=husband, wife=wife,
                    marriage_year=family_marriage,
                )
                link_spouse(husband.xref, sub_family.xref)
                link_spouse(wife.xref, sub_family.xref)
                queue.append((sub_family, gen + 1))

    return GedcomDocument(people=people, families=families)


@functools.cache
def _load_pools() -> dict[str, list[str]]:
    """Load the bundled name pools once and cache them (data is immutable JSON)."""
    given = json.loads(
        resources.files("webtrees_installer.data").joinpath("given_names.json").read_text(),
    )
    surnames = json.loads(
        resources.files("webtrees_installer.data").joinpath("surnames.json").read_text(),
    )
    return {
        "male": given["male"],
        "female": given["female"],
        "surnames": surnames["surnames"],
    }
