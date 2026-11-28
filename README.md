Music And Artist Information plugin for the Squeezebox ecosystem
====

This plugin for Logitech Media Server and the Squeezebox ecosystem provides additional information for your music collection: biographies, album reviews, credits, related artists etc.

The information presented by this plugin are sourced from:
* [Wikipedia](https://wikipedia.org)
* [Last.fm](https://last.fm)
* [Discogs](https://discogs.com)
* [MusicBrainz](https://musicbrainz.org)


## Experimental Mosaicly fork

This development fork adds **Mosaicly (album artwork)** to the Artist portrait
source setting. It is an experimental local deployment, not an upstream release.
Version 1.30.1.1 identifies this fork's first MVP package; it retains the
MusicArtistInfo plugin identity and must not be installed alongside another
copy of MusicArtistInfo. Mosaicly generation has been tested on Linux with
Lyrion 9.1.1, EV, GNU timeout/prlimit and cgroup v2. Other platforms and versions
are not validated for generation.

- Online retains the original online artist picture importer.
- Mosaicly generates eligible missing main-artist portraits from local album
  artwork after authenticated completion of a supported full-library scan.
  The importer must be enabled. Native local artist artwork takes precedence,
  existing portraits are preserved, and work is sequential and resource-gated.
- None disables automatic artist portrait generation without disabling native
  local artwork. Album-cover lookup and other importer options remain separate.

Changing the source does not initiate a scan or replace existing portraits.
Use an ordinary library rescan to fill missing portraits; an explicit Clear
Library and Rescan rebuilds associations using the selected source. Back up
the library and plugin settings before a rebuild. Playlist-only scans do not
authorize Mosaicly generation.

The MVP retains unreferenced generated JPEGs in the server cache after a full
rebuild. There is no automatic garbage collection yet. Do not delete referenced
files or unresolved worker/publication reservations. Candidate traversal is
deliberately paced; large libraries may take time even before the first worker
starts. Resource admission is a conservative heuristic, not an OOM guarantee.

For local installation use a versioned ZIP with install.xml at its root and
a repository XML entry naming MusicArtistInfo with the ZIP SHA-1. Verify a
separate SHA-256 checksum and pin the source revision. Preserve the previous
plugin and preferences for rollback, avoid duplicate copies, and control
automatic plugin updates to avoid replacement by an upstream version.
