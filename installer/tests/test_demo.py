"""Tests for the deterministic demo-tree generator."""

from __future__ import annotations

from webtrees_installer.demo import GENERATIONS_DEFAULT, generate_tree
from webtrees_installer.gedcom import Sex, serialize


def test_generate_tree_deterministic() -> None:
    """Same seed yields byte-identical GEDCOM output."""
    a = serialize(generate_tree(seed=42), submitter="Test")
    b = serialize(generate_tree(seed=42), submitter="Test")
    assert a == b


def test_generate_tree_different_seeds_diverge() -> None:
    """Different seeds produce different first names somewhere in the tree."""
    a = serialize(generate_tree(seed=1), submitter="Test")
    b = serialize(generate_tree(seed=2), submitter="Test")
    assert a != b


def test_generate_tree_root_couple_dates() -> None:
    """Root pair sits in generation 0 with birth year ~1850."""
    doc = generate_tree(seed=42)
    root_husband = doc.people[0]
    root_wife = doc.people[1]
    assert 1830 <= root_husband.birth_year <= 1870
    assert 1830 <= root_wife.birth_year <= 1870
    assert root_husband.sex is Sex.MALE
    assert root_wife.sex is Sex.FEMALE


def test_generate_tree_population_within_bounds() -> None:
    """7 generations with the default fertility settings produce 100-400 people."""
    doc = generate_tree(seed=42, generations=GENERATIONS_DEFAULT)
    assert 100 <= len(doc.people) <= 400
    assert 30 <= len(doc.families) <= 150
