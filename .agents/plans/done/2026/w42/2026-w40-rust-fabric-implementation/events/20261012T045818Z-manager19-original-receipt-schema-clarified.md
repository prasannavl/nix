---
type: review
plan: 2026-w40-rust-fabric-implementation
coordinator: agent:rust-fabric-main
status: source-schema-clarified-runtime-unissued
---

# Original M19 worker receipt schema clarification

ROOT and packet independently counted the actual original worker success result
AST. It has exactly16 top-level fields: grant, exit, outcome, inputHashes,
codeHashes, childrenReaped, requiredGoalMet, rootOutputs, steps, commands,
details, resourceSamples, baselineQualification, cargoFresh,
provenanceQualified, defaultAdoption. This event records their complete Source
finding, not a new runtime receipt.

Frozen M19 retention supplement20261012T044818Z used the mistaken shorthand
"top-level17". Preserve that historical record. Its intent is preservation of
this exact existing16-field worker receipt and original validator, with no
invented seventeenth field or relaxed validation. The original seventeen-field O
program Source review is a distinct schema and remains unchanged. The earlier
M19 initial-case scope and all original retention/current Source/custody/gates,
helper20/native300 full charge and forced --rebuild qualification remain intact.
No current receipt/result/qualification or native arm is issued here.
