"""Deterministic demo-tree generator.

Uses random.Random(seed) so the same seed yields the same tree (and
therefore the same GEDCOM bytes) on every host. The algorithm walks a
binary-ish descent: a root couple in generation 0, then 2-4 children
per couple over `generations` generations; ~80 % of adult children
marry a synthetic spouse drawn from the same name pools.
"""

from __future__ import annotations

import json
import random
from importlib import resources

from webtrees_installer.gedcom import Family, GedcomDocument, Person, Sex


GENERATIONS_DEFAULT = 7
ROOT_BIRTH_YEAR_DEFAULT = 1850
GENERATION_GAP_YEARS = 28


def generate_tree(
    *,
    seed: int,
    generations: int = GENERATIONS_DEFAULT,
    root_birth_year: int = ROOT_BIRTH_YEAR_DEFAULT,
) -> GedcomDocument:
    """Build a GedcomDocument deterministically from ``seed``."""
    rng = random.Random(seed)
    pools = _load_pools()

    people: list[Person] = []
    families: list[Family] = []

    def new_person(
        *, sex: Sex, surname: str, birth_year: int,
        parents_xref: str | None,
    ) -> Person:
        xref = f"I{len(people) + 1}"
        pool = pools["male"] if sex is Sex.MALE else pools["female"]
        given = rng.choice(pool)
        death_year = (
            None if rng.random() < 0.3
            else birth_year + rng.randint(50, 95)
        )
        person = Person(
            xref=xref, given_name=given, surname=surname, sex=sex,
            birth_year=birth_year, death_year=death_year,
            parents_xref=parents_xref, spouse_xref=None,
        )
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
        families.append(family)
        return family

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

    # Mutate root_husband / root_wife to point at root_family.
    _link_spouse(people, root_husband.xref, root_family.xref)
    _link_spouse(people, root_wife.xref, root_family.xref)

    queue: list[tuple[Family, int]] = [(root_family, 0)]
    while queue:
        family, gen = queue.pop(0)
        if gen + 1 >= generations:
            continue
        child_count = rng.randint(2, 4)
        child_birth = family.marriage_year + 1
        for _ in range(child_count):
            child_birth += rng.randint(1, 4)
            sex = Sex.MALE if rng.random() < 0.51 else Sex.FEMALE
            husband_record = _find_person(people, family.husband_xref)
            child = new_person(
                sex=sex, surname=husband_record.surname,
                birth_year=child_birth, parents_xref=family.xref,
            )
            _append_child(families, family.xref, child.xref)

            # ~80 % marry a synthetic spouse.
            if rng.random() < 0.8 and child_birth + 22 < root_birth_year + generations * GENERATION_GAP_YEARS:
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
                _link_spouse(people, husband.xref, sub_family.xref)
                _link_spouse(people, wife.xref, sub_family.xref)
                queue.append((sub_family, gen + 1))

    return GedcomDocument(people=people, families=families)


def _load_pools() -> dict[str, list[str]]:
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


def _find_person(people: list[Person], xref: str) -> Person:
    for person in people:
        if person.xref == xref:
            return person
    raise KeyError(xref)


def _link_spouse(people: list[Person], xref: str, family_xref: str) -> None:
    for idx, person in enumerate(people):
        if person.xref == xref:
            people[idx] = Person(
                xref=person.xref, given_name=person.given_name,
                surname=person.surname, sex=person.sex,
                birth_year=person.birth_year, death_year=person.death_year,
                parents_xref=person.parents_xref, spouse_xref=family_xref,
            )
            return
    raise KeyError(xref)


def _append_child(families: list[Family], xref: str, child_xref: str) -> None:
    for idx, family in enumerate(families):
        if family.xref == xref:
            families[idx] = Family(
                xref=family.xref,
                husband_xref=family.husband_xref,
                wife_xref=family.wife_xref,
                marriage_year=family.marriage_year,
                children_xrefs=[*family.children_xrefs, child_xref],
            )
            return
    raise KeyError(xref)
