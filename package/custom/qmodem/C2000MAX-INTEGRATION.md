# C2000MAX QModem integration

This package uses FUjr/QModem 3.1.0 (`473ff8f7`) as its maintained baseline
and preserves the C2000MAX slot and RGB ownership adaptations from the
previous firmware.

The following device-independent changes were selectively ported from
sfwtw/QModem-custom v3.0.0 (`1053f73`):

- fall back to the `Model:` field returned by `ATI` when CGMM/GMM cannot match
  a modem profile;
- add the USB and PCIe profiles for Quectel RG502Q-EA;
- query Quectel firmware revision with `AT+QGMR`, with the upstream `ATI`
  parser retained as a compatibility fallback.

QModem-custom's older Qualcomm NSS/MHI bundle, Night/Viomi board GPIO
presets, forced 32 KiB USB receive buffers, QModem-HC dual-SIM control, and
changed default PDP settings were intentionally not imported. They target
other SoCs/boards, alter global dial behaviour, or have since been superseded
upstream. The maintained upstream NSS sources remain in the source tree, but
the C2000MAX firmware configuration does not select them.
