# Mosaicly native regression tests

Run from the repository root with Perl and its normal test dependencies:

    prove t/mosaicly_*.t t/experimental/session_v2.t

The portable suites do not require Image::Scale. Native suites skip if
Image::Scale itself is not installed; broken installed dependencies and
Mosaicly loading errors are failures, not skips.

The native tests cover original artwork formats, production-size EXIF and alpha
normalization, composition and deterministic JPEG output, failure handling,
and high-contrast resampling. Fixtures are synthetic. The restricted internal
PNG decoder is tested separately by the portable component suite.

The ordinary native formats suite verifies that progressive JPEG is rejected
without the bounded-worker assertion. Its successful progressive decode case
(six assertions) is intentionally skipped unless explicitly requested under an
external timeout and address-space limit.

On Linux, with a compatible Image::Scale on Perl's search path and GNU timeout
and prlimit available, run the full native coverage from the repository root:

    timeout -k 5s 240s prlimit --as=268435456 --core=0 -- \
      env MOSAICLY_TEST_BOUNDED_PROGRESSIVE=1 prove t/mosaicly_native_*.t

If the native Perl architecture paths must be specified, pass the appropriate
paths to prove using -I, or run each test directly with the compatible Perl
interpreter and its architecture paths under the same external bounds.

The opt-in is a caller assertion that the external timeout is enforced.
The test also checks that Linux reports finite soft and hard address-space
limits of at most 256 MiB. Never enable it in an unbounded process. These are
test-only execution controls, not a production resource policy.

The defensive suite intentionally allocates an encoded input just above
64 MiB to exercise source-size rejection. The normalization suite generates
production-sized synthetic JPEGs, including 2400 x 2400. These tests should be
run sequentially on a host with adequate available memory.

Native standalone regression tests do not replace initialized Lyrion
integration testing or real-artwork visual acceptance.
