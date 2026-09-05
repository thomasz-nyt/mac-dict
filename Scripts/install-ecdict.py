#!/usr/bin/env python3
"""Download a pinned ECDICT snapshot and install a minimal local SQLite index."""

from __future__ import annotations

import argparse
import csv
import hashlib
import os
import sqlite3
import sys
import tempfile
import urllib.request
from pathlib import Path

SOURCE_COMMIT = "bc015ed2e24a7abef49fc6dbbb7fe32c1dadaf8b"
SOURCE_URL = (
    "https://raw.githubusercontent.com/skywind3000/ECDICT/"
    f"{SOURCE_COMMIT}/ecdict.csv"
)
EXPECTED_SHA256 = "1a6947e04785db63613a92e14903cdae7954f7e84860b10e68e5c7cbb3f9c3cf"
DEFAULT_DESTINATION = (
    Path.home() / "Library" / "Application Support" / "MacDict" / "ecdict.sqlite3"
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def download(destination: Path) -> None:
    print(f"Downloading ECDICT snapshot {SOURCE_COMMIT[:12]}…")
    request = urllib.request.Request(
        SOURCE_URL,
        headers={"User-Agent": "MacDict-ECDICT-Installer/0.1"},
    )
    with urllib.request.urlopen(request, timeout=60) as response, destination.open("wb") as output:
        while chunk := response.read(1024 * 1024):
            output.write(chunk)


def split_forms(exchange: str) -> set[str]:
    forms: set[str] = set()
    for component in exchange.split("/"):
        if ":" not in component:
            continue
        _, value = component.split(":", 1)
        for form in value.split(","):
            normalized = form.strip().lower()
            if normalized:
                forms.add(normalized)
    return forms


def install(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(".installing")
    temporary.unlink(missing_ok=True)

    connection = sqlite3.connect(temporary)
    try:
        connection.execute("PRAGMA journal_mode = OFF")
        connection.execute("PRAGMA synchronous = OFF")
        connection.execute(
            """
            CREATE TABLE entries (
                word TEXT PRIMARY KEY COLLATE NOCASE,
                phonetic TEXT,
                translation TEXT,
                exchange TEXT,
                frequency INTEGER
            ) WITHOUT ROWID
            """
        )
        connection.execute(
            """
            CREATE TABLE forms (
                form TEXT PRIMARY KEY COLLATE NOCASE,
                headword TEXT NOT NULL
            ) WITHOUT ROWID
            """
        )
        connection.execute("CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)")

        entries: list[tuple[str, str, str, str, int | None]] = []
        forms: dict[str, str] = {}
        count = 0

        with source.open("r", encoding="utf-8-sig", newline="") as handle:
            reader = csv.DictReader(handle)
            for row in reader:
                word = (row.get("word") or "").strip()
                if not word:
                    continue
                frequency_text = (row.get("frq") or "").strip()
                frequency = int(frequency_text) if frequency_text.isdigit() else None
                exchange = row.get("exchange") or ""
                entries.append(
                    (
                        word,
                        row.get("phonetic") or "",
                        row.get("translation") or "",
                        exchange,
                        frequency,
                    )
                )
                for form in split_forms(exchange):
                    forms.setdefault(form, word)

                if len(entries) >= 5_000:
                    connection.executemany(
                        "INSERT OR REPLACE INTO entries VALUES (?, ?, ?, ?, ?)", entries
                    )
                    entries.clear()
                count += 1

        if entries:
            connection.executemany(
                "INSERT OR REPLACE INTO entries VALUES (?, ?, ?, ?, ?)", entries
            )

        connection.executemany(
            "INSERT OR IGNORE INTO forms(form, headword) VALUES (?, ?)", forms.items()
        )
        connection.executemany(
            "INSERT INTO metadata(key, value) VALUES (?, ?)",
            [
                ("source", "skywind3000/ECDICT"),
                ("source_commit", SOURCE_COMMIT),
                ("source_url", SOURCE_URL),
                ("source_sha256", EXPECTED_SHA256),
                ("entry_count", str(count)),
            ],
        )
        connection.commit()
    finally:
        connection.close()

    os.replace(temporary, destination)
    print(f"Installed {count:,} entries at {destination}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, help="Use an existing ecdict.csv file")
    parser.add_argument("--destination", type=Path, default=DEFAULT_DESTINATION)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    downloaded: Path | None = None
    source = args.source
    try:
        if source is None:
            temporary = tempfile.NamedTemporaryFile(prefix="ecdict-", suffix=".csv", delete=False)
            temporary.close()
            downloaded = Path(temporary.name)
            download(downloaded)
            source = downloaded

        actual = sha256(source)
        if actual != EXPECTED_SHA256:
            print(
                f"ECDICT checksum mismatch: expected {EXPECTED_SHA256}, got {actual}",
                file=sys.stderr,
            )
            return 2

        install(source, args.destination.expanduser())
        return 0
    finally:
        if downloaded is not None:
            downloaded.unlink(missing_ok=True)


if __name__ == "__main__":
    raise SystemExit(main())
