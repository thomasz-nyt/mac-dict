# Third-party data and services

MacDict keeps dictionary sources visually and technically separate.

## macOS Dictionary Services

MacDict first calls Apple's public `DCSCopyTextDefinition` API. It searches dictionaries enabled by the user in the macOS Dictionary app, remains on-device, and does not redistribute their dictionary data.

- Apple API: https://developer.apple.com/documentation/coreservices/1446842-dcscopytextdefinition

## Free Dictionary API

When the active macOS dictionaries have no result, English entries are requested from [dictionaryapi.dev](https://dictionaryapi.dev/). The service currently derives English entries from Wiktionary and returns entry-level license and source URL fields. Wiktionary text is generally available under CC BY-SA 3.0 and GFDL; individual pronunciation recordings can carry separate licenses returned with the API response.

MacDict preserves source URLs and license metadata in its cache and presents source attribution in the result view. The API server implementation is GPL-3.0; MacDict calls the public service and does not incorporate its server source code.

- Project: https://github.com/meetDeveloper/freeDictionaryAPI
- Data licensing announcement: https://github.com/meetDeveloper/freeDictionaryAPI/issues/102
- Wiktionary terms: https://en.wiktionary.org/wiki/Wiktionary:Copyrights

## ECDICT

Chinese hints come from the optional [skywind3000/ECDICT](https://github.com/skywind3000/ECDICT) dataset. The repository contains an MIT `LICENSE`, but its README describes a dataset compiled from several historical sources. MacDict therefore does not commit or redistribute the database. The included installer downloads a pinned upstream snapshot directly to the user's computer, verifies its SHA-256 checksum, and records the source revision inside the generated SQLite database.

This conservative arrangement does not resolve every upstream provenance question. Do not redistribute the generated `ecdict.sqlite3` file without independently reviewing the rights of the underlying sources.

- Project: https://github.com/skywind3000/ECDICT
- Pinned revision: `bc015ed2e24a7abef49fc6dbbb7fe32c1dadaf8b`
- Snapshot SHA-256: `1a6947e04785db63613a92e14903cdae7954f7e84860b10e68e5c7cbb3f9c3cf`
