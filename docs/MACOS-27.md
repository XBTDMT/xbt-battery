# What changed for battery apps on macOS 27

Notes from building Battery on one MacBook Pro (M4 Max) across macOS 26.6, 27.0 and 27.2. Every figure here was
measured on that machine; nothing was tested on other Macs. Builds are named so you can compare with your own.

## The charging flag goes stale between percent steps

On macOS 27.0 build 26A5425a (September 2026), the `AppleSmartBattery` registry entry refreshed only at each
percent step — about every 50 seconds while charging. Each refresh showed roughly one second of `IsCharging = Yes` at
about +3694 mA, then a frame reading `IsCharging = No` at about −1763 mA (with `NotChargingReason` 0x2000) that stayed
until the next step. Over the same three minutes, `RemainingCapacity` rose from 1421 to 1643 mAh: the battery was
charging the whole time. (On the June 27.0 beta 26A5353q, the current still tracked charging correctly.)

In the app's history (a row a minute plus one at every state change), that looked like 21 one-second "charging" bursts an hour and "discharging" for 51 of 60 minutes.
A re-measure on 14 September (still 26A5425a) saw 62 → 63% and 3323 → 3375 mAh in one minute while `Amperage` read −619 and then
−1559 mA. A later 26-minute run caught the stale frame in about a third of rows, not nearly all of them.

**On 27.2 the evidence is mixed.** Short spot checks at a low charge showed normal flags. But the app's own history
still recorded many on-power "discharging" rows next to a rising percentage after the 27.2 install, so the behaviour
has not gone away.

**What Battery does about it:** it decides "charging" from the percentage trend, not the flag. A rise while plugged in
is held for 1.5× the gap between the last two steps (90–300 s); the inflow is a least-squares fit of the capacity climb
(mAh per hour, shown in watts) over at least three steps; a confirmed hold at the charge limit overrides the trend. The flag still
counts when it is on.

## The charge-inhibit SMC key disappeared

On macOS 26, other battery tools enforce a charge limit by writing the SMC key `CHTE` and re-writing it continuously;
Battery's own single write on 26.6 was accepted but did not stop charging. On macOS 27.0, an enumeration of all 3,439 SMC
keys found no `CHTE`. Battery stopped using the SMC entirely and moved to Apple's own Charge Limit (new in macOS 26.4), driven by Shortcuts. Its helper is built so that it can't reach the SMC, and a build gate checks
that on every helper build.

## Battery keys moved into nested dictionaries

On macOS 27 the top-level `AppleRawMaxCapacity`, `DesignCapacity` and `AppleRawCurrentCapacity` keys are gone. The
values now live in the nested `BatteryData` dictionary (`FullChargeCapacity`, `DesignCapacity`, `RemainingCapacity`).
Code that reads only the top level silently loses health and capacity.

## Temperature moved, it didn't vanish

The pack temperature is no longer at the top level. It is on the child `AppleSmartBatteryPack` node's
`BatteryData.Temperature` (or `VirtualTemperature`), in hundredths of a degree (3979 → 39.79 °C).

## The charger record reads zero

`ChargerData.ChargerPower`, `ChargerIBUS` and `ChargerVBUS` read 0 on macOS 27, even mid-charge. Adapter power has to
come from elsewhere (`AdapterDetails`, and the system power-in figures in `PowerTelemetryData`).

## Two different "BatteryPower" values

`BatteryData.BatteryPower` is voltage × the same stale current as above. `PowerTelemetryData.BatteryPower` is a
separate, accumulated figure. They disagree whenever the current is stale. Battery never reads the first. Its own Draw figure is worked out the same way (voltage × sampled current), so it goes
stale too; while the percentage is rising, Draw shows the measured inflow instead.

## Reading the charge limit back: gone on one beta, then back

On a June 2026 macOS 27.0 beta, Shortcuts no longer offered the *Get Battery Charge Limit* action; the remaining *Get Battery
Status* action returned the state of charge, not the limit, so the limit could not be read back. A later 27.0 seed
offered the action again, and on macOS 27.2 it works: read 80 → set 85 → read 85 → set 80 → read 80. Battery does not
decide this by OS version: it uses read-back whenever a shortcut named `Battery Limit Get` exists, so it went back to
reading the limit back without a code change.

## Per-port power exists — with one gap

`AppleSmartBattery.PowerOutDetails` lists, for each USB-C port supplying power, its measured `FilteredPower` (mW), the
negotiated `PDPowermW`, and more. The values update with the registry's refresh. On macOS 27.2 build 26B5101f, a
charge-only device (one that never appears on the USB bus) drawing 6–12 W read `FilteredPower` 0 across three refreshes
while its `Watts` read 6.3–12.4 W and its accumulator count kept
climbing. A data device on another port read correctly at the same time.
