# Changelog

## v1.1

### Added

- Added a configurable **Lamp Test** source that can be assigned to a physical or logical radio switch.
- Added a visual lamp-test mode that temporarily displays representative critical battery, link-quality, RSSI, SNR, failsafe, telemetry-loss, armed, and AIR MODE indications.
- Added remaining battery capacity in mAh to the battery panel.
- Added a fixed, screen-referenced bank-angle scale above the artificial horizon, with markings from -60° to +60° and a moving roll caret.
- Added numerical pitch-ladder labels at 20° intervals while retaining ladder lines every 10°.
- Added rate-aware color grading for LQ, SNR, and RSSI link metrics.
- Added ExpressLRS RF-mode sensitivity data so RSSI colors are based on margin above the receiver sensitivity limit rather than a single fixed RSSI threshold.
- Added special handling for ExpressLRS FLRC modes, where reported SNR cannot be graded normally.
- Added a dedicated FAILSAFE annunciator.
- Added a green normal-state BATTERY annunciator when valid battery telemetry is present and voltage is healthy.
- Added a dark empty-pack background to the battery gauge so the remaining fill level is easier to read.
- Added consistent light-gray borders around all annunciators.

### Changed

- Reworked the main dashboard to make the layout more balanced and visually symmetric.
- Enlarged the attitude display from 120×96 to 180×142 pixels and centered it between the battery and radio-link columns.
- Simplified the right-side telemetry area into three equally sized LQ, SNR, and RSSI panels.
- Combined dual-antenna RSSI readings into one RSSI display using the stronger available receiver value.
- Moved RF packet rate and transmitter power into a simplified footer strip.
- Moved consumed capacity into the battery panel and removed the separate CURRENT and USED metric boxes.
- Expanded the battery gauge vertically by removing its redundant BATTERY title from inside the panel.
- Removed the ATTITUDE title and used that space for the new bank-angle scale.
- Removed the pitch, roll, and yaw-rate text line beneath the artificial horizon to give the horizon more usable space.
- Changed pitch-ladder rung lengths so labeled 20° marks are slightly longer than intermediate 10° marks.
- Improved pitch-ladder readability by labeling only every 20° and keeping the labels upright as the ladder rotates.
- Corrected pitch displacement so the horizon and ladder move along the display’s rotated normal axis, preserving correct behavior while rolled or inverted.
- Changed the arming-state labels from **SAFE / ARM** to the Betaflight-aligned **DISARMED / ARMED** terminology.
- Changed DISARMED from green to a subdued gray inactive state.
- Consolidated the two separate LOW BAT and CRIT BAT annunciators into one state-aware **BATTERY / LOW BAT / CRITICAL BAT** annunciator.
- Renamed **CRIT BAT** to **CRITICAL BAT**.
- Kept ARMED and AIR MODE as teal normal/advisory states, while alternate flight modes remain neutral.
- Changed healthy link values to green, marginal values to amber, and critical values to red.
- Updated SNR formatting to show an explicit positive or negative sign.
- Changed the footer from antenna and downlink telemetry fields to the more immediately useful RF packet rate and transmitter-power values.
- Removed the startup splash screen so live telemetry appears immediately when the widget loads.
- Removed the on-screen version label from the footer.

### Fixed

- Prevented cached battery telemetry from producing false low- or critical-battery warnings after the CRSF telemetry link is lost.
- Prevented lamp-test values from changing cached telemetry state or triggering battery audio alarms.
- Prevented zero-height battery fills from drawing invalid or misleading fill rectangles.
- Improved artificial-horizon behavior during rolled and inverted flight by applying pitch movement in the rotated attitude coordinate system.
- Improved knife-edge horizon placement by using the pitch-adjusted horizon center.

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
