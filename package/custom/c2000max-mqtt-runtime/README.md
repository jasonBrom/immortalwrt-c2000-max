# C2000-MAX MQTT runtime closure

V35.7.3 adds the runtime libraries that were accidentally omitted when the
Mosquitto 2.0.22 client APK was merged into the image outside the normal APK
dependency resolver.

- `libcjson.so.1.7.15`: cJSON 1.7.15, SONAME `libcjson.so.1`
- `libcares.so.2.4.3`: c-ares 1.17.2, SONAME `libcares.so.2`

The AArch64/musl binaries are recovered from the same WT9303 factory firmware
used as the device compatibility reference. Both libraries are MIT licensed.
The image build checks the complete dynamic dependency closure of
`mosquitto_sub`, `mosquitto_pub`, and `libmosquitto.so.1` before packing.
