"""GEDCOM 5.5.1 serializer (write-only, eigenbau)."""

from __future__ import annotations

import enum
from dataclasses import dataclass, field


class Sex(enum.Enum):
    MALE = "M"
    FEMALE = "F"


@dataclass(frozen=True)
class Person:
    xref: str
    given_name: str
    surname: str
    sex: Sex
    birth_year: int
    death_year: int | None
    parents_xref: str | None
    spouse_xref: str | None


@dataclass(frozen=True)
class Family:
    xref: str
    husband_xref: str
    wife_xref: str
    marriage_year: int
    children_xrefs: list[str] = field(default_factory=list)


@dataclass(frozen=True)
class GedcomDocument:
    people: list[Person]
    families: list[Family]


def serialize(doc: GedcomDocument, *, submitter: str) -> str:
    """Render a GedcomDocument as a GEDCOM 5.5.1 string."""
    lines: list[str] = []
    lines.extend(_render_header(submitter=submitter))
    for person in doc.people:
        lines.extend(_render_person(person))
    for family in doc.families:
        lines.extend(_render_family(family))
    lines.append("0 @SUBM1@ SUBM")
    lines.append(f"1 NAME {submitter}")
    lines.append("0 TRLR")
    return "\n".join(lines) + "\n"


def _render_header(*, submitter: str) -> list[str]:
    return [
        "0 HEAD",
        "1 SOUR webtrees-installer",
        "2 NAME Webtrees Installer Demo Generator",
        "2 VERS 0.1.0",
        "1 GEDC",
        "2 VERS 5.5.1",
        "2 FORM LINEAGE-LINKED",
        "1 CHAR UTF-8",
        "1 SUBM @SUBM1@",
    ]


def _render_person(person: Person) -> list[str]:
    out = [
        f"0 @{person.xref}@ INDI",
        f"1 NAME {person.given_name} /{person.surname}/",
        f"1 SEX {person.sex.value}",
        "1 BIRT",
        f"2 DATE {person.birth_year}",
    ]
    if person.death_year is not None:
        out.append("1 DEAT")
        out.append(f"2 DATE {person.death_year}")
    if person.parents_xref is not None:
        out.append(f"1 FAMC @{person.parents_xref}@")
    if person.spouse_xref is not None:
        out.append(f"1 FAMS @{person.spouse_xref}@")
    return out


def _render_family(family: Family) -> list[str]:
    out = [
        f"0 @{family.xref}@ FAM",
        f"1 HUSB @{family.husband_xref}@",
        f"1 WIFE @{family.wife_xref}@",
        "1 MARR",
        f"2 DATE {family.marriage_year}",
    ]
    for child_xref in family.children_xrefs:
        out.append(f"1 CHIL @{child_xref}@")
    return out
