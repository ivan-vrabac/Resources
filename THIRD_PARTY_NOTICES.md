# Third-party notices

The Resources source code is MIT-licensed (see `LICENSE`). It depends on the
third-party software below, each under its own license. Release builds of the
Flutter app embed the full license texts automatically (Flutter's `LicenseRegistry`,
shown via `showLicensePage`); the Docker image installs Python packages from PyPI
with their own license files.

Audited 2026-10-18 against `app/pubspec.lock` and `server/requirements.txt`.
No GPL/LGPL/AGPL dependencies were found.

## Flutter app — direct dependencies

| Package | Version | License |
|---|---|---|
| Flutter SDK | 3.44.0 | BSD-3-Clause |
| http | 1.6.0 | BSD-3-Clause |
| shared_preferences | 2.5.6 | BSD-3-Clause |
| flutter_map | 7.0.2 | BSD-3-Clause |
| latlong2 | 0.9.1 | Apache-2.0 |
| geolocator | 13.0.4 | MIT |
| provider | 6.1.5+1 | MIT |
| flutter_local_notifications | 18.0.1 | BSD-3-Clause |
| timezone | 0.9.4 | BSD-2-Clause (bundled IANA tz data: public domain) |
| flutter_lints (dev) | 4.0.0 | BSD-3-Clause |

## Flutter app — transitive dependencies

BSD-3-Clause: args, async, boolean_selector, characters, collection, crypto, ffi, file,
fixnum, flutter_local_notifications_linux, flutter_local_notifications_platform_interface,
http_parser, intl, leak_tracker*, lints, lists, matcher, meta, path, path_provider_linux,
path_provider_platform_interface, path_provider_windows, platform, plugin_platform_interface,
polylabel, shared_preferences_* (platform packages), source_span, stack_trace,
stream_channel, string_scanner, term_glyph, test_api, typed_data, unicode, vector_math,
vm_service, web, xdg_directories.

MIT: dart_earcut, geolocator_* (platform packages), logger, mgrs_dart, nested,
petitparser, proj4dart, uuid, wkt_parser, xml.

Apache-2.0: clock, fake_async, material_color_utilities.

MPL-2.0: dbus (Linux desktop only, used unmodified; file-level copyleft does not
affect the rest of the project).

Android: `geolocator_android` uses Google Play services location, which is
proprietary and governed by the Android SDK / Google APIs terms. AndroidX
libraries are Apache-2.0. `desugar_jdk_libs` is GPL-2.0 with Classpath Exception
(linking exception; no obligation on this project's code).

## Server (Python)

| Package | Version | License |
|---|---|---|
| fastapi | 0.144.0 | MIT |
| uvicorn | 0.54.0 | BSD-3-Clause |
| httpx | 0.28.1 | BSD-3-Clause |
| python-multipart | 0.0.32 | Apache-2.0 |
| numpy | 2.5.4 | BSD-3-Clause (bundles 0BSD, MIT, Zlib, CC0 components) |
| google-auth | 2.62.0 | Apache-2.0 |

Transitive: starlette (BSD-3), pydantic / pydantic-core (MIT), anyio (MIT),
h11 (MIT), httpcore (BSD-3), idna (BSD-3), certifi (MPL-2.0, unmodified CA bundle),
click (BSD-3), cryptography (Apache-2.0 OR BSD-3), pyasn1 / pyasn1-modules (BSD-2),
cffi (MIT-0), pycparser (BSD-3), typing-extensions (PSF-2.0), annotated-types (MIT),
typing-inspection (MIT), opentelemetry-api (Apache-2.0).
Dev only: pytest (MIT), pluggy (MIT), iniconfig (MIT), packaging (Apache-2.0 OR BSD-2),
Pygments (BSD-2), colorama (BSD-3).

## Data and services

- **Map tiles**: © OpenStreetMap contributors, data under the Open Database License
  (ODbL). Tiles are fetched from `tile.openstreetmap.org`, which is subject to the
  [OSM Tile Usage Policy](https://operations.osmfoundation.org/policies/tiles/)
  (visible attribution required, no heavy use, identifying User-Agent). Public
  deployments with many users should switch to a tile provider they have an
  agreement with.
- **Firebase Cloud Messaging** (optional, disabled by default): Google APIs Terms of Service.
