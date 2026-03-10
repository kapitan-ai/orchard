"""Unit tests for backends.py hardened parsing."""

from __future__ import annotations

from orchard_worker_mlx.backends import decode_metadata, safe_int


# -- decode_metadata ---------------------------------------------------------


def test_decode_metadata_valid_json() -> None:
    assert decode_metadata(b'{"key": "value"}') == {"key": "value"}


def test_decode_metadata_valid_string() -> None:
    assert decode_metadata('{"key": "value"}') == {"key": "value"}


def test_decode_metadata_empty_inputs() -> None:
    assert decode_metadata(None) == {}
    assert decode_metadata(b"") == {}
    assert decode_metadata("") == {}


def test_decode_metadata_invalid_json() -> None:
    assert decode_metadata(b"not json") == {}


def test_decode_metadata_non_dict_json() -> None:
    assert decode_metadata(b'[1, 2, 3]') == {}
    assert decode_metadata(b'"just a string"') == {}


def test_decode_metadata_invalid_utf8() -> None:
    """Invalid UTF-8 bytes must not raise — return empty dict."""
    assert decode_metadata(b"\xff\xfe") == {}


# -- safe_int ----------------------------------------------------------------


def test_safe_int_valid() -> None:
    assert safe_int(42) == 42
    assert safe_int("100") == 100
    assert safe_int(0) == 0


def test_safe_int_invalid_string() -> None:
    assert safe_int("not_a_number") == 0
    assert safe_int("not_a_number", 99) == 99


def test_safe_int_none() -> None:
    assert safe_int(None) == 0
    assert safe_int(None, -1) == -1
