"""Tests for the GEDCOM 5.5.1 serializer."""

from webtrees_installer.gedcom import (
    Family,
    GedcomDocument,
    Person,
    Sex,
    serialize,
)


def test_serialize_minimal_document_has_header_and_trailer() -> None:
    doc = GedcomDocument(people=[], families=[])
    out = serialize(doc, submitter="Test")
    lines = out.splitlines()
    assert lines[0] == "0 HEAD"
    assert "1 GEDC" in out
    assert "2 VERS 5.5.1" in out
    assert "2 FORM LINEAGE-LINKED" in out
    assert lines[-1] == "0 TRLR"


def test_serialize_person_record() -> None:
    p = Person(
        xref="I1", given_name="Anna", surname="Müller", sex=Sex.FEMALE,
        birth_year=1880, death_year=1955, parents_xref=None, spouse_xref=None,
    )
    out = serialize(GedcomDocument(people=[p], families=[]), submitter="Test")
    assert "0 @I1@ INDI" in out
    assert "1 NAME Anna /Müller/" in out
    assert "1 SEX F" in out
    assert "1 BIRT" in out
    assert "2 DATE 1880" in out
    assert "1 DEAT" in out
    assert "2 DATE 1955" in out


def test_serialize_family_record() -> None:
    husband = Person(xref="I1", given_name="John", surname="Doe", sex=Sex.MALE,
                     birth_year=1900, death_year=None,
                     parents_xref=None, spouse_xref="F1")
    wife = Person(xref="I2", given_name="Jane", surname="Doe", sex=Sex.FEMALE,
                  birth_year=1902, death_year=None,
                  parents_xref=None, spouse_xref="F1")
    child = Person(xref="I3", given_name="Alice", surname="Doe", sex=Sex.FEMALE,
                   birth_year=1925, death_year=None,
                   parents_xref="F1", spouse_xref=None)
    fam = Family(xref="F1", husband_xref="I1", wife_xref="I2",
                 marriage_year=1924, children_xrefs=["I3"])
    out = serialize(GedcomDocument(people=[husband, wife, child], families=[fam]),
                    submitter="Test")
    assert "0 @F1@ FAM" in out
    assert "1 HUSB @I1@" in out
    assert "1 WIFE @I2@" in out
    assert "1 MARR" in out
    assert "2 DATE 1924" in out
    assert "1 CHIL @I3@" in out


def test_serialize_is_deterministic() -> None:
    """Two serializations of the same doc are byte-identical."""
    p = Person(xref="I1", given_name="X", surname="Y", sex=Sex.MALE,
               birth_year=1900, death_year=None,
               parents_xref=None, spouse_xref=None)
    doc = GedcomDocument(people=[p], families=[])
    assert serialize(doc, submitter="Test") == serialize(doc, submitter="Test")
