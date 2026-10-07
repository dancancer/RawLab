# Fujifilm LUT Compatibility Implementation Plan

**Goal:** Import and correctly render both supplied Fujifilm LUT packs.

**Architecture:** Internal typed CUBE transfer contract and a focused CPU adapter;
existing C ABI, generic interpolation and F-Log2 GPU implementation stay intact.

1. Add failing native acceptance and Log-output rendering checks to `core_tests`.
2. Add typed input/output transfers, F-Log curve and F-Gamut C input conversion;
   decode technical output before display blending, gate CPU-only contracts.
3. Add numerical and mode regressions, preserving old display reference tests.
4. Separate native-compatible metadata from canonical display metadata in
   `lutprep`; add classification/audit/preparation regressions.
5. Correct Mac error headings and extend native import tests in Mac/Android.
6. Update the color contract and affected usage text; build and run scoped client,
   native, Python and real-file checks. Record exact results and platform limits.

Tests use temporary files/libraries. Source LUTs and RAWs remain read-only.
User changes in `experiments/` are outside scope.
