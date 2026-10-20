#!/usr/bin/env python3
# Copyright (c) 2026 BlueMonkey
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
"""Linux-runnable mirror of SunshineConfigDocument parse/serialize/set/remove.

Keep cases aligned with SunshineConfigCheck.swift.
"""

from __future__ import annotations

import sys
from dataclasses import dataclass
from typing import Literal, Optional, Union


@dataclass(frozen=True)
class Blank:
    raw: str
    kind: Literal["blank"] = "blank"


@dataclass(frozen=True)
class Comment:
    raw: str
    kind: Literal["comment"] = "comment"


@dataclass(frozen=True)
class KeyValue:
    key: str
    value: str
    raw: str
    kind: Literal["key_value"] = "key_value"


@dataclass(frozen=True)
class Other:
    raw: str
    kind: Literal["other"] = "other"


Line = Union[Blank, Comment, KeyValue, Other]


def split_keeping_newlines(text: str) -> list[str]:
    if text == "":
        return []
    body = text
    if body.endswith("\r\n"):
        body = body[:-2]
    elif body.endswith("\n"):
        body = body[:-1]
    if body == "":
        return [""]
    lines = body.split("\n")
    return [ln[:-1] if ln.endswith("\r") else ln for ln in lines]


def parse_key_value(trimmed: str) -> Optional[tuple[str, str]]:
    if " = " in trimmed:
        key, value = trimmed.split(" = ", 1)
        key = key.strip()
        value = value.strip()
        if not key:
            return None
        return key, value
    if "=" in trimmed:
        key, value = trimmed.split("=", 1)
        key = key.strip()
        value = value.strip()
        if not key:
            return None
        return key, value
    return None


def classify(line: str) -> Line:
    trimmed = line.strip()
    if trimmed == "":
        return Blank(line)
    if trimmed.startswith("#") or trimmed.startswith(";"):
        return Comment(line)
    parsed = parse_key_value(trimmed)
    if parsed is not None:
        key, value = parsed
        return KeyValue(key, value, line)
    return Other(line)


@dataclass
class Document:
    lines: list[Line]

    @classmethod
    def parse(cls, text: str) -> "Document":
        return cls([classify(p) for p in split_keeping_newlines(text)])

    def serialize(self) -> str:
        if not self.lines:
            return "\n"
        body = "\n".join(line.raw for line in self.lines)
        if not body.endswith("\n"):
            body += "\n"
        return body

    def value(self, key: str) -> Optional[str]:
        for line in self.lines:
            if isinstance(line, KeyValue) and line.key == key:
                return line.value
        return None

    def set_value(self, key: str, value: str) -> None:
        rendered = f"{key} = {value}"
        found = False
        result: list[Line] = []
        for line in self.lines:
            if isinstance(line, KeyValue) and line.key == key:
                if not found:
                    result.append(KeyValue(key, value, rendered))
                    found = True
            else:
                result.append(line)
        if not found:
            if result and isinstance(result[-1], Blank):
                result.insert(-1, KeyValue(key, value, rendered))
            else:
                result.append(KeyValue(key, value, rendered))
        self.lines = result

    def remove_value(self, key: str) -> None:
        self.lines = [
            line
            for line in self.lines
            if not (isinstance(line, KeyValue) and line.key == key)
        ]


def clamp_fec(value: int) -> int:
    return min(255, max(1, value))


def clamp_port(value: int) -> int:
    return min(65535, max(1024, value))


def main() -> int:
    failures: list[str] = []

    def expect(cond: bool, msg: str) -> None:
        if not cond:
            failures.append(msg)

    text = "# header comment\nmin_log_level = info\n\nencoder = videotoolbox\nunknown_key = keepme\n"
    doc = Document.parse(text)
    expect(doc.value("min_log_level") == "info", "parse min_log_level")
    expect(doc.value("encoder") == "videotoolbox", "parse encoder")
    expect(doc.value("unknown_key") == "keepme", "parse unknown_key")
    expect(doc.value("missing") is None, "missing key is nil")
    round_trip = Document.parse(doc.serialize())
    expect(round_trip.serialize() == doc.serialize(), "round-trip serialize stable")
    expect(doc.serialize().endswith("\n"), "serialize ends with newline")
    expect("# header comment" in doc.serialize(), "preserves comment")

    doc2 = Document.parse("# keep\nencoder = software\nmin_log_level = debug\n")
    doc2.set_value("encoder", "videotoolbox")
    expect(doc2.value("encoder") == "videotoolbox", "setValue updates")
    expect("# keep" in doc2.serialize(), "setValue keeps comment")
    expect("min_log_level = debug" in doc2.serialize(), "setValue keeps other keys")
    doc2.remove_value("encoder")
    expect(doc2.value("encoder") is None, "removeValue drops key")
    expect("min_log_level = debug" in doc2.serialize(), "remove keeps others")
    expect("encoder" not in doc2.serialize(), "remove drops encoder text")

    doc3 = Document.parse("a = 1\nencoder = x\na = 2\n")
    doc3.set_value("a", "y")
    count = doc3.serialize().count("a = ")
    expect(count == 1, "setValue collapses duplicate keys")
    expect(doc3.value("a") == "y", "setValue uses new value")
    expect(doc3.value("encoder") == "x", "duplicates collapse keeps others")

    doc4 = Document([])
    doc4.set_value("min_log_level", "info")
    expect(doc4.serialize() == "min_log_level = info\n", "insert into empty")

    doc5 = Document.parse("bare=value\nspaced = v\n")
    expect(doc5.value("bare") == "value", "parse bare =")
    expect(doc5.value("spaced") == "v", "parse spaced =")

    doc6 = Document.parse("key = value with = signs\n")
    expect(doc6.value("key") == "value with = signs", "value may contain =")

    expect(clamp_fec(0) == 1, "fec clamp low")
    expect(clamp_fec(20) == 20, "fec pass-through")
    expect(clamp_fec(300) == 255, "fec clamp high")
    expect(clamp_port(80) == 1024, "port clamp low")
    expect(clamp_port(47989) == 47989, "port pass-through")
    expect(clamp_port(70000) == 65535, "port clamp high")

    if failures:
        print("FAIL:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print(f"ok ({len(failures)} failures, cases passed)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
