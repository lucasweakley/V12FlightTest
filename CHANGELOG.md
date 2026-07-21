# Changelog

## v1.0

- Renamed FlightHUD to V12FlightTest
- Simplified the pitch ladder to 10° increments
- Retained the expanded ±60° ladder range
- Added a brief startup identification screen
- Added an on-screen version label
- Added README, changelog, and MIT license
- Preserved teal ARM and AIR MODE advisory states
- Preserved full-roll horizon rendering and geometric ladder clipping
- Preserved battery-only optional audio warnings

## v0.12

- Changed ARM from amber to teal
- Changed AIR MODE to a teal-filled normal-state annunciator
- Kept alternate flight modes white on black

## v0.11

- Expanded the pitch ladder to ±60°
- Added intermediate 5° rungs

## v0.10

- Removed pitch clamping
- Improved steep-pitch sky/ground behavior

## v0.9

- Integrated the horizon line with the sky/ground boundary
- Added geometric clipping for pitch ladder lines

## v0.8

- Added optional battery-only audio warnings
- Added repeating critical-battery alarm cadence

## v0.7 and earlier

- Unified horizon and ladder transforms
- Added full-roll attitude rendering
- Added yaw-rate calculation
- Added date, time, transmitter battery, annunciators, and telemetry dashboard layout
